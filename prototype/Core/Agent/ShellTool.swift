import Foundation

/// How dangerous a command is. Safe ones run at once, the rest need the owner's spoken word, a few never run.
public enum CommandVerdict: Equatable, Sendable {
    case safe
    case confirm(String)
    case forbidden(String)
}

public enum CommandGate {
    /// Commands that only read or wait. Chained, redirected or substituted commands are never "safe", whatever they start with.
    static let readOnly: Set<String> = ["ls", "cat", "head", "tail", "wc", "grep", "pwd", "date", "echo", "sleep", "df", "du", "uname", "whoami",
                                         "which", "file", "stat", "sort", "uniq", "cut", "diff", "ps", "uptime", "hostname", "sw_vers", "basename",
                                         "dirname", "find", "true", "false", "printf", "seq", "tree"]

    private static let forbiddenPatterns: [(pattern: String, reason: String)] = [
        (#"\b(sudo|doas)\b|(^|[;&|]\s*)su\s"#, "повышение прав запрещено"),
        (#"\bmkfs|\bdiskutil\s+(erase|partition|reformat|secureerase)|\bdd\b.*\bof=/dev"#, "форматирование и запись на диск запрещены"),
        (#"\b(shutdown|reboot|halt)\b|\blaunchctl\b|\bcsrutil\b|\bnvram\b"#, "управление системой запрещено"),
        (#"\bsecurity\s+(find|add|delete|dump|import|export)"#, "доступ к связке ключей запрещён"),
        (#":\(\)\s*\{"#, "запрещено"),
        (#"\brm\b.*(\s/(\s|$)|\s~|\$home|\s\*|\s\.\.)"#, "удаление корня, домашней папки или всего подряд запрещено"),
        (#"(curl|wget)[^|]*\|\s*(ba|z)?sh\b"#, "запуск скачанного кода запрещён"),
        (#"\.ssh|\.aws|\.gnupg|id_rsa|id_ed25519|\.netrc|\.npmrc|\.pypirc|keychain|/etc/(passwd|shadow|sudoers)"#, "чужие секреты и ключи недоступны"),
        (#">\s*/dev/"#, "запись в устройства запрещена"),
        (#"\bch(mod|own)\s+(-\w*r|-r)"#, "рекурсивная смена прав запрещена")
    ]

    public static func classify(_ command: String) -> CommandVerdict {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .forbidden("пустая команда") }
        let lower = text.lowercased()
        for (pattern, reason) in forbiddenPatterns {
            if lower.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return .forbidden(reason) }
        }
        if text.contains(where: { ";&`<>$()\n".contains($0) }) { return .confirm("составная команда: цепочка, подстановка или перенаправление") }
        for segment in text.split(separator: "|") {
            let words = segment.split(separator: " ").map(String.init)
            guard let name = words.first, readOnly.contains(name) else {
                return .confirm("команда «\(segment.split(separator: " ").first.map(String.init) ?? text)» не из списка безопасных")
            }
            if name == "find", words.contains(where: { ["-exec", "-execdir", "-delete", "-ok", "-fprint"].contains($0) }) {
                return .confirm("find с действием над файлами")
            }
            // Reading a file outside the working folder would send its text to the model provider: ask first.
            if words.dropFirst().contains(where: { $0.hasPrefix("/") || $0.hasPrefix("~") || $0 == ".." || $0.contains("../") }) {
                return .confirm("путь вне рабочей папки")
            }
        }
        return .safe
    }
}

public struct ShellResult: Sendable {
    public let code: Int32
    public let output: String
    public let timedOut: Bool
}

/// Runs one command in a shell with a minimal environment: no API keys, no tokens, no inherited secrets.
public enum ShellRunner {
    public static func run(_ command: String, in directory: URL, timeout: TimeInterval = 30, maxOutput: Int = 6_000) -> ShellResult {
        exec("/bin/zsh", ["-c", command], in: directory, timeout: timeout, maxOutput: maxOutput)
    }

    /// One program with its arguments and no shell at all: nothing in an argument can be read as a command.
    public static func exec(_ path: String, _ arguments: [String], in directory: URL = FileManager.default.temporaryDirectory,
                            timeout: TimeInterval = 30, maxOutput: Int = 6_000) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", "HOME": NSHomeDirectory(),
                               "LANG": "ru_RU.UTF-8", "TERM": "dumb"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        let collected = Locked(Data())
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            collected.withLock { if $0.count < maxOutput * 2 { $0.append(chunk) } }
        }
        do { try process.run() } catch { return ShellResult(code: 127, output: "не запустилось: \(error.localizedDescription)", timedOut: false) }
        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = finished.wait(timeout: .now() + 2) }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd() { collected.withLock { if $0.count < maxOutput * 2 { $0.append(rest) } } }
        let text = collected.withLock { String(decoding: $0, as: UTF8.self) }
        let cut = text.count > maxOutput
        return ShellResult(code: timedOut ? -1 : process.terminationStatus,
                           output: String(text.prefix(maxOutput)) + (cut ? "\n[вывод обрезан]" : ""), timedOut: timedOut)
    }
}

/// A command that is waiting for the owner's word. One at a time, valid for five minutes.
public final class CommandApproval: @unchecked Sendable {
    public let workingDirectory: URL
    public var ttl: TimeInterval = 300
    private let lock = NSLock()
    private var pending: (command: String, at: Date)?

    public init(workingDirectory: URL) { self.workingDirectory = workingDirectory }

    public func propose(_ command: String, now: Date = Date()) { lock.withLock { pending = (command, now) } }

    public func pendingCommand(now: Date = Date()) -> String? {
        lock.withLock { pending.flatMap { now.timeIntervalSince($0.at) <= ttl ? $0.command : nil } }
    }

    public var hasPending: Bool { pendingCommand() != nil }

    /// The pending command, once: the owner said to run it.
    public func take(now: Date = Date()) -> String? {
        lock.withLock {
            defer { pending = nil }
            guard let pending, now.timeIntervalSince(pending.at) <= ttl else { return nil }
            return pending.command
        }
    }
}

struct RunCommandTool: AgentTool {
    let approval: CommandApproval

    var definition: ToolDefinition {
        ToolDefinition(name: "run_command", description: "Run a shell command in the working folder. Harmless read-only commands run at once. Anything else is NOT run: it waits for the owner, so tell him aloud what you want to run and ask him to say «выполняй». Some commands never run. Output and time are limited.",
                       parametersJSON: #"{"type":"object","properties":{"command":{"type":"string"},"timeout_seconds":{"type":"integer","description":"Up to 60, default 30"}},"required":["command"]}"#)
    }

    func run(argumentsJSON: String) -> ToolResult {
        guard let args = WorkspaceTools.arguments(argumentsJSON), let command = args["command"] as? String else {
            return ToolResult(ok: false, text: "bad arguments: need command")
        }
        switch CommandGate.classify(command) {
        case let .forbidden(reason):
            return ToolResult(ok: false, text: "запрещено: \(reason). Скажи Алексею, что такую команду ты не выполняешь.")
        case let .confirm(reason):
            approval.propose(command)
            return ToolResult(ok: true, text: "НЕ ВЫПОЛНЕНО (\(reason)). Команда «\(command)» ждёт слова Алексея. Скажи ему вслух, что именно собираешься выполнить, и попроси сказать «выполняй». Без его слова она не запустится.")
        case .safe:
            let timeout = TimeInterval(min(60, max(1, args["timeout_seconds"] as? Int ?? 30)))
            let result = ShellRunner.run(command, in: approval.workingDirectory, timeout: timeout)
            return ToolResult(ok: result.code == 0 && !result.timedOut,
                              text: (result.timedOut ? "время вышло, команда остановлена\n" : "код \(result.code)\n") + result.output)
        }
    }
}

public extension ToolRegistry {
    static func commandTools(_ approval: CommandApproval) -> ToolRegistry { ToolRegistry([RunCommandTool(approval: approval)]) }
}
