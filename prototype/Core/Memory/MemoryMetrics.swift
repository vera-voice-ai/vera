import Foundation

/// A read-only picture of what Core keeps: how many facts and tasks, how many notes, how many bytes on disk, and how
/// many characters of facts go into every task's context. Nothing is written; the numbers are measured on each call.
public struct MemoryMetrics: Sendable, Equatable {
    public let facts: Int
    public let tasks: Int
    public let notes: Int
    public let bytes: Int64
    /// Characters of `MemoryStore.factsText()`, which is put into the context of every task.
    public let factsContextCharacters: Int

    public init(facts: Int, tasks: Int, notes: Int, bytes: Int64, factsContextCharacters: Int) {
        self.facts = facts; self.tasks = tasks; self.notes = notes; self.bytes = bytes; self.factsContextCharacters = factsContextCharacters
    }

    /// Measures the memory store and the notes folder. A missing folder counts as empty.
    public static func measure(memory: MemoryStore, notesDirectory: URL) -> MemoryMetrics {
        let counts = memory.counts
        return MemoryMetrics(
            facts: counts.facts,
            tasks: counts.tasks,
            notes: noteCount(in: notesDirectory),
            bytes: bytesOnDisk([memory.directory, notesDirectory]),
            factsContextCharacters: memory.factsText()?.count ?? 0)
    }

    /// One line for the Core panel: "фактов N · в контексте ~M симв. · заметок K · задач в истории T · X КБ".
    public var summary: String {
        "фактов \(facts) · в контексте ~\(factsContextCharacters) симв. · заметок \(notes) · задач в истории \(tasks) · \(String(format: "%.1f", Double(bytes) / 1024)) КБ"
    }

    /// A note is one line "- HH:MM text" in a daily Markdown file, as written by NoteStore.
    static func noteCount(in directory: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".md") }.reduce(0) { total, name in
            let text = (try? String(contentsOf: directory.appending(path: name), encoding: .utf8)) ?? ""
            return total + text.split(separator: "\n").filter { $0.hasPrefix("- ") }.count
        }
    }

    /// Sum of the sizes of all regular files under the given folders (recursively). Missing folders add nothing.
    static func bytesOnDisk(_ directories: [URL]) -> Int64 {
        var total: Int64 = 0
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
