import Foundation

/// The last requests to Hermes from every channel (the MacBook's chat and voice, Telegram, …), one per Hermes turn,
/// straight from the vera-pulse journal: when the turn began, its model and tool calls, how it ended. Turns overlap
/// when they really do (a second request queued or steered while the first runs, Telegram while the laptop talks),
/// so the board can show that the first one got its answer while the next goes on. Observation only.
public struct RequestLog: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public enum Kind: String, Sendable { case model, tool }
        public var kind: Kind
        public var name: String
        public var start: Double
        public var end: Double?
        public var failed = false
        var key: String?
    }

    public struct Request: Sendable, Equatable, Identifiable {
        public let id: String          // the pulse turn id
        public var session: String
        public var platform: String?
        public var start: Double
        public var end: Double?
        /// `ok`, `interrupted`, `failed` (pulse `session.end`); `cut` — the journal has no end for it and the same
        /// session went on to its next turn (a gateway restart cuts a turn so); nil while the turn runs.
        public var status: String?
        public var steps: [Step] = []
        public var tokensOut = 0
        public var running: Bool { end == nil }
        public var lastAt: Double { [end ?? start, steps.map { $0.end ?? $0.start }.max() ?? start].max()! }
    }

    public static let keep = 10
    /// Oldest first; at most `keep`.
    public private(set) var requests: [Request] = []
    /// Platform of each session, from `session.open` / `session.start`.
    private var platforms: [String: String] = [:]

    public init() {}

    public mutating func apply(_ e: PulseEvent) {
        if let s = e.session, let p = e.platform, !p.isEmpty { platforms[s] = p }
        guard let turn = e.turn, let session = e.session else { return }
        var i = requests.firstIndex { $0.id == turn }
        if i == nil {
            // A finished turn that already fell out of the window is not brought back by a late line.
            guard e.kind != "session.end" || requests.count < Self.keep else { return }
            // A session runs its turns one after another: an earlier turn of it still open has ended without a line.
            for j in requests.indices where requests[j].session == session && requests[j].end == nil && requests[j].start < e.ts {
                requests[j].end = requests[j].lastAt
                requests[j].status = "cut"
                for k in requests[j].steps.indices where requests[j].steps[k].end == nil { requests[j].steps[k].end = requests[j].end }
            }
            requests.append(Request(id: turn, session: session, platform: platforms[session] ?? e.platform, start: e.ts))
            requests.sort { $0.start < $1.start }
            if requests.count > Self.keep { requests.removeFirst(requests.count - Self.keep) }
            i = requests.firstIndex { $0.id == turn }
            guard i != nil else { return }
        }
        update(i!, with: e)
    }

    private mutating func update(_ i: Int, with e: PulseEvent) {
        var r = requests[i]
        if r.platform == nil { r.platform = platforms[r.session] ?? e.platform }
        r.start = min(r.start, e.ts)
        switch e.kind {
        case "llm.start":
            r.steps.append(Step(kind: .model, name: e.model ?? "модель", start: e.ts, key: e.callId))
        case "tool.start":
            r.steps.append(Step(kind: .tool, name: e.name ?? "инструмент", start: e.ts, key: e.callId))
        case "llm.end", "llm.error", "tool.end":
            let kind: Step.Kind = e.kind.hasPrefix("llm") ? .model : .tool
            if let j = r.steps.lastIndex(where: { $0.kind == kind && $0.end == nil && ($0.key == e.callId || e.callId == nil) }) {
                r.steps[j].end = e.ts
                r.steps[j].failed = e.kind == "llm.error" || (e.status != nil && e.status != "ok")
            } else if let ms = e.durationMs {   // the start line fell before the window: the end carries the length
                r.steps.append(Step(kind: kind, name: e.name ?? e.model ?? (kind == .model ? "модель" : "инструмент"),
                                    start: e.ts - ms / 1000, end: e.ts,
                                    failed: e.kind == "llm.error" || (e.status != nil && e.status != "ok")))
            }
            r.tokensOut += e.tokensOut ?? 0
        case "session.end":
            r.end = e.ts
            r.status = e.status ?? "ok"
            for j in r.steps.indices where r.steps[j].end == nil { r.steps[j].end = e.ts }
        default: break
        }
        requests[i] = r
    }
}
