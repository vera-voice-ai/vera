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
