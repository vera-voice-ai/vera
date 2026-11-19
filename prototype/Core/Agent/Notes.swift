import Foundation

/// Spoken notes: one Markdown file per day, one line per note with its time. Plain files the owner can read and search too.
/// Notes older than two weeks move into `archive/<yyyy-MM>.md`. Each archived day sits under a `## yyyy-MM-dd` heading with its lines copied verbatim.
public final class NoteStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    static let keepDays = 14
    static let reviewCharacters = 3000
    private static let dayPattern = #"^\d{4}-\d{2}-\d{2}\.md$"#
    private static let monthPattern = #"^\d{4}-\d{2}\.md$"#

    public init(directory: URL) { self.directory = directory }

    private var archiveDirectory: URL { directory.appending(path: "archive", directoryHint: .isDirectory) }
    private var reviewMarker: URL { directory.appending(path: ".last-review") }

    private static func dayName(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    @discardableResult
    public func add(_ text: String, at date: Date = Date(), calendar: Calendar = .current) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let line = String(format: "- %02d:%02d %@\n", parts.hour ?? 0, parts.minute ?? 0, clean)
        let file = directory.appending(path: Self.dayName(date, calendar: calendar) + ".md")
        lock.withLock {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            try? (existing + line).write(to: file, atomically: true, encoding: .utf8)
        }
        return file.lastPathComponent
    }

    /// Notes whose text has every word of the query, newest first, as "2026-11-18 21:05 text". Notes from the archive end with «(архив)».
    public func search(_ query: String, limit: Int = 8) -> [String] {
        let wanted = MemoryStore.words(query)
        let entries = lock.withLock { entriesNewestFirst() }
        var found: [String] = []
        for entry in entries where wanted.isSubset(of: MemoryStore.words(entry.body)) {
            found.append(Self.line(entry))
            if found.count >= limit { break }
        }
        return found
    }

    /// Moves daily files older than `olderThanDays` into the archive. A daily file is deleted only after its text is read back from the archive.
    /// Running it again changes nothing. Returns how many daily files left the Notes folder.
    @discardableResult
    public func archiveOld(olderThanDays: Int = 14, now: Date, calendar: Calendar = .current) -> Int {
        lock.withLock { archiveLocked(olderThanDays: olderThanDays, now: now, calendar: calendar) }
    }

    /// The notes written since the last review (the last 14 days at the first one), newest first, as one text of at most 3000 characters.
    /// Archives old notes first. The review time is saved only after the text is ready; if saving fails, the error is thrown and the notes stay unreviewed.
    public func review(now: Date, calendar: Calendar = .current) throws -> String {
        try lock.withLock {
            _ = archiveLocked(olderThanDays: Self.keepDays, now: now, calendar: calendar)
            let since = readLastReview() ?? now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
            let floor = calendar.dateInterval(of: .minute, for: since)?.start ?? since
            let fresh = entriesNewestFirst().filter { entry in
                guard let when = Self.moment(entry, calendar: calendar) else { return false }
                return when >= floor
            }
            let text = fresh.isEmpty ? "новых заметок с прошлого просмотра нет" : Self.reviewText(fresh, limit: Self.reviewCharacters)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try String(now.timeIntervalSince1970).write(to: reviewMarker, atomically: true, encoding: .utf8)
            } catch {
                throw NoteReviewError.reviewNotSaved(error.localizedDescription)
            }
            return text
        }
    }

    // MARK: - Reading

    private struct Entry {
        let day: String
        let body: String      // "21:05 text", as written in the file
        let archived: Bool
    }

    private static func line(_ entry: Entry) -> String {
        entry.day + " " + entry.body + (entry.archived ? " (архив)" : "")
    }

    /// Every note, newest first: the daily files first, then the archive months, each day's notes in reverse order.
    /// Must be called under the lock.
    private func entriesNewestFirst() -> [Entry] {
        var result: [Entry] = []
        for name in Self.names(in: directory, matching: Self.dayPattern).sorted(by: >) {
            let content = Self.read(directory.appending(path: name))
            result += Self.entries(in: content, day: String(name.dropLast(3)), archived: false).reversed()
        }
        for name in Self.names(in: archiveDirectory, matching: Self.monthPattern).sorted(by: >) {
            let content = Self.read(archiveDirectory.appending(path: name))
            result += Self.entries(in: content, day: nil, archived: true).reversed()
        }
        return result
    }

    private static func entries(in content: String, day fixedDay: String?, archived: Bool) -> [Entry] {
        var day = fixedDay ?? ""
        var result: [Entry] = []
        for line in content.split(separator: "\n") {
            if fixedDay == nil, line.hasPrefix("## ") {
                day = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- ") {
                result.append(Entry(day: day, body: String(line.dropFirst(2)), archived: archived))
            }
        }
        return result
    }

    private static func names(in folder: URL, matching pattern: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.range(of: pattern, options: .regularExpression) != nil }
    }

    private static func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    private static func date(_ day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(calendar: calendar, year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func moment(_ entry: Entry, calendar: Calendar) -> Date? {
        guard let day = date(entry.day, calendar: calendar), entry.body.count >= 5 else { return nil }
        let hourMinute = entry.body.prefix(5).split(separator: ":").compactMap { Int($0) }
        guard hourMinute.count == 2 else { return nil }
        return calendar.date(byAdding: DateComponents(hour: hourMinute[0], minute: hourMinute[1]), to: day)
    }

    // MARK: - Archive

    /// Must be called under the lock.
    private func archiveLocked(olderThanDays: Int, now: Date, calendar: Calendar) -> Int {
        guard let cutoffDate = calendar.date(byAdding: .day, value: -olderThanDays, to: now) else { return 0 }
        let cutoff = calendar.startOfDay(for: cutoffDate)
        var moved = 0
        for name in Self.names(in: directory, matching: Self.dayPattern).sorted() {
            let day = String(name.dropLast(3))
            guard let dayDate = Self.date(day, calendar: calendar), dayDate < cutoff else { continue }
            let source = directory.appending(path: name)
            guard let content = try? String(contentsOf: source, encoding: .utf8) else { continue }
            let body = content.isEmpty || content.hasSuffix("\n") ? content : content + "\n"
            let block = "## \(day)\n" + body
            let target = archiveDirectory.appending(path: String(day.prefix(7)) + ".md")
            // An existing archive that cannot be read is never overwritten.
            let existing: String
            if FileManager.default.fileExists(atPath: target.path) {
                guard let text = try? String(contentsOf: target, encoding: .utf8) else { continue }
                existing = text
            } else {
                existing = ""
            }
            if !Self.holds(existing, block) {
                let combined = (existing.isEmpty || existing.hasSuffix("\n") ? existing : existing + "\n") + block
                do {
                    try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
                    try combined.write(to: target, atomically: true, encoding: .utf8)
                } catch { continue }
                guard Self.holds(Self.read(target), block) else { continue }
            }
            if (try? FileManager.default.removeItem(at: source)) != nil { moved += 1 }
        }
        return moved
    }

    /// True when the block is a whole section of the text: it starts a line and the next line is a heading or the text ends.
    private static func holds(_ text: String, _ block: String) -> Bool {
        var from = text.startIndex
        while let found = text.range(of: block, range: from..<text.endIndex) {
            let startsLine = found.lowerBound == text.startIndex || text[text.index(before: found.lowerBound)] == "\n"
            let endsSection = found.upperBound == text.endIndex || text[found.upperBound...].hasPrefix("## ")
            if startsLine && endsSection { return true }
            from = found.upperBound
        }
        return false
    }

    private func readLastReview() -> Date? {
        guard let text = try? String(contentsOf: reviewMarker, encoding: .utf8),
              let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Review text

    static let reviewInstruction = "Выбери из заметок ниже только то, что стоит помнить надолго (факты о владельце, его людях и решениях), сохрани каждое через remember, а остальное отбрось."

    private static func cutNote(hidden: Int) -> String {
        hidden > 0
            ? "(обрезано по \(reviewCharacters) знаков: показаны самые новые, ещё \(hidden) старых не вошли)"
            : "(заметка обрезана по \(reviewCharacters) знаков)"
    }

    /// Newest notes first, whole lines only, the instruction included in the limit.
    private static func reviewText(_ notes: [Entry], limit: Int) -> String {
        let reserve = cutNote(hidden: notes.count).count + 1
        var lines: [String] = []
        var used = reviewInstruction.count + 1
        var shown = 0
        var partial = false
        while shown < notes.count {
            let written = line(notes[shown])
            let room = limit - used - reserve
            if written.count + 1 > room {
                // A single note longer than the room is cut to fit; anything after it is left out.
                if !lines.isEmpty { break }
                lines.append(String(written.prefix(max(0, room - 1))))
                shown += 1
                partial = true
                break
            }
            lines.append(written)
            used += written.count + 1
            shown += 1
        }
        var text = ([reviewInstruction] + lines).joined(separator: "\n")
        let hidden = notes.count - shown
        if hidden > 0 || partial { text += "\n" + cutNote(hidden: hidden) }
        return text
    }
}

public enum NoteReviewError: Error, LocalizedError {
    case reviewNotSaved(String)

    public var errorDescription: String? {
        switch self {
        case let .reviewNotSaved(reason): return "не смогла сохранить отметку просмотра: \(reason)"
        }
    }
}

struct AddNoteTool: AgentTool {
    let store: NoteStore
    var definition: ToolDefinition {
        ToolDefinition(name: "add_note", description: "Write down a note of the owner with the time; use when he says «запиши», «заметка», «не забыть».",
                       parametersJSON: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#)
    }
    func run(argumentsJSON: String) -> ToolResult {
        guard let args = WorkspaceTools.arguments(argumentsJSON), let text = args["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolResult(ok: false, text: "bad arguments: need text")
        }
        return ToolResult(ok: true, text: "записала в \(store.add(text))")
    }
}

struct FindNotesTool: AgentTool {
    let store: NoteStore
    var definition: ToolDefinition {
        ToolDefinition(name: "find_notes", description: "Find earlier notes by words, including the archive (marked «(архив)»). An empty query gives the latest notes.",
                       parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#)
    }
    func run(argumentsJSON: String) -> ToolResult {
        guard let args = WorkspaceTools.arguments(argumentsJSON), let query = args["query"] as? String else { return ToolResult(ok: false, text: "bad arguments: need query") }
        let hits = store.search(query)
        return ToolResult(ok: true, text: hits.isEmpty ? "заметок не нашла" : hits.joined(separator: "\n"))
    }
}

/// Reads what the owner noted since the last review and hands it to the model to pick the lasting facts. Also archives notes older than two weeks.
struct ReviewNotesTool: AgentTool {
    let store: NoteStore
    var definition: ToolDefinition {
        ToolDefinition(name: "review_notes", description: "Read the owner's notes since the last review (the first time: last 14 days); older ones move to the archive. Then remember each lasting fact.",
                       parametersJSON: #"{"type":"object","properties":{}}"#)
    }
    func run(argumentsJSON: String) -> ToolResult {
        do {
            return ToolResult(ok: true, text: try store.review(now: Date()))
        } catch {
            return ToolResult(ok: false, text: error.localizedDescription)
        }
    }
}

public extension ToolRegistry {
    static func noteTools(_ store: NoteStore) -> ToolRegistry {
        ToolRegistry([AddNoteTool(store: store), FindNotesTool(store: store), ReviewNotesTool(store: store)])
    }
}

/// What is going on in Core, in words, for the question «что там с задачей?». The provider reads the live task list.
struct TaskStatusTool: AgentTool {
    let provider: @Sendable () async -> String
    var definition: ToolDefinition {
        ToolDefinition(name: "list_tasks", description: "Running, waiting and finished work. Do not count the task that asks.",
                       parametersJSON: #"{"type":"object","properties":{}}"#)
    }
    func run(argumentsJSON: String) -> ToolResult { ToolResult(ok: false, text: "runs asynchronously") }
    func runAsync(argumentsJSON: String) async -> ToolResult { ToolResult(ok: true, text: await provider()) }
}

public extension ToolRegistry {
    static func taskTools(_ provider: @escaping @Sendable () async -> String) -> ToolRegistry { ToolRegistry([TaskStatusTool(provider: provider)]) }
}
