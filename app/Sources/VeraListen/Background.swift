import Foundation

/// The key phrase that makes Vera active: «Привет, Вера» anywhere in what was said — plain mechanics on the
/// recognised text, no model. No pause is needed before it (talk before it in the same breath is left out) or after it
/// (what follows in the same breath is the request). Punctuation, case and «ё» do not matter.
public enum WakePhrase {
    /// The key phrase, word by word: lower case, «ё» as «е».
    public static let words = ["привет", "вера"]
    /// As it is shown on screens.
    public static let shown = "Привет, Вера"

    /// nil — the key phrase is not there; "" — nothing after it; otherwise the request after it (the last occurrence).
    public static func match(_ text: String) -> String? {
        // Words with their ranges in the text.
        var found: [(word: String, end: String.Index)] = []
        var i = text.startIndex
        while let start = text[i...].firstIndex(where: \.isLetter) {
            let end = text[start...].firstIndex(where: { !$0.isLetter }) ?? text.endIndex
            found.append((text[start..<end].lowercased().replacingOccurrences(of: "ё", with: "е"), end))
            i = end
        }
        guard found.count >= words.count else { return nil }
        for k in stride(from: found.count - words.count, through: 0, by: -1)
        where zip(found[k..<k + words.count], words).allSatisfy({ $0.0.word == $0.1 }) {
            let rest = text[found[k + words.count - 1].end...].drop(while: { !$0.isLetter && !$0.isNumber })
            return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}

/// What background listening heard, written and not sent: one JSON line per phrase. The Mac: `background-YYYY-MM-DD.jsonl`
/// in Vera's data folder `ears/`; the phone: `YYYY-MM-DD/background.jsonl` next to its activity log (`dayFolders`),
/// which the Mac copies home. The text stays with Vera; nothing here goes to the agent.
public struct BackgroundTranscript: Sendable {
    public let directory: URL
    public let dayFolders: Bool

    public init(directory: URL, dayFolders: Bool = false) { self.directory = directory; self.dayFolders = dayFolders }

    public struct Line: Codable, Sendable, Equatable {
        public var ts: Double
        public var text: String
        /// Length of the phrase, s, and its loudness, dBFS.
        public var seconds: Double
        public var db: Double
        /// The phrase opened the conversation (started with the key word).
        public var woke: Bool

        public init(ts: Double, text: String, seconds: Double, db: Double, woke: Bool) {
            self.ts = ts; self.text = text; self.seconds = seconds; self.db = db; self.woke = woke
        }
    }

    private static let day: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    public func file(for date: Date) -> URL {
        let day = Self.day.string(from: date)
        return dayFolders ? directory.appending(path: day).appending(path: "background.jsonl")
                          : directory.appending(path: "background-\(day).jsonl")
    }

    public func append(_ line: Line) {
        let url = file(for: Date(timeIntervalSince1970: line.ts))
        guard var data = try? JSONEncoder().encode(line) else { return }
        data.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// The day's lines, oldest first.
    public func read(day date: Date = Date()) -> [Line] {
        guard let text = try? String(contentsOf: file(for: date), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Line.self, from: Data($0.utf8)) }
    }
}
