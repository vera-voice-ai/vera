import Foundation

/// A local journal of every model call: the request (messages and tools, never the authorization header), what came
/// back, timing and token use. JSON Lines, one file per day, owner-only permissions. It holds conversation text.
public actor ModelJournal {
    private let directory: URL
    private var handle: FileHandle?
    private var day = ""

    public init(directory: URL) { self.directory = directory }

    public func record(request: Data, turn: ChatTurn, error: String?) {
        var entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "request": (try? JSONSerialization.jsonObject(with: request)) ?? NSNull(),
            "text": turn.text,
            "tool_calls": turn.toolCalls.map { ["id": $0.id, "name": $0.name, "arguments": $0.arguments] },
            "finish_reason": turn.finishReason,
            "prompt_tokens": turn.usage.promptTokens, "completion_tokens": turn.usage.completionTokens,
            "first_token_ms": turn.firstTokenMilliseconds as Any, "total_ms": turn.totalMilliseconds
        ]
        if let error { entry["error"] = error }
        guard JSONSerialization.isValidJSONObject(entry), var line = try? JSONSerialization.data(withJSONObject: entry) else { return }
        line.append(0x0A)
        if let handle = openHandle() { try? handle.write(contentsOf: line) }
    }

    private func openHandle() -> FileHandle? {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let today = formatter.string(from: Date())
        if today == day, let handle { return handle }
        try? handle?.close()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: "\(today)-model.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        day = today
        return handle
    }
}
