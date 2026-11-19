import Foundation

/// How one run of an external program ended, and the end of its output (for reading errors only).
public struct CLIResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case exited(Int32)
        case timedOut
        case cancelled
        case launchFailed
    }

    public let outcome: Outcome
    /// The last few thousand characters of stdout and stderr together.
    public let recentOutput: String
    /// The last non-empty line the program wrote to stderr.
    public let lastErrorLine: String?

    public init(outcome: Outcome, recentOutput: String = "", lastErrorLine: String? = nil) {
        self.outcome = outcome
        self.recentOutput = recentOutput
        self.lastErrorLine = lastErrorLine
    }
}

/// Runs one program without a shell: each argument reaches the program exactly as given.
/// stdout is read line by line while the program runs. A timeout or a cancelled Swift task sends SIGTERM,
/// then SIGKILL two seconds later.
public enum CLIRunner {
    public static let defaultTimeout: TimeInterval = 20 * 60

    public static func run(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL,
                           timeout: TimeInterval = CLIRunner.defaultTimeout,
                           onStdoutLine: @escaping @Sendable (String) -> Void = { _ in }) async -> CLIResult {
        let job = CLIJob(onStdoutLine: onStdoutLine)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CLIResult, Never>) in
                job.start(executable: executable, arguments: arguments, environment: environment,
                          workingDirectory: workingDirectory, timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            job.cancel()
        }
    }
}

/// The state of one run. Pipe callbacks, the termination handler and the timers all meet here, under one lock.
final class CLIJob: @unchecked Sendable {
    private static let killGrace: TimeInterval = 2
    private static let recentLimit = 4_000
    private static let maxPartialLine = 1_000_000

    private let lock = NSLock()
    private let onStdoutLine: @Sendable (String) -> Void
    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var continuation: CheckedContinuation<CLIResult, Never>?
    private var timeoutWork: DispatchWorkItem?
    private var stdoutPartial = Data()
    private var stderrPartial = Data()
    private var stdoutOpen = true
    private var stderrOpen = true
    private var exitStatus: Int32?
    private var cancelled = false
    private var timedOut = false
    private var finished = false
    private var recent = ""
    private var lastError: String?

    init(onStdoutLine: @escaping @Sendable (String) -> Void) {
        self.onStdoutLine = onStdoutLine
    }

    func start(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL,
               timeout: TimeInterval, continuation: CheckedContinuation<CLIResult, Never>) {
        lock.lock()
        if cancelled {
            finished = true
            lock.unlock()
            continuation.resume(returning: CLIResult(outcome: .cancelled))
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [self] finishedProcess in
            self.terminated(finishedProcess.terminationStatus)
        }
        stdout.fileHandleForReading.readabilityHandler = { [self] handle in self.read(handle, isStdout: true) }
        stderr.fileHandleForReading.readabilityHandler = { [self] handle in self.read(handle, isStdout: false) }
        do {
            try process.run()
        } catch {
            finished = true
            lock.unlock()
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            continuation.resume(returning: CLIResult(outcome: .launchFailed))
            return
        }
        self.process = process
        self.stdoutHandle = stdout.fileHandleForReading
        self.stderrHandle = stderr.fileHandleForReading
        self.continuation = continuation
        let work = DispatchWorkItem { [self] in self.timeOut() }
        timeoutWork = work
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running { stop(running) }
    }

    private func timeOut() {
        lock.lock()
        guard !finished, let running = process else { lock.unlock(); return }
        timedOut = true
        lock.unlock()
        stop(running)
    }

    private func stop(_ process: Process) {
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func read(_ handle: FileHandle, isStdout: Bool) {
        let data = handle.availableData
        guard !data.isEmpty else {
            // End of this pipe. The run ends once both pipes are closed and the program has exited.
            handle.readabilityHandler = nil
            lock.lock()
            if isStdout { stdoutOpen = false } else { stderrOpen = false }
            let ready = exitStatus != nil && !stdoutOpen && !stderrOpen
            lock.unlock()
            if ready { finish() }
            return
        }
        lock.lock()
        recent = String((recent + String(decoding: data, as: UTF8.self)).suffix(Self.recentLimit))
        let lines: [String]
        if isStdout {
            stdoutPartial.append(data)
            lines = Self.completeLines(&stdoutPartial)
        } else {
            stderrPartial.append(data)
            lastError = Self.completeLines(&stderrPartial).last ?? lastError
            lines = []
        }
        lock.unlock()
        for line in lines { onStdoutLine(line) }
    }

    private func terminated(_ status: Int32) {
        lock.lock()
        exitStatus = status
        let bothClosed = !stdoutOpen && !stderrOpen
        lock.unlock()
        if bothClosed {
            finish()
        } else {
            // A child of the program may keep a pipe open; do not wait for it forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) { [self] in self.finish() }
        }
    }

    private func finish() {
        lock.lock()
        guard !finished, let status = exitStatus else { lock.unlock(); return }
        finished = true
        timeoutWork?.cancel()
        var tail: [String] = []
        if !stdoutPartial.isEmpty {
            tail = [String(decoding: stdoutPartial, as: UTF8.self).trimmingCharacters(in: .newlines)].filter { !$0.isEmpty }
            stdoutPartial = Data()
        }
        let outcome: CLIResult.Outcome = cancelled ? .cancelled : timedOut ? .timedOut : .exited(status)
        let result = CLIResult(outcome: outcome, recentOutput: recent, lastErrorLine: lastError)
        let resume = continuation
        continuation = nil
        let stdout = stdoutHandle, stderr = stderrHandle
        process = nil
        lock.unlock()
        stdout?.readabilityHandler = nil
        stderr?.readabilityHandler = nil
        for line in tail { onStdoutLine(line) }
        resume?.resume(returning: result)
    }

    /// Takes the complete lines out of the buffer (without line ends and blank lines); the rest stays for the next chunk.
    private static func completeLines(_ buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(line) }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        if buffer.count > maxPartialLine { buffer = Data() }
        return lines
    }
}
