import Foundation

public final class JSONLineWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    private let pythonURL: URL
    private let scriptURL: URL
    private let environment: [String: String]
    private let logURL: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()

    public init(name: String, pythonURL: URL, scriptURL: URL, environment: [String: String], logURL: URL) {
        self.queue = DispatchQueue(label: "vera.prototype.worker.\(name)")
        self.pythonURL = pythonURL
        self.scriptURL = scriptURL
        self.environment = environment
        self.logURL = logURL
    }

    public func warm() async throws -> String {
        try await perform { try self.ensureStarted() }
    }

    /// Child process identifier for live resource sampling; nil when the worker is down.
    /// Never call from inside this worker's own queue blocks.
    public var processIdentifier: Int32? {
        queue.sync { process?.isRunning == true ? process?.processIdentifier : nil }
    }

    public func send(_ jsonLine: String, timeout: TimeInterval = 180) async throws -> String {
        try await perform {
            _ = try self.ensureStarted()
            guard let input = self.input else { throw WorkerError.notRunning }
            try input.write(contentsOf: Data((jsonLine + "\n").utf8))
            return try self.readLine(timeout: timeout)
        }
    }

    public func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.stopLocked()
                continuation.resume()
            }
        }
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func ensureStarted() throws -> String {
        if process?.isRunning == true { return "Worker уже запущен" }
        stopLocked()
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path),
              FileManager.default.fileExists(atPath: scriptURL.path) else { throw WorkerError.runtimeMissing }
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()
        let child = Process()
        let inputPipe = Pipe(), outputPipe = Pipe()
        child.executableURL = pythonURL
        child.arguments = ["-u", scriptURL.path]
        child.currentDirectoryURL = scriptURL.deletingLastPathComponent()
        child.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        child.standardInput = inputPipe
        child.standardOutput = outputPipe
        child.standardError = log
        try child.run()
        process = child
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        buffer.removeAll(keepingCapacity: true)
        let readyLine = try readLine(timeout: 300)
        guard let data = readyLine.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ready"] as? Bool == true else {
            let message = (try? JSONSerialization.jsonObject(with: Data(readyLine.utf8)) as? [String: Any])?["error"] as? String
                ?? readyLine
            stopLocked()
            throw WorkerError.startFailed(message)
        }
        return object["model"] as? String ?? "Worker готов"
    }

    private func readLine(timeout: TimeInterval) throws -> String {
        guard let child = process else { throw WorkerError.notRunning }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak child] in if child?.isRunning == true { child?.terminate() } }
        timer.resume()
        defer { timer.cancel() }
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let string = String(data: line, encoding: .utf8) else { throw WorkerError.badResponse }
                return string
            }
            guard let output else { throw WorkerError.notRunning }
            let chunk = output.availableData
            guard !chunk.isEmpty else { throw WorkerError.notRunning }
            buffer.append(chunk)
        }
    }

    private func stopLocked() {
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? input?.close()
        try? output?.close()
        process = nil
        input = nil
        output = nil
        buffer.removeAll(keepingCapacity: false)
    }
}

public enum WorkerError: LocalizedError {
    case runtimeMissing, notRunning, badResponse, startFailed(String), inferenceFailed(String)
    public var errorDescription: String? {
        switch self {
        case .runtimeMissing: "Не найден Python runtime или worker. Проверь путь к Vera 1."
        case .notRunning: "Локальная модель завершила работу."
        case .badResponse: "Локальная модель вернула некорректный ответ."
        case .startFailed(let reason): "Не удалось запустить локальную модель: \(reason)"
        case .inferenceFailed(let reason): reason
        }
    }
}
