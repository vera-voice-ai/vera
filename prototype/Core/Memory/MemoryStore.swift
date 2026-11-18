import Foundation

/// What Vera keeps between tasks and restarts, as two JSON Lines files in one folder:
/// `facts.jsonl` (things the owner asked her to remember) and `history.jsonl` (every finished task: request and answer).
/// Search is plain word overlap: enough to find "что я просил про кодовое слово" without an index or a model.
public final class MemoryStore: @unchecked Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case fact, task }
        public let kind: Kind
        public let at: Date
        public let text: String
        /// For tasks: the answer that was given.
        public let answer: String?
    }

    public let directory: URL
    private let lock = NSLock()
    private let maxFactCharacters = 500
    private let maxFileBytes = 20 * 1024 * 1024

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private var factsURL: URL { directory.appending(path: "facts.jsonl") }
    private var historyURL: URL { directory.appending(path: "history.jsonl") }

    @discardableResult
    public func remember(_ text: String, at date: Date = .now) -> Bool {
        let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxFactCharacters))
        guard !clean.isEmpty else { return false }
        return append(Entry(kind: .fact, at: date, text: clean, answer: nil), to: factsURL)
    }

    public func recordTask(request: String, answer: String, at date: Date = .now) {
        append(Entry(kind: .task, at: date, text: String(request.prefix(400)), answer: String(answer.prefix(600))), to: historyURL)
    }

    /// The best matches first. A fact beats a task of the same score; newer beats older.
    public func search(_ query: String, limit: Int = 5) -> [Entry] {
        let wanted = Self.words(query)
        guard !wanted.isEmpty else { return [] }
        let scored: [(Entry, Int)] = (entries(factsURL) + entries(historyURL)).compactMap { entry in
            let have = Self.words(entry.text + " " + (entry.answer ?? ""))
            let score = wanted.reduce(0) { $0 + (have.contains($1) ? 1 : 0) }
            return score > 0 ? (entry, score) : nil
        }
        return scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.kind != $1.0.kind { return $0.0.kind == .fact }
            return $0.0.at > $1.0.at
        }.prefix(limit).map(\.0)
    }

    /// All remembered facts, oldest first, for the model's background context.
    public func factsText(limit: Int = 40) -> String? {
        let facts = entries(factsURL).suffix(limit)
        guard !facts.isEmpty else { return nil }
        return "Что Алексей просил запомнить:\n" + facts.map { "- \($0.text)" }.joined(separator: "\n")
    }

    public var counts: (facts: Int, tasks: Int) { (entries(factsURL).count, entries(historyURL).count) }

    // MARK: - Files

    private func entries(_ url: URL) -> [Entry] {
        lock.withLock {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            return text.split(separator: "\n").compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
        }
    }

    @discardableResult
    private func append(_ entry: Entry, to url: URL) -> Bool {
        lock.withLock {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
            guard var line = try? encoder.encode(entry) else { return false }
            line.append(0x0A)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxFileBytes { return false }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return false }
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf: line); return true } catch { return false }
        }
    }

    /// Lower-cased words of three letters or more, with endings cut so that "слова" finds "слово".
    static func words(_ text: String) -> Set<String> {
        var result = Set<String>()
        for piece in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where piece.count >= 3 {
            result.insert(piece.count > 5 ? String(piece.dropLast(2)) : String(piece))
        }
        return result
    }
}

struct RememberTool: AgentTool {
    let memory: MemoryStore
    var definition: ToolDefinition {
        ToolDefinition(name: "remember", description: "Save one short fact the owner asked to remember (a preference, a name, a decision). It stays after restarts and is shown to you in later tasks.",
                       parametersJSON: #"{"type":"object","properties":{"fact":{"type":"string","description":"One self-contained sentence"}},"required":["fact"]}"#)
    }
    func run(argumentsJSON: String) -> ToolResult {
        guard let args = WorkspaceTools.arguments(argumentsJSON), let fact = args["fact"] as? String else { return ToolResult(ok: false, text: "bad arguments: need fact") }
        return memory.remember(fact) ? ToolResult(ok: true, text: "remembered") : ToolResult(ok: false, text: "nothing to remember or the memory is full")
    }
}

struct SearchMemoryTool: AgentTool {
    let memory: MemoryStore
    var definition: ToolDefinition {
        ToolDefinition(name: "search_memory", description: "Search what the owner asked to remember and the earlier tasks (requests and answers) by words. Use it when the owner refers to something from before.",
                       parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#)
    }
    func run(argumentsJSON: String) -> ToolResult {
        guard let args = WorkspaceTools.arguments(argumentsJSON), let query = args["query"] as? String else { return ToolResult(ok: false, text: "bad arguments: need query") }
        let found = memory.search(query)
        guard !found.isEmpty else { return ToolResult(ok: true, text: "nothing found") }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return ToolResult(ok: true, text: found.map { entry in
            let when = formatter.string(from: entry.at)
            return entry.kind == .fact ? "[\(when)] факт: \(entry.text)" : "[\(when)] просьба: \(entry.text) → ответ: \(entry.answer ?? "")"
        }.joined(separator: "\n"))
    }
}

public extension ToolRegistry {
    static func memoryTools(_ memory: MemoryStore) -> ToolRegistry { ToolRegistry([RememberTool(memory: memory), SearchMemoryTool(memory: memory)]) }
    func adding(_ other: ToolRegistry) -> ToolRegistry { ToolRegistry(tools + other.tools) }
}
