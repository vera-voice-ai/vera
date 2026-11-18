import Foundation

public struct ToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    /// The raw JSON arguments exactly as the model produced them.
    public let arguments: String
    public init(id: String, name: String, arguments: String) { self.id = id; self.name = name; self.arguments = arguments }
}

public struct ChatMessage: Sendable {
    public enum Role: String, Sendable { case system, user, assistant, tool }
    public let role: Role
    public var content: String?
    public var toolCalls: [ToolCall] = []
    /// For `tool` messages: the call this result answers.
    public var toolCallID: String?
    /// Reasoning text some models return; kept so it can be sent back where the API requires it.
    public var reasoning: String?
    public init(role: Role, content: String?, toolCalls: [ToolCall] = [], toolCallID: String? = nil, reasoning: String? = nil) {
        self.role = role; self.content = content; self.toolCalls = toolCalls; self.toolCallID = toolCallID; self.reasoning = reasoning
    }
}

/// A tool the model may call. `parametersJSON` is a JSON Schema object as text, which keeps the type Sendable.
public struct ToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let parametersJSON: String
    public init(name: String, description: String, parametersJSON: String) {
        self.name = name; self.description = description; self.parametersJSON = parametersJSON
    }
}

public struct TokenUsage: Sendable, Equatable {
    public var promptTokens = 0
    public var completionTokens = 0
    public init(promptTokens: Int = 0, completionTokens: Int = 0) { self.promptTokens = promptTokens; self.completionTokens = completionTokens }
}

/// What one request to the model produced.
public struct ChatTurn: Sendable {
    public var text = ""
    public var reasoning = ""
    public var toolCalls: [ToolCall] = []
    public var finishReason = ""
    public var usage = TokenUsage()
    /// Milliseconds from sending the request to the first streamed text or tool-call fragment.
    public var firstTokenMilliseconds: Int?
    public var totalMilliseconds = 0
    public init() {}
}

public enum ChatError: Error, CustomStringConvertible {
    case noKey
    case http(Int, String)
    case stalled
    case tooLarge
    case badResponse(String)

    public var description: String {
        switch self {
        case .noKey: return "no API key (set OPENCODE_API_KEY or store it in the Keychain item space.vera.v2 / OPENCODE_API_KEY)"
        case let .http(code, body): return "HTTP \(code): \(body.prefix(300))"
        case .stalled: return "the stream went silent"
        case .tooLarge: return "the response is too large"
        case let .badResponse(reason): return "unexpected response: \(reason)"
        }
    }
}

/// Any chat model. The agent loop only needs this, so providers can be swapped.
public protocol ChatModel: Sendable {
    /// One request. Streamed text is reported through `onText`; the full turn is returned.
    func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn
}
