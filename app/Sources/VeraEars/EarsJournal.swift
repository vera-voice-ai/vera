import Foundation

/// The ears' signals on disk, one JSON line each: `<data>/ears/<yyyy-MM-dd>.jsonl`. Like the pulse journal — names,
/// engine, durations, counts; never the words or the audio. It is what the engines are compared by.
public struct EarsJournal: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public struct Phrase: Codable, Sendable, Equatable {
        public var ts: Double
        public var kind = "phrase"
        public var engine: String
        /// Length of the phrase, s.
        public var seconds: Double
        /// From the phrase's start to its first partial text, ms (how soon the words appear).
        public var firstPartialMs: Int?
        /// From the phrase's end to the final text, ms.
        public var decodeMs: Int
        public var chars: Int
        public var partials: Int
        /// Loudness of the phrase, dBFS, and whether it went to the agent (background phrases under the threshold do not).
        public var db: Double?
        public var sent: Bool?
        /// The shadow engine's reading of the same phrase (engine comparison): never sent, never «ниже порога».
        public var shadow: Bool?

        public init(ts: Double, engine: String, seconds: Double, firstPartialMs: Int?, decodeMs: Int, chars: Int, partials: Int) {
            self.ts = ts; self.engine = engine; self.seconds = seconds; self.firstPartialMs = firstPartialMs
            self.decodeMs = decodeMs; self.chars = chars; self.partials = partials
        }
    }

    private static let day: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    public func file(for date: Date) -> URL { directory.appending(path: Self.day.string(from: date) + ".jsonl") }

    public func append(_ p: Phrase) {
        guard var line = try? JSONEncoder().encode(p) else { return }
        line.append(0x0A)
        let url = file(for: Date(timeIntervalSince1970: p.ts))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try? h.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    /// Phrases of the last `days` days.
    public func read(days: Int = 7, now: Date = Date()) -> [Phrase] {
        (0..<days).reversed().flatMap { d -> [Phrase] in
            let url = file(for: now.addingTimeInterval(-Double(d) * 86_400))
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Phrase.self, from: Data($0.utf8)) }
        }
    }

    public struct Summary: Sendable, Equatable {
        public var phrases = 0
        public var seconds = 0.0
        public var avgDecodeMs = 0
        public var avgFirstPartialMs: Int?
    }

    public static func summarize(_ phrases: [Phrase]) -> [String: Summary] {
        Dictionary(grouping: phrases, by: \.engine).mapValues { ps in
            var s = Summary()
            s.phrases = ps.count
            s.seconds = ps.reduce(0) { $0 + $1.seconds }
            s.avgDecodeMs = ps.reduce(0) { $0 + $1.decodeMs } / max(1, ps.count)
            let firsts = ps.compactMap(\.firstPartialMs)
            s.avgFirstPartialMs = firsts.isEmpty ? nil : firsts.reduce(0, +) / firsts.count
            return s
        }
    }
}
