import Foundation

/// How Hermes' skills are really used, from `<HERMES_HOME>/skills/.usage.json` (the file Hermes' curator keeps:
/// `use_count`, `last_used_at`, `last_viewed_at`, `last_patched_at`, `created_at`, `state`, `created_by`, `pinned`).
public struct SkillUsage: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        public let uses: Int
        /// The latest of used / viewed / patched, unix seconds.
        public let lastActive: Double?
        public let createdBy: String?
        public let pinned: Bool
        public let state: String
    }

    public var rows: [Row] = []
    public init() {}

    public var used: [Row] { rows.filter { $0.uses > 0 }.sorted { ($0.uses, $0.lastActive ?? 0) > ($1.uses, $1.lastActive ?? 0) } }
    public var lastUsed: Row? { rows.filter { $0.lastActive != nil }.max { ($0.lastActive ?? 0) < ($1.lastActive ?? 0) } }
    public var madeByAgent: [Row] { rows.filter { $0.createdBy == "agent" || $0.createdBy == "learn" } }

    public static func read(hermesHome: URL) -> SkillUsage {
        guard let data = try? Data(contentsOf: hermesHome.appending(path: "skills/.usage.json")),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return SkillUsage() }
        return parse(json)
    }

    public static func parse(_ json: JSONValue) -> SkillUsage {
        var u = SkillUsage()
        for (name, rec) in json.object ?? [:] {
            let times = ["last_used_at", "last_viewed_at", "last_patched_at", "created_at"].compactMap { timestamp(rec[$0]) }
            u.rows.append(Row(name: name, uses: Int(rec["use_count"]?.number ?? 0), lastActive: times.max(),
                              createdBy: rec["created_by"]?.string, pinned: rec["pinned"]?.bool ?? false,
                              state: rec["state"]?.string ?? "active"))
        }
        u.rows.sort { $0.name < $1.name }
        return u
    }

    /// Epoch seconds from a number, a numeric string or an ISO-8601 date (as Hermes' `_to_int_ts`).
    static func timestamp(_ v: JSONValue?) -> Double? {
        if let n = v?.number { return n }
        guard let s = v?.string?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let n = Double(s) { return n }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)?.timeIntervalSince1970
    }
}
