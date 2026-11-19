import Foundation
import SignalBus

/// One run of an external agent tool, as the board remembers it.
public struct ToolRun: Sendable, Equatable {
    public enum State: String, Sendable { case running, done, failed, cancelled }

    public let id: String
    public let tool: String
    public let title: String
    public internal(set) var state: State
    public let startedAt: Date
    public internal(set) var finishedAt: Date?
    public internal(set) var lastProgress: String?
    public internal(set) var summary: String?

    public func elapsed(at now: Date = .now) -> TimeInterval { (finishedAt ?? now).timeIntervalSince(startedAt) }
}

/// Records the runs of the external agent tools and tells the bus about them:
/// `core.toolrun.started`, `core.toolrun.progress` and `core.toolrun.finished`, in that order for each run.
/// Thread-safe. Events go through one ordered outbox, so a slow bus never reorders them.
public final class ToolRunBoard: @unchecked Sendable {
    public static let maxRemembered = 50
    static let source = "Core.Tools"

    private let lock = NSLock()
    private var runs: [ToolRun] = []
    private let outbox: AsyncStream<SignalMessage>.Continuation?

    public init(bus: SignalBus? = nil) {
        if let bus {
            let (stream, continuation) = AsyncStream<SignalMessage>.makeStream()
            outbox = continuation
            Task {
                for await message in stream { await bus.publish(message) }
            }
        } else {
            outbox = nil
        }
    }

    /// The runs, oldest first (the last `maxRemembered`).
    public func all() -> [ToolRun] { lock.withLock { runs } }

    public func run(_ id: String) -> ToolRun? { lock.withLock { runs.first { $0.id == id } } }

    /// Starts a run. The title is the first 80 characters of the task.
    @discardableResult
    public func start(tool: String, task: String, now: Date = .now) -> String {
        let id = String(UUID().uuidString.lowercased().prefix(8))
        let title = String(Self.oneLine(task).prefix(80))
        lock.withLock {
            runs.append(ToolRun(id: id, tool: tool, title: title, state: .running, startedAt: now))
            runs = Array(runs.suffix(Self.maxRemembered))
            publish(type: "core.toolrun.started", id: id, payload: [
                "id": id, "tool": tool, "title": title, "state": "running",
                "started_at": String(Int(now.timeIntervalSince1970))
            ])
        }
        return id
    }

    /// The latest line of progress (up to 120 characters). Ignored once the run has finished.
    public func progress(_ id: String, line: String, now: Date = .now) {
        let cleaned = String(Self.oneLine(line).prefix(120))
        guard !cleaned.isEmpty else { return }
        lock.withLock {
            guard let index = runs.firstIndex(where: { $0.id == id }), runs[index].state == .running else { return }
            runs[index].lastProgress = cleaned
            publish(type: "core.toolrun.progress", id: id, payload: [
                "id": id, "line": cleaned, "elapsed_s": Self.seconds(runs[index].elapsed(at: now))
            ])
        }
    }

    /// Ends a run with a summary (up to 300 characters). A second call for the same run is ignored.
    public func finish(_ id: String, state: ToolRun.State, summary: String, now: Date = .now) {
        let cleaned = String(Self.oneLine(summary).prefix(300))
        lock.withLock {
            guard let index = runs.firstIndex(where: { $0.id == id }), runs[index].state == .running else { return }
            runs[index].state = state
            runs[index].finishedAt = now
            runs[index].summary = cleaned
            publish(type: "core.toolrun.finished", id: id, payload: [
                "id": id, "state": state.rawValue, "summary": cleaned, "elapsed_s": Self.seconds(runs[index].elapsed(at: now))
            ])
        }
    }

    // Called under the lock, so the order of the yields is the order of the calls.
    private func publish(type: String, id: String, payload: [String: String]) {
        outbox?.yield(SignalMessage(kind: .event, domain: .core, source: Self.source, type: type,
                                    subjectID: "toolrun/\(id)", payload: payload))
    }

    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func seconds(_ interval: TimeInterval) -> String { String(Int(interval.rounded(.down))) }
}
