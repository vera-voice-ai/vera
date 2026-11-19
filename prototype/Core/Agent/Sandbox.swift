import Darwin
import Foundation

/// Whether commands the agent runs by itself (the `.safe` path) are wrapped in sandbox-exec.
/// Commands the owner approved by voice are never sandboxed: his word is the exit from the sandbox.
/// Read once. `VERA_SANDBOX=off` in the launch environment turns the sandbox off (escape hatch for the owner).
public enum SandboxPolicy {
    public static let enabled: Bool = ProcessInfo.processInfo.environment["VERA_SANDBOX"] != "off"
}

/// Builds the Seatbelt (SBPL) profile for one sandboxed command and prepares its private scratch folder.
/// Deny by default: reads are allowed broadly except a few secret places, writes only into the workspace and scratch folder, no network.
public enum SandboxProfile {
    /// Folders under the home directory that are never readable from a sandboxed command.
    static let deniedHomeFolders = [".ssh", ".aws", ".gnupg", ".hermes", "Library/Keychains"]
    /// Files under the home directory that are never readable from a sandboxed command.
    static let deniedHomeFiles = [".netrc", ".npmrc"]
    /// The Vera data folder: readable and writable only through the workspace.
    static let appSupportFolder = "Library/Application Support/VeraSensorPrototype"

    /// The private scratch folder that sandboxed commands may write to (`$TMPDIR/vera-sandbox`), created on demand.
    public static func scratchDirectory() -> URL {
        let url = URL(fileURLWithPath: realPath(FileManager.default.temporaryDirectory.path)).appending(path: "vera-sandbox", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The real location of a path (symlinks such as /var -> /private/var resolved). `resolvingSymlinksInPath()` is not
    /// enough: Foundation drops the /private prefix again, and Seatbelt matches real paths only.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Returns the SBPL profile text. Paths are resolved to their real locations, because Seatbelt matches real paths
    /// (a symlinked `/var/folders` would otherwise never match). Quotes and backslashes in paths are escaped.
    public static func make(workspace: URL,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            scratch: URL = scratchDirectory()) -> String {
        let homePath = realPath(home.path)
        let workspacePath = realPath(workspace.path)
        let scratchPath = realPath(scratch.path)
        let appSupport = homePath + "/" + appSupportFolder

        var rules = [
            "(version 1)",
            "(deny default)",
            // What a shell and basic tools need to start and run.
            "(allow process-exec*)",
            "(allow process-fork)",
            "(allow signal)",
            "(allow sysctl-read)",
            "(allow mach-lookup)",
            "(allow ipc-posix-shm*)",
            "(allow file-ioctl)",
            // Reading is broad; the denials below come after and win.
            "(allow file-read*)",
        ]
        for folder in deniedHomeFolders {
            rules.append("(deny file-read* (subpath \(quote(homePath + "/" + folder))))")
        }
        for file in deniedHomeFiles {
            rules.append("(deny file-read* (literal \(quote(homePath + "/" + file))))")
        }
        rules.append("(deny file-read* (subpath \(quote(appSupport))))")
        // The workspace is the one place inside the app data folder that stays readable.
        rules.append("(allow file-read* (subpath \(quote(workspacePath))))")
        // Writes: workspace, private scratch, and harmless devices only.
        rules.append("(allow file-write* (subpath \(quote(workspacePath))) (subpath \(quote(scratchPath))) "
                     + "(literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/tty\"))")
        rules.append("(deny network*)")
        return rules.joined(separator: "\n") + "\n"
    }

    /// An SBPL string literal: wraps the path in quotes and escapes backslashes and quotes.
    static func quote(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}
