import Foundation

/// «Жизнь»: summaries over days, read from what is already on disk — the vera-pulse journal (one file a day) and
/// Vera's own record of how her Hermes' data grows. Read in the background every half minute; never message text.
public enum LifeHistory {
    /// Activity per day × hour for the last `days` days (oldest first): model calls + tool calls + turns.
    public struct Grid: Sendable, Equatable {
        public var days: [Date] = []
        public var counts: [[Int]] = []
        public var max: Int { counts.flatMap { $0 }.max() ?? 0 }
        public init() {}
    }

    /// Today's model calls: when, how long, tokens, failed or not.
    public struct ModelCall: Sendable, Equatable {
        public let ts: Double
        public let ms: Double
        public let tokensIn: Int
        public let tokensOut: Int
        public let failed: Bool
    }

    private static let day: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    public static func events(pulseDirectory: URL, on date: Date) -> [PulseEvent] {
        let url = pulseDirectory.appending(path: day.string(from: date) + ".jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? dec.decode(PulseEvent.self, from: Data($0.utf8)) }
    }

    public static func grid(pulseDirectory: URL, days: Int = 7, now: Date = Date(), calendar: Calendar = .current) -> Grid {
        var g = Grid()
        let today = calendar.startOfDay(for: now)
        for d in (0..<days).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -d, to: today) else { continue }
            var row = Array(repeating: 0, count: 24)
            for e in events(pulseDirectory: pulseDirectory, on: date)
            where e.kind == "llm.start" || e.kind == "tool.start" || e.kind == "session.start" {
                row[calendar.component(.hour, from: Date(timeIntervalSince1970: e.ts))] += 1
            }
            g.days.append(date); g.counts.append(row)
        }
        return g
    }

    public static func modelCalls(pulseDirectory: URL, now: Date = Date()) -> [ModelCall] {
        events(pulseDirectory: pulseDirectory, on: now).compactMap { e in
            guard e.kind == "llm.end" || e.kind == "llm.error" else { return nil }
            return ModelCall(ts: e.ts, ms: e.durationMs ?? 0, tokensIn: e.tokensIn ?? 0, tokensOut: e.tokensOut ?? 0,
                             failed: e.kind == "llm.error" || (e.status != nil && e.status != "ok"))
        }
    }

    /// One point of how the data of Vera's Hermes grows (`<data>/history/usage.jsonl`).
    public struct UsagePoint: Codable, Sendable, Equatable {
        public let ts: Double
        public let total: Int64
        public let conversations: Int64
        public let memoryBytes: Int64
        public let memoryFiles: Int
    }

    /// Appends a point when an hour has passed since the last one or the memory changed; returns the whole history.
    @discardableResult
    public static func record(_ u: DataUsage, in directory: URL, now: Date = Date()) -> [UsagePoint] {
        let url = directory.appending(path: "usage.jsonl")
        var points = readUsage(url)
        let p = UsagePoint(ts: now.timeIntervalSince1970, total: u.total, conversations: u.conversations,
                           memoryBytes: u.memoryBytes, memoryFiles: u.memoryFiles)
        let last = points.last
        guard u.measured, last == nil || p.ts - last!.ts >= 3600 || p.memoryFiles != last!.memoryFiles
                || p.memoryBytes != last!.memoryBytes else { return points }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if var line = try? JSONEncoder().encode(p) {
            line.append(0x0A)
            if let h = try? FileHandle(forWritingTo: url) { _ = try? h.seekToEnd(); try? h.write(contentsOf: line); try? h.close() }
            else { try? line.write(to: url) }
        }
        points.append(p)
        return points
    }

    public static func readUsage(_ url: URL) -> [UsagePoint] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(UsagePoint.self, from: Data($0.utf8)) }
    }
}
