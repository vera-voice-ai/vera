import Foundation
import Testing
@testable import Core

private let noteCalendar = Calendar(identifier: .gregorian)

private func noteFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "vera-notes-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    DateComponents(calendar: noteCalendar, year: year, month: month, day: day, hour: hour, minute: minute).date!
}

private func writeFile(_ text: String, _ path: String, in folder: URL) throws {
    let url = folder.appending(path: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func readFile(_ path: String, in folder: URL) -> String? {
    try? String(contentsOf: folder.appending(path: path), encoding: .utf8)
}

@Test func archiveMovesOnlyOldDaysAndKeepsTheirTextByteIdentical() throws {
    let folder = try noteFolder("archive"); defer { try? FileManager.default.removeItem(at: folder) }
    let store = NoteStore(directory: folder)
    let october1 = "- 21:05 купить зарядку для часов\n- 09:00 Наташа: «билеты» — 2 шт. (100%)\n"
    let october3 = "- 08:15 позвонить маме\n"
    let november4 = "- 07:00 сдать «отчёт»\n- 23:59 конец\n"
    let november5 = "- 10:00 ровно четырнадцать дней\n"     // exactly 14 days old: stays
    let recent = "- 12:00 свежая\n"
    try writeFile(october1, "2026-10-01.md", in: folder)
    try writeFile(october3, "2026-10-03.md", in: folder)
    try writeFile(november4, "2026-11-04.md", in: folder)
    try writeFile(november5, "2026-11-05.md", in: folder)
    try writeFile(recent, "2026-11-18.md", in: folder)
    let now = at(2026, 11, 19, 10, 0)

    #expect(store.archiveOld(olderThanDays: 14, now: now, calendar: noteCalendar) == 3)
    for gone in ["2026-10-01.md", "2026-10-03.md", "2026-11-04.md"] {
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: gone).path))
    }
    #expect(readFile("2026-11-05.md", in: folder) == november5)
    #expect(readFile("2026-11-18.md", in: folder) == recent)
    #expect(readFile("archive/2026-10.md", in: folder) == "## 2026-10-01\n" + october1 + "## 2026-10-03\n" + october3)
    #expect(readFile("archive/2026-11.md", in: folder) == "## 2026-11-04\n" + november4)

    // A second run changes nothing.
    let before = readFile("archive/2026-10.md", in: folder)
    #expect(store.archiveOld(olderThanDays: 14, now: now, calendar: noteCalendar) == 0)
    #expect(readFile("archive/2026-10.md", in: folder) == before)
}

@Test func anArchivedDayThatReappearsIsNotDuplicatedAndNewNotesAreNotLost() throws {
    let folder = try noteFolder("idempotent"); defer { try? FileManager.default.removeItem(at: folder) }
    let store = NoteStore(directory: folder)
    let now = at(2026, 11, 19, 10, 0)
    try writeFile("- 09:00 первая\n", "2026-10-01.md", in: folder)
    store.archiveOld(now: now, calendar: noteCalendar)
    let archived = readFile("archive/2026-10.md", in: folder)

    // An interrupted run left the same daily file behind: it is removed, the archive stays as it was.
    try writeFile("- 09:00 первая\n", "2026-10-01.md", in: folder)
    #expect(store.archiveOld(now: now, calendar: noteCalendar) == 1)
    #expect(readFile("archive/2026-10.md", in: folder) == archived)

    // A file that holds more than the archived copy keeps the new note.
    try writeFile("- 09:00 первая\n- 10:00 новая\n", "2026-10-01.md", in: folder)
    #expect(store.archiveOld(now: now, calendar: noteCalendar) == 1)
    #expect(readFile("archive/2026-10.md", in: folder)?.contains("- 10:00 новая\n") == true)
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "2026-10-01.md").path))
}

@Test func findReachesTheArchiveMarksItAndListsRecentFirst() throws {
    let folder = try noteFolder("find"); defer { try? FileManager.default.removeItem(at: folder) }
    let store = NoteStore(directory: folder)
    try writeFile("- 08:00 зарядка для часов старая\n", "2026-10-02.md", in: folder)
    try writeFile("- 21:05 зарядка для часов новая\n- 07:00 другое\n", "2026-11-18.md", in: folder)
    try writeFile("- 09:00 зарядка в ноябре\n", "2026-11-04.md", in: folder)
    store.archiveOld(now: at(2026, 11, 19, 10, 0), calendar: noteCalendar)

    let hits = store.search("зарядка часов")
    #expect(hits == ["2026-11-18 21:05 зарядка для часов новая", "2026-10-02 08:00 зарядка для часов старая (архив)"])
    let tools = ToolRegistry.noteTools(store)
    #expect(tools.run(ToolCall(id: "c", name: "find_notes", arguments: #"{"query":"зарядка часов"}"#)).text == hits.joined(separator: "\n"))

    // An empty query lists everything, newest first, the archive after the daily files.
    let all = store.search("", limit: 20)
    #expect(all.map { String($0.prefix(10)) } == ["2026-11-18", "2026-11-18", "2026-11-04", "2026-10-02"])
    #expect(all[2] == "2026-11-04 09:00 зарядка в ноябре (архив)")
}

@Test func reviewTakesNotesSinceTheLastReviewAndArchivesOldOnes() throws {
    let folder = try noteFolder("review"); defer { try? FileManager.default.removeItem(at: folder) }
    let store = NoteStore(directory: folder)
    try writeFile("- 09:00 старая заметка\n", "2026-11-01.md", in: folder)     // older than 14 days: archived, outside the first window
    try writeFile("- 10:00 первая заметка\n", "2026-11-10.md", in: folder)
    try writeFile("- 21:05 вторая заметка\n", "2026-11-18.md", in: folder)

    let first = try store.review(now: at(2026, 11, 19, 12, 0), calendar: noteCalendar)
    #expect(first.hasPrefix("Выбери"))
    #expect(first.contains("remember"))
    #expect(first.contains("2026-11-18 21:05 вторая заметка"))
    #expect(first.contains("2026-11-10 10:00 первая заметка"))
    #expect(!first.contains("старая"))
    #expect(first.range(of: "вторая")!.lowerBound < first.range(of: "первая")!.lowerBound)   // newest first
    #expect(readFile("archive/2026-11.md", in: folder)?.contains("старая заметка") == true)
    #expect(readFile(".last-review", in: folder) == String(at(2026, 11, 19, 12, 0).timeIntervalSince1970))

    // The second review counts only what was written after the first one.
    try writeFile("- 11:00 ранняя\n", "2026-11-19.md", in: folder)
    store.add("пятая заметка", at: at(2026, 11, 19, 12, 30), calendar: noteCalendar)
    let second = try store.review(now: at(2026, 11, 19, 13, 0), calendar: noteCalendar)
    #expect(second.contains("2026-11-19 12:30 пятая заметка"))
    #expect(!second.contains("вторая") && !second.contains("ранняя"))

    let third = try store.review(now: at(2026, 11, 19, 13, 10), calendar: noteCalendar)
    #expect(third == "новых заметок с прошлого просмотра нет")
}

@Test func reviewIsCutAtThreeThousandCharactersNewestFirst() throws {
    let folder = try noteFolder("cut"); defer { try? FileManager.default.removeItem(at: folder) }
    let store = NoteStore(directory: folder)
    for minute in 0..<60 {
        store.add("заметка \(minute) " + String(repeating: "я", count: 60), at: at(2026, 11, 18, 9, minute), calendar: noteCalendar)
    }
    let text = try store.review(now: at(2026, 11, 19, 8, 0), calendar: noteCalendar)
    #expect(text.count <= 3000)
    #expect(text.contains("показаны самые новые"))
    #expect(text.contains("2026-11-18 09:59 заметка 59 "))
    #expect(!text.contains("заметка 0 "))
    #expect(text.range(of: "заметка 59")!.lowerBound < text.range(of: "заметка 58")!.lowerBound)
}

@Test func oneHugeNoteIsCutToFitTheLimit() throws {
    let folder = try noteFolder("huge"); defer { try? FileManager.default.removeItem(at: folder) }
    let store = NoteStore(directory: folder)
    store.add(String(repeating: "очень длинная заметка ", count: 300), at: at(2026, 11, 18, 9, 0), calendar: noteCalendar)
    let text = try store.review(now: at(2026, 11, 19, 8, 0), calendar: noteCalendar)
    #expect(text.count <= 3000)
    #expect(text.contains("обрезана"))
}

@Test func lastReviewIsSavedOnlyAfterTheReviewSucceeds() throws {
    let folder = try noteFolder("marker"); defer { try? FileManager.default.removeItem(at: folder) }
    let store = NoteStore(directory: folder)
    try writeFile("- 10:00 важная\n", "2026-11-18.md", in: folder)
    let now = at(2026, 11, 19, 12, 0)

    // The marker cannot be written: a folder stands where the file goes.
    try FileManager.default.createDirectory(at: folder.appending(path: ".last-review"), withIntermediateDirectories: true)
    #expect(throws: NoteReviewError.self) { try store.review(now: now, calendar: noteCalendar) }

    // Nothing was marked as reviewed, so the note comes back next time.
    try FileManager.default.removeItem(at: folder.appending(path: ".last-review"))
    let text = try store.review(now: now, calendar: noteCalendar)
    #expect(text.contains("важная"))
    #expect(readFile(".last-review", in: folder) == String(now.timeIntervalSince1970))
}

@Test func reviewNotesIsAReadToolOutsideTheWriteLock() throws {
    let folder = try noteFolder("tool"); defer { try? FileManager.default.removeItem(at: folder) }
    #expect(!ToolRegistry.writeTools.contains("review_notes"))
    let result = ToolRegistry.noteTools(NoteStore(directory: folder)).run(ToolCall(id: "c", name: "review_notes", arguments: "{}"))
    #expect(result.ok)
    #expect(result.text == "новых заметок с прошлого просмотра нет")
}
