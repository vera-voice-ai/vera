import Foundation
import Core
import TaskKit

// Runs task cases through the real agent against the real model (OpenCode Go endpoint, key from the environment
// or the Vera 2 Keychain item). Prints a table of numbers; the model journal keeps the full conversations locally.
//
//   swift run TaskBench [basic|spoken]  all 32 tasks, or only the 8 basic / the 24 spoken-style ones
//   swift run TaskBench repo           read-only questions about Vera's own source (copies in the sandbox)
//   swift run TaskBench ask "..."       one free request in a fresh sandbox, prints the answer

let args = Array(CommandLine.arguments.dropFirst())
let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "VeraSensorPrototype")
let journal = ModelJournal(directory: support.appending(path: "Journal", directoryHint: .isDirectory))

guard Secrets.key(named: "OPENCODE_API_KEY") != nil else {
    print("No API key: set OPENCODE_API_KEY (or store it in the Keychain item space.vera.v2 / OPENCODE_API_KEY).")
    exit(2)
}

/// `VERA_REASONING=default` leaves the provider's hidden reasoning on (the app runs with it off); other values are passed as
/// the reasoning effort. Used to compare accuracy and speed with and without it.
func makeLoop(_ sandbox: URL) -> AgentLoop {
    var configuration = OpenAICompatibleClient.Configuration()
    if let mode = ProcessInfo.processInfo.environment["VERA_REASONING"] {
        configuration.reasoningEffort = mode == "default" ? nil : mode
    }
    return AgentLoop(model: OpenAICompatibleClient(configuration: configuration, journal: journal), tools: WorkspaceTools(root: sandbox).registry,
              systemPrompt: VeraPrompt.system)
}

let cases: [TaskCase]
if args.first == "ask", args.count > 1 {
    cases = [TaskCase(id: "ask", category: "free", spoken: args[1...].joined(separator: " "), checks: [])]
} else if args.first == "basic" {
    cases = Suite.basic
} else if args.first == "repo" {
    // Run from the prototype folder: the questions are about Vera's own source, read from the working directory.
    cases = Suite.repo(root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
} else if args.first == "spoken" {
    cases = Suite.spoken
} else {
    cases = Suite.all
}

let runner = await TaskRunner(makeLoop: makeLoop)
let outcomes = await runner.run(cases) { print($0) }

print("\n| task | ok | steps | tools | first token ms | total ms | tokens in/out | note |")
print("|---|---|---|---|---|---|---|---|")
for o in outcomes {
    var note = o.error ?? o.failedChecks.joined(separator: "; ")
    if !o.passed, o.error == nil { note += " · said: \(o.answerExcerpt)" }
    print("| \(o.id) | \(o.passed ? "yes" : "NO") | \(o.steps) | \(o.toolCalls) | \(o.firstTokenMilliseconds.map(String.init) ?? "-") | \(o.totalMilliseconds) | \(o.promptTokens)/\(o.completionTokens) | \(note) |")
}
let passed = outcomes.filter(\.passed).count
let times = outcomes.map(\.totalMilliseconds).sorted()
print("\npassed \(passed)/\(outcomes.count) · median \(times.isEmpty ? 0 : times[times.count / 2]) ms · tokens \(outcomes.map(\.promptTokens).reduce(0, +))/\(outcomes.map(\.completionTokens).reduce(0, +))")
