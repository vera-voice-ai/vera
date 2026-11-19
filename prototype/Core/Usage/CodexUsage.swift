import Foundation

/// Codex subscription limits (a 5-hour window and a week), read through the official CLI's JSON-RPC server
/// (`codex app-server`). Each refresh starts the server, sends the handshake and one `account/rateLimits/read`
/// request, reads lines until the answer to request 1 arrives, and stops the process. Failure texts never hold
/// paths, output of the CLI, or credentials.
public actor CodexUsage {
    public struct Window: Sendable, Equatable {
        public let usedPercent: Int
        public let windowMinutes: Int
        public let resetsAt: Date?
    }

    public struct Limits: Sendable, Equatable {
        /// The 5-hour window.
        public let primary: Window
        /// The week.
        public let secondary: Window
        public let planType: String?

        /// "5%/29%": 5 hours / week.
        public var display: String { "\(primary.usedPercent)%/\(secondary.usedPercent)%" }
    }

    public enum State: Sendable, Equatable {
        case unknown
        case limits(Limits)
        case failed(String)
    }

    /// Starts the server with the given input lines written to its stdin and returns the stdout lines read so far.
    /// Reading stops at the answer to request 1, at the end of output, or when `timeout` expires.
    public typealias Runner = @Sendable (_ binary: URL, _ input: [String], _ timeout: Duration) async throws -> [String]

    public enum RunError: Error, Equatable { case cannotStart, timedOut }

    public enum ParseError: Error, Equatable { case rpcError, missingLimits, noAnswer }

    /// The handshake, the `initialized` notification the protocol expects before requests, and the limits request.
    public static let requests: [String] = [
        #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"clientInfo":{"name":"vera","version":"0"},"capabilities":{"experimentalApi":false,"requestAttestation":false}}}"#,
        #"{"jsonrpc":"2.0","method":"initialized"}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"account/rateLimits/read","params":{}}"#,
    ]
    public static let timeout: Duration = .seconds(20)

    /// Every state change, for the UI. Buffered, so a consumer that starts late still gets the latest value.
    public nonisolated let updates: AsyncStream<State>
    private let continuation: AsyncStream<State>.Continuation
    public private(set) var state: State = .unknown

    private let binaryProvider: @Sendable () -> URL?
    private let run: Runner
    private var loop: Task<Void, Never>?

    public init(binary: @escaping @Sendable () -> URL? = { CodexUsage.defaultBinary() },
                run: @escaping Runner = { try await CodexUsage.runAppServer(binary: $0, input: $1, timeout: $2) }) {
        self.binaryProvider = binary
        self.run = run
        (updates, continuation) = AsyncStream.makeStream(of: State.self)
    }

    /// Refreshes now, then every `interval`. Calling it again while running does nothing.
    public func start(every interval: Duration = .seconds(300)) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    @discardableResult
    public func refresh() async -> State {
        let next = await fetch()
        state = next
        continuation.yield(next)
        return next
    }

    private func fetch() async -> State {
        guard let binary = binaryProvider() else { return .failed("Codex не найден") }
        do {
            let lines = try await run(binary, Self.requests, Self.timeout)
            return .limits(try Self.parse(lines))
        } catch RunError.cannotStart {
            return .failed("не удалось запустить Codex")
        } catch RunError.timedOut {
            return .failed("Codex не ответил за 20 секунд")
        } catch ParseError.rpcError {
            return .failed("Codex ответил ошибкой")
        } catch ParseError.missingLimits {
            return .failed("Codex не вернул лимиты")
        } catch ParseError.noAnswer {
            return .failed("Codex не ответил на запрос лимитов")
        } catch {
            return .failed("неожиданный ответ Codex")
        }
    }

    /// Lines are JSON-RPC messages. Notifications, other ids and garbage lines are skipped.
    public static func parse(_ lines: [String]) throws -> Limits {
        for line in lines {
            guard let object = jsonObject(line), number(object["id"]) == 1 else { continue }
            if object["error"] != nil { throw ParseError.rpcError }
            guard let result = object["result"] as? [String: Any],
                  let rate = result["rateLimits"] as? [String: Any],
                  let primary = window(rate["primary"]),
                  let secondary = window(rate["secondary"]) else { throw ParseError.missingLimits }
            let plan = (result["planType"] ?? rate["planType"]) as? String
            return Limits(primary: primary, secondary: secondary, planType: plan)
        }
        throw ParseError.noAnswer
    }

    /// The id of a JSON-RPC answer line, nil for anything else.
    static func answerID(of line: String) -> Int? {
        guard let object = jsonObject(line) else { return nil }
        return number(object["id"])
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func number(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber else { return nil }
        return value.intValue
    }

    private static func window(_ value: Any?) -> Window? {
        guard let dictionary = value as? [String: Any],
              let used = number(dictionary["usedPercent"]),
              let minutes = number(dictionary["windowDurationMins"]) else { return nil }
        let resets = (dictionary["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return Window(usedPercent: used, windowMinutes: minutes, resetsAt: resets)
    }

    /// The CLI installed for the Vera engines first, then the usual install places.
    public static func defaultBinary() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appending(path: "Library/Application Support/VeraSensorPrototype/Engines/agents/node_modules/.bin/codex"),
            home.appending(path: ".local/bin/codex"),
            URL(filePath: "/opt/homebrew/bin/codex"),
            URL(filePath: "/usr/local/bin/codex"),
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Runs `<binary> app-server` for real. The process is stopped as soon as the answer to request 1 is read,
    /// or after `timeout`.
    public static func runAppServer(binary: URL, input: [String], timeout: Duration) async throws -> [String] {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["app-server"]
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { throw RunError.cannotStart }

            let handle = RunningProcess(process)
            let watchdog = Task { try? await Task.sleep(for: timeout); handle.expire() }
            defer {
                watchdog.cancel()
                handle.stop()
            }

            let payload = Data(input.map { $0 + "\n" }.joined().utf8)
            try? stdin.fileHandleForWriting.write(contentsOf: payload)

            var lines: [String] = []
            var pending = Data()
            var answered = false
            reading: while true {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[..<newline], as: UTF8.self)
                    pending.removeSubrange(...newline)
                    lines.append(line)
                    if answerID(of: line) == 1 { answered = true; break reading }
                }
            }
            if handle.timedOut && !answered { throw RunError.timedOut }
            return lines
        }.value
    }
}

/// Lets the watchdog task stop the server from another thread. `Process` itself is not Sendable.
private final class RunningProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var expired = false

    init(_ process: Process) { self.process = process }

    var timedOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return expired
    }

    func expire() {
        lock.lock(); expired = true; lock.unlock()
        stop()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if process.isRunning { process.terminate() }
    }
}
