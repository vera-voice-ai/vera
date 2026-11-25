import Foundation

/// Runs a short command and collects its output. For small outputs only (attach, git, --version).
public enum ProcessRunner {
    public struct Output: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: Data
        public var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil) async throws -> Output {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let environment { process.environment = environment }
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            try process.run()
            // Read before waiting: a full pipe would otherwise block the child forever.
            let stdout = out.fileHandleForReading.readDataToEndOfFile()
            let stderr = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Output(status: process.terminationStatus, stdout: stdout, stderr: stderr)
        }.value
    }
}
