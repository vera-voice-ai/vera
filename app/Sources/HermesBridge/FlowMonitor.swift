import Foundation

/// The real traffic between the parts of the scheme. Every channel is a line on the board; each recorded flow
/// becomes a dot running along it. Nothing is simulated: a dot appears only when Vera saw that traffic.
public enum FlowChannel: String, CaseIterable, Hashable, Sendable {
    case windowsToAdapter      // a message or /command typed in the chat → the MacBook conversation
    case channelToAdapter      // the MacBook conversation's prompt.submit / slash.exec → the adapter
    case adapterToChannel      // a gateway event of the MacBook conversation → its card
    case telegramToChannel     // new messages of the Telegram session, read by the adapter (session.transcript) → its card
    case phoneToAdapter        // the iPhone sensor's message or voice (via Vera's phone door) → the MacBook conversation
    case adapterToPhone        // the conversation's tail → the paired iPhones
    case phoneToChannel        // the iPhone itself → its conversation card: a phrase it heard or a typed line
    case channelToPhone        // the iPhone conversation → the phone: the session's tail and state for its screen and voice
    case hermesToPhone         // Hermes' phone_route* tool → the phone's navigator (plugin vera-phone, through Vera)
    case phoneToHermes         // the navigator's answer and state → back to the tool
    case micToGate             // sound to the VAD: it heard a phrase begin
    case micToEars             // sound to the recogniser, in parallel: a piece of the phrase read (a partial text)
    case gateToEars            // the VAD's signal to the recogniser: the phrase began / ended
    case turnJudge             // sound of the phrase to Smart Turn: finished or not
    case judgeToEars           // Smart Turn's verdict to the recogniser: the phrase is closed
    case earsMerge             // the two engines' outputs joined back into one phrase
    case voiceprint            // sound of the phrase to CAM++: whose voice it is
    case voiceToAdapter        // a spoken phrase → the MacBook conversation
    case adapterToVoice        // the conversation's answer → «Голос», a sentence Vera speaks
    case adapterToHermes       // a gateway call (prompt.submit, slash.exec, model.*, session.*)
    case hermesToAdapter       // a gateway event or the agent's question
    case adapterToPulse        // a line vera-pulse broadcast, carried live by the adapter (plugin.vera-pulse.event)
    case pluginToPulse         // a line vera-pulse wrote to its journal, read from the file (history, fallback)
    case telegram              // a turn that came in through Hermes' Telegram platform
    case hermesToProvider      // a model request (llm.start)
    case providerToHermes      // a model answer or error (llm.end / llm.error)
    case hands                 // a tool call inside Hermes (tool.start)

    public var title: String {
        switch self {
        case .windowsToAdapter: "чат → разговор MacBook"
        case .channelToAdapter: "разговор MacBook → адаптер"
        case .adapterToChannel: "адаптер → разговор MacBook"
        case .telegramToChannel: "адаптер → Telegram в «Разговорах» (session.transcript)"
        case .phoneToAdapter: "iPhone → разговор MacBook"
        case .adapterToPhone: "разговор MacBook → iPhone"
        case .phoneToChannel: "iPhone → его разговор (фраза или текст)"
        case .channelToPhone: "разговор iPhone → телефон (ответ, состояние)"
        case .hermesToPhone: "Hermes → навигатор iPhone (vera-phone)"
        case .phoneToHermes: "навигатор iPhone → Hermes (ответ, состояние)"
        case .micToGate: "микрофон → VAD"
        case .micToEars: "микрофон → распознавание"
        case .gateToEars: "VAD ⇢ распознавание (начало / конец)"
        case .turnJudge: "VAD (тишина) → Smart Turn: фраза закончена?"
        case .judgeToEars: "Smart Turn ⇢ распознавание: фраза закрыта"
        case .earsMerge: "выходы движков → общая фраза"
        case .voiceprint: "микрофон → CAM++ (кто говорит)"
        case .voiceToAdapter: "фраза → разговор MacBook"
        case .adapterToVoice: "разговор → голос"
        case .adapterToHermes: "адаптер → Hermes"
        case .hermesToAdapter: "Hermes → адаптер"
        case .adapterToPulse: "адаптер → пульс (живьём)"
        case .pluginToPulse: "журнал на диске → пульс (история)"
        case .telegram: "Telegram → Hermes"
        case .hermesToProvider: "Hermes → провайдер"
        case .providerToHermes: "провайдер → Hermes"
        case .hands: "руки Hermes"
        }
    }
}

public struct FlowMonitor: Sendable {
    public init() {}
    public struct Pulse: Hashable, Sendable {
        public let channel: FlowChannel
        public let at: Date
        public let id: Int
    }

    /// Dots in flight (the last couple of seconds).
    public private(set) var pulses: [Pulse] = []
    /// Every flow of the last 10 minutes, for the per-minute counters.
    private var history: [FlowChannel: [Date]] = [:]
    private var nextId = 0

    public static let flight: TimeInterval = 1.1

    public mutating func note(_ channel: FlowChannel, count: Int = 1, now: Date = Date()) {
        // Many at once (a burst of events) still reads as a few dots, spaced a little.
        for i in 0..<min(count, 4) {
            pulses.append(Pulse(channel: channel, at: now.addingTimeInterval(Double(i) * 0.12), id: nextId))
            nextId += 1
        }
        history[channel, default: []].append(contentsOf: Array(repeating: now, count: count))
        trim(now: now)
    }

    public mutating func trim(now: Date = Date()) {
        pulses.removeAll { now.timeIntervalSince($0.at) > Self.flight }
        for (k, v) in history { history[k] = v.filter { now.timeIntervalSince($0) < 600 } }
    }

    public func perMinute(_ channel: FlowChannel, now: Date = Date()) -> Int {
        (history[channel] ?? []).filter { now.timeIntervalSince($0) < 60 }.count
    }

    public func total10m(_ channel: FlowChannel) -> Int { history[channel]?.count ?? 0 }

    /// The last `seconds` cut into `count` equal pieces, oldest first: how many flows in each (the tiles' bars).
    public func buckets(_ channel: FlowChannel, seconds: Double = 600, count: Int = 30, now: Date = Date()) -> [Int] {
        var out = Array(repeating: 0, count: count)
        let step = seconds / Double(count)
        for d in history[channel] ?? [] {
            let age = now.timeIntervalSince(d)
            guard age >= 0, age < seconds else { continue }
            out[count - 1 - min(count - 1, Int(age / step))] += 1
        }
        return out
    }

    public var active: Bool { !pulses.isEmpty }
}

/// What Hermes is made of right now: its standard parts and ours, read from the gateway (`plugins.list`,
/// `tools.list` (with the tools' names), `skills.manage list`, `cron.manage list`, `mcp.servers.list`).
public struct HermesInventory: Equatable, Sendable {
    public init() {}
    public struct Plugin: Equatable, Identifiable, Sendable {
        public var id: String { key }
        public let name: String
        /// Unique: two plugins may share a name (a model provider and an image backend both called «xai»).
        public let key: String
        public let enabled: Bool
        public let tools: Int
        public let hooks: Int
        public let error: String?
        public var ours: Bool { name.hasPrefix("vera-") }
        public var platform: Bool { name.hasSuffix("-platform") }
    }
    public struct Toolset: Equatable, Identifiable, Sendable {
        public var id: String { name }
        public let name: String
        public let enabled: Bool
        public let tools: Int
        public let description: String
        /// The tools' names (`tools.list`); empty when only counts came.
        public var toolNames: [String] = []
        /// Ours: a toolset a vera-* plugin registers (`vera_phone`).
        public var ours: Bool { name.hasPrefix("vera_") }
    }
    public struct CronJob: Equatable, Identifiable, Sendable {
        public var id: String { name }
        public let name: String
        public let schedule: String
        public let enabled: Bool
    }

    public var plugins: [Plugin] = []
    public var toolsets: [Toolset] = []
    public var skills: [String: [String]] = [:]
    public var cronJobs: [String] = []
    public var cron: [CronJob] = []
    public var mcpServers: [String] = []
    public var loaded = false

    public var ourPlugins: [Plugin] { plugins.filter(\.ours) }
    public var platforms: [Plugin] { plugins.filter(\.platform) }
    public var otherPlugins: [Plugin] { plugins.filter { !$0.ours && !$0.platform } }
    public var enabledToolsets: [Toolset] { toolsets.filter(\.enabled) }
    /// The tools our plugins add to Hermes, by name.
    public var ourTools: [String] { toolsets.filter(\.ours).flatMap(\.toolNames).sorted() }
    public var skillCount: Int { skills.values.reduce(0) { $0 + $1.count } }

    public static func from(plugins p: JSONValue?, toolsets t: JSONValue?, skills s: JSONValue?, cron c: JSONValue?, mcp m: JSONValue?) -> HermesInventory {
        var inv = HermesInventory()
        inv.plugins = (p?["plugins"]?.array ?? []).compactMap { r in
            guard let name = r["name"]?.string else { return nil }
            return Plugin(name: name, key: r["key"]?.string ?? name, enabled: r["enabled"]?.bool ?? false,
                          tools: r["tools"]?.array?.count ?? Int(r["tools"]?.number ?? 0),
                          hooks: r["hooks"]?.array?.count ?? Int(r["hooks"]?.number ?? 0),
                          error: r["error"]?.string.flatMap { $0.isEmpty ? nil : $0 })
        }.sorted { ($0.ours ? 0 : 1, $0.name) < ($1.ours ? 0 : 1, $1.name) }
        inv.toolsets = (t?["toolsets"]?.array ?? []).compactMap { r in
            guard let name = r["name"]?.string else { return nil }
            return Toolset(name: name, enabled: r["enabled"]?.bool ?? false, tools: Int(r["tool_count"]?.number ?? 0),
                           description: r["description"]?.string ?? "",
                           toolNames: r["tools"]?.array?.compactMap(\.string) ?? [])
        }
        if let obj = s?["skills"]?.object {
            for (k, v) in obj { inv.skills[k] = v.array?.compactMap(\.string) ?? [] }
        }
        inv.cronJobs = (c?["jobs"]?.array ?? []).compactMap { $0["name"]?.string ?? $0["job_id"]?.string }
        inv.cron = (c?["jobs"]?.array ?? []).compactMap { j in
            guard let name = j["name"]?.string ?? j["job_id"]?.string else { return nil }
            let schedule = j["schedule_display"]?.string ?? j["schedule"]?.string ?? j["schedule"]?["expr"]?.string ?? ""
            return CronJob(name: name, schedule: schedule, enabled: j["enabled"]?.bool ?? (j["state"]?.string != "paused"))
        }
        inv.mcpServers = (m?["servers"]?.array ?? []).compactMap { $0["name"]?.string }
        inv.loaded = true
        return inv
    }
}
