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
