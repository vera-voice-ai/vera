import Foundation
@testable import Core

/// A temporary folder with fake `codex` and `claude` executables (small shell scripts). Each fake records its arguments and
/// environment, prints what the test put in `<name>.out`, writes `<name>.err` to stderr, writes `<name>.last` into the
/// `--output-last-message` file, sleeps when `<name>.sleep` exists, and exits with the code in `<name>.exit`.
/// Nothing here starts the real CLIs or touches the owner's Application Support folder.
struct FakeEngines {
    let base: URL

    init() {
        base = FileManager.default.temporaryDirectory
            .appending(path: "vera-engine-tests-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    var root: URL { base.appending(path: "Engines", directoryHint: .isDirectory) }
    var bin: URL { root.appending(path: "agents/node_modules/.bin", directoryHint: .isDirectory) }
    var workspace: URL { base.appending(path: "Workspace", directoryHint: .isDirectory) }

    func cleanUp() { try? FileManager.default.removeItem(at: base) }

    /// Writes an executable fake named `name` into `folder` (default: Vera's own bin folder).
    @discardableResult
    func install(_ name: String, in folder: URL? = nil) -> URL {
        let directory = folder ?? bin
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dir = base.path
        let script = """
        #!/bin/sh
        D='\(dir)'
        N='\(name)'
        printf '%s\\0' "$@" > "$D/$N.argv"
        env > "$D/$N.env"
        prev=""
        for a in "$@"; do
          if [ "$prev" = "--output-last-message" ] && [ -f "$D/$N.last" ]; then cat "$D/$N.last" > "$a"; fi
          prev="$a"
        done
        if [ -f "$D/$N.out" ]; then cat "$D/$N.out"; fi
        if [ -f "$D/$N.err" ]; then cat "$D/$N.err" >&2; fi
        if [ -f "$D/$N.sleep" ]; then exec sleep 30; fi
        if [ -f "$D/$N.exit" ]; then exit "$(cat "$D/$N.exit")"; fi
        exit 0

        """
        let url = directory.appending(path: name)
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Sets what a fake prints and does on its next run.
    func behave(_ name: String, stdout: String? = nil, stderr: String? = nil, exit: Int32? = nil,
                lastMessage: String? = nil, sleeps: Bool = false) {
        let files: [(String, String?)] = [("out", stdout), ("err", stderr), ("exit", exit.map(String.init)), ("last", lastMessage)]
        for (suffix, text) in files {
            let url = base.appending(path: "\(name).\(suffix)")
            if let text { try? text.write(to: url, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: url) }
        }
        let sleepFile = base.appending(path: "\(name).sleep")
        if sleeps { FileManager.default.createFile(atPath: sleepFile.path, contents: nil) } else { try? FileManager.default.removeItem(at: sleepFile) }
    }

    /// The arguments the fake received, one element per entry.
    func argv(_ name: String) -> [String] {
        guard let data = try? Data(contentsOf: base.appending(path: "\(name).argv")) else { return [] }
        var parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// The environment the fake received.
    func environment(_ name: String) -> [String: String] {
        guard let text = try? String(contentsOf: base.appending(path: "\(name).env"), encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            result[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return result
    }

    /// The locator for this folder: Vera's copy only, no system folders.
    var locator: EngineLocator { EngineLocator(root: root, searchDirectories: []) }
}

/// Calls one tool of a registry by its name, the way the agent loop does.
func callEngineTool(_ registry: ToolRegistry, _ name: String, _ arguments: String) async -> ToolResult {
    guard let tool = registry.tools.first(where: { $0.definition.name == name }) else {
        return ToolResult(ok: false, text: "no tool \(name)")
    }
    return await tool.runAsync(argumentsJSON: arguments)
}

/// A JSON string literal for a task (quotes, newlines and backslashes escaped), for building tool arguments in tests.
func jsonArguments(task: String, mode: String? = nil) -> String {
    var object: [String: Any] = ["task": task]
    if let mode { object["mode"] = mode }
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
}
