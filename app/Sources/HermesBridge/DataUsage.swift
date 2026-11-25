import Foundation

/// What Vera's Hermes keeps on disk, measured where it really lies (`<data>/hermes`): the conversation store
/// (`state.db`), long-term memory (`memories/`), installed skills (`skills/`), logs, and our pulse journal.
public struct DataUsage: Sendable, Equatable {
    public var total: Int64 = 0
    public var conversations: Int64 = 0      // state.db (+ -wal)
    public var memoryFiles = 0
    public var memoryBytes: Int64 = 0
    public var skillDirs = 0
    public var logs: Int64 = 0
    public var pulse: Int64 = 0
    public var measured = false

    public init() {}

    /// Walks `hermesHome` once; cheap enough every half minute for a home of a few hundred MB.
    public static func scan(hermesHome: URL) -> DataUsage {
        var u = DataUsage()
        let fm = FileManager.default
        func size(_ url: URL) -> Int64 {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
            if !isDir.boolValue { return Int64((try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0) }
            var sum: Int64 = 0
            if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                for case let f as URL in e {
                    let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if v?.isRegularFile == true { sum += Int64(v?.fileSize ?? 0) }
                }
            }
            return sum
        }
        u.total = size(hermesHome)
        u.conversations = size(hermesHome.appending(path: "state.db")) + size(hermesHome.appending(path: "state.db-wal"))
        let memories = hermesHome.appending(path: "memories")
        u.memoryFiles = ((try? fm.contentsOfDirectory(atPath: memories.path)) ?? []).filter { !$0.hasPrefix(".") }.count
        u.memoryBytes = size(memories)
        u.skillDirs = ((try? fm.contentsOfDirectory(atPath: hermesHome.appending(path: "skills").path)) ?? []).filter { !$0.hasPrefix(".") }.count
        u.logs = size(hermesHome.appending(path: "logs"))
        u.pulse = size(hermesHome.appending(path: "vera-pulse"))
        u.measured = true
        return u
    }

    public static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
