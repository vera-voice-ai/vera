import Foundation

@main
enum AnalyzerMain {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "--ping" else {
            SmartAnalyzerApp.main()
            return
        }
        guard args.count >= 2, let provider = Provider.allCases.first(where: { $0.argument == args[1] }) else {
            FileHandle.standardError.write(Data("Usage: SmartAnalyzer --ping deepseek|opencode|claude|openai [--model ID] [--voice]\n".utf8))
            exit(64)
        }
        var model = provider.model
        var voice = false
        var index = 2
        while index < args.count {
            switch args[index] {
            case "--model" where index + 1 < args.count && !args[index + 1].hasPrefix("--"):
                index += 1
                model = args[index]
            case "--voice": voice = true
            default:
                FileHandle.standardError.write(Data("Unknown or incomplete argument: \(args[index])\n".utf8))
                exit(64)
            }
            index += 1
        }

        Task { @MainActor in
            let state = AnalyzerModel()
            state.provider = provider
            state.modelOverride = model
            state.speak = voice
            state.send(ping: true)
            while state.running {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if voice, !state.failed, state.firstText != nil {
                let deadline = ContinuousClock.now + .seconds(5)
                while state.firstVoice == nil, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                while state.speaking, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            let result = PingResult(provider: provider.argument, model: model, reply: state.reply,
                                    status: state.status, firstTextMs: state.firstText,
                                    speechStartMs: state.firstVoice, totalMs: state.finished)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let encoded = try? encoder.encode(result) { print(String(decoding: encoded, as: UTF8.self)) }
            exit(state.failed ? 1 : 0)
        }
        RunLoop.main.run()
    }
}

private extension Provider {
    var argument: String {
        switch self {
        case .deepseek: "deepseek"
        case .opencode: "opencode"
        case .claude: "claude"
        case .openAI: "openai"
        }
    }
}

private struct PingResult: Encodable {
    let provider: String
    let model: String
    let reply: String
    let status: String
    let firstTextMs: Int?
    let speechStartMs: Int?
    let totalMs: Int?
}
