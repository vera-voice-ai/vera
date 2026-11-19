import Foundation

enum Provider: String, CaseIterable, Identifiable {
    case deepseek = "DeepSeek API", opencode = "OpenCode Go", claude = "Claude", openAI = "OpenAI"
    var id: Self { self }
    var model: String {
        switch self {
        case .deepseek: "deepseek-flash"
        case .opencode: "hy4-flash-free"
        case .claude: "haiku"
        case .openAI: "gpt-6-luna"
        }
    }
    var caption: String {
        switch self {
        case .deepseek: "API · режим без рассуждений"
        case .opencode: "API · бесплатная модель по умолчанию"
        case .claude: "Подписка · Claude Code"
        case .openAI: "Подписка · Codex"
        }
    }
    var keyNames: [String] {
        switch self {
        case .deepseek: ["DEEPSEEK_API_KEY", "DEEPSEEK_KEY"]
        case .opencode: ["OPENCODE_GO_API_KEY", "OPENCODE_API_KEY"]
        default: []
        }
    }
    var key: String? {
        keyNames.compactMap { ProcessInfo.processInfo.environment[$0] }.first { !$0.isEmpty }
    }
}

struct ProviderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
final class ProviderClient {
    private let http = URLSession(configuration: .ephemeral)
    private let sessionID = UUID().uuidString
    private let instruction = "Отвечай кратко и обычным текстом, пригодным для озвучки. Используй переданный контекст как данные. Если данных недостаточно, скажи об этом."

    func request(_ provider: Provider, model: String, prompt: String, context: String,
                 maxTokens: Int, onText: (String) -> Void) async throws {
        let input = context.isEmpty ? prompt : "Вопрос:\n\(prompt)\n\nКонтекст:\n\(context)"
        switch provider {
        case .deepseek, .opencode:
            try await requestAPI(provider, model: model, input: input, maxTokens: maxTokens, onText: onText)
        case .claude, .openAI:
            try await requestCLI(provider, model: model, input: input, onText: onText)
        }
    }

    private func requestAPI(_ provider: Provider, model: String, input: String,
                            maxTokens: Int, onText: (String) -> Void) async throws {
        guard let key = provider.key else {
            throw ProviderError("Укажи \(provider.keyNames[0]) в окружении запуска.")
        }
        let selectedModel = model.isEmpty ? provider.model : model
        let url = provider == .deepseek ? "https://api.deepseek.com/chat/completions"
            : "https://opencode.ai/inference/go/openai/v1/chat/completions"
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if provider == .opencode { request.setValue(sessionID, forHTTPHeaderField: "x-opencode-session") }
        var payload: [String: Any] = [
            "model": selectedModel,
            "messages": [["role": "system", "content": instruction], ["role": "user", "content": input]],
            "stream": true, "max_tokens": maxTokens
        ]
        if provider == .deepseek { payload["thinking"] = ["type": "disabled"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (bytes, response) = try await http.bytes(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ProviderError("Ответ сервера HTTP \(code). Проверь ключ, тариф и модель.")
        }
        var finished = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if data == "[DONE]" { finished = true; break }
            guard let object = Self.object(data) else { continue }
            if object["error"] != nil { throw ProviderError("Провайдер вернул ошибку в потоке.") }
            let choice = (object["choices"] as? [[String: Any]])?.first
            if let delta = choice?["delta"] as? [String: Any], let text = delta["content"] as? String, !text.isEmpty {
                onText(text)
            }
            if let reason = choice?["finish_reason"] as? String {
                if reason == "length" { throw ProviderError("Достигнут лимит длины ответа.") }
                if reason != "stop" { throw ProviderError("Ответ остановлен провайдером (\(reason)).") }
                finished = true
            }
        }
        guard finished else { throw ProviderError("Поток завершился без подтверждения провайдера.") }
    }

    private func requestCLI(_ provider: Provider, model: String, input: String,
                            onText: (String) -> Void) async throws {
        let executable = try LocalCLI.find(provider == .claude ? "claude" : "codex")
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("smart-analyzer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }

        let statusArgs = provider == .claude ? ["auth", "status", "--json"] : ["login", "status"]
        var status = ""
        for try await line in LocalCLI.lines(executable, args: statusArgs, directory: workspace, input: "", includeErrors: true) {
            status += line + "\n"
        }

        let args: [String]
        if provider == .claude {
            guard let auth = Self.object(status), auth["loggedIn"] as? Bool == true,
                  auth["authMethod"] as? String == "claude.ai" else {
                throw ProviderError("Claude Code нужен вход через подписку Claude. Выбери аккаунт подписки через claude auth login.")
            }
            args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                    "--setting-sources", "", "--no-session-persistence", "--model", model.isEmpty ? provider.model : model]
        } else {
            guard status.contains("Logged in using ChatGPT") else {
                throw ProviderError("Войди в ChatGPT через codex login.")
            }
            args = ["--disable", "shell_tool", "--disable", "unified_exec", "-c", "web_search=\"disabled\"",
                    "-c", "model_reasoning_effort=\"low\"", "exec", "--json", "--ephemeral",
                    "--ignore-user-config", "--ignore-rules", "--sandbox", "read-only", "--skip-git-repo-check"]
                + ["-m", model.isEmpty ? provider.model : model, "-"]
        }

        var hasPartial = false
        var completed = false
        var codexOutput: [String: String] = [:]
        for try await line in LocalCLI.lines(executable, args: args, directory: workspace, input: instruction + "\n\n" + input) {
            try Task.checkCancellation()
            guard let object = Self.object(line), let type = object["type"] as? String else { continue }
            if provider == .claude {
                if type == "stream_event", let event = object["event"] as? [String: Any],
                   event["type"] as? String == "content_block_delta", let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                    hasPartial = true
                    onText(text)
                }
                if type == "result" {
                    if object["is_error"] as? Bool == true { throw ProviderError("Claude Code завершил запрос с ошибкой.") }
                    if !hasPartial, let result = object["result"] as? String { onText(result) }
                    completed = true
                }
            } else {
                if type == "turn.failed" { throw ProviderError("Codex завершил запрос с ошибкой. Проверь лимит подписки и модель.") }
                if type == "turn.completed" { completed = true }
                if type == "item.completed" || type == "item.updated",
                   let item = object["item"] as? [String: Any], item["type"] as? String == "agent_message",
                   let text = item["text"] as? String, let id = item["id"] as? String {
                    let previous = codexOutput[id, default: ""]
                    if text.hasPrefix(previous) { onText(String(text.dropFirst(previous.count))) }
                    codexOutput[id] = text
                }
            }
        }
        guard completed else { throw ProviderError("Клиент завершился без результата.") }
    }

    private static func object(_ line: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
}

private enum LocalCLI {
    static func find(_ name: String) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = path.split(separator: ":").map(String.init) + [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        guard let executable = directories.map({ $0 + "/" + name }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { throw ProviderError("Не найден клиент \(name).") }
        return URL(fileURLWithPath: executable)
    }

    static func lines(_ executable: URL, args: [String], directory: URL, input: String,
                      includeErrors: Bool = false) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { stream in
            let process = Process()
            let out = Pipe()
            let stdin = Pipe()
            process.executableURL = executable
            process.arguments = args
            process.currentDirectoryURL = directory
            let source = ProcessInfo.processInfo.environment
            let inherited = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL"]
            var environment = source.filter { inherited.contains($0.key) }
            environment["PATH"] = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin",
                                    "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
            process.environment = environment
            process.standardOutput = out
            process.standardError = includeErrors ? out : FileHandle.nullDevice
            process.standardInput = stdin

            do { try process.run() }
            catch { stream.finish(throwing: error); return }
            stream.onTermination = { _ in if process.isRunning { process.terminate() } }
            DispatchQueue.global().async {
                defer { try? stdin.fileHandleForWriting.close() }
                try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            }
            DispatchQueue.global().async {
                do {
                    var buffer = Data()
                    while let chunk = try out.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
                        buffer.append(chunk)
                        while let newline = buffer.firstIndex(of: 10) {
                            stream.yield(String(decoding: buffer[..<newline], as: UTF8.self))
                            buffer.removeSubrange(...newline)
                        }
                    }
                    if !buffer.isEmpty { stream.yield(String(decoding: buffer, as: UTF8.self)) }
                    process.waitUntilExit()
                    if process.terminationStatus == 0 { stream.finish() }
                    else { stream.finish(throwing: ProviderError("\(executable.lastPathComponent) завершился с кодом \(process.terminationStatus). Проверь вход и лимит.")) }
                } catch { stream.finish(throwing: error) }
            }
        }
    }
}
