import Foundation

/// Skills are Markdown files in one folder, each starting with a front-matter block:
///
///     ---
///     name: edit-file
///     description: one line saying when to use it
///     ---
///     the full procedure...
///
/// The model sees only the list of names and one-line descriptions; it loads a full text with `read_skill` when the task
/// needs it (progressive disclosure), so unused skills cost almost no context.
public struct SkillStore: Sendable {
    public struct Skill: Sendable, Equatable { public let name: String; public let description: String; public let body: String }

    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func all() -> [Skill] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { Self.parse(try? String(contentsOf: $0, encoding: .utf8), fallbackName: $0.deletingPathExtension().lastPathComponent) }
    }

    /// The list shown to the model in every task.
    public func catalogText() -> String? {
        let skills = all()
        guard !skills.isEmpty else { return nil }
        return "Навыки (полный текст — через read_skill, когда задача подходит):\n" + skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
    }

    static func parse(_ text: String?, fallbackName: String) -> Skill? {
        guard let text, !text.isEmpty else { return nil }
        var name = fallbackName, description = "", body = text
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            for line in text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
                if line.hasPrefix("name:") { name = line.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                if line.hasPrefix("description:") { description = line.dropFirst(12).trimmingCharacters(in: .whitespaces) }
            }
            body = String(text[end.upperBound...])
        }
        return Skill(name: name, description: description, body: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public var registry: ToolRegistry { ToolRegistry([ReadSkillTool(store: self)]) }
}

struct ReadSkillTool: AgentTool {
    let store: SkillStore
    var definition: ToolDefinition {
        ToolDefinition(name: "read_skill", description: "Load the full text of a skill from the skill list.",
                       parametersJSON: #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#)
    }
    func run(argumentsJSON: String) -> ToolResult {
        guard let args = WorkspaceTools.arguments(argumentsJSON), let name = args["name"] as? String else { return ToolResult(ok: false, text: "bad arguments: need name") }
        guard let skill = store.all().first(where: { $0.name == name }) else { return ToolResult(ok: false, text: "no skill named \(name)") }
        return ToolResult(ok: true, text: skill.body)
    }
}
