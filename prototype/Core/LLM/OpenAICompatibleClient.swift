import Foundation

/// Streaming chat completions over HTTPS for any OpenAI-compatible endpoint. The default configuration is the
/// OpenCode Go subscription used as a plain model endpoint (no OpenCode program involved).
public struct OpenAICompatibleClient: ChatModel {
    public struct Configuration: Sendable {
        public var endpoint = URL(string: "https://opencode.ai/inference/go/openai/v1/chat/completions")!
        /// Model id as the endpoint expects it, without the `opencode-go/` prefix.
        public var model = "deepseek-v4.1-flash"
        public var keyName = "OPENCODE_API_KEY"
        public var sessionID = UUID().uuidString.lowercased()
        /// The whole request may take this long.
        public var lifetime: TimeInterval = 120
        /// No line for this long on an active stream means it is dead (a lost Wi-Fi gives silence, not an error).
        public var idleTimeout: TimeInterval = 25
        public var maxStreamBytes = 5 * 1024 * 1024
        public init() {}
    }

    public let configuration: Configuration
    private let journal: ModelJournal?
    private let keyProvider: @Sendable () -> String?

    public init(configuration: Configuration = Configuration(), journal: ModelJournal? = nil,
                keyProvider: (@Sendable () -> String?)? = nil) {
        self.configuration = configuration
        self.journal = journal
        let name = configuration.keyName
        self.keyProvider = keyProvider ?? { Secrets.key(named: name) }
    }

    public func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn {
        guard let key = keyProvider(), !key.isEmpty else { throw ChatError.noKey }
        let body = try Self.requestBody(model: configuration.model, messages: messages, tools: tools)
        var request = URLRequest(url: configuration.endpoint, timeoutInterval: configuration.lifetime)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("Vera/2 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue(configuration.sessionID, forHTTPHeaderField: "x-opencode-session")
        request.httpBody = body

        let started = ContinuousClock.now
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatError.badResponse("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            var text = ""
            for try await line in stream.lines { text += line + "\n"; if text.count > 600 { break } }
            let error = ChatError.http(http.statusCode, text)
            await journal?.record(request: body, turn: ChatTurn(), error: "\(error)")
            throw error
        }
        let watchdog = IdleWatchdog(limit: configuration.idleTimeout)
        let maxBytes = configuration.maxStreamBytes
        // The reader owns all the state it mutates; a second task cancels it if the stream goes silent.
        let reader = Task { () -> ChatTurn in
            var turn = ChatTurn()
            var pending: [Int: (id: String, name: String, arguments: String)] = [:]
            var bytes = 0
            func elapsed() -> Int {
                let d = started.duration(to: .now)
                return Int(d.components.seconds * 1_000 + d.components.attoseconds / 1_000_000_000_000_000)
            }
            for try await line in stream.lines {
                await watchdog.touch()
                bytes += line.utf8.count
                if bytes > maxBytes { throw ChatError.tooLarge }
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let usage = object["usage"] as? [String: Any] {
                    turn.usage = TokenUsage(promptTokens: usage["prompt_tokens"] as? Int ?? 0,
                                            completionTokens: usage["completion_tokens"] as? Int ?? 0)
                }
                guard let choice = (object["choices"] as? [[String: Any]])?.first else { continue }
                if let reason = choice["finish_reason"] as? String { turn.finishReason = reason }
                guard let delta = choice["delta"] as? [String: Any] else { continue }
                if let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String), !reasoning.isEmpty {
                    turn.reasoning += reasoning
                    if turn.firstTokenMilliseconds == nil { turn.firstTokenMilliseconds = elapsed() }
                }
                if let text = delta["content"] as? String, !text.isEmpty {
                    if turn.firstTokenMilliseconds == nil { turn.firstTokenMilliseconds = elapsed() }
                    turn.text += text
                    onText(text)
                }
                for call in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
                    let index = call["index"] as? Int ?? 0
                    var entry = pending[index] ?? ("", "", "")
                    if let id = call["id"] as? String { entry.id = id }
                    if let function = call["function"] as? [String: Any] {
                        if let name = function["name"] as? String { entry.name += name }
                        if let arguments = function["arguments"] as? String { entry.arguments += arguments }
                    }
                    pending[index] = entry
                    if turn.firstTokenMilliseconds == nil { turn.firstTokenMilliseconds = elapsed() }
                }
            }
            turn.toolCalls = pending.sorted { $0.key < $1.key }.map { ToolCall(id: $0.value.id, name: $0.value.name, arguments: $0.value.arguments) }
            turn.totalMilliseconds = elapsed()
            return turn
        }
        let guardTask = Task {
            do { try await watchdog.watch() } catch { reader.cancel() }
        }
        defer { guardTask.cancel() }
        do {
            let turn = try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
            await journal?.record(request: body, turn: turn, error: nil)
            return turn
        } catch is CancellationError {
            if Task.isCancelled { await journal?.record(request: body, turn: ChatTurn(), error: "cancelled"); throw CancellationError() }
            await journal?.record(request: body, turn: ChatTurn(), error: "stalled")
            throw ChatError.stalled
        } catch {
            await journal?.record(request: body, turn: ChatTurn(), error: "\(error)")
            throw error
        }
    }

    static func requestBody(model: String, messages: [ChatMessage], tools: [ToolDefinition]) throws -> Data {
        var encoded: [[String: Any]] = []
        for message in messages {
            var item: [String: Any] = ["role": message.role.rawValue]
            if let content = message.content { item["content"] = content } else if message.role == .assistant { item["content"] = NSNull() }
            if !message.toolCalls.isEmpty {
                item["tool_calls"] = message.toolCalls.map { ["id": $0.id, "type": "function",
                                                               "function": ["name": $0.name, "arguments": $0.arguments]] as [String: Any] }
            }
            if let id = message.toolCallID { item["tool_call_id"] = id }
            if let reasoning = message.reasoning, !reasoning.isEmpty { item["reasoning_content"] = reasoning }
            encoded.append(item)
        }
        var body: [String: Any] = ["model": model, "messages": encoded, "stream": true,
                                   "stream_options": ["include_usage": true]]
        if !tools.isEmpty {
            body["tools"] = try tools.map { tool -> [String: Any] in
                guard let data = tool.parametersJSON.data(using: .utf8),
                      let schema = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ChatError.badResponse("bad schema for tool \(tool.name)")
                }
                return ["type": "function", "function": ["name": tool.name, "description": tool.description, "parameters": schema]]
            }
            body["tool_choice"] = "auto"
        }
        return try JSONSerialization.data(withJSONObject: body)
    }
}

/// Fails when nothing arrives for `limit` seconds.
actor IdleWatchdog {
    private var last = Date()
    private let limit: TimeInterval
    init(limit: TimeInterval) { self.limit = limit }
    func touch() { last = Date() }
    func watch() async throws {
        while true {
            try await Task.sleep(for: .seconds(1))
            if Date().timeIntervalSince(last) > limit { throw ChatError.stalled }
        }
    }
}
