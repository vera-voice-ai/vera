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
