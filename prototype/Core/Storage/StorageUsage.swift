import Foundation

/// Measures what Vera 2 keeps under its Application Support folder. Only reads the file system: no caching, no UI.
/// Symbolic links are neither followed nor counted; unreadable entries are skipped.
public enum StorageUsage {
    public enum Area: String, CaseIterable, Sendable {
        case tape = "Tape"
        case recordings = "Recordings"
        case journal = "Journal"
        case logs = "Logs"
        case memory = "Memory"
        case notes = "Notes"
        case skills = "Skills"
        case telegram = "Telegram"
        case users = "Users"
        case workspace = "Workspace"
        /// Deleted workspace files. Counted on its own: the Workspace total leaves it out.
        case workspaceTrash = "Workspace/.trash"

        var relativePath: String { rawValue }

        fileprivate var excludedSubpath: String? { self == .workspace ? ".trash" : nil }
    }

    public struct Folder: Sendable, Equatable {
        public let area: Area
        public let bytes: Int64
        public let files: Int
    }

    public struct Snapshot: Sendable, Equatable {
        public let folders: [Folder]
        public let freeBytes: Int64?
        public let totalBytes: Int64?

        public func folder(_ area: Area) -> Folder? { folders.first { $0.area == area } }
    }

    public static func snapshot(root: URL) -> Snapshot {
        Snapshot(folders: Area.allCases.map { folder($0, under: root) },
                 freeBytes: freeBytes(at: root),
                 totalBytes: totalBytes(at: root))
    }

    /// A missing folder is reported as empty, not as an error.
    public static func folder(_ area: Area, under root: URL) -> Folder {
        let url = root.appending(path: area.relativePath, directoryHint: .isDirectory)
        let excluded = area.excludedSubpath.map { url.appending(path: $0, directoryHint: .isDirectory) }
        let totals = measure(url, excluding: excluded)
        return Folder(area: area, bytes: totals.bytes, files: totals.files)
    }

    /// Free space available for important use on the volume that holds `url` (or its nearest existing parent).
    public static func freeBytes(at url: URL) -> Int64? {
        let values = try? existingAncestor(of: url).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    public static func totalBytes(at url: URL) -> Int64? {
        let values = try? existingAncestor(of: url).resourceValues(forKeys: [.volumeTotalCapacityKey])
        return values?.volumeTotalCapacity.map(Int64.init)
    }

    private static func measure(_ url: URL, excluding excluded: URL?) -> (bytes: Int64, files: Int) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                          options: [], errorHandler: { _, _ in true })
        else { return (0, 0) }
        let skipPath = excluded?.standardizedFileURL.path
        var bytes: Int64 = 0
        var files = 0
        for case let entry as URL in walker {
            if let skipPath, entry.standardizedFileURL.path == skipPath {
                walker.skipDescendants()
                continue
            }
            guard let values = try? entry.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
            if values.isRegularFile == true {
                bytes += Int64(values.fileSize ?? 0)
                files += 1
            }
        }
        return (bytes, files)
    }

    private static func existingAncestor(of url: URL) -> URL {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
            candidate = candidate.deletingLastPathComponent()
        }
        return candidate
    }
}
