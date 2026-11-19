import Foundation
import Testing
import Core

private func tempDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "vera-metrics-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@Test func emptyStoreMeasuresZero() {
    let memory = MemoryStore(directory: tempDirectory("empty-memory"))
    let notes = tempDirectory("empty-notes")
    let metrics = MemoryMetrics.measure(memory: memory, notesDirectory: notes)
    #expect(metrics == MemoryMetrics(facts: 0, tasks: 0, notes: 0, bytes: 0, factsContextCharacters: 0))
    #expect(metrics.summary == "фактов 0 · в контексте ~0 симв. · заметок 0 · задач в истории 0 · 0.0 КБ")
}

@Test func metricsCountFactsTasksNotesAndBytes() {
    let memory = MemoryStore(directory: tempDirectory("memory"))
    let notes = NoteStore(directory: tempDirectory("notes"))
    memory.remember("Кодовое слово для проекта — сокол")
    memory.remember("Алексей любит чай без сахара")
    memory.recordTask(request: "какая погода", answer: "Солнечно")
    notes.add("купить молоко")
    notes.add("позвонить маме")
    let before = MemoryMetrics.measure(memory: memory, notesDirectory: notes.directory)

    #expect(before.facts == 2)
    #expect(before.tasks == 1)
    #expect(before.notes == 2)
    #expect(before.factsContextCharacters == (memory.factsText()?.count ?? -1))
    #expect(before.factsContextCharacters > 0)
    #expect(before.bytes > 0)
    #expect(before.summary.hasPrefix("фактов 2 · в контексте ~\(before.factsContextCharacters) симв. · заметок 2 · задач в истории 1 · "))
    #expect(before.summary.hasSuffix(" КБ"))

    // Measuring is read-only, and a new note makes the notes folder larger.
    notes.add("ещё одна заметка")
    let after = MemoryMetrics.measure(memory: memory, notesDirectory: notes.directory)
    #expect(after.notes == 3)
    #expect(after.bytes > before.bytes)
    #expect(after.facts == before.facts && after.tasks == before.tasks)
}
