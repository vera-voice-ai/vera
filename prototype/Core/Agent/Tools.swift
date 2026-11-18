import Foundation

public struct ToolResult: Sendable {
    public let ok: Bool
    public let text: String
    public init(ok: Bool, text: String) { self.ok = ok; self.text = text }
}

/// One thing the agent can do. Arguments arrive as the model's raw JSON text.
public protocol AgentTool: Sendable {
    var definition: ToolDefinition { get }
    func run(argumentsJSON: String) -> ToolResult
}

public struct ToolRegistry: Sendable {
    public let tools: [any AgentTool]
    public init(_ tools: [any AgentTool]) { self.tools = tools }
    public var definitions: [ToolDefinition] { tools.map(\.definition) }
    public func run(_ call: ToolCall) -> ToolResult {
        guard let tool = tools.first(where: { $0.definition.name == call.name }) else {
            return ToolResult(ok: false, text: "unknown tool \(call.name)")
        }
        return tool.run(argumentsJSON: call.arguments)
    }
}

/// The four file tools, confined to one folder. Paths that leave it (by `..`, an absolute path or a symlink) are refused.
public struct WorkspaceTools: Sendable {
    public let root: URL
    public let maxReadCharacters = 20_000
    public let maxWriteCharacters = 100_000

    public init(root: URL) { self.root = root }

    public var registry: ToolRegistry {
        ToolRegistry([ReadFileTool(box: self), ListDirectoryTool(box: self), WriteFileTool(box: self), ReplaceInFileTool(box: self)])
    }

    func resolve(_ path: String) -> URL? {
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = (cleaned.hasPrefix("/") ? URL(fileURLWithPath: cleaned) : base.appending(path: cleaned))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path == base.path || candidate.path.hasPrefix(base.path + "/") else { return nil }
        return candidate
    }

    /// Names in the folder that a missing path probably meant: the same name with an extension added ("status" → "status.txt").
    func suggestions(for path: String) -> String {
        let wanted = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return "" }
        let close = names.filter { $0.hasPrefix(wanted + ".") || $0.hasPrefix(wanted) && wanted.count >= 3 }.sorted().prefix(5)
        return close.isEmpty ? "" : " (did you mean: \(close.joined(separator: ", "))?)"
    }

    static func arguments(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    static let outside = ToolResult(ok: false, text: "refused: the path is outside the working folder")
}

struct ReadFileTool: AgentTool {
    let box: WorkspaceTools
    var definition: ToolDefinition {
        ToolDefinition(name: "read_file", description: "Read a text file from the working folder.",
                       parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"File path relative to the working folder"}},"required":["path"]}"#)
    }
    func run(argumentsJSON: String) -> ToolResult {
        guard let args = WorkspaceTools.arguments(argumentsJSON), let path = args["path"] as? String else { return ToolResult(ok: false, text: "bad arguments: need path") }
        guard let url = box.resolve(path) else { return WorkspaceTools.outside }
        if !FileManager.default.fileExists(atPath: url.path) {
            return ToolResult(ok: false, text: "no file named \(path)" + box.suggestions(for: path))
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ToolResult(ok: false, text: "cannot read \(path) as text") }
        if text.count > box.maxReadCharacters { return ToolResult(ok: true, text: String(text.prefix(box.maxReadCharacters)) + "\n[truncated]") }
        return ToolResult(ok: true, text: text)
    }
}

struct ListDirectoryTool: AgentTool {
    let box: WorkspaceTools
    var definition: ToolDefinition {
        ToolDefinition(name: "list_dir", description: "List the entries of a folder in the working folder (use \".\" for the root). Folders end with /.",
                       parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#)
    }
    func run(argumentsJSON: String) -> ToolResult {
        guard let args = WorkspaceTools.arguments(argumentsJSON) else { return ToolResult(ok: false, text: "bad arguments") }
        guard let url = box.resolve((args["path"] as? String).flatMap { $0.isEmpty ? "." : $0 } ?? ".") else { return WorkspaceTools.outside }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return ToolResult(ok: false, text: "cannot list that folder") }
        let lines = names.sorted().map { name -> String in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.appending(path: name).path, isDirectory: &isDirectory)
            return isDirectory.boolValue ? name + "/" : name
        }
        return ToolResult(ok: true, text: lines.isEmpty ? "(empty)" : lines.joined(separator: "\n"))
    }
}

struct WriteFileTool: AgentTool {
    let box: WorkspaceTools
    var definition: ToolDefinition {
        ToolDefinition(name: "write_file", description: "Create a file or replace it completely with the given text.",
                       parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}"#)
    }
    func run(argumentsJSON: String) -> ToolResult {
        guard let args = WorkspaceTools.arguments(argumentsJSON), let path = args["path"] as? String, let content = args["content"] as? String else {
            return ToolResult(ok: false, text: "bad arguments: need path and content")
        }
        guard content.count <= box.maxWriteCharacters else { return ToolResult(ok: false, text: "refused: content is too large") }
        guard let url = box.resolve(path) else { return WorkspaceTools.outside }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return ToolResult(ok: true, text: "written \(path) (\(content.count) characters)")
        } catch { return ToolResult(ok: false, text: "cannot write: \(error.localizedDescription)") }
    }
}

struct ReplaceInFileTool: AgentTool {
    let box: WorkspaceTools
    var definition: ToolDefinition {
        ToolDefinition(name: "replace_in_file", description: "Replace text in an existing file. `old` must occur exactly once unless replace_all is true. Prefer this to rewriting a whole file.",
                       parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"},"old":{"type":"string"},"new":{"type":"string"},"replace_all":{"type":"boolean"}},"required":["path","old","new"]}"#)
    }
    func run(argumentsJSON: String) -> ToolResult {
        guard let args = WorkspaceTools.arguments(argumentsJSON), let path = args["path"] as? String,
              let old = args["old"] as? String, let new = args["new"] as? String, !old.isEmpty else {
            return ToolResult(ok: false, text: "bad arguments: need path, old (not empty) and new")
        }
        guard let url = box.resolve(path) else { return WorkspaceTools.outside }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ToolResult(ok: false, text: "cannot read \(path) as text") }
        let count = text.components(separatedBy: old).count - 1
        guard count > 0 else { return ToolResult(ok: false, text: "the text to replace was not found") }
        let all = args["replace_all"] as? Bool ?? false
        guard count == 1 || all else { return ToolResult(ok: false, text: "the text occurs \(count) times; give more context or set replace_all") }
        do {
            try text.replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
            return ToolResult(ok: true, text: "replaced \(all ? count : 1) occurrence(s) in \(path)")
        } catch { return ToolResult(ok: false, text: "cannot write: \(error.localizedDescription)") }
    }
}
