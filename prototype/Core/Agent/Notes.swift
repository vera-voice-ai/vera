import Foundation

/// Spoken notes: one Markdown file per day, one line per note with its time. Plain files the owner can read and search too.
public final class NoteStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) { self.directory = directory }

    private static func dayName(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    @discardableResult
    public func add(_ text: String, at date: Date = Date(), calendar: Calendar = .current) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let line = String(format: "- %02d:%02d %@\n", parts.hour ?? 0, parts.minute ?? 0, clean)
        let file = directory.appending(path: Self.dayName(date, calendar: calendar) + ".md")
        lock.withLock {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            try? (existing + line).write(to: file, atomically: true, encoding: .utf8)
        }
        return file.lastPathComponent
    }

    /// Notes whose text has every word of the query, newest first, as "2026-11-19 05:44 text".
    public func search(_ query: String, limit: Int = 8) -> [String] {
        let wanted = MemoryStore.words(query)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted(by: >)
        var found: [String] = []
        for name in files {
            let lines = ((try? String(contentsOf: directory.appending(path: name), encoding: .utf8)) ?? "").split(separator: "\n").reversed()
            for line in lines where line.hasPrefix("- ") {
                let text = line.dropFirst(2)
                let have = MemoryStore.words(String(text))
                if wanted.isSubset(of: have) { found.append(name.replacingOccurrences(of: ".md", with: "") + " " + text) }
                if found.count >= limit { return found }
            }
        }
        return found
    }
}

struct AddNoteTool: AgentTool {
    let store: NoteStore
    var definition: ToolDefinition {
        ToolDefinition(name: "add_note", description: "Write down a thought or a note of the owner with the time. Use when he says «запиши», «заметка», «не забыть».",
                       parametersJSON: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#)
    }
    func run(argumentsJSON: String) -> ToolResult {
        guard let args = WorkspaceTools.arguments(argumentsJSON), let text = args["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolResult(ok: false, text: "bad arguments: need text")
        }
        return ToolResult(ok: true, text: "записала в \(store.add(text))")
    }
}

struct FindNotesTool: AgentTool {
    let store: NoteStore
    var definition: ToolDefinition {
        ToolDefinition(name: "find_notes", description: "Find earlier notes by words (what the owner wrote down or said to note). An empty query gives the latest notes.",
                       parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#)
    }
    func run(argumentsJSON: String) -> ToolResult {
        guard let args = WorkspaceTools.arguments(argumentsJSON), let query = args["query"] as? String else { return ToolResult(ok: false, text: "bad arguments: need query") }
        let hits = store.search(query)
        return ToolResult(ok: true, text: hits.isEmpty ? "заметок не нашла" : hits.joined(separator: "\n"))
    }
}

public extension ToolRegistry {
    static func noteTools(_ store: NoteStore) -> ToolRegistry { ToolRegistry([AddNoteTool(store: store), FindNotesTool(store: store)]) }
}

/// What is going on in Core, in words, for the question «что там с задачей?». The provider reads the live task list.
struct TaskStatusTool: AgentTool {
    let provider: @Sendable () async -> String
    var definition: ToolDefinition {
        ToolDefinition(name: "list_tasks", description: "What is running, waiting or just finished in your work. The task that asks is in the list as running too: do not count it.",
                       parametersJSON: #"{"type":"object","properties":{}}"#)
    }
    func run(argumentsJSON: String) -> ToolResult { ToolResult(ok: false, text: "runs asynchronously") }
    func runAsync(argumentsJSON: String) async -> ToolResult { ToolResult(ok: true, text: await provider()) }
}

public extension ToolRegistry {
    static func taskTools(_ provider: @escaping @Sendable () async -> String) -> ToolRegistry { ToolRegistry([TaskStatusTool(provider: provider)]) }
}
