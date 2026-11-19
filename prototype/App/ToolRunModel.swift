import Foundation
import Observation
import SignalBus

/// Counts per key for the current local day. The first count after local midnight starts again from zero.
struct DayCounter: Sendable {
    private let calendar: Calendar
    private var day: Date
    private var counts: [String: Int] = [:]

    init(now: Date, calendar: Calendar) {
        self.calendar = calendar
        self.day = calendar.startOfDay(for: now)
    }

    /// Reads the count for `now`'s day; a count left over from an earlier day reads as zero.
    func count(_ key: String, now: Date) -> Int {
        calendar.isDate(day, inSameDayAs: now) ? counts[key, default: 0] : 0
    }

    mutating func increment(_ key: String, now: Date) {
        if !calendar.isDate(day, inSameDayAs: now) {
            day = calendar.startOfDay(for: now)
            counts = [:]
        }
        counts[key, default: 0] += 1
    }
}

/// Runs of the strong tools (codex, claude) that Core asked for. It only shows what Core and the tools report on the bus:
/// `core.toolrun.started`, `core.toolrun.progress`, `core.toolrun.finished` from `Core.Tools`.
@MainActor
@Observable
final class ToolRunModel {
    enum State: String, Sendable {
        case running, done, failed, cancelled
    }

    struct Run: Identifiable, Equatable, Sendable {
        let id: String
        let tool: String
        let title: String
        var state: State
        let startedAt: Date
        /// The last progress line while running, one line as the tool printed it.
        var progressLine = ""
        var summary = ""
        /// Set when the run finishes; a running run takes its elapsed time from `startedAt` and the clock.
        var finishedElapsed: TimeInterval?
    }

    static let capacity = 20
    /// The tools that get a row in the panel; a future tool gets its own row here.
    static let knownTools = ["codex", "claude"]

    /// Newest first, at most `capacity`.
    private(set) var runs: [Run] = []
    private var counter: DayCounter
    private let clock: @Sendable () -> Date

    init(clock: @escaping @Sendable () -> Date = { .now }, calendar: Calendar = .current) {
        self.clock = clock
        self.counter = DayCounter(now: clock(), calendar: calendar)
    }

    func consume(_ bus: SignalBus) async {
        for await message in await bus.subscribe() {
            handle(message)
        }
    }

    func handle(_ message: SignalMessage) {
        guard message.domain == .core, message.source == "Core.Tools" else { return }
        let payload = message.payload
        switch message.type {
        case "core.toolrun.started":
            start(message)
        case "core.toolrun.progress":
            // Progress only moves a run that is still running; an unknown id is ignored.
            guard let index = index(of: payload["id"]), runs[index].state == .running else { return }
            runs[index].progressLine = payload["line"] ?? ""
        case "core.toolrun.finished":
            guard let index = index(of: payload["id"]), runs[index].state == .running else { return }
            runs[index].state = Self.finishState(payload["state"])
            runs[index].summary = payload["summary"] ?? ""
            runs[index].finishedElapsed = Double(payload["elapsed_s"] ?? "")
                ?? max(0, message.timestamp.timeIntervalSince(runs[index].startedAt))
            runs[index].progressLine = ""
        default:
            break
        }
    }

    /// Runs of one tool that started today, counted at their start (not limited by the list cap).
    func runsToday(_ tool: String) -> Int {
        counter.count(tool, now: clock())
    }

    /// The state of the newest run of a tool, or nil when it has not run yet (or its run left the list).
    func lastState(of tool: String) -> State? {
        runs.first { $0.tool == tool }?.state
    }

    func elapsed(of run: Run, at now: Date) -> TimeInterval {
        run.finishedElapsed ?? max(0, now.timeIntervalSince(run.startedAt))
    }

    /// m:ss, for elapsed times in the panel.
    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func start(_ message: SignalMessage) {
        let payload = message.payload
        guard let id = payload["id"], !id.isEmpty, index(of: id) == nil else { return }
        let startedAt = Double(payload["started_at"] ?? "").map { Date(timeIntervalSince1970: $0) } ?? message.timestamp
        let tool = payload["tool"] ?? ""
        runs.insert(Run(id: id, tool: tool, title: payload["title"] ?? "", state: .running, startedAt: startedAt), at: 0)
        if runs.count > Self.capacity { runs.removeLast(runs.count - Self.capacity) }
        counter.increment(tool, now: clock())
    }

    private func index(of id: String?) -> Int? {
        guard let id else { return nil }
        return runs.firstIndex { $0.id == id }
    }

    private static func finishState(_ raw: String?) -> State {
        switch raw {
        case "done": return .done
        case "cancelled": return .cancelled
        default: return .failed
        }
    }
}
