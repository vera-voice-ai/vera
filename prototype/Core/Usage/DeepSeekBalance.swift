import Foundation

/// Reads the DeepSeek account balance. The key comes only from the Keychain (`DEEPSEEK_API_KEY`) and is never
/// logged or put into a message: failure texts name the reason, not the URL or the key.
public actor DeepSeekBalance {
    public struct Balance: Sendable, Equatable {
        public let amount: String
        public let currency: String

        /// "$12.34" for USD, "¥…" for CNY, otherwise the currency code before the amount.
        public var display: String {
            let symbol = currency == "USD" ? "$" : currency == "CNY" ? "¥" : currency + " "
            return symbol + amount
        }
    }

    public enum State: Sendable, Equatable {
        case unknown
        case balance(Balance)
        case failed(String)
    }

    public static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!
    public static let keyName = "DEEPSEEK_API_KEY"

    /// Every state change, for the UI. Buffered, so a consumer that starts late still gets the latest values.
    public nonisolated let updates: AsyncStream<State>
    private let continuation: AsyncStream<State>.Continuation
    public private(set) var state: State = .unknown

    private let session: URLSession
    private let endpointURL: URL
    private let keyProvider: @Sendable () -> String?
    private var loop: Task<Void, Never>?

    public init(session: URLSession = .shared,
                endpoint: URL = DeepSeekBalance.endpoint,
                keyProvider: @escaping @Sendable () -> String? = { Secrets.keychainKey(named: DeepSeekBalance.keyName) }) {
        self.session = session
        self.endpointURL = endpoint
        self.keyProvider = keyProvider
        (updates, continuation) = AsyncStream.makeStream(of: State.self)
    }

    /// Refreshes now, then every `interval`. Calling it again while running does nothing.
    public func start(every interval: Duration = .seconds(600)) {
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
        guard let key = keyProvider(), !key.isEmpty else {
            return .failed("нет ключа \(Self.keyName) в Keychain")
        }
        var request = URLRequest(url: endpointURL, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("нет ответа от DeepSeek") }
            guard (200..<300).contains(http.statusCode) else { return .failed("DeepSeek ответил HTTP \(http.statusCode)") }
            return .balance(try Self.parse(data))
        } catch let error as URLError {
            // URLError text can contain the address, so only the code is reported.
            return .failed("нет связи с DeepSeek (код \(error.code.rawValue))")
        } catch {
            return .failed("неожиданный ответ DeepSeek")
        }
    }

    public enum ParseError: Error { case malformed }

    /// Expects {"is_available": …, "balance_infos": [{"currency": "USD", "total_balance": "110.00", …}]}.
    public static func parse(_ data: Data) throws -> Balance {
        struct Body: Decodable {
            struct Info: Decodable {
                let currency: String
                let total_balance: String
            }
            let balance_infos: [Info]
        }
        let body: Body
        do {
            body = try JSONDecoder().decode(Body.self, from: data)
        } catch {
            throw ParseError.malformed
        }
        guard let first = body.balance_infos.first, Decimal(string: first.total_balance) != nil,
              !first.currency.isEmpty else { throw ParseError.malformed }
        return Balance(amount: first.total_balance, currency: first.currency)
    }
}
