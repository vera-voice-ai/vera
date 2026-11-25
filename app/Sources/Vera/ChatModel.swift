import Foundation
import Observation
import HermesBridge

/// The chat with Vera's Hermes over the gateway's canonical session methods (the ones Desktop and TUI use):
/// `session.list` (stored), `session.create {source: gui}` / `session.resume`, `prompt.submit` (with a
/// `submission_id`), `session.interrupt`, `session.detach`; the agent's `approval` / `clarify` questions are
/// answered as JSON-RPC responses; slash commands go through `slash.exec` (TUI rules, `SlashOutcome`).
/// Session events and the agent's questions arrive through `BoardModel.addSink`.
///
/// `pinnedStore` set: the model is bound to one session for good — Vera's main session (chat now, voice next);
/// its id lives in that file and is resumed on every start.
@MainActor @Observable
final class ChatModel {
    struct SessionRow: Identifiable, Equatable {
        let id: String
        let title: String
        let preview: String?
        let lastActive: Double?
        let messageCount: Int
        let running: Bool
    }

    private(set) var sessions: [SessionRow] = []
    private(set) var sessionId: String?
    private(set) var transcript = ChatTranscript()
    private(set) var busy = false
    private(set) var problem: String?
    var draft = ""

    struct Completion: Identifiable, Equatable {
        var id: String { text }
        let text: String
        let display: String
        let meta: String
    }
    private(set) var completions: [Completion] = []

    /// What the voice listens to: the answer as it streams, and the agent's questions.
    enum AssistantEvent { case start, delta(String), interim(String), complete(String) }
    @ObservationIgnored var onAssistant: ((AssistantEvent) -> Void)?
    @ObservationIgnored var onRequest: ((ChatTranscript.PendingRequest) -> Void)?

    private var subscriptionId: String?
    private var completionTask: Task<Void, Never>?
    let board: BoardModel
    let pinnedStore: URL?
    /// Which channel of «Разговоры» this is: the MacBook (chat and voice on the Mac, the turn recorder) or the iPhone
    /// sensor — each a pinned Hermes session of its own.
    enum Lane { case macbook, phone }
    let lane: Lane

    init(board: BoardModel, pinnedStore: URL? = nil, lane: Lane = .macbook) {
        self.board = board
        self.pinnedStore = pinnedStore
        self.lane = lane
        board.addSink(self)
    }

    var pinned: Bool { pinnedStore != nil }
    /// The MacBook conversation: its flows and the turn recorder («Ход») are about it only.
    var main: Bool { pinned && lane == .macbook }

    var connected: Bool { board.gatewayState == .connected }

    func refreshSessions() async {
        guard connected else { return }
        do {
            // Live sessions (open now, or whose turns have not been stored yet) first, then stored ones; one row per id.
            let live = try await board.call("session.list", ["scope": .string("live")])
            let stored = try await board.call("session.list", ["scope": .string("stored"), "limit": .number(60)])
            var seen = Set<String>()
            let rows = ((live["sessions"]?.array ?? []) + (stored["sessions"]?.array ?? [])).filter { row in
                guard let id = row["session_id"]?.string ?? row["id"]?.string else { return false }
                return seen.insert(id).inserted
            }
            sessions = rows.compactMap { row in
                guard let id = row["session_id"]?.string ?? row["id"]?.string else { return nil }
                let title = row["title"]?.string
                return SessionRow(id: id, title: (title?.isEmpty == false ? title! : "Без названия"),
                                  preview: row["preview"]?.string ?? row["last_reply"]?.string,
                                  lastActive: row["last_active_at"]?.number ?? row["started_at"]?.number,
                                  messageCount: Int(row["message_count"]?.number ?? 0),
                                  running: row["running"]?.bool ?? false)
            }
        } catch {
            problem = "Список чатов: \(error)"
        }
    }

    func open(_ id: String) async {
        guard id != sessionId else { return }
        await detach()
        busy = true
        defer { busy = false }
        do {
            let snap = try await board.call("session.resume", ["session_id": .string(id)], timeout: .seconds(60))
            adopt(snapshot: snap)
        } catch {
            problem = "Не удалось открыть чат: \(error)"
        }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, connected else { return }
        draft = ""
        completions = []
        if text.hasPrefix("/") && text.count > 1 { await runSlash(text) } else { await sendText(text) }
    }

    /// One message to the agent (typed, spoken, or a command's `send`); `display` is what the transcript shows.
    func sendText(_ text: String, display: String? = nil, spoken: Bool = false) async {
        guard connected else { return }
        if lane == .phone { board.noteFlow(.phoneToAdapter) } else { board.noteFlow(spoken ? .voiceToAdapter : .windowsToAdapter) }
        if main { board.noteFlow(.channelToAdapter, at: Date().addingTimeInterval(FlowMonitor.flight * 0.8)) }
        busy = true
        defer { busy = false }
        do {
            if sessionId == nil { try await create() }
            guard let sid = sessionId else { return }
            transcript.addUser(display ?? text)
            let at = Date().timeIntervalSince1970
            _ = try await board.call("prompt.submit", [
                "session_id": .string(sid), "text": .string(text), "submission_id": .string(UUID().uuidString)
            ], timeout: .seconds(30))
            if main { board.pulse.turns.session = sid; board.pulse.turns.submitted(at: at, ack: Date().timeIntervalSince1970) }
            problem = nil
        } catch {
            if main { board.pulse.turns.abort(at: Date().timeIntervalSince1970) }
            transcript.addError("Сообщение не отправлено: \(error)")
        }
    }

    // MARK: Slash commands (same rules as Hermes' TUI)

    func runSlash(_ line: String, depth: Int = 0) async {
        guard depth < 3 else { transcript.addError("\(line): слишком длинная цепочка псевдонимов"); return }
        if depth == 0 { board.noteFlow(.windowsToAdapter) }
        busy = true
        defer { busy = false }
        do {
            if sessionId == nil { try await create() }
            guard let sid = sessionId else { return }
            if depth == 0 { transcript.addUser(line) }
            // The routing of Hermes' own client for gateway sessions: what changes the session is a mutation,
            // not slash.exec (which refuses it as unsupported_command).
            switch GatewayCommand.route(line) {
            case .interrupt:
                await interrupt()
                transcript.addOutput("ход прерван")
            case .help:
                transcript.addOutput(GatewayCommand.helpText)
            case .showModel:
                transcript.addOutput("модель разговора: \(transcript.model ?? "?") · сменить: /model <модель> [--provider имя]")
            case .unavailable(let text), .problem(let text):
                transcript.addError(text)
            case .yolo(let on):
                var p: [String: JSONValue] = ["session_id": .string(sid), "key": .string("yolo")]
                if let on { p["value"] = .string(on ? "1" : "0") }
                let r = try await board.call("config.set", p)
                transcript.addOutput("YOLO \(r["value"]?.string == "1" ? "включён" : "выключен") для этой сессии")
            case .mutate(let operation, let payload, let confirmed):
                try await mutate(operation, payload: payload, session: sid, confirmed: confirmed)
            case .rewind(let turns, let retry):
                try await rewind(turns, retry: retry, session: sid)
            case .exec(let command):
                try await exec(command, session: sid, depth: depth)
            }
        } catch {
            transcript.addError("Команда не выполнена: \(error)")
        }
    }

    /// `session.mutate`, fenced by the session's revision (and generation, except metadata) read fresh from
    /// `session.resume`; then the session is read again, so the chat shows what the mutation left.
    @discardableResult
    private func mutate(_ operation: String, payload: [String: JSONValue], session sid: String,
                        confirmed: Bool = false, report: Bool = true) async throws -> JSONValue {
        let snap = try await board.call("session.resume", ["session_id": .string(sid)], timeout: .seconds(60))
        guard let revision = snap["revision"]?.number else { throw GatewayClient.CallError.rpc(code: 0, message: "шлюз не дал ревизию сессии") }
        var params: [String: JSONValue] = [
            "session_id": .string(sid), "request_id": .string(UUID().uuidString), "operation": .string(operation),
            "expected_revision": .number(revision), "payload": .object(payload),
        ]
        if !GatewayCommand.metadataOperations.contains(operation), let g = snap["execution_generation"]?.number {
            params["expected_generation"] = .number(g)
        }
        let budget = Duration.seconds(operation == "compress" ? GatewayCommand.compressTimeout : 60)
        var r = try await board.call("session.mutate", params, timeout: budget)
        // A guarded switch: Hermes wrote nothing and asks the owner. With his yes given in advance (--yes) the same
        // mutation goes once more with Hermes' token — as Ink and Desktop do after their dialog.
        if r["status"]?.string == "confirmation_required", confirmed, let token = r["confirm"]?.string {
            var again = payload
            again["confirm"] = .string(token)
            params["payload"] = .object(again)
            params["request_id"] = .string(UUID().uuidString)
            r = try await board.call("session.mutate", params, timeout: budget)
        }
        guard report else { return r }
        switch r["status"]?.string {
        case "confirmation_required":
            let words = (r["confirm_message"]?.string ?? "модель под защитой").replacingOccurrences(of: "!!! ", with: "")
                .replacingOccurrences(of: " !!!", with: "")
            transcript.addError("Hermes предупреждает и ничего не сменил:\n\(words)\nСогласен — повтори команду с --yes.")
            return r
        case "preview":
            transcript.addOutput((r["lines"]?.array ?? []).compactMap(\.string).joined(separator: "\n"))
            return r
        case "noop":
            let s = r["summary"]
            transcript.addOutput([s?["headline"]?.string, s?["token_line"]?.string, s?["note"]?.string ?? r["note"]?.string]
                .compactMap { $0 }.joined(separator: "\n"))
            return r
        default: break
        }
        if let fresh = try? await board.call("session.resume", ["session_id": .string(sid)], timeout: .seconds(60)) { adopt(snapshot: fresh) }
        switch operation {
        case "model": transcript.addOutput("модель разговора: \(r["model"]?.string ?? payload["model"]?.string ?? "?")")
        case "rename": transcript.addOutput("название: \(r["title"]?.string ?? payload["title"]?.string ?? "")")
        case "compress":
            let s = r["summary"]
            let text = [s?["headline"]?.string, s?["token_line"]?.string].compactMap { $0 }.joined(separator: "\n")
            transcript.addOutput(text.isEmpty ? "история сжата" : text)
        default: transcript.addOutput("\(operation): готово")
        }
        return r
    }

    /// `/undo [N]` and `/retry`: rewind to the N-th user turn from the end; the removed message goes back into the
    /// composer (undo) or is sent again (retry).
    private func rewind(_ turns: Int, retry: Bool, session sid: String) async throws {
        let snap = try await board.call("session.resume", ["session_id": .string(sid)], timeout: .seconds(60))
        let ids = GatewayCommand.userTurnIds(snap)
        guard ids.count >= turns else { transcript.addOutput("нечего отменять: в разговоре нет столько твоих сообщений"); return }
        let r = try await mutate("rewind", payload: ["target_message_id": .number(Double(ids[ids.count - turns]))],
                                 session: sid, report: false)
        guard r["status"]?.string != "nothing", (r["rewound_count"]?.number ?? 0) > 0 else {
            transcript.addOutput("нечего отменять"); return
        }
        if let fresh = try? await board.call("session.resume", ["session_id": .string(sid)], timeout: .seconds(60)) { adopt(snapshot: fresh) }
        let text = r["target_message"]?["content"]?.string ?? ""
        if retry {
            guard !text.isEmpty else { transcript.addError("/retry: последнее сообщение не текст — отправь заново сам"); return }
            await sendText(text)
        } else {
            draft = text
            transcript.addOutput("отменено сообщений: \(Int(r["rewound_count"]?.number ?? 0)) — последнее вернулось в поле ввода")
        }
    }

    /// Reports, plugin and skill commands: `slash.exec`. Its refusal is the real answer — shown as it is; a skill
    /// (`4018`) is the one case the gateway sends to `command.dispatch`.
    private func exec(_ command: String, session sid: String, depth: Int) async throws {
        let name = String(command.prefix { !$0.isWhitespace })
        let args = String(command.dropFirst(name.count))
        let result: JSONValue
        do {
            result = try await board.call("slash.exec", ["session_id": .string(sid), "command": .string(command)], timeout: .seconds(60))
        } catch GatewayClient.CallError.rpc(let code, let message) where code == 4018 {
            _ = message
            result = try await board.call("command.dispatch", [
                "name": .string(name), "arg": args.isEmpty ? .null : .string(args.trimmingCharacters(in: .whitespaces)),
                "session_id": .string(sid),
            ], timeout: .seconds(60))
        } catch GatewayClient.CallError.rpc(_, let message) where message == "unsupported_command" {
            transcript.addError("/\(name) общий шлюз Hermes пока не выполняет — \(GatewayCommand.parityDoc)")
            return
        }
        switch SlashOutcome.from(result, command: name) {
        case .show(let text): transcript.addOutput(text)
        case .alias(let target): await runSlash("/\(target)\(args)", depth: depth + 1)
        case .send(let message, let display, let notice):
            if let notice { transcript.addNote(notice) }
            await sendText(message, display: display ?? message)
        case .prefill(let message, let notice):
            if let notice { transcript.addNote(notice) }
            draft = message
        case .problem(let text): transcript.addError(text)
        }
    }

    func updateCompletions() {
        completionTask?.cancel()
        let text = draft
        guard connected, text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else { completions = []; return }
        completionTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            var params: [String: JSONValue] = ["text": .string(text)]
            if let sid = sessionId { params["session_id"] = .string(sid) }
            guard let r = try? await board.call("complete.slash", params), !Task.isCancelled, draft == text else { return }
            completions = (r["items"]?.array ?? []).compactMap { item in
                guard let t = item["text"]?.string else { return nil }
                return Completion(text: t, display: item["display"]?.string ?? "/\(t)", meta: item["meta"]?.string ?? "")
            }
        }
    }

    func pick(_ c: Completion) {
        draft = "/\(c.text) "
        completions = []
    }

    // MARK: The pinned main session

    /// Resume Vera's main session (its id is kept in `pinnedStore`), or create it the first time / when it is gone.
    func openPinned() async {
        guard let store = pinnedStore, connected, sessionId == nil else { return }
        if let data = try? Data(contentsOf: store),
           let id = (try? JSONDecoder().decode([String: String].self, from: data))?["session_id"],
           let snap = try? await board.call("session.resume", ["session_id": .string(id)], timeout: .seconds(60)) {
            adopt(snapshot: snap)
            return
        }
        do { try await create(title: lane == .phone ? "iPhone" : "Вера") } catch { problem = "Сессия не открылась: \(error)" }
    }

    private func savePinned() {
        guard let store = pinnedStore, let sid = sessionId,
              let data = try? JSONEncoder().encode(["session_id": sid]) else { return }
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: store)
    }

    func interrupt() async {
        guard let sid = sessionId, let gen = transcript.generation else { return }
        _ = try? await board.call("session.interrupt", ["session_id": .string(sid), "execution_generation": .number(Double(gen))])
    }

    func answer(_ request: ChatTranscript.PendingRequest, result: JSONValue) async {
        transcript.resolve(key: request.key)
        await board.respond(id: request.rpcId, result: result)
    }

    /// After a reconnect the subscription is gone: resume the open chat to get it back (and what was missed).
    func reattach() async {
        guard let sid = sessionId, connected else { return }
        subscriptionId = nil
        if let snap = try? await board.call("session.resume", ["session_id": .string(sid)], timeout: .seconds(60)) {
            adopt(snapshot: snap)
        }
    }

    // MARK: -

    private func create(title: String? = nil) async throws {
        var params: [String: JSONValue] = ["source": .string("gui"), "cwd": .string(board.runtime.workspace.path)]
        // Which of Vera's channels made the session (a label, not a permission): plugin vera-context gives the
        // session its channel's description by it.
        params["client"] = .object(["name": .string(lane == .phone ? "vera-phone" : "vera-mac"), "version": .string("0.3")])
        if let title { params["title"] = .string(title) }
        let snap = try await board.call("session.create", params, timeout: .seconds(60))
        adopt(snapshot: snap)
        if pinned { savePinned() } else { await refreshSessions() }
    }

    private func adopt(snapshot: JSONValue) {
        sessionId = snapshot["session_id"]?.string
        subscriptionId = snapshot["subscription_id"]?.string
        transcript.load(snapshot: snapshot)
        problem = nil
        // A compression may hand back a new id for the same conversation: the pin follows it.
        if pinned { savePinned() }
    }

    private func detach() async {
        guard let sid = sessionId, let sub = subscriptionId, connected else { return }
        _ = try? await board.call("session.detach", ["session_id": .string(sid), "subscription_id": .string(sub)])
        subscriptionId = nil
    }

    /// Called by `BoardModel` for every gateway frame; requests only when this model's session asked.
    func take(_ frame: GatewayIncoming) {
        switch frame {
        case .event(let type, let sid, let payload, let meta):
            if type == "sessions.changed" { if !pinned { Task { await refreshSessions() } }; return }
            guard let sid, sid == sessionId else { return }
            if main { board.noteFlow(.adapterToChannel) } else if lane == .phone { board.noteFlow(.adapterToPhone) }
            transcript.apply(type: type, payload: payload, meta: meta)
            switch type {
            case "message.start": onAssistant?(.start)
            case "message.delta": if let t = payload["text"]?.string { onAssistant?(.delta(t)) }
            case "message.interim": if let t = payload["text"]?.string, !t.isEmpty { onAssistant?(.interim(t)) }
            case "message.complete": onAssistant?(.complete(payload["text"]?.string ?? ""))
            default: break
            }
            if !pinned, type == "message.complete" || type == "session.title" { Task { await refreshSessions() } }
        case .request(let id, let method, let params):
            transcript.addRequest(id: id, method: method, params: params)
            if let r = transcript.pending.last { onRequest?(r) }
        case .closed:
            break
        }
    }
}
