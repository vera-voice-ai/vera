import Foundation

/// How Vera changes herself, safely. She works on her own copy of the source (a git worktree on the branch `vera-self`,
/// never the checkout her developer works in), and a change can go live only through these gates, in order:
/// edit → `self_test` passes on exactly these edits → `self_commit` → `self_apply` asks the owner → the owner says
/// "применяй" in a separate turn → the copy is built, and Vera restarts from it. Nothing is pushed anywhere.
public final class SelfModifier: @unchecked Sendable {
    public typealias Runner = @Sendable (_ launch: String, _ arguments: [String], _ directory: URL, _ timeout: TimeInterval) -> (code: Int32, output: String)

    public let repo: URL
    public let worktree: URL
    public let applyScript: URL
    private let run: Runner
    private let lock = NSLock()
    private var testsFresh = false
    private var committedAndTested = false
    private var pendingUntil: Date?
    private var pendingSummary = ""
    /// How long the owner has to confirm after Vera asks.
    public var confirmationWindow: TimeInterval = 300

    public init(repo: URL, worktree: URL, applyScript: URL, runner: Runner? = nil) {
        self.repo = repo; self.worktree = worktree; self.applyScript = applyScript
        self.run = runner ?? SelfModifier.shell
    }

    /// Makes sure the copy exists. Idempotent.
    @discardableResult
    public func prepare() -> Bool {
        if FileManager.default.fileExists(atPath: worktree.appending(path: ".git").path) { return true }
        try? FileManager.default.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let result = run("/usr/bin/git", ["-C", repo.path, "worktree", "add", "-B", "vera-self", worktree.path, "HEAD"], repo, 120)
        return result.code == 0
    }

    var files: WorkspaceTools { WorkspaceTools(root: worktree) }

    public var registry: ToolRegistry {
        let base = files.registry.tools.map { SelfFileTool(inner: $0, modifier: self) as any AgentTool }
        return ToolRegistry(base + [SelfTestTool(modifier: self), SelfCommitTool(modifier: self), SelfApplyTool(modifier: self)])
    }

    // MARK: Gates

    func markEdited() { lock.withLock { testsFresh = false; committedAndTested = false } }

    func test() -> ToolResult {
        guard prepare() else { return ToolResult(ok: false, text: "cannot prepare the copy of the source") }
        let result = run("/usr/bin/swift", ["test"], worktree.appending(path: "prototype"), 1500)
        let lines = result.output.split(separator: "\n").filter { $0.contains("✘") || $0.contains("Test run with") || $0.contains("error:") }.suffix(25)
        let passed = result.code == 0 && result.output.contains("Test run with") && !result.output.contains("✘")
        lock.withLock { testsFresh = passed }
        return ToolResult(ok: passed, text: (passed ? "tests passed\n" : "tests FAILED\n") + lines.joined(separator: "\n"))
    }

    func commit(message: String) -> ToolResult {
        guard lock.withLock({ testsFresh }) else { return ToolResult(ok: false, text: "refused: run self_test after your last edit, and it must pass") }
        let clean = String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !clean.isEmpty else { return ToolResult(ok: false, text: "need a commit message") }
        _ = run("/usr/bin/git", ["add", "-A"], worktree, 60)
        let result = run("/usr/bin/git", ["-c", "user.name=Vera", "-c", "user.email=vera@localhost", "commit", "-q", "-m", clean + "\n\nCo-Authored-By: Vera <vera@localhost>"], worktree, 60)
        guard result.code == 0 else { return ToolResult(ok: false, text: "nothing to commit or commit failed: \(result.output.prefix(200))") }
        lock.withLock { committedAndTested = true }
        return ToolResult(ok: true, text: "committed on branch vera-self")
    }

    func requestApply(summary: String) -> ToolResult {
        guard lock.withLock({ committedAndTested }) else { return ToolResult(ok: false, text: "refused: the change must be tested and committed first") }
        lock.withLock { pendingUntil = Date().addingTimeInterval(confirmationWindow); pendingSummary = String(summary.prefix(300)) }
        return ToolResult(ok: true, text: "waiting for the owner. Ask him aloud, in one sentence, to say «применяй» to apply this change and restart you, or to ignore it. Do not apply anything yourself.")
    }

    public var hasPendingApply: Bool { lock.withLock { (pendingUntil ?? .distantPast) > Date() } }
    public var pendingDescription: String { lock.withLock { pendingSummary } }
    public func cancelPending() { lock.withLock { pendingUntil = nil } }

    /// Only the owner's own spoken confirmation may call this (Core does, on a "применяй" turn while a request is pending).
    /// Builds the copy; returns true when a restart should follow.
    public func applyConfirmed() -> (ok: Bool, log: String) {
        guard hasPendingApply else { return (false, "nothing is waiting for confirmation") }
        cancelPending()
        let result = run("/bin/zsh", [applyScript.path, worktree.path], worktree, 1800)
        return (result.code == 0, String(result.output.suffix(400)))
    }

    // MARK: Processes

    static let shell: Runner = { launch, arguments, directory, timeout in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        var data = Data()
        let reader = DispatchQueue(label: "vera.self.read")
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            reader.sync { if data.count < 2_000_000 { data.append(chunk) } }
        }
        do { try process.run() } catch { return (127, "cannot start \(launch): \(error)") }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.5) }
        pipe.fileHandleForReading.readabilityHandler = nil
        let output = reader.sync { String(decoding: data, as: UTF8.self) }
        return (process.isRunning ? 124 : process.terminationStatus, output)
    }
}

/// The ordinary file tools, renamed `self_*` and kept out of `.git` and build folders.
struct SelfFileTool: AgentTool {
    let inner: any AgentTool
    let modifier: SelfModifier
    var definition: ToolDefinition {
        let d = inner.definition
        return ToolDefinition(name: "self_" + d.name, description: "[ТВОЙ СОБСТВЕННЫЙ КОД, отдельная копия] " + d.description, parametersJSON: d.parametersJSON)
    }
    func run(argumentsJSON: String) -> ToolResult {
        guard modifier.prepare() else { return ToolResult(ok: false, text: "the copy of the source is not available") }
        if let args = WorkspaceTools.arguments(argumentsJSON), let path = args["path"] as? String {
            let parts = path.split(separator: "/").map(String.init)
            if parts.contains(".git") || parts.contains(".build") { return ToolResult(ok: false, text: "refused: this folder is off limits") }
        }
        let result = inner.run(argumentsJSON: argumentsJSON)
        if result.ok, inner.definition.name != "read_file", inner.definition.name != "list_dir" { modifier.markEdited() }
        return result
    }
}

struct SelfTestTool: AgentTool {
    let modifier: SelfModifier
    var definition: ToolDefinition {
        ToolDefinition(name: "self_test", description: "Run the whole test suite of your own source copy (takes minutes). A change can only be committed after this passes.",
                       parametersJSON: #"{"type":"object","properties":{}}"#)
    }
    func run(argumentsJSON: String) -> ToolResult { modifier.test() }
}

struct SelfCommitTool: AgentTool {
    let modifier: SelfModifier
    var definition: ToolDefinition {
        ToolDefinition(name: "self_commit", description: "Commit your edits to your own branch. Refused unless self_test passed after the last edit.",
                       parametersJSON: #"{"type":"object","properties":{"message":{"type":"string"}},"required":["message"]}"#)
    }
    func run(argumentsJSON: String) -> ToolResult {
        guard let args = WorkspaceTools.arguments(argumentsJSON), let message = args["message"] as? String else { return ToolResult(ok: false, text: "bad arguments: need message") }
        return modifier.commit(message: message)
    }
}

struct SelfApplyTool: AgentTool {
    let modifier: SelfModifier
    var definition: ToolDefinition {
        ToolDefinition(name: "self_apply", description: "Ask the owner to let you switch to your changed code and restart. It does not apply anything by itself: the owner must say «применяй».",
                       parametersJSON: #"{"type":"object","properties":{"summary":{"type":"string","description":"What changed, in one sentence"}},"required":["summary"]}"#)
    }
    func run(argumentsJSON: String) -> ToolResult {
        guard let args = WorkspaceTools.arguments(argumentsJSON), let summary = args["summary"] as? String else { return ToolResult(ok: false, text: "bad arguments: need summary") }
        return modifier.requestApply(summary: summary)
    }
}

/// Vera's own skills are Markdown files she may write herself.
struct WriteSkillTool: AgentTool {
    let store: SkillStore
    var definition: ToolDefinition {
        ToolDefinition(name: "write_skill", description: "Create or update one of your skills: a short procedure you will see in the skill list next time. Use it when you learned a better way to do a kind of task.",
                       parametersJSON: #"{"type":"object","properties":{"name":{"type":"string","description":"latin letters, digits and dashes"},"description":{"type":"string","description":"one line: when to use it"},"body":{"type":"string"}},"required":["name","description","body"]}"#)
    }
    func run(argumentsJSON: String) -> ToolResult {
        guard let args = WorkspaceTools.arguments(argumentsJSON), let name = args["name"] as? String, let description = args["description"] as? String,
              let body = args["body"] as? String else { return ToolResult(ok: false, text: "bad arguments: need name, description and body") }
        guard name.range(of: "^[a-z0-9][a-z0-9-]{0,40}$", options: .regularExpression) != nil else { return ToolResult(ok: false, text: "bad skill name") }
        guard body.count <= 8000, !description.contains("\n") else { return ToolResult(ok: false, text: "skill too long or description has line breaks") }
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        do {
            try "---\nname: \(name)\ndescription: \(description)\n---\n\(body)\n".write(to: store.directory.appending(path: name + ".md"), atomically: true, encoding: .utf8)
            return ToolResult(ok: true, text: "skill \(name) saved")
        } catch { return ToolResult(ok: false, text: "cannot save: \(error.localizedDescription)") }
    }
}

public extension SkillStore { var writeRegistry: ToolRegistry { ToolRegistry([WriteSkillTool(store: self)]) } }
