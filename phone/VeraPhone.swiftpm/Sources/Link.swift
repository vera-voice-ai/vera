import Foundation
import Network
import Observation
import PhoneWire
import Security

/// The phone's line to Vera: one WebSocket (`wss://<tunnel host>/phone` through the owner's tunnel). Pairs once with the
/// code from the QR, then says hello with its token on every connect; reconnects by itself. Holds what Vera sends:
/// the session's tail and whether Hermes is working. Nothing is decided here — the phone is a sensor.
@MainActor @Observable
final class Link {
    enum Phase: Equatable { case unpaired, connecting, online, offline(String) }

    private(set) var phase: Phase = .unpaired
    private(set) var items: [PhoneItem] = []
    private(set) var state = PhoneState(connected: false, running: false, thinking: nil)
    private(set) var heard: String?
    /// What Hermes does in the phone's session (from Vera's pulse).
    private(set) var hermes: PhoneHermes?
    /// Round trip phone → tunnel → Vera and back, ms (a WebSocket ping every 10 s).
    private(set) var rttMs: Int?
    /// When something last went each way — the board's flow dots.
    private(set) var sentAt: Date?
    private(set) var receivedAt: Date?
    private(set) var problem: String?
    /// Every new tail of the session (the conversation speaks the answers from it).
    @ObservationIgnored var onItems: (([PhoneItem]) -> Void)?
    /// A request from Hermes for the navigator (plugin vera-phone, through Vera).
    @ObservationIgnored var onNavigate: ((PhoneNavCommand) -> Void)?
    /// A request from Hermes for the player (plugin vera-phone, through Vera).
    @ObservationIgnored var onMusic: ((PhoneMusicCommand) -> Void)?
    /// Vera let the phone in (after every connect): what it should know about the phone again.
    @ObservationIgnored var onWelcome: (() -> Void)?

    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var retry = 1.0
    @ObservationIgnored private var pendingPair: String?
    /// The phone's network: when it comes back or changes (Wi-Fi ↔ cellular), the line is rebuilt at once instead of
    /// waiting for the old socket to die or for the next retry.
    @ObservationIgnored private let path = NWPathMonitor()
    @ObservationIgnored private var lastPath: (ok: Bool, wifi: Bool, cell: Bool)?
    /// A connect that got no answer (welcome) in this time is dropped and tried again.
    static let connectTimeout = 10.0
    /// Pings in a row without a pong before the line counts as dead.
    static let pingMisses = 2

    let device: String

    init(device: String) {
        self.device = device
        path.pathUpdateHandler = { [weak self] p in
            let now = (ok: p.status == .satisfied, wifi: p.usesInterfaceType(.wifi), cell: p.usesInterfaceType(.cellular))
            Task { @MainActor in self?.networkChanged(now) }
        }
        path.start(queue: DispatchQueue(label: "vera.link.path"))
        if Keychain.token != nil { connect() }
    }

    private func networkChanged(_ now: (ok: Bool, wifi: Bool, cell: Bool)) {
        defer { lastPath = now }
        guard paired, now.ok, let was = lastPath else { return }
        let switched = !was.ok || was.wifi != now.wifi || was.cell != now.cell
        guard switched else { return }
        // The network is back or another one: a socket opened on the old one is as good as dead.
        retry = 1
        connect()
    }

    var paired: Bool { Keychain.token != nil }
    /// Where Vera is: the address from the QR, or — for a typed code — the build's own tunnel host
    /// (`VERA_TUNNEL_HOST` in phone/Local.xcconfig → Info.plist `VeraTunnelHost`).
    var url: URL? { Keychain.url.flatMap(URL.init(string:)) ?? Self.builtInURL }
    static let builtInURL = PhoneWire.tunnelURL(host: Bundle.main.object(forInfoDictionaryKey: "VeraTunnelHost") as? String)

    // MARK: Pairing

    /// From the QR (`vera://pair?url=…&code=…`) or a typed code.
    func pair(link: URL) -> Bool {
        guard let p = PhoneWire.parsePairingLink(link) else { return false }
        Keychain.url = p.url.absoluteString
        pendingPair = p.code
        connect()
        return true
    }

    func pair(code: String) {
        pendingPair = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        connect()
    }

    func unpair() {
        Keychain.token = nil
        disconnect()
        items = []
        phase = .unpaired
    }

    // MARK: Connection

    func connect() {
        guard paired || pendingPair != nil else { phase = .unpaired; return }
        // No address: a typed code on a build without VERA_TUNNEL_HOST — pairing goes by the QR, which carries it.
        guard let url else { pendingPair = nil; phase = .unpaired; return }
        disconnect()
        generation += 1
        let gen = generation
        phase = .connecting
        let t = URLSession.shared.webSocketTask(with: url)
        t.maximumMessageSize = 8 * 1024 * 1024
        task = t
        t.resume()
        if let code = pendingPair {
            send(.pair(code: code, device: device))
        } else if let token = Keychain.token {
            send(.hello(token: token, device: device))
        }
        Task { await receive(t, gen) }
        Task { await pinging(t, gen) }
        Task {
            try? await Task.sleep(for: .seconds(Self.connectTimeout))
            if gen == generation, phase == .connecting { drop(gen, "Мак не ответил за \(Int(Self.connectTimeout)) с") }
        }
    }

    /// Gives up on this socket and starts the reconnect (the backoff in `lost`).
    private func drop(_ gen: Int, _ why: String) {
        guard gen == generation else { return }
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        lost(why)
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// The app came back to the foreground: reconnect now if the line is down.
    func wake() {
        if case .online = phase { return }
        retry = 1
        if paired { connect() }
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) async {
        while gen == generation {
            do {
                let m = try await t.receive()
                let data: Data
                switch m {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: continue
                }
                if let msg = PhoneWire.decode(VeraToPhone.self, data) { handle(msg) }
            } catch {
                guard gen == generation else { return }
                lost(error.localizedDescription)
                return
            }
        }
    }

    private func handle(_ m: VeraToPhone) {
        receivedAt = Date()
        switch m {
        case .paired(let token):
            Keychain.token = token
            pendingPair = nil
            phase = .online; retry = 1; problem = nil
        case .welcome:
            phase = .online; retry = 1; problem = nil
            onWelcome?()
        case .refused(let reason):
            if pendingPair != nil { pendingPair = nil } else { Keychain.token = nil }
            problem = reason
            phase = .unpaired
            generation += 1
            disconnect()
        case .items(let list):
            if phase != .online { phase = .online; retry = 1 }
            items = list
            onItems?(list)
        case .state(let s): state = s
        case .hermes(let h): hermes = h
        case .heard(let text): heard = text
        case .problem(let text): problem = text
        case .navigate(let c): onNavigate?(c)
        case .music(let c): onMusic?(c)
        }
    }

    private func lost(_ why: String) {
        task = nil
        guard paired else { phase = .unpaired; problem = why; return }
        phase = .offline(why)
        let wait = retry
        retry = min(retry * 2, 8)   // a short ceiling: the tunnel usually comes back in seconds
        let gen = generation
        Task {
            try? await Task.sleep(for: .seconds(wait))
            if gen == generation, paired { connect() }
        }
    }

    // MARK: Sending

    /// A ping every 10 s; a pong that does not come in 5 s is a miss, and two misses in a row mean the line is dead
    /// (a socket left over from another network, or a tunnel that dropped it quietly) — reconnect then.
    private func pinging(_ t: URLSessionWebSocketTask, _ gen: Int) async {
        var misses = 0
        while gen == generation {
            let t0 = Date()
            // URLSession may call the pong handler more than once when the line drops: resume only the first time.
            let ok: Bool = await withCheckedContinuation { c in
                let once = Once()
                t.sendPing { error in if once.first() { c.resume(returning: error == nil) } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if once.first() { c.resume(returning: false) } }
            }
            guard gen == generation else { return }
            if ok {
                misses = 0
                rttMs = Int(Date().timeIntervalSince(t0) * 1000)
            } else {
                misses += 1
                if misses >= Self.pingMisses { drop(gen, "нет ответа от Мака \(misses * 10) с"); return }
            }
            try? await Task.sleep(for: .seconds(ok ? 10 : 3))
        }
    }

    /// `done` (on the main actor): nil — the socket took it; else why not (no socket, or the send failed).
    func send(_ m: PhoneToVera, done: (@MainActor (String?) -> Void)? = nil) {
        if case .say = m { sentAt = Date() }
        if case .spoken = m { sentAt = Date() }
        guard let task else { done?("нет соединения"); return }
        task.send(.string(String(decoding: PhoneWire.encode(m), as: UTF8.self))) { error in
            let why = error?.localizedDescription
            Task { @MainActor in done?(why) }
        }
    }

    func sendAudio(_ pcm: Data) {
        task?.send(.data(pcm)) { _ in }
    }

    func say(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        send(.say(text: t))
    }
}

/// The token and the address live in the Keychain, this device only.
enum Keychain {
    private static let service = "space.vera.v03.phone"

    static var token: String? {
        get { read("token") }
        set { write("token", newValue) }
    }
    static var url: String? {
        get { read("url") }
        set { write("url", newValue) }
    }
    /// The Google Maps Platform key for the navigator — entered by the owner in Settings, never in the code.
    static var mapsKey: String? {
        get { read("mapsKey") }
        set { write("mapsKey", newValue) }
    }

    private static func read(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func write(_ key: String, _ value: String?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard let value else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// True exactly once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
