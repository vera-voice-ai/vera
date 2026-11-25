import Foundation
import Observation
import PhoneGate
import PhoneWire
import HermesBridge

/// The road between Hermes' `phone_route*` and `phone_music*` tools (plugin vera-phone) and the phone's navigator and
/// player. Transport only, no
/// decisions: the tool drops a request into `<data>/phone-bridge/commands/<id>.json`, Vera hands it to the paired
/// phone and writes the phone's answer to `results/<id>.json`; the phone's navigator state lands in `nav.json`.
/// Files, not a socket: the plugin runs inside Hermes' gateway, and the phone's port is reachable from the tunnel.
@MainActor @Observable
final class PhoneNavBridge {
    static let answerWithin: TimeInterval = 25

    let root: URL
    private let server: PhoneServer
    @ObservationIgnored private var pending: [String: Date] = [:]
    /// The scheme's dots: a request going to the phone, an answer or a state coming back.
    @ObservationIgnored var onFlow: ((FlowChannel) -> Void)?
    /// The last request and its answer, for the iPhone tile.
    private(set) var last: (what: String, answer: String?, ok: Bool?, at: Date)?
    private(set) var lastState: PhoneNav?
    @ObservationIgnored private var timer: Timer?

    var commands: URL { root.appending(path: "commands") }
    var results: URL { root.appending(path: "results") }
    var navFile: URL { root.appending(path: "nav.json") }

    init(dataRoot: URL, server: PhoneServer) {
        self.root = dataRoot.appending(path: "phone-bridge")
        self.server = server
    }

    func start() {
        for d in [commands, results] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        sweepOldResults()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let files = (try? FileManager.default.contentsOfDirectory(at: commands, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            defer { try? FileManager.default.removeItem(at: f) }
            guard let data = try? Data(contentsOf: f),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = raw["id"] as? String, let action = raw["action"] as? String else { continue }
            guard !server.peers.isEmpty else {
                answer(id, ok: false, text: "iPhone сейчас не на связи с Верой (приложение закрыто или нет сети)")
                continue
            }
            // `music.*` — the player (phone_music* tools); anything else — the navigator (phone_route*).
            let message: VeraToPhone
            if action.hasPrefix("music.") {
                let cmd = PhoneMusicCommand(id: id, action: String(action.dropFirst(6)), query: raw["query"] as? String)
                last = (Self.describe(cmd), nil, nil, Date())
                message = .music(cmd)
            } else {
                guard let cmd = PhoneWire.decode(PhoneNavCommand.self, data) else { continue }
                last = (Self.describe(cmd), nil, nil, Date())
                message = .navigate(cmd)
            }
            pending[id] = Date()
            onFlow?(.hermesToPhone)
            server.broadcast(message)
        }
        for (id, since) in pending where Date().timeIntervalSince(since) > Self.answerWithin {
            answer(id, ok: false, text: "iPhone не ответил за \(Int(Self.answerWithin)) с")
        }
    }

    /// The phone's answer to a request (the first one wins if several phones are paired).
    func result(id: String, ok: Bool, text: String) {
        guard pending[id] != nil else { return }
        onFlow?(.phoneToHermes)
        answer(id, ok: ok, text: text)
    }

    func state(_ nav: PhoneNav) {
        lastState = nav
        onFlow?(.phoneToHermes)
        try? PhoneWire.encode(nav).write(to: navFile, options: .atomic)
    }

    private func answer(_ id: String, ok: Bool, text: String) {
        pending[id] = nil
        if let l = last { last = (l.what, text, ok, Date()) }
        guard id.range(of: "^[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil else { return }
        let body: [String: Any] = ["id": id, "ok": ok, "text": text]
        if let data = try? JSONSerialization.data(withJSONObject: body) {
            try? data.write(to: results.appending(path: "\(id).json"), options: .atomic)
        }
    }

    private static func describe(_ c: PhoneNavCommand) -> String {
        switch c.action {
        case "route": "маршрут «\(c.destination ?? "")»\(c.start ? " и вести" : "")"
        case "start": "вести по маршруту"
        case "stop": "закончить навигацию"
        default: c.action
        }
    }

    private static func describe(_ c: PhoneMusicCommand) -> String {
        switch c.action {
        case "play": (c.query ?? "").isEmpty ? "музыка: «Моё любимое»" : "музыка: «\(c.query ?? "")»"
        case "pause": "музыка: пауза"
        case "resume": "музыка: дальше играть"
        case "next": "музыка: следующий трек"
        case "previous": "музыка: предыдущий трек"
        case "status": "музыка: что играет"
        default: "музыка: \(c.action)"
        }
    }

    /// Answers nobody picked up (the tool gave up) do not pile up.
    private func sweepOldResults() {
        let files = (try? FileManager.default.contentsOfDirectory(at: results, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files {
            let at = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(at) > 3600 { try? FileManager.default.removeItem(at: f) }
        }
    }
}
