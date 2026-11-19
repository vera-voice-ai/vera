import Foundation

/// The two external agent CLIs Vera can call as tools.
public enum EngineKind: String, Sendable, CaseIterable {
    case codex, claude

    /// The executable's name, also the tool's name.
    public var binaryName: String { rawValue }

    /// The variable that moves the CLI's configuration and login into Vera's own folder.
    public var configVariable: String { self == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR" }

    /// The folder under `agents/home/` that holds this CLI's own configuration.
    var configFolder: String { rawValue }
}

/// Where a CLI was found: Vera's own copy inside the engines folder, or a system folder on the search path.
public struct EngineLocation: Equatable, Sendable {
    public enum Source: String, Sendable { case veraCopy, systemPath }
    public let executable: URL
    public let source: Source
    public init(executable: URL, source: Source) { self.executable = executable; self.source = source }
}

/// Finds the CLIs. Vera's own copy (installed by `Evaluation/install-engines.sh`) always wins; the search path is the fallback.
/// Each CLI gets its own configuration folder, so Vera's login stays apart from the owner's global one.
public struct EngineLocator: Sendable {
    public static let defaultRoot: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: "Library/Application Support/VeraSensorPrototype/Engines", directoryHint: .isDirectory)

    public static let defaultSearchDirectories: [URL] = [
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".local/bin", directoryHint: .isDirectory),
        URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
        URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
    ]

    /// The engines folder: `agents/` holds the npm prefix, `agents/home/<cli>` the configuration of each CLI.
    public let root: URL
    public let searchDirectories: [URL]

    public init(root: URL = EngineLocator.defaultRoot, searchDirectories: [URL] = EngineLocator.defaultSearchDirectories) {
        self.root = root
        self.searchDirectories = searchDirectories
    }

    public var agentsFolder: URL { root.appending(path: "agents", directoryHint: .isDirectory) }

    /// `<root>/agents/node_modules/.bin/<cli>`: where npm puts the executable of a local install.
    public func veraCopy(_ kind: EngineKind) -> URL {
        agentsFolder.appending(path: "node_modules/.bin/\(kind.binaryName)")
    }

    /// Vera's copy first; then the first executable of that name in the search directories.
    public func locate(_ kind: EngineKind) -> EngineLocation? {
        let fileManager = FileManager.default
        let copy = veraCopy(kind)
        if fileManager.isExecutableFile(atPath: copy.path) {
            return EngineLocation(executable: copy, source: .veraCopy)
        }
        for directory in searchDirectories {
            let candidate = directory.appending(path: kind.binaryName)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return EngineLocation(executable: candidate, source: .systemPath)
            }
        }
        return nil
    }

    /// `<root>/agents/home/<cli>`: the CLI's own configuration folder (login lives there).
    public func configHome(_ kind: EngineKind) -> URL {
        agentsFolder.appending(path: "home/\(kind.configFolder)", directoryHint: .isDirectory)
    }

    /// Creates both configuration folders, readable by the owner only.
    public func prepareHomes() throws {
        let fileManager = FileManager.default
        let parent = agentsFolder.appending(path: "home", directoryHint: .isDirectory)
        for folder in [parent] + EngineKind.allCases.map(configHome) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
    }

    /// The child's whole environment: no key or token is inherited from Vera's process.
    public func environment(for location: EngineLocation, kind: EngineKind) -> [String: String] {
        var path = [location.executable.deletingLastPathComponent().path]
        path += searchDirectories.map(\.path)
        path += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return [
            "PATH": path.joined(separator: ":"),
            "HOME": NSHomeDirectory(),
            "LANG": "ru_RU.UTF-8",
            "TERM": "dumb",
            kind.configVariable: configHome(kind).path
        ]
    }
}
