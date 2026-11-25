import Foundation

/// One frame the gateway pushed to Vera.
public enum GatewayIncoming: Sendable {
    /// `{"method":"event","params":{"type":…,"session_id":…,"payload":…,"seq":…,"execution_generation":…}}`;
    /// `gateway.ready` is the first one. `meta` is the whole `params` (sequence, generation, admission).
    case event(type: String, sessionId: String?, payload: JSONValue, meta: JSONValue)
    /// A server→client request Vera answers (`approval`, `clarify`): reply with `respond(id:result:)`.
    case request(id: JSONValue, method: String, params: JSONValue)
    /// The connection ended; `reason` is safe to show (never contains the ticket).
    case closed(reason: String)
}

/// A client of the Hermes gateway (`/api/ws`, newline-delimited JSON-RPC 2.0, wire `hermes-gateway-v1`).
///
/// Server→client requests: only `answerable` ones reach the app (after `setAnswering(true)`, which goes with
/// `client.capabilities {server_requests: true}`); every other one — `secret`, `sudo`, vault, desktop bridges —
/// is refused at once, so the agent never waits on a question Vera will not ask.
public actor GatewayClient {
    public enum CallError: Error, CustomStringConvertible {
        case notConnected
        case timeout(String)
        case rpc(code: Int, message: String)
        case closed(String)
        public var description: String {
            switch self {
            case .notConnected: "нет соединения"
            case .timeout(let m): "таймаут \(m)"
            case .rpc(let code, let message): "\(code): \(message)"
            case .closed(let r): "закрыто: \(r)"
            }
        }
    }

    public static let answerable: Set<String> = ["approval", "clarify"]

    public nonisolated let incoming: AsyncStream<GatewayIncoming>
    private var answering = false
    private let incomingContinuation: AsyncStream<GatewayIncoming>.Continuation
    private var task: URLSessionWebSocketTask?
    /// The gateway's largest frame (`_DESKTOP_ATTACHMENT_WS_MAX_BYTES`, 384 MiB) — contract path in hermes.lock.json.
    public static let maximumFrame = 384 * 1024 * 1024
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var loops: [Task<Void, Never>] = []
    private let session: URLSession

    public init() {
        (incoming, incomingContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(512))
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3600
        session = URLSession(configuration: config)
    }

    /// Dials the attach result's URL offering its subprotocols (the wire name and the single-use ticket).
    public func connect(_ attach: GatewayAttachResult) throws {
        guard attach.isReady, let urlString = attach.url, let url = URL(string: urlString), let protocols = attach.protocols else {
            throw CallError.notConnected
        }
        disconnect(reason: "переподключение")
        let task = session.webSocketTask(with: url, protocols: protocols)
        // URLSession accepts 1 MiB frames by default; the gateway sends up to its own limit (a long session's
        // history on session.resume, big lists). A larger frame was refused and the link dropped
        // («Message too long»). Same limit as Hermes' server: hermes_cli/web_server_boundary.py.
        task.maximumMessageSize = Self.maximumFrame
        self.task = task
        task.resume()
        loops = [
            Task { [weak self] in await self?.receiveLoop(task) },
            Task { [weak self] in await self?.pingLoop() }
        ]
    }

    public func disconnect(reason: String = "закрыто Верой") {
        loops.forEach { $0.cancel() }
        loops = []
        if let task {
            task.cancel(with: .goingAway, reason: nil)
            self.task = nil
            failAll(CallError.closed(reason))
        }
    }

    /// A JSON-RPC call; the gateway's `result` or its error.
    public func call(_ method: String, params: JSONValue = .object([:]), timeout: Duration = .seconds(10)) async throws -> JSONValue {
        guard let task else { throw CallError.notConnected }
        let id = nextId
        nextId += 1
        let frame: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)),
                                        "method": .string(method), "params": params])
        let text = frame.description + "\n"
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.resolve(id, .failure(CallError.timeout(method)))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self] in
                do { try await task.send(.string(text)) } catch { await self?.resolve(id, .failure(CallError.closed("\(error.localizedDescription)"))) }
            }
        }
    }

    public func setAnswering(_ on: Bool) { answering = on }

    /// The answer to a server→client request (`{"jsonrpc","id","result"}`; JSON-RPC responses get no reply).
    public func respond(id: JSONValue, result: JSONValue) async {
        await sendFrame(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    public func refuse(id: JSONValue, message: String) async {
        await sendFrame(.object(["jsonrpc": .string("2.0"), "id": id,
                                 "error": .object(["code": .number(-32601), "message": .string(message)])]))
    }

    private func sendFrame(_ frame: JSONValue) async {
        guard let task else { return }
        try? await task.send(.string(frame.description + "\n"))
    }

    // MARK: - Loops

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(decoding: d, as: UTF8.self)
                @unknown default: continue
                }
                for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
                    handle(Data(line.utf8))
                }
            } catch {
                guard self.task === task else { return }
                let reason = task.closeCode == .invalid ? error.localizedDescription : "код \(task.closeCode.rawValue)"
                self.task = nil
                failAll(CallError.closed(reason))
                incomingContinuation.yield(.closed(reason: reason))
                return
            }
        }
    }

    /// The gateway advertises `heartbeat: true` in `gateway.ready` and answers `gateway.ping`.
    private func pingLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(20))
            if Task.isCancelled { return }
            _ = try? await call("gateway.ping", timeout: .seconds(10))
        }
    }

    private func handle(_ data: Data) {
        guard let frame = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        let method = frame["method"]?.string
        if method == nil, let id = frame["id"]?.number.map(Int.init) {
            if let error = frame["error"] {
                resolve(id, .failure(CallError.rpc(code: Int(error["code"]?.number ?? 0), message: error["message"]?.string ?? "?")))
            } else {
                resolve(id, .success(frame["result"] ?? .null))
            }
            return
        }
        if method == "event", let params = frame["params"], let type = params["type"]?.string {
            let sid = params["session_id"]?.string
            incomingContinuation.yield(.event(type: type, sessionId: sid?.isEmpty == true ? nil : sid,
                                              payload: params["payload"] ?? .null, meta: params))
            return
        }
        if let method, let id = frame["id"] {
            if answering && Self.answerable.contains(method) {
                incomingContinuation.yield(.request(id: id, method: method, params: frame["params"] ?? .null))
            } else {
                // A question Vera does not take (secrets, sudo, desktop bridges): refuse now so nothing waits on her.
                Task { await self.refuse(id: id, message: "Vera does not answer \(method)") }
            }
        }
    }

    private func resolve(_ id: Int, _ result: Result<JSONValue, Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func failAll(_ error: Error) {
        let all = pending
        pending = [:]
        all.values.forEach { $0.resume(throwing: error) }
    }
}
