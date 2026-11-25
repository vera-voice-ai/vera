import Foundation

/// One turn of the main session laid out in time: where the seconds go, from the spoken phrase to the last word of
/// the spoken answer. Built only from what Vera really sees: the ears (phrase), the adapter (submit, gateway events),
/// the vera-pulse journal (model calls, tools — with their own timestamps) and the mouth (first word, end of voice).
public struct TurnTrace: Sendable, Equatable, Identifiable {
    public enum Lane: String, Sendable, CaseIterable {
        case phrase     // the user speaking, then the ears finishing the phrase
        case gateway    // prompt.submit
        case model      // each model call (pulse llm.start → llm.end / llm.error)
        case tool       // each tool call (pulse tool.start → tool.end)
        case text       // the answer's text streaming (message.start → message.complete)
        case voice      // Vera speaking the answer (first sentence sounding → mouth idle)
    }

    public struct Step: Sendable, Equatable {
        public var lane: Lane
        public var name: String
        public var start: Double
        public var end: Double?
        public var failed = false
        /// Pulse call id, to close the step that opened it.
        public var key: String?
        public var seconds: Double? { end.map { $0 - start } }
    }

    public let id: UUID
    public var spoken: Bool
    public var steps: [Step] = []
    /// Message complete seen; the trace closes when the voice is idle too.
    public var answered = false
    public var done = false

    public init(id: UUID = UUID(), spoken: Bool) { self.id = id; self.spoken = spoken }

    public var start: Double { steps.map(\.start).min() ?? 0 }
    public var end: Double { steps.map { $0.end ?? $0.start }.max() ?? start }
    public var total: Double { end - start }
    /// From the end of the user's phrase (or the submit) to the first sound of the answer.
    public var toFirstWord: Double? {
        guard let voice = steps.first(where: { $0.lane == .voice }) else { return nil }
        let from = steps.first(where: { $0.lane == .phrase && $0.name == "дочитала" })?.end
            ?? steps.first(where: { $0.lane == .gateway })?.start
        return from.map { voice.start - $0 }
    }
    /// From the submit to the end of the text answer.
    public var thinking: Double? {
        guard let sub = steps.first(where: { $0.lane == .gateway }), let txt = steps.last(where: { $0.lane == .text })?.end else { return nil }
        return txt - sub.start
    }
}

/// Builds traces of the main session. Pure: every call carries its own time.
public struct TurnRecorder: Sendable {
    public private(set) var current: TurnTrace?
    public private(set) var recent: [TurnTrace] = []
    public static let keep = 12
    /// The main session's Hermes id: pulse lines of other sessions (Чат, Telegram) are not this trace.
    public var session: String?

    public init() {}

    /// A phrase was heard: `start` when speech began, `end` when the VAD closed it, `decodeMs` the ears' last read.
    public mutating func phrase(start: Double, end: Double, decodeMs: Int) {
        begin(spoken: true)
        current?.steps.append(.init(lane: .phrase, name: "фраза", start: start, end: end))
        current?.steps.append(.init(lane: .phrase, name: "дочитала", start: end, end: end + Double(decodeMs) / 1000))
    }

    /// prompt.submit sent (`at`) and acknowledged (`ack`). A typed message starts a trace of its own.
    public mutating func submitted(at: Double, ack: Double) {
        if current == nil || current!.steps.contains(where: { $0.lane == .gateway }) { begin(spoken: false) }
        current?.steps.append(.init(lane: .gateway, name: "шлюз", start: at, end: ack))
    }

    public mutating func pulse(_ e: PulseEvent) {
        guard let s = session, e.session == s else { return }
        let lane: TurnTrace.Lane
        switch e.kind {
        case "llm.start", "llm.end", "llm.error": lane = .model
        case "tool.start", "tool.end": lane = .tool
        default: return
        }
        // Lines come from the journal a little late, with their own time: they go to the trace they belong to.
        guard let idx = traceIndex(for: e.ts) else { return }
        update(idx) { t in
            if e.kind.hasSuffix(".start") {
                t.steps.append(.init(lane: lane, name: lane == .tool ? (e.name ?? "инструмент") : "модель",
                                     start: e.ts, end: nil, key: e.callId))
            } else if let i = t.steps.lastIndex(where: { $0.lane == lane && $0.end == nil && ($0.key == e.callId || e.callId == nil) }) {
                t.steps[i].end = e.ts
                t.steps[i].failed = e.kind == "llm.error" || (e.status != nil && e.status != "ok")
            }
        }
    }

    public mutating func messageStarted(at: Double) {
        guard current != nil, !(current!.steps.contains { $0.lane == .text && $0.end == nil }) else { return }
        current?.steps.append(.init(lane: .text, name: "ответ", start: at, end: nil))
    }

    /// The answer's text is complete; with `voicePending` the trace waits for the mouth to finish.
    public mutating func messageCompleted(at: Double, voicePending: Bool) {
        guard current != nil else { return }
        if let i = current!.steps.lastIndex(where: { $0.lane == .text && $0.end == nil }) { current!.steps[i].end = at }
        else { current!.steps.append(.init(lane: .text, name: "ответ", start: at, end: at)) }
        current!.answered = true
        if !voicePending { close(at: at) }
    }

    /// Vera began speaking — the answer, or a word in the middle of the turn («Проверяю…»): each stretch of speech is a
    /// segment of the voice lane; a sentence while one is open continues it.
    public mutating func voiceStarted(at: Double) {
        guard current != nil, !(current!.steps.contains { $0.lane == .voice && $0.end == nil }) else { return }
        current?.steps.append(.init(lane: .voice, name: "голос", start: at, end: nil))
    }

    public mutating func voiceIdle(at: Double) {
        guard current != nil else { return }
        if let i = current!.steps.lastIndex(where: { $0.lane == .voice && $0.end == nil }) { current!.steps[i].end = at }
        if current!.answered { close(at: at) }
    }

    /// The turn was interrupted or failed: what is open is closed now.
    public mutating func abort(at: Double) { close(at: at) }

    private mutating func begin(spoken: Bool) {
        if let c = current, !c.steps.isEmpty { close(at: c.end) }
        current = TurnTrace(spoken: spoken)
    }

    private mutating func close(at: Double) {
        guard var t = current else { return }
        for i in t.steps.indices where t.steps[i].end == nil { t.steps[i].end = max(at, t.steps[i].start) }
        t.done = true
        recent.append(t)
        if recent.count > Self.keep { recent.removeFirst(recent.count - Self.keep) }
        current = nil
    }

    /// -1 = current; otherwise an index into `recent`.
    private func traceIndex(for ts: Double) -> Int? {
        if let c = current, ts >= c.start - 0.5 { return -1 }
        return recent.lastIndex { ts >= $0.start - 0.5 && ts <= $0.end + 0.5 }
    }

    private mutating func update(_ idx: Int, _ f: (inout TurnTrace) -> Void) {
        if idx == -1 { if current != nil { f(&current!) } } else { f(&recent[idx]) }
    }

    /// The trace to show: the one in progress, else the last one.
    public var latest: TurnTrace? { current ?? recent.last }
}
