import Foundation

/// What the board shows, folded from pulse events. Pure value: tested without a gateway.
public struct PulseStats: Sendable, Equatable {
    public struct ToolStat: Sendable, Equatable {
        public var calls = 0
        public var errors = 0
        public var totalMs = 0.0
        public var lastAt: Double = 0
        public var averageMs: Double { calls == 0 ? 0 : totalMs / Double(calls) }
    }

    public struct SessionState: Sendable, Equatable {
        public var id: String
        public var platform: String?
        public var model: String?
        public var openedAt: Double
        public var lastAt: Double
        public var turns = 0
        public var toolCalls = 0
        public var llmCalls = 0
        public var lastOutcome: String?
    }

    public struct Running: Sendable, Equatable {
        public var kind: String
        public var name: String
        public var session: String?
        public var since: Double
    }

    public private(set) var tools: [String: ToolStat] = [:]
    public private(set) var sessions: [String: SessionState] = [:]
    public private(set) var llmCalls = 0
    public private(set) var llmErrors = 0
    public private(set) var llmTotalMs = 0.0
    public private(set) var tokensIn = 0
    public private(set) var tokensOut = 0
    public private(set) var models: [String: Int] = [:]
    public private(set) var subagents = 0
    public private(set) var compactions = 0
    public private(set) var humanWaits = 0
    /// In flight now, keyed by call/turn id.
    public private(set) var running: [String: Running] = [:]
    public private(set) var lastEventAt: Double?

    public init() {}

    public mutating func apply(_ e: PulseEvent) {
        lastEventAt = max(lastEventAt ?? 0, e.ts)
        if let s = e.session {
            var state = sessions[s] ?? SessionState(id: s, platform: e.platform, model: e.model, openedAt: e.ts, lastAt: e.ts)
            state.lastAt = max(state.lastAt, e.ts)
            if let p = e.platform { state.platform = p }
            if let m = e.model { state.model = m }
            switch e.kind {
            case "tool.end": state.toolCalls += 1
            case "llm.end": state.llmCalls += 1
            case "session.end": state.turns += 1; state.lastOutcome = e.status
            default: break
            }
            sessions[s] = state
        }
        let key = e.callId ?? e.turn ?? e.session ?? e.kind
        switch e.kind {
        case "tool.start":
            running["tool:" + key] = Running(kind: "tool", name: e.name ?? "?", session: e.session, since: e.ts)
        case "tool.end":
            running["tool:" + key] = nil
            var t = tools[e.name ?? "?"] ?? ToolStat()
            t.calls += 1
            if let s = e.status, s != "ok", s != "success" { t.errors += 1 }
            t.totalMs += e.durationMs ?? 0
            t.lastAt = e.ts
            tools[e.name ?? "?"] = t
        case "llm.start":
            running["llm:" + key] = Running(kind: "llm", name: e.model ?? "модель", session: e.session, since: e.ts)
        case "llm.end", "llm.error":
            running["llm:" + key] = nil
            llmCalls += 1
            if e.kind == "llm.error" { llmErrors += 1 }
            llmTotalMs += e.durationMs ?? 0
            tokensIn += e.tokensIn ?? 0
            tokensOut += e.tokensOut ?? 0
            if let m = e.model { models[m, default: 0] += 1 }
        case "subagent.start":
            subagents += 1
            running["sub:" + key] = Running(kind: "subagent", name: e.name ?? "сабагент", session: e.session, since: e.ts)
        case "subagent.stop":
            running["sub:" + key] = nil
        case "human.wait":
            humanWaits += 1
            running["human:" + key] = Running(kind: "human", name: e.name ?? "вопрос", session: e.session, since: e.ts)
        case "human.done":
            running["human:" + key] = nil
        case "session.end":
            // A session runs one turn at a time: once its turn ended, nothing of it is in flight. A model call cut
            // mid-request (an interrupt, a dropped connection) gets no llm.end, and without this it would hang
            // as «думает» for hours.
            if let s = e.session { running = running.filter { $0.value.session != s } }
        case "compaction":
            compactions += 1
        default:
            break
        }
    }
}
