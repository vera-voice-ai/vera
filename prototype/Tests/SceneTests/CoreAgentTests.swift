import Foundation
import Testing
import Core
import SignalBus
import TaskKit

private func sandbox(_ files: [String: String] = Fixtures.files) -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "vera-core-test-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    for (name, content) in files { try? content.write(to: url.appending(path: name), atomically: true, encoding: .utf8) }
    return url
}

private func call(_ tool: String, _ json: String) -> ToolCall { ToolCall(id: "c1", name: tool, arguments: json) }

// MARK: - The sandbox

@Test func fileToolsStayInsideTheWorkingFolder() throws {
    let root = sandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = WorkspaceTools(root: root).registry
    #expect(registry.run(call("read_file", #"{"path":"notes.txt"}"#)).ok)
    for path in ["../secret.txt", "/etc/hosts", "a/../../x", "/tmp/vera-escape.txt"] {
        let read = registry.run(call("read_file", #"{"path":"\#(path)"}"#))
        #expect(!read.ok, "read \(path)")
        let write = registry.run(call("write_file", #"{"path":"\#(path)","content":"x"}"#))
        #expect(!write.ok, "write \(path)")
    }
    // A symlink inside the folder that points outside must not be followed.
    let outside = FileManager.default.temporaryDirectory.appending(path: "vera-outside-\(UUID().uuidString.prefix(6)).txt")
    try "outside".write(to: outside, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: root.appending(path: "link.txt"), withDestinationURL: outside)
    #expect(!registry.run(call("read_file", #"{"path":"link.txt"}"#)).ok)
    #expect(!registry.run(call("write_file", #"{"path":"link.txt","content":"changed"}"#)).ok)
    #expect((try? String(contentsOf: outside, encoding: .utf8)) == "outside")
}

@Test func replaceNeedsAUniqueMatchUnlessToldOtherwise() throws {
    let root = sandbox(["a.txt": "один два один\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = WorkspaceTools(root: root).registry
    #expect(!registry.run(call("replace_in_file", #"{"path":"a.txt","old":"один","new":"три"}"#)).ok)      // twice
    #expect(!registry.run(call("replace_in_file", #"{"path":"a.txt","old":"нет","new":"три"}"#)).ok)       // absent
    #expect(registry.run(call("replace_in_file", #"{"path":"a.txt","old":"два","new":"три"}"#)).ok)
    #expect(registry.run(call("replace_in_file", #"{"path":"a.txt","old":"один","new":"ноль","replace_all":true}"#)).ok)
    #expect((try String(contentsOf: root.appending(path: "a.txt"), encoding: .utf8)) == "ноль три ноль\n")
}

@Test func unknownToolsAndBrokenArgumentsAreReportedNotCrashed() {
    let registry = WorkspaceTools(root: sandbox()).registry
    #expect(!registry.run(call("format_disk", "{}")).ok)
    #expect(!registry.run(call("read_file", "not json")).ok)
    #expect(!registry.run(call("write_file", #"{"path":"x.txt"}"#)).ok)
}

// MARK: - The loop, with a scripted model (no network)

private final class ScriptedModel: ChatModel, @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [ChatTurn]
    private var counts: [Int] = []
    var seenMessageCounts: [Int] { lock.withLock { counts } }
    init(_ turns: [ChatTurn]) { self.turns = turns }
    private func next(messageCount: Int) -> ChatTurn? {
        lock.withLock {
            counts.append(messageCount)
            return turns.isEmpty ? nil : turns.removeFirst()
        }
    }
    func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn {
        guard let turn = next(messageCount: messages.count) else { throw ChatError.badResponse("script exhausted") }
        if !turn.text.isEmpty { onText(turn.text) }
        return turn
    }
}

private func turn(text: String = "", calls: [ToolCall] = []) -> ChatTurn {
    var t = ChatTurn(); t.text = text; t.toolCalls = calls; t.totalMilliseconds = 5; t.firstTokenMilliseconds = 2
    t.usage = TokenUsage(promptTokens: 10, completionTokens: 3)
    return t
}

@Test func theLoopRunsToolsAndFeedsResultsBackUntilTheModelAnswers() async {
    let root = sandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = ScriptedModel([turn(calls: [call("read_file", #"{"path":"notes.txt"}"#)]), turn(text: "Кодовое слово сокол.")])
    let loop = AgentLoop(model: model, tools: WorkspaceTools(root: root).registry, systemPrompt: "s")
    let result = await loop.run(request: "какое слово")
    #expect(result.succeeded)
    #expect(result.answer == "Кодовое слово сокол.")
    #expect(result.steps == 2 && result.toolCalls.count == 1 && result.toolCalls[0].ok)
    #expect(result.usage.promptTokens == 20)
    #expect(model.seenMessageCounts == [2, 4])     // system+user, then +assistant tool call +tool result
}

@Test func theLoopStopsAtTheStepLimitAndReportsModelFailures() async {
    let root = sandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    let endless = ScriptedModel(Array(repeating: turn(calls: [call("list_dir", #"{"path":"."}"#)]), count: 10))
    let limited = await AgentLoop(model: endless, tools: WorkspaceTools(root: root).registry, systemPrompt: "s", maxSteps: 3).run(request: "x")
    #expect(!limited.succeeded)
    #expect(limited.error == "step limit reached" && limited.steps == 3)

    let broken = await AgentLoop(model: ScriptedModel([]), tools: WorkspaceTools(root: root).registry, systemPrompt: "s").run(request: "x")
    #expect(!broken.succeeded && broken.error != nil)

    let silent = await AgentLoop(model: ScriptedModel([turn(text: "")]), tools: WorkspaceTools(root: root).registry, systemPrompt: "s").run(request: "x")
    #expect(!silent.succeeded)
}

@MainActor @Test func coreAgentStripsTheAddressAndReportsWhenThereIsNoModel() async {
    #expect(CoreAgent.stripAddress("Вера, прочитай файл") == "прочитай файл")
    #expect(CoreAgent.stripAddress("Вер, покажи строку пожалуйста") == "покажи строку пожалуйста")
    #expect(CoreAgent.stripAddress("прочитай файл, Вера") == "прочитай файл, Вера")   // only a leading address is removed
    #expect(CoreAgent.stripAddress("Вера") == "")
    let agent = CoreAgent(loop: nil, unavailableReason: "no key")
    agent.setEnabled(true)
    #expect(!agent.isEnabled)
    #expect((await agent.run(request: "x")).error == "no key")
}

// MARK: - The checks of the task suite

@Test func taskChecksJudgeFilesAndAnswers() throws {
    let root = sandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    try "статус: final\nавтор: тест\n".write(to: root.appending(path: "status.txt"), atomically: true, encoding: .utf8)
    let ok = TaskRunner.evaluate([.fileEquals(path: "status.txt", content: "статус: final\nавтор: тест"),
                                  .fileHasLinePrefix(path: "status.txt", prefix: "АВТОР"), .fileUnchanged(path: "notes.txt"),
                                  .answerContainsAny(["готово"]), .fileContainsLine(path: "status.txt", line: " Статус: FINAL ")],
                                 sandbox: root, answer: "Готово, поменяла.")
    #expect(ok.isEmpty)
    let bad = TaskRunner.evaluate([.fileUnchanged(path: "status.txt"), .fileExists(path: "todo.txt"), .nothingChanged, .answerContainsAll(["а", "яблоко"])],
                                  sandbox: root, answer: "а")
    #expect(bad.count == 4)
    // Declining is accepted only if nothing changed.
    #expect(TaskRunner.evaluate([.askedOrDeclined], sandbox: sandbox(), answer: "Что именно удалить?").isEmpty)
    #expect(!TaskRunner.evaluate([.askedOrDeclined], sandbox: root, answer: "Что именно удалить?").isEmpty)
}

@MainActor @Test func coreActsOnlyWhenAddressedByNameUnlessToldOtherwise() async {
    struct Model: ChatModel {
        func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn {
            var turn = ChatTurn(); turn.text = "ок"; return turn
        }
    }
    let bus = SignalBus()
    let agent = CoreAgent(loop: AgentLoop(model: Model(), tools: ToolRegistry([]), systemPrompt: "s"))
    agent.setEnabled(true)
    let task = Task { await agent.consume(bus) }
    defer { task.cancel() }
    try? await Task.sleep(for: .milliseconds(150))
    func ready(_ id: String, _ addressed: String) -> SignalMessage {
        SignalMessage(domain: .scene, source: "Scene.Builder", type: "scene.turn.ready",
                      payload: ["turn_id": id, "text": "Вера, сделай", "addressed": addressed])
    }
    await bus.publish(ready("turn/1", "possible"))
    try? await Task.sleep(for: .milliseconds(400))
    #expect(agent.tasks.isEmpty)
    await bus.publish(ready("turn/2", "likely"))
    for _ in 0..<40 where agent.tasks.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
    #expect(agent.tasks.count == 1)
    agent.actsOnPossibleAddress = true
    await bus.publish(ready("turn/3", "possible"))
    for _ in 0..<40 where agent.tasks.count < 2 { try? await Task.sleep(for: .milliseconds(50)) }
    #expect(agent.tasks.count == 2)
}
