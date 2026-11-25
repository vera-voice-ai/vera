import Foundation

/// What the iPhone sensor and Vera say to each other over one WebSocket (`wss://<tunnel host>/phone` through the
/// owner's tunnel, e.g. Cloudflare Tunnel, which ends at Vera's `127.0.0.1:8765`). JSON text frames; the voice goes as binary frames
/// of 16 kHz mono Int16 little-endian PCM between `voiceBegin` and `voiceEnd`. Shared by the Mac app and the phone app.
/// The phone is a sensor, not a brain: it sends what was typed or said and shows what Hermes answered.
public enum PhoneWire {
    public static let sampleRate = 16_000
    /// Where Vera listens; the tunnel forwards here. Loopback only: the outside world reaches it through the tunnel.
    public static let port: UInt16 = 8765
    /// The phone's address of Vera through the owner's tunnel: `wss://<host>/phone`. The host is the owner's own setting
    /// (Mac: `local.json` in Vera's data, phone: `VERA_TUNNEL_HOST` in `phone/Local.xcconfig`); nil when it is not set.
    public static func tunnelURL(host: String?) -> URL? {
        guard let h = host?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty,
              !h.contains("/"), !h.contains(":") else { return nil }
        return URL(string: "wss://\(h)/phone")
    }
    /// Longest voice message the phone may send in one go (seconds).
    public static let maxVoiceSeconds = 120

    public static func encode<T: Encodable>(_ value: T) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }
    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? { try? JSONDecoder().decode(type, from: data) }

    /// The QR on Vera's «iPhone» tile: where to connect and the one-time pairing code.
    public static func pairingLink(url: URL, code: String) -> URL {
        var c = URLComponents()
        c.scheme = "vera"; c.host = "pair"
        c.queryItems = [URLQueryItem(name: "url", value: url.absoluteString), URLQueryItem(name: "code", value: code)]
        return c.url!
    }

    public static func parsePairingLink(_ link: URL) -> (url: URL, code: String)? {
        guard link.scheme == "vera", link.host == "pair",
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
              let u = items.first(where: { $0.name == "url" })?.value.flatMap(URL.init(string:)),
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
        return (u, code)
    }

    public static func pcm16(_ samples: [Float]) -> Data {
        var d = Data(capacity: samples.count * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s)) * 32767).littleEndian
            withUnsafeBytes(of: &v) { d.append(contentsOf: $0) }
        }
        return d
    }

    public static func floats(_ pcm: Data) -> [Float] {
        pcm.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count - 1, by: 2).map {
                Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: Int16.self))) / 32767
            }
        }
    }
}

/// Phone → Vera.
public enum PhoneToVera: Codable, Equatable, Sendable {
    /// First contact: the code from the QR, and a name for the device. Answered by `paired(token:)` or `refused`.
    case pair(code: String, device: String)
    /// Every later connection starts with the token the phone keeps in its Keychain.
    case hello(token: String, device: String)
    case say(text: String)
    /// A phrase the phone's own ears heard and recognised (GigaAM on the phone): goes to Hermes as a spoken message.
    case spoken(text: String)
    case voiceBegin
    case voiceEnd
    case voiceCancel
    case interrupt
    /// The answer to a request from Hermes — `navigate` or `music`: what the phone did, a short sentence for Hermes;
    /// `ok` false on failure. (One answer for both: Vera's bridge matches it by the request's id.)
    case navResult(id: String, ok: Bool, text: String)
    /// The navigator's state, on every change of phase and every minute while guiding.
    case nav(PhoneNav)
    /// What the phone's conversation is doing now (`off`, `starting`, `listening`, `hearing`, `thinking`, `speaking`)
    /// and whether listening is paused — on every change; Vera's board draws it on the iPhone tile.
    case talk(stage: String, paused: Bool)
}

/// Vera → phone.
public enum VeraToPhone: Codable, Equatable, Sendable {
    case paired(token: String)
    case welcome(title: String?)
    case refused(reason: String)
    /// The tail of the main conversation («Разговор»), whole each time it changes.
    case items([PhoneItem])
    case state(PhoneState)
    /// What the ears made of the phone's voice message (already sent on to Hermes).
    case heard(text: String)
    /// What Hermes is doing for the phone's session, from Vera's pulse (the phone's board draws it).
    case hermes(PhoneHermes)
    case problem(text: String)
    /// A request from Hermes' `phone_route*` tools (plugin vera-phone), forwarded by Vera; answered by `navResult`.
    case navigate(PhoneNavCommand)
    /// A request from Hermes' `phone_music*` tools (plugin vera-phone), forwarded by Vera; answered by `navResult`.
    case music(PhoneMusicCommand)
}

/// Hermes asks the phone's player: `play` (`query` — an artist, an album or a track, as said; empty — «Моё любимое»),
/// `pause`, `resume`, `next`, `previous`, `status` (what plays now).
public struct PhoneMusicCommand: Codable, Equatable, Sendable {
    public let id: String
    public let action: String
    public let query: String?
    public init(id: String, action: String, query: String? = nil) {
        self.id = id; self.action = action; self.query = query
    }
}

/// Hermes asks the phone's navigator: `route` (find the place, build the route; `start` — and go),
/// `start` (go along the route that is built), `stop` (end the guidance, clear the route).
public struct PhoneNavCommand: Codable, Equatable, Sendable {
    public let id: String
    public let action: String
    public let destination: String?
    public let start: Bool
    public init(id: String, action: String, destination: String? = nil, start: Bool = false) {
        self.id = id; self.action = action; self.destination = destination; self.start = start
    }
}

/// The phone's navigator as it is now: `idle`, `routing`, `ready`, `guiding`, `arrived`, `failed`, or `unavailable`
/// (no Google key on the phone).
public struct PhoneNav: Codable, Equatable, Sendable {
    public let phase: String
    public let destination: String?
    public let address: String?
    public let remainingSeconds: Double?
    public let remainingMeters: Double?
    public let nextStep: String?
    public let problem: String?
    public let at: Double
    public init(phase: String, destination: String?, address: String?, remainingSeconds: Double?, remainingMeters: Double?,
                nextStep: String?, problem: String?, at: Double) {
        self.phase = phase; self.destination = destination; self.address = address; self.remainingSeconds = remainingSeconds
        self.remainingMeters = remainingMeters; self.nextStep = nextStep; self.problem = problem; self.at = at
    }
}

public struct PhoneItem: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant, tool, notice, output, error }
    public let id: Int
    public let role: Role
    public let text: String
    public let done: Bool
    public init(id: Int, role: Role, text: String, done: Bool) { self.id = id; self.role = role; self.text = text; self.done = done }
}

public struct PhoneState: Codable, Equatable, Sendable {
    /// Vera is attached to Hermes' gateway.
    public let connected: Bool
    /// Hermes is working on a turn.
    public let running: Bool
    public let thinking: String?
    public init(connected: Bool, running: Bool, thinking: String?) { self.connected = connected; self.running = running; self.thinking = thinking }
}

/// Hermes as the phone's board shows it: real data from the pulse of the phone's own session, never a guess.
public struct PhoneHermes: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        /// `llm`, `tool`, `subagent`, `human`.
        public let kind: String
        public let name: String
        public let ms: Double?
        public let ok: Bool
        public let at: Double
        public init(kind: String, name: String, ms: Double?, ok: Bool, at: Double) {
            self.kind = kind; self.name = name; self.ms = ms; self.ok = ok; self.at = at
        }
    }
    public let model: String?
    public let provider: String?
    /// In flight now in this session: "думает" or a tool's name.
    public let now: [String]
    public let turns: Int
    public let llmCalls: Int
    public let toolCalls: Int
    /// The last finished steps of this session, oldest first.
    public let steps: [Step]
    public init(model: String?, provider: String?, now: [String], turns: Int, llmCalls: Int, toolCalls: Int, steps: [Step]) {
        self.model = model; self.provider = provider; self.now = now
        self.turns = turns; self.llmCalls = llmCalls; self.toolCalls = toolCalls; self.steps = steps
    }
}
