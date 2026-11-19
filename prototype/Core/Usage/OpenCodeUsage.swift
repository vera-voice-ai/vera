import Foundation

/// How much of the OpenCode Go subscription is used: three rolling windows (5 hours, a week, a month), each as a percent.
/// The same call the owner's FamilyOS makes: `GET https://opencode.ai/zen/go/v1/usage` with the subscription key as a bearer
/// token. The key is the one Vera already uses for the model (`OPENCODE_API_KEY`); it is never logged or put into an error text.
public actor OpenCodeUsage {
    public struct Window: Sendable, Equatable {
        public let percent: Double
        public let status: String
        public let resetsAt: String
    }

    public struct Usage: Sendable, Equatable {
        public let rolling: Window
        public let weekly: Window
        public let monthly: Window

        /// "23%/8%/3%": 5 hours / week / month. The windows are explained in the tooltip, not here.
        public var display: String {
            func p(_ w: Window) -> String { String(Int(w.percent.rounded())) + "%" }
            return "\(p(rolling))/\(p(weekly))/\(p(monthly))"
        }
    }

    public enum State: Sendable, Equatable {
        case unknown
        case usage(Usage)
        case failed(String)
    }

    public static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    public static let keyName = "OPENCODE_API_KEY"

    public nonisolated let updates: AsyncStream<State>
    private let continuation: AsyncStream<State>.Continuation
    public private(set) var state: State = .unknown
    private let session: URLSession
    private let endpointURL: URL
    private let keyProvider: @Sendable () -> String?
    private var loop: Task<Void, Never>?

    public init(session: URLSession = .shared, endpoint: URL = OpenCodeUsage.endpoint,
                keyProvider: @escaping @Sendable () -> String? = { Secrets.key(named: OpenCodeUsage.keyName) }) {
        self.session = session
        self.endpointURL = endpoint
        self.keyProvider = keyProvider
        (updates, continuation) = AsyncStream.makeStream(of: State.self)
    }

    /// Refreshes now, then every `interval` (the windows move slowly: five minutes is plenty).
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

    public func stop() { loop?.cancel(); loop = nil }

    @discardableResult
    public func refresh() async -> State {
        let next = await fetch()
        state = next
        continuation.yield(next)
        return next
    }

    private func fetch() async -> State {
        guard let key = keyProvider(), !key.isEmpty else { return .failed("нет ключа \(Self.keyName)") }
        var request = URLRequest(url: endpointURL, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("нет ответа от OpenCode") }
            guard (200..<300).contains(http.statusCode) else { return .failed("OpenCode ответил HTTP \(http.statusCode)") }
            return .usage(try Self.parse(data))
        } catch let error as URLError {
            return .failed("нет связи с OpenCode (код \(error.code.rawValue))")   // the text of a URLError can hold the address
        } catch {
            return .failed("неожиданный ответ OpenCode")
        }
    }

    public enum ParseError: Error { case malformed }

    /// {"usage": {"rolling": {"status": "ok", "percent": 23, "resetsAt": "..."}, "weekly": {...}, "monthly": {...}}}
    public static func parse(_ data: Data) throws -> Usage {
        struct Body: Decodable {
            struct W: Decodable { let status: String?; let percent: Double; let resetsAt: String? }
            struct U: Decodable { let rolling: W; let weekly: W; let monthly: W }
            let usage: U
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw ParseError.malformed }
        func window(_ w: Body.W) -> Window { Window(percent: w.percent, status: w.status ?? "", resetsAt: w.resetsAt ?? "") }
        return Usage(rolling: window(body.usage.rolling), weekly: window(body.usage.weekly), monthly: window(body.usage.monthly))
    }
}
