import Foundation
import HermesBridge
import Observation
import PhoneGate
import PhoneWire
import VeraEars

/// The iPhone sensor on Vera's side: one more channel of «Разговоры» — its own pinned Hermes session («канал = сессия»).
/// What the phone types goes to Hermes as a message; what it says is turned into text by the ears from the box (GigaAM)
/// and sent the same way. The session's tail and whether Hermes is working go back to every paired phone. No thinking here.
@MainActor @Observable
final class PhoneModel {
    let chat: ChatModel
    let server: PhoneServer
    let nav: PhoneNavBridge
    /// The last thing a phone sent, for the tile.
    private(set) var lastFromPhone: (text: String, at: Date, voice: Bool)?
    private(set) var transcribing = false
    /// The phone's activity log (self-analysis) as it lies in Vera's data (`sensors/<day>/*.jsonl`, copied home by
    /// scripts/phone-sensors.sh): today's lines by stream and when it last came. Read once a minute, for the iPhone tile.
    private(set) var diary: (today: [String: Int], days: Int, updated: Date?, last: [String]) = ([:], 0, nil, [])
    @ObservationIgnored private var diaryTimer: Timer?
    /// Vera's downloaded music mirrored to the phone (scripts/phone-music-sync.sh): tracks in the mirror, last transfer.
    private(set) var musicMirror: (tracks: Int, synced: Date?) = (0, nil)
    /// What the phone's conversation is doing (from the phone), for the iPhone tile.
    private(set) var phoneTalk: (stage: String, paused: Bool, at: Date)?

    @ObservationIgnored private var voice: [Int: Data] = [:]
    @ObservationIgnored private var pushPending = false
    @ObservationIgnored private var lastSent: [PhoneItem] = []
    @ObservationIgnored private var lastState: PhoneState?
    @ObservationIgnored private var lastHermes: PhoneHermes?
    @ObservationIgnored private var wasConnected = false

    /// The phone's address of Vera through the owner's tunnel (`phone_tunnel` in `local.json`); nil — not set.
    let tunnelURL: URL?

    init(board: BoardModel) {
        let data = board.runtime.dataRoot
        self.tunnelURL = PhoneWire.tunnelURL(host: LocalSettings.load(dataRoot: data).phoneTunnel)
        self.chat = ChatModel(board: board, pinnedStore: data.appending(path: "phone-session.json"), lane: .phone)
        self.server = PhoneServer(book: DeviceBook(store: data.appending(path: "phone-devices.json")))
        self.nav = PhoneNavBridge(dataRoot: data, server: server)
        nav.onFlow = { [weak board] c in board?.noteFlow(c) }
    }

    var board: BoardModel { chat.board }
    var code: String? { server.book.liveCode() }

    func start() {
        server.onMessage = { [weak self] id, m in self?.handle(id, m) }
        server.onAudio = { [weak self] id, data in self?.audio(id, data) }
        server.onPeersChanged = { [weak self] joined in
            guard let self, let joined else { return }
            self.server.send(joined, .welcome(title: self.chat.transcript.title))
            self.server.send(joined, .items(self.items()))
            self.server.send(joined, .state(self.state()))
            self.server.send(joined, .hermes(self.hermes()))
        }
        server.start()
        nav.start()
        readDiary()
        diaryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readDiary() }
        }
        watch()
        attachIfNeeded()
    }

    /// The phone's session follows the gateway like the MacBook one: opened once connected, re-attached after a reconnect.
    private func attachIfNeeded() {
        let now = board.gatewayState == .connected
        defer { wasConnected = now }
        guard now, !wasConnected else { return }
        Task { if chat.sessionId == nil { await chat.openPinned() } else { await chat.reattach() } }
    }

    private func readDiary() {
        // devicectl may copy the folder itself or its contents: either layout is the log.
        let fm = FileManager.default
        let base = board.runtime.dataRoot.appending(path: "sensors")
        let root = fm.fileExists(atPath: base.appending(path: "Sensors").path) ? base.appending(path: "Sensors") : base
        let days = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.count == 10 }.sorted()
        guard let last = days.last else { diary = ([:], 0, nil, []); readMusicMirror(); return }
        var counts: [String: Int] = [:]
        var newest: Date?
        for f in (try? fm.contentsOfDirectory(at: root.appending(path: last), includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            counts[f.deletingPathExtension().lastPathComponent] = (try? String(contentsOf: f, encoding: .utf8))?.split(separator: "\n").count ?? 0
            if let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate { newest = max(newest ?? m, m) }
        }
        diary = (counts, days.count, newest, Self.latest(root.appending(path: last)))
        readMusicMirror()
    }

    private func readMusicMirror() {
        let url = board.runtime.dataRoot.appending(path: "phone-music.json")
        let o = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        musicMirror = ((o?["tracks"] as? Int) ?? 0, (o?["synced"] as? Double).map { Date(timeIntervalSince1970: $0) })
    }

    /// The newest values in the log's last lines: what the phone thought you did, its charge and network.
    private static func latest(_ day: URL) -> [String] {
        func lastObject(_ stream: String, where ok: ([String: Any]) -> Bool = { _ in true }) -> [String: Any]? {
            guard let text = try? String(contentsOf: day.appending(path: "\(stream).jsonl"), encoding: .utf8) else { return nil }
            for line in text.split(separator: "\n").reversed() {
                if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], ok(o) { return o }
            }
            return nil
        }
        var out: [String] = []
        let names = ["automotive": "ехал", "cycling": "велосипед", "running": "бежал", "walking": "шёл", "stationary": "стоял"]
        if let a = lastObject("activity"), let k = a["kind"] as? String, let n = names[k] { out.append(n) }
        if let d = lastObject("device", where: { $0["battery"] != nil }), let b = d["battery"] as? Double, b >= 0 {
            out.append("\(Int(b * 100))%\((d["power"] as? String) == "заряжается" ? " ⚡" : "")")
        }
        if let d = lastObject("device", where: { $0["network"] != nil }), let n = d["network"] as? String { out.append(n) }
        return out
    }

    /// A fresh QR code for pairing a phone.
    func newCode() { server.book.newCode() }

    func forget(_ name: String) {
        server.disconnect(device: name)
        server.book.forget(name)
    }

    // MARK: Phone → Hermes

    private func handle(_ id: Int, _ m: PhoneToVera) {
        switch m {
        case .say(let text):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            lastFromPhone = (t, Date(), false)
            board.noteFlow(.phoneToChannel)
            send(t, spoken: false)
        case .spoken(let text):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            lastFromPhone = (t, Date(), true)
            board.noteFlow(.phoneToChannel)
            send(t, spoken: true)
        case .voiceBegin: voice[id] = Data()
        case .voiceCancel: voice[id] = nil
        case .voiceEnd:
            guard let pcm = voice.removeValue(forKey: id), !pcm.isEmpty else { return }
            transcribe(id, pcm)
        case .interrupt: Task { await chat.interrupt() }
        case .navResult(let rid, let ok, let text): nav.result(id: rid, ok: ok, text: text)
        case .nav(let state): nav.state(state)
        case .talk(let stage, let paused): phoneTalk = (stage, paused, Date())
        case .pair, .hello: break
        }
    }

    private func audio(_ id: Int, _ data: Data) {
        guard var buf = voice[id] else { return }
        guard buf.count + data.count <= PhoneWire.maxVoiceSeconds * PhoneWire.sampleRate * 2 else {
            voice[id] = nil
            server.send(id, .problem(text: "голосовое длиннее \(PhoneWire.maxVoiceSeconds) с — не принято"))
            return
        }
        buf.append(data)
        voice[id] = buf
    }

    private func transcribe(_ id: Int, _ pcm: Data) {
        guard let runtime = EarsRuntime.resolve() else { server.send(id, .problem(text: "ушей нет в коробке")); return }
        transcribing = true
        Task {
            let samples = PhoneWire.floats(pcm)
            let result: Result<String, Error> = await Task.detached {
                Result { try VoiceNote.transcribe(samples, runtime: runtime) }
            }.value
            transcribing = false
            switch result {
            case .success(let text) where !text.isEmpty:
                server.send(id, .heard(text: text))
                lastFromPhone = (text, Date(), true)
                send(text, spoken: true)
            case .success: server.send(id, .problem(text: "речи не слышно"))
            case .failure(let e): server.send(id, .problem(text: "уши: \(e.localizedDescription)"))
            }
        }
    }

    private func send(_ text: String, spoken: Bool) {
        Task {
            if chat.sessionId == nil { await chat.openPinned() }
            await chat.sendText(text, spoken: spoken)
        }
    }

    // MARK: Hermes → phone

    /// Re-armed on every change of the conversation or the gateway; pushes at most ~7 times a second while streaming.
    private func watch() {
        withObservationTracking {
            _ = chat.transcript
            _ = board.gatewayState
            _ = board.pulse.events.count
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.attachIfNeeded()
                self.schedulePush()
                self.watch()
            }
        }
    }

    private func schedulePush() {
        guard !pushPending else { return }
        pushPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            pushPending = false
            push()
        }
    }

    private func push() {
        guard !server.peers.isEmpty else { return }
        let list = items(), st = state()
        if list != lastSent {
            lastSent = list; server.broadcast(.items(list))
            if !server.peers.isEmpty { board.noteFlow(.channelToPhone) }
        }
        if st != lastState { lastState = st; server.broadcast(.state(st)) }
        let h = hermes()
        if h != lastHermes { lastHermes = h; server.broadcast(.hermes(h)) }
    }

    static let tail = 60

    func items() -> [PhoneItem] {
        var out: [PhoneItem] = chat.transcript.items.suffix(Self.tail).compactMap { item in
            switch item.kind {
            case .user(let t): PhoneItem(id: item.id, role: .user, text: t, done: true)
            case .assistant(let t, let done): PhoneItem(id: item.id, role: .assistant, text: t, done: done)
            case .tool(_, let name, let preview, _, let summary, let done):
                PhoneItem(id: item.id, role: .tool, text: [name, summary ?? preview].compactMap { $0 }.joined(separator: " · "), done: done)
            case .notice(let t, _): PhoneItem(id: item.id, role: .notice, text: t, done: true)
            case .output(let t): PhoneItem(id: item.id, role: .output, text: t, done: true)
            case .error(let t): PhoneItem(id: item.id, role: .error, text: t, done: true)
            }
        }
        // The agent's questions are answered on the Mac for now; the phone sees that it waits.
        for (i, r) in chat.transcript.pending.enumerated() {
            out.append(PhoneItem(id: -1 - i, role: .notice,
                                 text: "Агент ждёт ответа — ответь на Маке, в карточке «Телефон»: \(r.description ?? r.command ?? r.method)", done: true))
        }
        return out
    }

    /// The phone session's part of the pulse: the model, what runs now, counts and the last steps.
    func hermes() -> PhoneHermes {
        let sid = chat.sessionId
        let mine = board.pulse.events.filter { $0.session == sid && sid != nil }
        let stats = sid.flatMap { board.pulse.stats.sessions[$0] }
        let now = board.pulse.stats.running.values.filter { $0.session == sid && sid != nil }
            .sorted { $0.since < $1.since }.map { $0.kind == "llm" ? "думает" : $0.name }
        let steps: [PhoneHermes.Step] = mine.compactMap { e in
            switch e.kind {
            case "llm.end", "llm.error": PhoneHermes.Step(kind: "llm", name: e.model ?? "модель", ms: e.durationMs, ok: e.kind == "llm.end", at: e.ts)
            case "tool.end": PhoneHermes.Step(kind: "tool", name: e.name ?? "инструмент", ms: e.durationMs, ok: e.status != "error", at: e.ts)
            case "subagent.stop": PhoneHermes.Step(kind: "subagent", name: e.name ?? "сабагент", ms: e.durationMs, ok: e.status != "error", at: e.ts)
            default: nil
            }
        }
        let last = mine.last { $0.model != nil }
        return PhoneHermes(model: last?.model ?? stats?.model, provider: last?.provider, now: now,
                           turns: stats?.turns ?? 0, llmCalls: stats?.llmCalls ?? 0, toolCalls: stats?.toolCalls ?? 0,
                           steps: Array(steps.suffix(8)))
    }

    func state() -> PhoneState {
        PhoneState(connected: board.gatewayState == .connected, running: chat.transcript.running, thinking: chat.transcript.thinking)
    }
}
