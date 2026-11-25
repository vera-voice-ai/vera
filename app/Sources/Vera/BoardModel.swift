import Foundation
import Observation
import HermesBridge

/// Everything the board shows about Hermes: the install, the lock, the gateway link and the pulse.
@MainActor @Observable
final class BoardModel {
    enum GatewayState: Equatable {
        case idle
        case muted
        case attaching
        case connected
        case failed(String)

        var title: String {
            switch self {
            case .idle: "ожидание"
            case .muted: "отключено (--mute)"
            case .attaching: "подключение…"
            case .connected: "подключено"
            case .failed(let r): "нет связи · \(r)"
            }
        }
    }

    struct GatewayEventStat: Equatable {
        var count = 0
        var lastAt = Date.distantPast
    }

    private(set) var install: HermesInstall?
    private(set) var lock: HermesLock?
    private(set) var lockStatus: LockStatus = .unknown
    private(set) var gatewayState: GatewayState = .idle
    private(set) var endpoint: GatewayAttachResult.Endpoint?
    private(set) var gatewayProtocol: String?
    private(set) var gatewayURL: String?
    private(set) var readyPayloadKeys: [String] = []
    private(set) var describeCapabilities: [String] = []
    private(set) var gatewayEvents: [String: GatewayEventStat] = [:]
    private(set) var connectedAt: Date?
    /// Observation: the journal, its summary and the turns (`PulseState`) — the board's «Пульс».
    var pulse = PulseState()
    /// Real traffic on the scheme's lines (dots on the board).
    private(set) var flows = FlowMonitor()
    /// Hermes' standard parts and ours, read from the gateway every half minute.
    private(set) var inventory = HermesInventory()
    @ObservationIgnored private var pulseBacklogSeen = false
    /// When the last journal line came live through the gateway (`plugin.vera-pulse.event`); nil before the first.
    private(set) var pulseLiveAt: Date?
    /// Ids of the journal lines already taken, bounded: a line can arrive live and again from the file tail.
    @ObservationIgnored private var seenPulseIds = Set<String>()
    @ObservationIgnored private var seenPulseOrder: [String] = []
    static let seenPulseLimit = 2000
    /// Live through the gateway in the last two minutes: the «Пульс» header says so; otherwise it reads the file.
    var pulseLive: Bool { pulseLiveAt.map { Date().timeIntervalSince($0) < 120 } ?? false }
    /// What Vera's Hermes keeps on disk (memory tile), measured every half minute.
    private(set) var dataUsage = DataUsage()
    /// Which skills Hermes really used (`skills/.usage.json`).
    private(set) var skillUsage = SkillUsage()
    /// Conversations Hermes holds (stored + live), from `session.list`.
    private(set) var sessionCount: Int?
    /// The adapter's last gateway call: method and time.
    private(set) var lastCall: (method: String, at: Date)?
    /// The adapter's last calls to the gateway: method, when, how long, whether it failed (newest last).
    struct CallRecord: Identifiable { let id = UUID(); let method: String; let at: Date; var ms: Double?; var failed = false }
    private(set) var recentCalls: [CallRecord] = []

    /// «Жизнь»: activity by day × hour, today's model calls, how the data grows, the conversations in time.
    var activity = LifeHistory.Grid()
    var modelCalls: [LifeHistory.ModelCall] = []
    var usageHistory: [LifeHistory.UsagePoint] = []
    struct Conversation: Identifiable, Equatable { let id: String; let ts: Double; let source: String; let messages: Int; let title: String }
    var conversations: [Conversation] = []
    /// Hermes' messaging platforms as its gateway records them (`gateway_state.json` → platforms): state and error.
    struct PlatformState: Equatable { let state: String; let error: String?; var updatedAt: Date? = nil }
    /// Connecting the bot, step by step, for the Telegram tile (nil — nothing in progress): saving, restarting the
    /// gateway, waiting for Hermes to reach Telegram (≈ 30 s). Ends when `gateway_state.json` says so.
    var telegramPhase: String?
    var platformStates: [String: PlatformState] = [:]
    /// Whether a Telegram bot token is set in Hermes (never the token) and how many users are allowed.
    var telegramToken: Bool?
    /// Hermes' home channels (`/sethome`): platform → the home's name. Where cron results and cross-platform messages go.
    var homeChannels: [String: String] = [:]
    var telegramAllowed = 0
    /// The Telegram conversation itself — Hermes' session, read by the adapter with `session.transcript` (a stored read
    /// that never attaches): right after a pulse line of that session comes in, and with the inventory every half minute.
    private(set) var telegramChat = ChatTranscript()
    private(set) var telegramSessionId: String?
    /// `session.list` (stored scope) takes at most this many rows per page.
    static let storedPage = 200
    private(set) var telegramReadAt: Date?
    /// The Telegram session the pulse saw last (newer than `session.list` between inventories).
    @ObservationIgnored private var telegramLiveSession: String?
    @ObservationIgnored private var telegramReadQueued = false
    /// The newest stable Hermes on GitHub (checked at most every 6 h; nil — not known) and when it was checked.
    var latestHermes: String?
    var latestCheckedAt: Date?
    /// What is in the box besides Hermes: the ears' and the mouth's pinned versions (from the bundle's locks).
    var boxVersions: [String: String] = [:]

    func noteFlow(_ channel: FlowChannel, count: Int = 1, at: Date = Date()) { flows.note(channel, count: count, now: at) }
    func trimFlows() { flows.trim() }
    var pulseDirectory: URL { runtime.pulseDirectory }
    private(set) var bootstrapNotes: [String] = []

    let muted: Bool
    /// Hermes inside Vera (payload) and Vera's own data; nothing else on the machine is used.
    let runtime = HermesRuntime.resolve()
    private let client = GatewayClient()
    /// Conversations open in Vera's windows. Events go to every one (each keeps its own session's); the agent's
    /// question goes only to the window whose session asked, and is refused when no window has that session open.
    @ObservationIgnored private var sinks: [WeakSink] = []
    private struct WeakSink { weak var sink: ChatModel? }

    func addSink(_ chat: ChatModel) { sinks.append(WeakSink(sink: chat)) }
    /// What Vera and her Hermes cost the machine (memory, CPU), every 2 s.
    private(set) var resources: ProcessResources.Reading?
    @ObservationIgnored private var resourcesBefore: ProcessResources.Snapshot?
    /// The current provider's plan limits (5 h / week / month…), as Hermes reads them, every 5 minutes.
    private(set) var accountUsage: AccountUsage?
    private(set) var accountUsageAt: Date?
    private let feed: PulseFeed
    private var tasks: [Task<Void, Never>] = []

    init(muted: Bool) {
        self.muted = muted
        feed = PulseFeed(directory: runtime.pulseDirectory)
        if let url = HermesLock.find() { lock = try? HermesLock.load(url) }
        if muted { gatewayState = .muted }
    }

    func start() {
        guard !muted, tasks.isEmpty else { return }
        tasks.append(Task {
            await self.locate()
            if self.install != nil { self.bootstrapNotes = await HermesBootstrap.ensure(self.runtime) }
            await self.runGateway()
        })
        tasks.append(Task {
            while !Task.isCancelled {
                if self.gatewayState == .connected { await self.refreshInventory() }
                try? await Task.sleep(for: .seconds(self.inventory.loaded ? 30 : 4))
            }
        })
        tasks.append(Task {
            while !Task.isCancelled {
                await self.sampleResources()
                try? await Task.sleep(for: .seconds(2))
            }
        })
        tasks.append(Task {
            while !Task.isCancelled {
                if self.gatewayState == .connected { await self.refreshAccountUsage() }
                try? await Task.sleep(for: .seconds(self.accountUsageAt == nil ? 5 : 300))
            }
        })
        tasks.append(Task {
            await self.feed.start()
            for await batch in self.feed.events { self.takeFile(batch) }
        })
    }

    var pluginSilent: Bool { pulse.events.isEmpty }

    private func sampleResources() async {
        var roots: [(name: String, pid: Int32)] = [("Вера", getpid())]
        if let gw = ProcessResources.gatewayPID(hermesHome: runtime.hermesHome) { roots.append(("Hermes", gw)) }
        let now = ProcessInfo.processInfo.systemUptime
        let snap = await Task.detached(priority: .utility) { ProcessResources.takeSnapshot(at: now, roots: roots) }.value
        resources = ProcessResources.summarize(snap, previous: resourcesBefore)
        resourcesBefore = snap
    }

    /// `plugin.vera-setup.account_usage`: Hermes asks its provider for the plan limits (up to ~10 s).
    func refreshAccountUsage() async {
        guard let v = try? await client.call("plugin.vera-setup.account_usage", params: .object([:]), timeout: .seconds(20)) else { return }
        accountUsage = AccountUsage(v)
        accountUsageAt = Date()
    }

    private func locate() async {
        install = await HermesLocator.locate(runtime)
        refreshLock()
    }

    private func refreshLock() {
        lockStatus = LockStatus.check(lock: lock, install: install, gatewayCodeSha: endpoint?.codeSha, gatewayProtocol: gatewayProtocol)
    }

    /// Attach, read `gateway.ready`, ask `runtime.describe`, then count every event; on loss, retry every 5 s.
    private func runGateway() async {
        let incoming = Task { for await frame in client.incoming { self.handle(frame) } }
        defer { incoming.cancel() }
        while !Task.isCancelled {
            if gatewayState != .connected {
                await connectOnce()
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func connectOnce() async {
        gatewayState = .attaching
        if install == nil { install = await HermesLocator.locate(runtime) }
        guard install != nil else { gatewayState = .failed("нет пакета Hermes: scripts/build-hermes.sh"); return }
        do {
            let attach = try await GatewayAttach.attach(runtime)
            endpoint = attach.endpoint
            gatewayProtocol = attach.protocol
            gatewayURL = attach.url
            refreshLock()
            guard attach.isReady else {
                gatewayState = .failed("\(attach.state) \(attach.reasonCode ?? "")")
                return
            }
            try await client.connect(attach)
            gatewayState = .connected
            connectedAt = Date()
            let describe = try? await client.call("runtime.describe")
            describeCapabilities = describe?["capabilities"]?.array?.compactMap(\.string) ?? []
            // Vera answers approvals and clarify questions in her chat; everything else is refused by the client.
            await client.setAnswering(true)
            _ = try? await client.call("client.capabilities", params: .object(["server_requests": .bool(true)]))
        } catch {
            gatewayState = .failed(String(describing: error).prefix(80).description)
        }
    }

    /// A gateway method for the setup window. Only while connected.
    func call(_ method: String, _ params: [String: JSONValue], timeout: Duration = .seconds(15)) async throws -> JSONValue {
        guard gatewayState == .connected else { throw GatewayClient.CallError.notConnected }
        noteFlow(.adapterToHermes)
        let start = Date()
        lastCall = (method, start)
        var rec = CallRecord(method: method, at: start)
        defer {
            rec.ms = Date().timeIntervalSince(start) * 1000
            recentCalls.append(rec)
            if recentCalls.count > 20 { recentCalls.removeFirst(recentCalls.count - 20) }
        }
        do { return try await client.call(method, params: .object(params), timeout: timeout) }
        catch { rec.failed = true; throw error }
    }

    func respond(id: JSONValue, result: JSONValue) async { await client.respond(id: id, result: result) }
    func refuse(id: JSONValue, message: String) async { await client.refuse(id: id, message: message) }

    /// `hermes gateway stop`, then the usual attach (`--recover`) starts a fresh one.
    func restartGateway() async {
        guard install != nil else { return }
        await client.disconnect(reason: "перезапуск")
        gatewayState = .attaching
        _ = try? await ProcessRunner.run(runtime.binary, ["gateway", "stop"], environment: runtime.environment)
        await connectOnce()
    }

    /// The latest thing that went wrong, for the board's bottom line: no gateway, or a model error in the last hour.
    var lastProblem: String? {
        if case .failed(let r) = gatewayState { return "шлюз: \(r)" }
        if let e = pulse.events.last(where: { $0.kind == "llm.error" }), Date().timeIntervalSince1970 - e.ts < 3600 {
            return "ошибка модели \(Format.ago(e.ts, now: Date())): \([e.status, e.detail].compactMap { $0 }.joined(separator: " · "))"
        }
        return nil
    }

    var pluginState: String {
        if !bootstrapNotes.isEmpty { return bootstrapNotes.joined(separator: "; ") }
        let linked = HermesRuntime.pluginNames.filter {
            FileManager.default.fileExists(atPath: runtime.pluginLink($0).appending(path: "plugin.yaml").path)
        }
        if linked.count < HermesRuntime.pluginNames.count { return "подключены: \(linked.joined(separator: ", "))" }
        return pulse.events.isEmpty ? "vera-pulse, vera-setup · событий ещё нет" : "vera-pulse, vera-setup · работают"
    }

    private func handle(_ frame: GatewayIncoming) {
        switch frame {
        case .event(let type, _, let payload, _):
            noteFlow(.hermesToAdapter)
            gatewayEvents[type, default: GatewayEventStat()].count += 1
            gatewayEvents[type]?.lastAt = Date()
            if type == Self.livePulseEvent, let line = Self.pulseLine(from: payload) { takeLive(line) }
            if type == "gateway.ready" { readyPayloadKeys = payload.object.map { Array($0.keys).sorted() } ?? [] }
            if type == "platforms.changed" { platformStates = Self.readPlatforms(hermesHome: runtime.hermesHome) }
        case .request:
            noteFlow(.hermesToAdapter)
        case .closed(let reason):
            gatewayState = .failed(reason)
            connectedAt = nil
        }
        let live = sinks.compactMap(\.sink)
        if case .request(let id, _, let params) = frame {
            let sid = params["session_id"]?.string
            if let owner = live.first(where: { $0.sessionId != nil && $0.sessionId == sid }) {
                owner.take(frame)
            } else {
                // An error, not a «deny» Vera would be choosing for the owner: the agent learns no window answered.
                Task { await client.refuse(id: id, message: "no Vera window has this session open") }
            }
        } else {
            live.forEach { $0.take(frame) }
        }
    }

    /// The gateway's inventory of Hermes: plugins (standard and ours), toolsets, skills, cron, MCP.
    func refreshInventory() async {
        guard gatewayState == .connected else { return }
        async let p = try? client.call("plugins.list", params: .object([:]), timeout: .seconds(20))
        async let t = try? client.call("tools.list", params: .object([:]), timeout: .seconds(20))   // with the tools' names
        async let s = try? client.call("skills.manage", params: .object(["action": .string("list")]), timeout: .seconds(20))
        async let c = try? client.call("cron.manage", params: .object(["action": .string("list")]), timeout: .seconds(20))
        async let m = try? client.call("mcp.servers.list", params: .object([:]), timeout: .seconds(20))
        async let live = try? client.call("session.list", params: .object(["scope": .string("live")]), timeout: .seconds(20))
        // 200 is the gateway's ceiling for one page: above it the whole call fails (invalid_params) and the board loses
        // every stored conversation — Telegram among them.
        async let stored = try? client.call("session.list", params: .object(["scope": .string("stored"), "limit": .number(Double(Self.storedPage))]), timeout: .seconds(20))
        let (pv, tv, sv, cv, mv) = await (p, t, s, c, m)
        if pv != nil || tv != nil { inventory = HermesInventory.from(plugins: pv, toolsets: tv, skills: sv, cron: cv, mcp: mv) }
        let (lv, st) = await (live, stored)
        let ids = Set(((lv?["sessions"]?.array ?? []) + (st?["sessions"]?.array ?? [])).compactMap { $0["session_id"]?.string })
        if lv != nil || st != nil { sessionCount = ids.count }
        var seenConv = Set<String>()
        conversations = ((lv?["sessions"]?.array ?? []) + (st?["sessions"]?.array ?? [])).compactMap { row in
            guard let id = row["session_id"]?.string ?? row["id"]?.string, seenConv.insert(id).inserted,
                  let ts = row["started_at"]?.number ?? row["last_active_at"]?.number else { return nil }
            return Conversation(id: id, ts: ts, source: row["source"]?.string ?? row["platform"]?.string ?? "?",
                                messages: Int(row["message_count"]?.number ?? 0), title: row["title"]?.string ?? "")
        }.sorted { $0.ts < $1.ts }
        let home = runtime.hermesHome
        dataUsage = await Task.detached(priority: .utility) { DataUsage.scan(hermesHome: home) }.value
        platformStates = Self.readPlatforms(hermesHome: home)
        if !muted, latestCheckedAt.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true, let src = lock?.source {
            latestCheckedAt = Date()
            latestHermes = await UpdateCheck.fetchLatest(source: src)
        }
        if boxVersions.isEmpty { boxVersions = Self.readBox() }
        if let h = try? await client.call("plugin.vera-setup.home_channels", params: .object([:]), timeout: .seconds(10)), h["ok"]?.bool == true {
            homeChannels = Dictionary((h["homes"]?.array ?? []).compactMap { r in r["platform"]?.string.map { ($0, r["name"]?.string ?? "") } },
                                      uniquingKeysWith: { a, _ in a })
        }
        if let t = try? await client.call("plugin.vera-setup.telegram_status", params: .object([:]), timeout: .seconds(10)) {
            telegramToken = t["token_set"]?.bool
            telegramAllowed = Int(t["allowed_users"]?.number ?? 0)
        }
        await readTelegram()
        let pulseDir = runtime.pulseDirectory, usage = dataUsage, historyDir = runtime.dataRoot.appending(path: "history")
        (activity, modelCalls, usageHistory) = await Task.detached(priority: .utility) {
            (LifeHistory.grid(pulseDirectory: pulseDir), LifeHistory.modelCalls(pulseDirectory: pulseDir),
             LifeHistory.record(usage, in: historyDir))
        }.value
        skillUsage = await Task.detached(priority: .utility) { SkillUsage.read(hermesHome: home) }.value
    }

    /// The ears' and the mouth's pinned versions, from the app's copy of ears.lock.json (or the repository's).
    static func readBox() -> [String: String] {
        let candidates = [Bundle.main.resourceURL?.appending(path: "ears.lock.json"),
                          HermesLock.find()?.deletingLastPathComponent().appending(path: "ears.lock.json")].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let obj = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        out["sherpa-onnx"] = obj["sherpa_onnx"] as? String
        if let items = obj["items"] as? [[String: Any]] {
            out["модели ушей"] = items.compactMap { $0["name"] as? String }.filter { $0 != "sherpa-onnx" }.joined(separator: " · ")
        }
        if let mouth = obj["mouth"] as? [String: Any] {
            out["голос"] = ((mouth["model"] as? [String: Any])?["name"] as? String ?? "silero") + " · " + (mouth["speaker"] as? String ?? "")
            out["torch"] = (mouth["pip"] as? [String])?.first { $0.hasPrefix("torch") }?.replacingOccurrences(of: "torch==", with: "")
        }
        return out
    }

    /// `gateway_state.json` in Vera's Hermes home: the platforms' runtime state (contract path gateway/status.py).
    static func readPlatforms(hermesHome: URL) -> [String: PlatformState] {
        guard let data = try? Data(contentsOf: hermesHome.appending(path: "gateway_state.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let platforms = obj["platforms"] as? [String: Any] else { return [:] }
        return platforms.reduce(into: [:]) { out, kv in
            guard let p = kv.value as? [String: Any] else { return }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            out[kv.key] = PlatformState(state: p["state"] as? String ?? "?", error: (p["error_message"] ?? p["error_code"]) as? String,
                                        updatedAt: (p["updated_at"] as? String).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) })
        }
    }

    /// Saves the Telegram bot token / allowed users (typed by the owner) through vera-setup, restarts the gateway so
    /// Hermes starts the platform, then follows `gateway_state.json` until Telegram is connected or failed — the tile
    /// shows each step (`telegramPhase`). Returns an error text when saving itself failed, else nil at once.
    func saveTelegram(token: String, allowed: String) async -> String? {
        var params: [String: JSONValue] = [:]
        if !token.isEmpty { params["token"] = .string(token) }
        if !allowed.isEmpty { params["allowed_users"] = .string(allowed) }
        telegramPhase = "сохраняю в Hermes…"
        do {
            let r = try await client.call("plugin.vera-setup.telegram_save", params: .object(params), timeout: .seconds(20))
            guard r["ok"]?.bool == true else { telegramPhase = nil; return r["error"]?.string ?? "не сохранилось" }
        } catch { telegramPhase = nil; return "\(error)" }
        let saved = Date()
        Task { await self.followTelegram(since: saved) }
        return nil
    }

    private func followTelegram(since saved: Date) async {
        telegramPhase = "перезапускаю шлюз Hermes…"
        await restartGateway()
        await refreshInventory()
        telegramPhase = "Hermes подключается к Telegram…"
        let deadline = saved.addingTimeInterval(120)
        while Date() < deadline {
            platformStates = Self.readPlatforms(hermesHome: runtime.hermesHome)
            if let st = platformStates["telegram"], (st.updatedAt ?? .distantPast) > saved {
                if st.state == "connected" { telegramPhase = nil; return }
                if st.error != nil || ["fatal", "failed", "error"].contains(st.state) { telegramPhase = nil; return }
                telegramPhase = "Hermes подключается к Telegram · \(st.state)…"
            }
            try? await Task.sleep(for: .seconds(2))
        }
        telegramPhase = "Telegram не ответил за 2 мин — журнал шлюза: logs/gateway.log"
    }

    /// The event vera-pulse broadcasts with each journal line (`broadcast_plugin_event("vera-pulse", "event", …)`).
    static let livePulseEvent = "plugin.vera-pulse.event"

    /// The payload is the journal line itself, so it decodes as `PulseEvent` through its own Codable keys.
    static func pulseLine(from payload: JSONValue) -> PulseEvent? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return try? JSONDecoder().decode(PulseEvent.self, from: data)
    }

    /// A line that came through the gateway: the adapter carried it, so it is live traffic.
    private func takeLive(_ line: PulseEvent) {
        pulseLiveAt = Date()
        noteFlow(.adapterToPulse)
        absorb([line], live: true)
    }

    /// Lines from the journal file: history on start, and the fallback when the gateway does not bring them.
    private func takeFile(_ batch: [PulseEvent]) {
        // While the gateway is connected, a file line is only a fallback for what it did not bring: the live copy of
        // the same line normally arrives right after, and the dedupe in `absorb` keeps one of them.
        absorb(batch, live: false)
        pulseBacklogSeen = true
    }

    /// One place for both sources: a line counts once, whichever came first.
    private func absorb(_ batch: [PulseEvent], live: Bool) {
        let fresh = batch.filter { event in
            guard !seenPulseIds.contains(event.id) else { return false }
            seenPulseIds.insert(event.id)
            seenPulseOrder.append(event.id)
            if seenPulseOrder.count > Self.seenPulseLimit {
                seenPulseIds.remove(seenPulseOrder.removeFirst())
            }
            return true
        }
        guard !fresh.isEmpty else { return }
        pulse.take(fresh)
        // The journal's backlog on start is history, not traffic now; a live line is traffic at once.
        guard live || pulseBacklogSeen else { return }
        if !live, gatewayState != .connected { noteFlow(.pluginToPulse, count: fresh.count) }
        for e in fresh {
            switch e.kind {
            case "llm.start": noteFlow(.hermesToProvider)
            case "llm.end", "llm.error": noteFlow(.providerToHermes)
            case "tool.start": noteFlow(.hands)
            case "session.start" where e.platform == "telegram": noteFlow(.telegram)
            default: break
            }
            // A line of the Telegram session: the adapter reads its new messages for the card in «Разговоры».
            if live, let sid = e.session, (e.platform ?? pulse.stats.sessions[sid]?.platform) == "telegram" {
                telegramLiveSession = sid
                queueTelegramRead()
            }
        }
    }

    /// One read for a burst of pulse lines (a turn sends several in a second).
    private func queueTelegramRead() {
        guard !telegramReadQueued else { return }
        telegramReadQueued = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            telegramReadQueued = false
            await readTelegram()
        }
    }

    /// The last rows of the Telegram session (`session.transcript`, newest page). The pulse's session id first, then
    /// the newest Telegram session `session.list` knows.
    func readTelegram() async {
        guard gatewayState == .connected else { return }
        let stored = conversations.filter { $0.source == "telegram" }.max { $0.ts < $1.ts }?.id
        var ids = [telegramLiveSession, stored].compactMap { $0 }
        if ids.count == 2, ids[0] == ids[1] { ids.removeLast() }
        for sid in ids {
            guard let r = try? await call("session.transcript", ["session_id": .string(sid), "order": .string("latest"),
                                                                 "limit": .number(Double(Self.telegramRows))], timeout: .seconds(15)),
                  let rows = r["rows"]?.array, !rows.isEmpty else { continue }
            var chat = ChatTranscript()
            chat.load(snapshot: .object(["messages": .array(rows)]))
            telegramSessionId = sid
            telegramReadAt = Date()
            if chat.items != telegramChat.items {
                telegramChat = chat
                noteFlow(.telegramToChannel)
            }
            return
        }
    }
    static let telegramRows = 16

    /// Counts per domain per second over the last `seconds`, oldest first.
    func timeline(seconds: Int = 60, now: Date = Date()) -> [String: [Int]] {
        let end = now.timeIntervalSince1970
        var lanes: [String: [Int]] = [:]
        for e in pulse.events.reversed() {
            let age = end - e.ts
            if age >= Double(seconds) { break }
            if age < 0 { continue }
            let bucket = seconds - 1 - Int(age)
            lanes[e.domain, default: Array(repeating: 0, count: seconds)][bucket] += 1
        }
        return lanes
    }
}
