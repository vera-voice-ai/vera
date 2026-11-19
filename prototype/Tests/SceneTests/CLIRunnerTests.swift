import Foundation
import Testing
@testable import Core

@Suite struct CLIRunnerTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")
    private let sleeper = URL(fileURLWithPath: "/bin/sleep")

    @Test func streamsStdoutLinesAndReportsTheExitCode() async throws {
        let lines = Lines()
        let result = await CLIRunner.run(executable: shell, arguments: ["-c", "echo first; echo second; echo oops >&2; exit 3"],
                                         environment: ["PATH": "/usr/bin:/bin"], workingDirectory: FileManager.default.temporaryDirectory,
                                         onStdoutLine: { lines.add($0) })
        #expect(result.outcome == .exited(3))
        #expect(lines.all == ["first", "second"])
        #expect(result.lastErrorLine == "oops")
        #expect(result.recentOutput.contains("oops"))
    }

    @Test func argumentsReachTheProgramAsGivenWithoutAShell() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "runner-marker-\(UUID().uuidString)")
        let lines = Lines()
        let weird = "$(touch \(marker.path))"
        _ = await CLIRunner.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["[%s]\n", weird, "a b"],
                                environment: ["PATH": "/usr/bin:/bin"], workingDirectory: FileManager.default.temporaryDirectory,
                                onStdoutLine: { lines.add($0) })
        #expect(lines.all == ["[\(weird)]", "[a b]"])
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func timeoutStopsTheProgram() async throws {
        let started = Date()
        let result = await CLIRunner.run(executable: sleeper, arguments: ["30"], environment: ["PATH": "/bin:/usr/bin"],
                                         workingDirectory: FileManager.default.temporaryDirectory, timeout: 0.5)
        #expect(result.outcome == .timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func cancellingTheTaskStopsTheProgram() async throws {
        let started = Date()
        let task = Task {
            await CLIRunner.run(executable: sleeper, arguments: ["30"], environment: ["PATH": "/bin:/usr/bin"],
                                workingDirectory: FileManager.default.temporaryDirectory, timeout: 60)
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await task.value
        #expect(result.outcome == .cancelled)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func aMissingProgramIsALaunchFailure() async throws {
        let result = await CLIRunner.run(executable: URL(fileURLWithPath: "/nonexistent/vera-engine"), arguments: [],
                                         environment: [:], workingDirectory: FileManager.default.temporaryDirectory)
        #expect(result.outcome == .launchFailed)
    }
}

/// Collects lines from the runner's callback, which may run on another thread.
private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ line: String) { lock.withLock { items.append(line) } }
    var all: [String] { lock.withLock { items } }
}
