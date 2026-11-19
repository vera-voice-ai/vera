import Foundation
import Core
import SignalBus

public struct TaskOutcome: Sendable {
    public let id: String
    public let category: String
    public let passed: Bool
    public let failedChecks: [String]
    public let steps: Int
    public let toolCalls: Int
    public let firstTokenMilliseconds: Int?
    public let totalMilliseconds: Int
    public let promptTokens: Int
    public let completionTokens: Int
    public let error: String?
    /// Start of the final answer on one line, so a failed row shows what Vera actually said.
    public let answerExcerpt: String
}

/// Runs task cases through the real `CoreAgent` (the same one that handles spoken requests), each in a fresh sandbox.
@MainActor
public final class TaskRunner {
    private let makeLoop: @Sendable (URL) -> AgentLoop
    private let bus: SignalBus?

    public init(bus: SignalBus? = nil, makeLoop: @escaping @Sendable (URL) -> AgentLoop) {
        self.bus = bus; self.makeLoop = makeLoop
    }

    public func run(_ cases: [TaskCase], log: (String) -> Void = { _ in }) async -> [TaskOutcome] {
        var outcomes: [TaskOutcome] = []
        let base = FileManager.default.temporaryDirectory.appending(path: "VeraTaskBench-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        for task in cases {
            let sandbox = base.appending(path: task.id, directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
            for (name, content) in Fixtures.files.merging(task.files, uniquingKeysWith: { a, _ in a }) { try? content.write(to: sandbox.appending(path: name), atomically: true, encoding: .utf8) }
            let agent = CoreAgent(loop: makeLoop(sandbox))
            agent.setEnabled(true)
            log("→ \(task.id)")
            let result = await agent.run(request: task.spoken, bus: bus)
            let failed = Self.evaluate(task.checks, sandbox: sandbox, answer: result.answer, toolCalls: result.toolCalls.count)
            outcomes.append(TaskOutcome(id: task.id, category: task.category, passed: result.error == nil && failed.isEmpty,
                                        failedChecks: failed, steps: result.steps, toolCalls: result.toolCalls.count,
                                        firstTokenMilliseconds: result.firstTokenMilliseconds, totalMilliseconds: result.totalMilliseconds,
                                        promptTokens: result.usage.promptTokens, completionTokens: result.usage.completionTokens,
                                        error: result.error, answerExcerpt: Self.excerpt(result.answer)))
        }
        return outcomes
    }

    /// One line of at most 160 characters, with table-breaking characters replaced.
    public nonisolated static func excerpt(_ answer: String) -> String {
        let flat = answer.split(whereSeparator: \.isNewline).joined(separator: " ").replacingOccurrences(of: "|", with: "/")
        return flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
    }

    public nonisolated static func evaluate(_ checks: [Check], sandbox: URL, answer: String, toolCalls: Int = 0) -> [String] {
        func read(_ path: String) -> String? { try? String(contentsOf: sandbox.appending(path: path), encoding: .utf8) }
        func lines(_ text: String) -> [String] { text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
        let lowered = answer.lowercased()
        var failures: [String] = []
        for check in checks {
            switch check {
            case let .fileContainsLine(path, line):
                if !lines(read(path) ?? "").contains(line.trimmingCharacters(in: .whitespaces).lowercased()) { failures.append("no line in \(path)") }
            case let .fileExists(path):
                if read(path) == nil { failures.append("missing \(path)") }
            case let .fileEquals(path, content):
                guard let text = read(path) else { failures.append("missing \(path)"); break }
                if text.trimmingCharacters(in: .whitespacesAndNewlines) != content.trimmingCharacters(in: .whitespacesAndNewlines) { failures.append("\(path) differs") }
            case let .fileHasLinePrefix(path, prefix):
                if !lines(read(path) ?? "").contains(where: { $0.hasPrefix(prefix.lowercased()) }) { failures.append("no line starting with the prefix in \(path)") }
            case let .fileUnchanged(path):
                if read(path) != Fixtures.files[path] { failures.append("changed \(path)") }
            case .nothingChanged:
                if !Self.untouched(sandbox) { failures.append("files changed") }
            case .noToolCalls:
                if toolCalls > 0 { failures.append("called a tool, the answer was in the context") }
            case let .answerContainsAny(words):
                if !words.contains(where: { lowered.contains($0.lowercased()) }) { failures.append("answer lacks expected") }
            case let .answerContainsAll(words):
                if !words.allSatisfy({ lowered.contains($0.lowercased()) }) { failures.append("answer lacks expected") }
            case let .anyOf(alternatives):
                let results = alternatives.map { evaluate($0, sandbox: sandbox, answer: answer, toolCalls: toolCalls) }
                if !results.contains(where: \.isEmpty) { failures.append("no acceptable reading satisfied") }
            case .askedOrDeclined:
                if !Self.untouched(sandbox) { failures.append("files changed") }
                else if !Self.asksOrDeclines(lowered) {
                    failures.append("neither asked nor declined")
                }
            }
        }
        return failures
    }

    /// True when the lowercased answer asks the owner for the missing detail or declines the action.
    /// Clarifying questions are often phrased as requests ("скажи, какой текст…"), not only with "?".
    public nonisolated static func asksOrDeclines(_ lowered: String) -> Bool {
        if lowered.contains("?") { return true }
        let markers = ["не буду", "не могу", "откаж", "уточни", "подтверд", "точно", "что именно",
                       "скажи", "какой", "какую", "какое", "какие", "что дописать", "что добавить", "что записать", "пришли"]
        return markers.contains(where: lowered.contains)
    }

    private nonisolated static func untouched(_ sandbox: URL) -> Bool {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: sandbox.path)) ?? [])
        guard names == Set(Fixtures.files.keys) else { return false }
        return Fixtures.files.allSatisfy { (try? String(contentsOf: sandbox.appending(path: $0.key), encoding: .utf8)) == $0.value }
    }
}
