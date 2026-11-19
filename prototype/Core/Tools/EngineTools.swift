import Foundation

enum EngineMode: String {
    case read, write
}

/// What a run leaves behind for the outcome: the Claude result line, if it came.
final class EngineCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: (text: String, isError: Bool)?

    func setClaude(text: String, isError: Bool) { lock.withLock { answer = (text, isError) } }
    var claude: (text: String, isError: Bool)? { lock.withLock { answer } }
}

/// Runs one external CLI for one tool call: a board record, one process with its own arguments and environment, and a capped answer.
struct EngineExecutor: Sendable {
    let locator: EngineLocator
    let workspace: URL
    let board: ToolRunBoard
    let timeout: TimeInterval

    func execute(_ kind: EngineKind, argumentsJSON: String) async -> ToolResult {
        let board = self.board
        guard let args = WorkspaceTools.arguments(argumentsJSON), let raw = args["task"] as? String else {
            return ToolResult(ok: false, text: "bad arguments: need task")
        }
        let task = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return ToolResult(ok: false, text: "bad arguments: need task") }
        guard let mode = EngineMode(rawValue: (args["mode"] as? String) ?? EngineMode.read.rawValue) else {
            return ToolResult(ok: false, text: "bad arguments: mode is read or write")
        }

        let runID = board.start(tool: kind.binaryName, task: task)
        func fail(_ message: String, state: ToolRun.State = .failed) -> ToolResult {
            board.finish(runID, state: state, summary: message)
            return ToolResult(ok: false, text: message)
        }

        guard let location = locator.locate(kind) else { return fail(EngineText.notFound(kind)) }
        board.progress(runID, line: location.source == .veraCopy ? "движок: копия Веры" : "движок: системный, не копия Веры")
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "vera-engine-\(runID)-\(UUID().uuidString.lowercased().prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try locator.prepareHomes()
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return fail("\(EngineText.name(kind)) не запустился: не готовы папки")
        }
        let lastMessage = scratch.appending(path: "last-message.txt")

        let capture = EngineCapture()
        let arguments = kind == .codex
            ? Self.codexArguments(task: task, mode: mode, workspace: workspace, lastMessage: lastMessage)
            : Self.claudeArguments(task: task, mode: mode)
        let result = await CLIRunner.run(executable: location.executable, arguments: arguments,
                                         environment: locator.environment(for: location, kind: kind),
                                         workingDirectory: workspace, timeout: timeout) { line in
            if kind == .codex {
                if let snippet = EngineProgress.codexLine(line) { board.progress(runID, line: snippet) }
                return
            }
            switch EngineProgress.claudeLine(line) {
            case let .progress(text): board.progress(runID, line: text)
            case let .result(text, isError): capture.setClaude(text: text, isError: isError)
            case .ignored: break
            }
        }

        switch result.outcome {
        case .cancelled: return fail(EngineText.cancelled(kind), state: .cancelled)
        case .timedOut: return fail(EngineText.timedOut(kind))
        case .launchFailed: return fail(EngineText.launchFailed(kind))
        case let .exited(code):
            let claude = capture.claude
            let codexAnswer = kind == .codex ? (try? String(contentsOf: lastMessage, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) : nil
            let answer = kind == .codex ? codexAnswer : claude?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let claudeFailed = claude?.isError ?? false
            if code == 0, !claudeFailed, let answer, !answer.isEmpty {
                board.finish(runID, state: .done, summary: answer)
                return ToolResult(ok: true, text: EngineText.answer(answer))
            }
            if EngineText.looksLoggedOut(result.recentOutput) { return fail(EngineText.notLoggedIn(kind)) }
            if claudeFailed { return fail(EngineText.failed(kind, code: code, detail: EngineText.sanitize(answer ?? ""))) }
            if code != 0 {
                return fail(EngineText.failed(kind, code: code, detail: EngineText.sanitize(result.lastErrorLine ?? "")))
            }
            return fail(EngineText.noAnswer(kind))
        }
    }

    /// `codex exec`: JSON events on stdout, the final message into a file, the task as one argument after `--`.
    static func codexArguments(task: String, mode: EngineMode, workspace: URL, lastMessage: URL) -> [String] {
        ["exec", "--json", "--skip-git-repo-check", "-C", workspace.path,
         "-s", mode == .read ? "read-only" : "workspace-write",
         "--output-last-message", lastMessage.path, "--", task]
    }

    /// `claude -p`: stream-json, plan mode for reading; for writing, edits are accepted only for the listed tools.
    static func claudeArguments(task: String, mode: EngineMode) -> [String] {
        // A task that starts with a dash would be read as an option; a leading space keeps it a prompt.
        let prompt = task.hasPrefix("-") ? " " + task : task
        var arguments = ["-p", prompt, "--output-format", "stream-json", "--verbose"]
        switch mode {
        case .read:
            arguments += ["--permission-mode", "plan"]
        case .write:
            arguments += ["--permission-mode", "acceptEdits", "--allowedTools", "Read", "Grep", "Glob", "Edit", "Write"]
        }
        return arguments
    }
}

/// One of the two external agents, as a tool. Slow and expensive: it runs in the background and reports progress on the bus.
struct EngineTool: AgentTool {
    let kind: EngineKind
    let executor: EngineExecutor

    var definition: ToolDefinition {
        let description = kind == .codex
            ? "Агент Codex: медленный, дорогой, сильный. Только если Алексей просит глубокий разбор кода или исследование; идёт минуты."
            : "Агент Claude Code: медленный, дорогой, сильный. Только если Алексей просит глубокий разбор кода или исследование; идёт минуты."
        return ToolDefinition(name: kind.binaryName, description: description,
                              parametersJSON: #"{"type":"object","properties":{"task":{"type":"string","description":"Что сделать, полным предложением"},"mode":{"type":"string","enum":["read","write"],"description":"read: только читать (по умолчанию); write: менять файлы в рабочей папке"}},"required":["task"]}"#)
    }

    func run(argumentsJSON: String) -> ToolResult { ToolResult(ok: false, text: "engine tools run asynchronously") }

    func runAsync(argumentsJSON: String) async -> ToolResult {
        await executor.execute(kind, argumentsJSON: argumentsJSON)
    }
}

public extension ToolRegistry {
    /// `codex` and `claude` as tools. The board publishes each run on the bus; the timeout is 20 minutes unless a test shortens it.
    static func engineTools(workspace: URL, board: ToolRunBoard, locator: EngineLocator = EngineLocator(),
                            timeout: TimeInterval = CLIRunner.defaultTimeout) -> ToolRegistry {
        let executor = EngineExecutor(locator: locator, workspace: workspace, board: board, timeout: timeout)
        return ToolRegistry([EngineTool(kind: .codex, executor: executor), EngineTool(kind: .claude, executor: executor)])
    }
}
