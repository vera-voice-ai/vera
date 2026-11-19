import Foundation
import Testing
@testable import Core

private func tempStore() -> MemoryStore {
    MemoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "vera-memory-\(UUID().uuidString)"))
}

@Test func factsSurviveReopeningTheStoreAndAreSearchable() {
    let store = tempStore()
    #expect(store.remember("Кодовое слово для проекта — сокол"))
    store.recordTask(request: "прочитай notes.txt", answer: "Первая строка заметок")
    let reopened = MemoryStore(directory: store.directory)
    #expect(reopened.counts == (facts: 1, tasks: 1))
    #expect(reopened.search("какое кодовое слово").first?.kind == .fact)
    #expect(reopened.search("заметки").first?.kind == .task)
    #expect(reopened.search("совсем другое").isEmpty)
    #expect(reopened.factsText()?.contains("сокол") == true)
}

@Test func emptyFactsAreRefusedAndTheToolsWork() {
    let store = tempStore()
    #expect(!store.remember("   "))
    let tools = ToolRegistry.memoryTools(store)
    let saved = tools.run(ToolCall(id: "1", name: "remember", arguments: #"{"fact":"Алексей любит чай без сахара"}"#))
    #expect(saved.ok)
    let found = tools.run(ToolCall(id: "2", name: "search_memory", arguments: #"{"query":"какой чай"}"#))
    #expect(found.ok && found.text.contains("чай"))
}

@Test func skillsAreListedByDescriptionAndLoadedByName() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vera-skills-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "---\nname: edit-file\ndescription: как менять файл\n---\nСначала прочитай.\n".write(to: dir.appending(path: "a.md"), atomically: true, encoding: .utf8)
    try "без шапки\n".write(to: dir.appending(path: "plain.md"), atomically: true, encoding: .utf8)
    let store = SkillStore(directory: dir)
    #expect(store.catalogText()?.contains("- edit-file: как менять файл") == true)
    #expect(store.catalogText()?.contains("Сначала прочитай") == false)
    #expect(store.registry.run(ToolCall(id: "1", name: "read_skill", arguments: #"{"name":"edit-file"}"#)).text == "Сначала прочитай.")
    #expect(!store.registry.run(ToolCall(id: "2", name: "read_skill", arguments: #"{"name":"nope"}"#)).ok)
}

// MARK: - Self-modification gates

private func fakeModifier(testOutput: String, testCode: Int32 = 0) throws -> (SelfModifier, URL) {
    let wt = FileManager.default.temporaryDirectory.appending(path: "vera-self-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: wt.appending(path: ".git"), withIntermediateDirectories: true)
    try "let x = 1\n".write(to: wt.appending(path: "a.swift"), atomically: true, encoding: .utf8)
    let modifier = SelfModifier(repo: wt, worktree: wt, applyScript: wt.appending(path: "apply.sh"), runner: { launch, args, _, _ in
        if args.first == "test" { return (testCode, testOutput) }
        if launch.hasSuffix("zsh") { return (0, "built") }
        return (0, "")
    })
    return (modifier, wt)
}

@Test func aChangeCannotBeCommittedOrAppliedWithoutPassingTestsAfterTheLastEdit() throws {
    let (modifier, _) = try fakeModifier(testOutput: "✔ Test run with 5 tests passed after 1 seconds.")
    let tools = modifier.registry
    #expect(!tools.run(ToolCall(id: "1", name: "self_commit", arguments: #"{"message":"x"}"#)).ok)
    #expect(!tools.run(ToolCall(id: "2", name: "self_apply", arguments: #"{"summary":"x"}"#)).ok)
    #expect(tools.run(ToolCall(id: "3", name: "self_replace_in_file", arguments: #"{"path":"a.swift","old":"1","new":"2"}"#)).ok)
    #expect(tools.run(ToolCall(id: "4", name: "self_test", arguments: "{}")).ok)
    #expect(tools.run(ToolCall(id: "5", name: "self_commit", arguments: #"{"message":"set x to 2"}"#)).ok)
    // A new edit makes the earlier test result stale again.
    #expect(tools.run(ToolCall(id: "6", name: "self_write_file", arguments: #"{"path":"b.swift","content":"let y = 1"}"#)).ok)
    #expect(!tools.run(ToolCall(id: "7", name: "self_apply", arguments: #"{"summary":"x"}"#)).ok)
}

@Test func failingTestsBlockTheCommitAndGitFoldersAreOffLimits() throws {
    let (modifier, _) = try fakeModifier(testOutput: "✘ Test x failed\n✔ Test run with 5 tests failed", testCode: 1)
    let tools = modifier.registry
    _ = tools.run(ToolCall(id: "1", name: "self_replace_in_file", arguments: #"{"path":"a.swift","old":"1","new":"2"}"#))
    #expect(!tools.run(ToolCall(id: "2", name: "self_test", arguments: "{}")).ok)
    #expect(!tools.run(ToolCall(id: "3", name: "self_commit", arguments: #"{"message":"x"}"#)).ok)
    #expect(!tools.run(ToolCall(id: "4", name: "self_write_file", arguments: #"{"path":".git/config","content":"x"}"#)).ok)
    #expect(!tools.run(ToolCall(id: "5", name: "self_read_file", arguments: #"{"path":"../outside.txt"}"#)).ok)
}

@Test func applyNeedsThePendingRequestAndTheOwnersSpokenConfirmation() throws {
    let (modifier, _) = try fakeModifier(testOutput: "✔ Test run with 5 tests passed after 1 seconds.")
    let tools = modifier.registry
    _ = tools.run(ToolCall(id: "1", name: "self_replace_in_file", arguments: #"{"path":"a.swift","old":"1","new":"2"}"#))
    _ = tools.run(ToolCall(id: "2", name: "self_test", arguments: "{}"))
    _ = tools.run(ToolCall(id: "3", name: "self_commit", arguments: #"{"message":"m"}"#))
    #expect(!modifier.applyConfirmed().ok)               // nothing was asked yet: the model alone cannot apply
    #expect(tools.run(ToolCall(id: "4", name: "self_apply", arguments: #"{"summary":"s"}"#)).ok)
    #expect(modifier.hasPendingApply)
    #expect(modifier.applyConfirmed().ok)
    #expect(!modifier.hasPendingApply)
}

@MainActor @Test func onlyShortConfirmationsCountAsApply() {
    #expect(CoreAgent.isApplyCommand("Да, применяй"))
    #expect(CoreAgent.isApplyCommand("применяй изменения"))
    #expect(!CoreAgent.isApplyCommand("не применяй пока это"))
    #expect(!CoreAgent.isApplyCommand("если захочешь, можешь применять изменения когда-нибудь"))
}

@Test func theFilesThatHoldTheGatesCannotBeWrittenByVera() throws {
    let (modifier, wt) = try fakeModifier(testOutput: "")
    try FileManager.default.createDirectory(at: wt.appending(path: "Core/Agent"), withIntermediateDirectories: true)
    try "x".write(to: wt.appending(path: "Core/Agent/SelfModifier.swift"), atomically: true, encoding: .utf8)
    let tools = modifier.registry
    #expect(!tools.run(ToolCall(id: "1", name: "self_write_file", arguments: #"{"path":"Core/Agent/SelfModifier.swift","content":"y"}"#)).ok)
    #expect(tools.run(ToolCall(id: "2", name: "self_read_file", arguments: #"{"path":"Core/Agent/SelfModifier.swift"}"#)).ok)
}

@Test func theProfileFileIsShownCappedAndAbsentWhenEmpty() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "vera-profile-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let memory = MemoryStore(directory: directory)
    #expect(memory.profileText() == nil)
    try "  \n".write(to: directory.appending(path: "profile.md"), atomically: true, encoding: .utf8)
    #expect(memory.profileText() == nil)
    try String(repeating: "я", count: 6_000).write(to: directory.appending(path: "profile.md"), atomically: true, encoding: .utf8)
    let text = try #require(memory.profileText())
    #expect(text.hasPrefix("Профиль Алексея") && text.count < MemoryStore.profileLimit + 120)
}

private func tempMemory() -> (MemoryStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "vera-conv-\(UUID().uuidString)")
    return (MemoryStore(directory: directory), directory)
}

@Test func recentExchangesComeOldestFirstWithinTheBudgetAndTheAge() {
    let (memory, directory) = tempMemory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    memory.recordTask(request: "очень старое", answer: "давно", at: now.addingTimeInterval(-3 * 86_400))
    for i in 1...6 { memory.recordTask(request: "вопрос \(i)", answer: "ответ \(i)", at: now.addingTimeInterval(Double(i - 10) * 60)) }
    let all = memory.recentExchanges(now: now)
    #expect(all.map(\.text) == (1...6).map { "вопрос \($0)" })              // the old one is out; the rest in time order
    #expect(memory.recentExchanges(maxCount: 2, now: now).map(\.text) == ["вопрос 5", "вопрос 6"])
    #expect(memory.recentExchanges(maxChars: 30, now: now).count < 6)       // the character budget cuts from the old end
}

@Test func olderExchangesAreFoldedIntoTheSummaryAndLeaveTheRecentOnes() async {
    let (memory, directory) = tempMemory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    for i in 1...30 { memory.recordTask(request: "вопрос \(i)", answer: "ответ \(i)", at: now.addingTimeInterval(Double(i - 40) * 60)) }
    let old = try! #require(memory.exchangesToCompact(keep: 12, batch: 12))
    #expect(old.count == 18 && old.first?.text == "вопрос 1" && old.last?.text == "вопрос 18")
    let done = await memory.compact(old) { previous, transcript in
        #expect(previous.isEmpty && transcript.contains("Алексей: вопрос 1") && transcript.contains("Вера: ответ 18"))
        return "Говорили про вопросы 1–18."
    }
    #expect(done)
    #expect(memory.conversationSummary()?.contains("Говорили про вопросы 1–18.") == true)
    // The summary replaces the old exchanges in the thread, and nothing more needs compacting until more pile up.
    #expect(memory.recentExchanges(now: now).first?.text == "вопрос 19")
    #expect(memory.exchangesToCompact(keep: 12, batch: 12) == nil)
}

@Test func aFailedSummarizerLeavesEverythingAsItWas() async {
    let (memory, directory) = tempMemory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for i in 1...20 { memory.recordTask(request: "q\(i)", answer: "a\(i)", at: Date().addingTimeInterval(Double(i - 30) * 60)) }
    let old = memory.exchangesToCompact(keep: 5, batch: 5)!
    #expect(await memory.compact(old) { _, _ in nil } == false)
    #expect(memory.conversationSummary() == nil)
    #expect(memory.exchangesToCompact(keep: 5, batch: 5)?.count == old.count)
}

private actor ThreadSeen {
    private(set) var runs: [[ChatMessage]] = []
    func add(_ messages: [ChatMessage]) { runs.append(messages) }
}

@MainActor @Test func theThreadOfTheConversationReachesTheModelAsMessages() async {
    struct Spy: ChatModel {
        let seen: ThreadSeen
        func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn {
            await seen.add(messages)
            var turn = ChatTurn(); turn.text = "ок"; onText("ок"); return turn
        }
    }
    let (memory, directory) = tempMemory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let seen = ThreadSeen()
    let agent = CoreAgent(loop: AgentLoop(model: Spy(seen: seen), tools: ToolRegistry([]), systemPrompt: "s"), memory: memory)
    agent.includesSceneContext = false
    agent.includesChangelog = false
    agent.setEnabled(true)
    _ = await agent.run(request: "поменяй draft на final")
    _ = await agent.run(request: "а теперь верни обратно")
    let second = await seen.runs.last ?? []
    let roles = second.map { $0.role }
    #expect(roles.suffix(3) == [ChatMessage.Role.user, .assistant, .user])                       // earlier request, her answer, the new request
    #expect(second.suffix(3).first?.content == "поменяй draft на final")
    #expect(second.last?.content == "а теперь верни обратно")
}
