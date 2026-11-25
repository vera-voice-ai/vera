import Foundation

/// One chat with the agent, folded from the gateway's session events (`message.*`, `tool.*`, `status.update`,
/// `agent.print`, `session.*`) and from a resume snapshot's transcript. Pure value: tested without a gateway.
public struct ChatTranscript: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case user(String)
        case assistant(String, done: Bool)
        case tool(id: String, name: String, preview: String?, durationS: Double?, summary: String?, done: Bool)
        /// Hermes' own lines: retries, lifecycle, prints. `warning` for failures.
        case notice(String, warning: Bool)
        /// A slash command's output.
        case output(String)
        case error(String)
    }

    public struct Item: Sendable, Equatable, Identifiable {
        public let id: Int
        public var kind: Kind
    }

    /// A question the agent is waiting on.
    public struct PendingRequest: Sendable, Equatable, Identifiable {
        public var id: String { key }
        /// The JSON-RPC id to answer (`srq-…`), as text for identity.
        public let key: String
        public let rpcId: JSONValue
        public let method: String
        public let params: JSONValue

        public var command: String? { params["command"]?.string }
        public var description: String? { params["description"]?.string }
        public var choices: [String] { params["choices"]?.array?.compactMap(\.string) ?? ["once", "session", "always", "deny"] }
        public var questions: [(qid: String, question: String, choices: [String], multi: Bool)] {
            (params["questions"]?.array ?? []).compactMap { q in
                guard let qid = q["qid"]?.string, let text = q["question"]?.string else { return nil }
                return (qid, text, q["choices"]?.array?.compactMap(\.string) ?? [], q["multi_select"]?.bool ?? false)
            }
        }
    }

    public private(set) var items: [Item] = []
    public private(set) var running = false
    public private(set) var thinking: String?
    public private(set) var title: String?
    public private(set) var model: String?
    public private(set) var generation: Int?
    public private(set) var tokensIn = 0
    public private(set) var tokensOut = 0
    public private(set) var costUSD: Double?
    public private(set) var lastSequence = 0
    public var pending: [PendingRequest] = []
    private var nextId = 0
    /// Where the running turn began: its answer is looked for only after this.
    private var turnStart = 0

    public init() {}

    public mutating func addUser(_ text: String) {
        append(.user(text))
    }

    public mutating func addError(_ text: String) {
        append(.error(text))
    }

    public mutating func addOutput(_ text: String) {
        append(.output(text))
    }

    public mutating func addNote(_ text: String) {
        append(.notice(text, warning: false))
    }

    /// A resume/create snapshot: `messages` are `TranscriptMessage` rows (`role`, `text`, `name`, `args`, …).
    public mutating func load(snapshot: JSONValue) {
        items = []
        pending = []
        thinking = nil
        running = snapshot["running"]?.bool ?? false
        generation = snapshot["execution_generation"]?.number.map(Int.init)
        lastSequence = snapshot["last_sequence"]?.number.map(Int.init) ?? 0
        title = snapshot["info"]?["title"]?.string ?? title
        model = snapshot["info"]?["model"]?.string ?? model
        let rows = snapshot["display_messages"]?.array ?? snapshot["messages"]?.array ?? []
        // Stored history: the tool's name and arguments sit on the assistant row that called it (`tool_calls`),
        // the result row carries `tool_name` and the raw result.
        var calls: [String: (name: String, preview: String?)] = [:]
        for row in rows {
            let text = row["text"]?.string ?? row["content"]?.string ?? ""
            switch row["role"]?.string {
            // Hermes keeps its own notes (a background process finished, a delegation came back) as `user` rows marked
            // with `display_kind`; its windows paint them as a notice with `display_metadata.display_text`. Only a
            // row without that mark is the person.
            case "user" where row["display_kind"]?.string.map({ !$0.isEmpty }) ?? false:
                append(.notice(row["display_metadata"]?["display_text"]?.string ?? text, warning: false))
            case "user": append(.user(text))
            case "assistant":
                let said = text.isEmpty ? Self.commentary(row) : text
                if !said.isEmpty { append(.assistant(said, done: true)) }
                for call in row["tool_calls"]?.array ?? [] {
                    guard let id = call["id"]?.string ?? call["call_id"]?.string, let name = call["function"]?["name"]?.string else { continue }
                    calls[id] = (name, Self.argumentPreview(call["function"]?["arguments"]?.string))
                }
            case "tool":
                let id = row["tool_call_id"]?.string ?? ""
                let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // The raw result (often JSON) is shown as its size, not dumped.
                let summary: String? = raw.isEmpty ? nil
                    : (raw.hasPrefix("{") || raw.hasPrefix("[")) ? "результат · \(raw.count) симв." : String(raw.prefix(200))
                append(.tool(id: id, name: row["tool_name"]?.string ?? row["name"]?.string ?? calls[id]?.name ?? "инструмент",
                             preview: row["context"]?.string ?? calls[id]?.preview, durationS: nil, summary: summary, done: true))
            default:
                if !text.isEmpty { append(.notice(text, warning: false)) }
            }
        }
        for open in snapshot["open_requests"]?.array ?? [] {
            if let method = open["method"]?.string, let id = open["id"] {
                addRequest(id: id, method: method, params: open["params"] ?? .null)
            }
        }
    }

    public mutating func addRequest(id: JSONValue, method: String, params: JSONValue) {
        let key = id.string ?? id.description
        guard !pending.contains(where: { $0.key == key }) else { return }
        pending.append(PendingRequest(key: key, rpcId: id, method: method, params: params))
    }

    public mutating func resolve(key: String) {
        pending.removeAll { $0.key == key }
    }

    /// One session event. Returns false for events this transcript does not show.
    @discardableResult
    public mutating func apply(type: String, payload: JSONValue, meta: JSONValue = .null) -> Bool {
        if let seq = meta["seq"]?.number.map(Int.init) { lastSequence = max(lastSequence, seq) }
        if let gen = meta["execution_generation"]?.number.map(Int.init) { generation = gen }
        switch type {
        case "message.start":
            running = true
            thinking = nil
            turnStart = items.count
        case "message.delta":
            let text = payload["text"]?.string ?? ""
            if let i = openAssistant() {
                if case .assistant(let old, _) = items[i].kind { items[i].kind = .assistant(old + text, done: false) }
            } else if !text.isEmpty {
                append(.assistant(text, done: false))
            }
            thinking = nil
        case "message.interim":
            if let text = payload["text"]?.string, !text.isEmpty { append(.assistant(text, done: true)) }
        case "message.complete":
            running = false
            thinking = nil
            let final = payload["text"]?.string ?? ""
            let failed = payload["error"]?.string ?? payload["failure_reason"]?.string
            if let i = openAssistant() {
                if case .assistant(let streamed, _) = items[i].kind {
                    // The streamed bubble is this turn's last segment: the final text replaces it only when it
                    // is that segment (or nothing streamed); a full-turn recap would duplicate earlier segments.
                    let text = streamed.isEmpty || final.hasSuffix(streamed) == false ? (final.isEmpty ? streamed : final) : streamed
                    if text.isEmpty { items.remove(at: i) } else { items[i].kind = .assistant(text, done: true) }
                }
            } else if !final.isEmpty, !answered(final) {
                append(.assistant(final, done: true))
            }
            if let failed, !failed.isEmpty, failed != final, !final.contains(failed) {
                // A bare reason code (`format_error`) is a hint, not a second error message.
                if Self.isCode(failed) { append(.notice("код причины: \(failed)", warning: false)) } else { append(.error(failed)) }
            }
            if let usage = payload["usage"] { take(usage: usage) }
        case "thinking.delta", "reasoning.delta":
            let text = payload["text"]?.string ?? ""
            thinking = text.isEmpty ? thinking : text
        case "tool.generating":
            thinking = "готовит «\(payload["name"]?.string ?? "инструмент")»"
        case "tool.start":
            seal()
            append(.tool(id: payload["tool_id"]?.string ?? "", name: payload["name"]?.string ?? "инструмент",
                         preview: payload["preview"]?.string ?? payload["context"]?.string, durationS: nil, summary: nil, done: false))
        case "tool.complete":
            let id = payload["tool_id"]?.string ?? ""
            let summary = payload["summary"]?.string ?? payload["result_text"]?.string.map { String($0.prefix(300)) }
            if let i = items.lastIndex(where: { if case .tool(let tid, _, _, _, _, false) = $0.kind { return tid == id }; return false }),
               case .tool(_, let name, let preview, _, _, _) = items[i].kind {
                items[i].kind = .tool(id: id, name: name, preview: preview, durationS: payload["duration_s"]?.number,
                                      summary: summary, done: true)
            } else {
                append(.tool(id: id, name: payload["name"]?.string ?? "инструмент", preview: nil,
                             durationS: payload["duration_s"]?.number, summary: summary, done: true))
            }
        case "status.update", "agent.print":
            guard let text = payload["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return false }
            // Hermes reports one failure both as `agent.print` and as `status.update`: show it once per turn.
            let key = Self.noticeKey(text)
            if items[min(turnStart, items.count)...].contains(where: {
                if case .notice(let t, _) = $0.kind { return Self.noticeKey(t) == key }; return false
            }) { return false }
            seal()
            append(.notice(text, warning: text.hasPrefix("❌") || text.hasPrefix("⚠")))
        case "error":
            append(.error(payload["message"]?.string ?? "ошибка"))
            running = false
        case "session.usage":
            take(usage: payload["usage"] ?? payload)
        case "session.info":
            if let r = payload["running"]?.bool { running = r }
            if let t = payload["title"]?.string, !t.isEmpty { title = t }
            if let m = payload["model"]?.string, !m.isEmpty { model = m }
        case "session.title":
            if let t = payload["title"]?.string ?? payload["text"]?.string, !t.isEmpty { title = t }
        case "request.cancel":
            if let id = payload["id"]?.string { resolve(key: id) }
        default:
            return false
        }
        return true
    }

    /// The notice without its leading marks (❌, ⚠️, 💡) and spacing: two lines that differ only there are one.
    static func noticeKey(_ text: String) -> String {
        String(text.drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `format_error`, `rate_limit`: a machine reason, not a sentence.
    static func isCode(_ text: String) -> Bool {
        text.count <= 40 && text.wholeMatch(of: /[a-z0-9]+(?:[_.:-][a-z0-9]+)+/) != nil
    }

    private mutating func take(usage: JSONValue) {
        if let i = usage["input"]?.number { tokensIn = Int(i) }
        if let o = usage["output"]?.number { tokensOut = Int(o) }
        if let c = usage["cost_usd"]?.number { costUSD = c }
        if let m = usage["model"]?.string, !m.isEmpty { model = m }
    }

    /// What the model said alongside a tool call («Читаю файл.»), kept apart from `content` in stored history.
    static func commentary(_ row: JSONValue) -> String {
        for item in row["codex_message_items"]?.array ?? [] {
            for part in item["content"]?.array ?? [] where part["type"]?.string == "output_text" {
                if let t = part["text"]?.string, !t.isEmpty { return t }
            }
        }
        return ""
    }

    /// The one argument worth showing: a path, a command, a query or a URL.
    static func argumentPreview(_ json: String?) -> String? {
        guard let json, let v = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else { return nil }
        for key in ["path", "file_path", "command", "query", "url", "pattern", "name"] {
            if let s = v[key]?.string, !s.isEmpty { return (s as NSString).lastPathComponent == s ? s : (s as NSString).lastPathComponent }
        }
        return nil
    }

    private func openAssistant() -> Int? {
        guard let i = items.indices.last, i >= turnStart, case .assistant(_, false) = items[i].kind else { return nil }
        return i
    }

    /// Close the streaming bubble: what comes next (a tool, a notice) goes below it, and so does the rest of the answer.
    private mutating func seal() {
        if let i = openAssistant(), case .assistant(let text, _) = items[i].kind {
            if text.isEmpty { items.remove(at: i) } else { items[i].kind = .assistant(text, done: true) }
        }
    }

    /// This turn already shows `text` as an answer bubble.
    private func answered(_ text: String) -> Bool {
        items[min(turnStart, items.count)...].contains { if case .assistant(let t, _) = $0.kind { return t == text }; return false }
    }

    private mutating func append(_ kind: Kind) {
        items.append(Item(id: nextId, kind: kind))
        nextId += 1
    }
}
