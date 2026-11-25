import Foundation

/// Hermes inside Vera: a read-only payload (Hermes source + CPython + dependencies, built by `pm bundle`)
/// and Vera's own writable data. Nothing of the user's machine is looked up: no `~/.hermes`, no PATH search,
/// no inherited environment. Hermes processes get a home of their own, so even Hermes' own "found on this
/// computer" probes (`Path.home()`) see only Vera's folder.
public struct HermesRuntime: Sendable, Equatable {
    /// `<payload>/bin/hermes`, `<payload>/venv`, `<payload>/hermes-agent`, `<payload>/tools`, `<payload>/vera-payload.json`.
    public let payload: URL
    /// `~/Library/Application Support/Vera03` unless `VERA_DATA_ROOT` says otherwise.
    public let dataRoot: URL
    /// Vera's Hermes plugins by name → source folder (bundle `Resources/plugins/<name>`, or the repository's
    /// `hermes-plugin/<name>` during development). Linked into `<HERMES_HOME>/plugins/<name>` on every start.
    public let plugins: [String: URL]
    /// Vera's own executable: the vera-ears plugin runs it as `Vera --transcribe <file>` for Hermes' voice messages
    /// (`VERA_EARS_BIN` in Hermes' environment). Nil when Vera is not an app run (tests).
    public let earsBinary: URL?

    public static let pluginNames = ["vera-pulse", "vera-setup", "vera-ears", "vera-phone", "vera-context", "vera-browser"]

    public init(payload: URL, dataRoot: URL, plugins: [String: URL], earsBinary: URL? = nil) {
        self.payload = payload; self.dataRoot = dataRoot; self.plugins = plugins; self.earsBinary = earsBinary
    }

    public var hermesHome: URL { dataRoot.appending(path: "hermes") }
    /// `HOME` of every Hermes process.
    public var home: URL { dataRoot.appending(path: "home") }
    public var binary: URL { payload.appending(path: "bin/hermes") }
    public var pulseDirectory: URL { hermesHome.appending(path: "vera-pulse") }
    /// The agent's working folder for chats Vera starts.
    public var workspace: URL { dataRoot.appending(path: "workspace") }
    public func pluginLink(_ name: String) -> URL { hermesHome.appending(path: "plugins/\(name)") }
    public var stampURL: URL { payload.appending(path: "vera-payload.json") }

    public var payloadDescription: String {
        payload.path(percentEncoded: false).contains(".app/Contents/Resources") ? "внутри Vera03.app" : payload.path(percentEncoded: false)
    }

    /// Built from nothing but Vera's own paths: the user's environment variables (API keys, PATH, HERMES_*)
    /// never reach Hermes.
    public var environment: [String: String] {
        let system = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "HOME": home.path,
            "HERMES_HOME": hermesHome.path,
            "PATH": [payload.appending(path: "bin").path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":"),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "SHELL": "/bin/zsh",
            "PYTHONNOUSERSITE": "1",
            "VERA_PULSE_DIR": pulseDirectory.path,
            // Vera's data folder: plugin vera-phone talks to the phone through `phone-bridge/` there, vera-context reads
            // which session is which channel from the pinned-session files.
            "VERA_DATA": dataRoot.path
        ]
        if let earsBinary { env["VERA_EARS_BIN"] = earsBinary.path }
        // Identity and the per-user temp folder are the OS's, not the user's configuration.
        for key in ["USER", "LOGNAME", "TMPDIR"] { env[key] = system[key] }
        return env
    }

    /// Payload: `VERA_HERMES_PAYLOAD`, else `Vera03.app/Contents/Resources/hermes`, else the build folder
    /// `scripts/build-hermes.sh` fills (`~/.vera03/build/payload`) for `swift run` during development.
    public static func resolve(bundle: Bundle = .main,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> HermesRuntime {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let bundled = bundle.resourceURL?.appending(path: "hermes")
        let payload: URL
        if let p = environment["VERA_HERMES_PAYLOAD"], !p.isEmpty { payload = URL(filePath: p) }
        else if let b = bundled, fm.fileExists(atPath: b.appending(path: "bin/hermes").path) { payload = b }
        else { payload = home.appending(path: ".vera03/build/payload") }

        let dataRoot = environment["VERA_DATA_ROOT"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
            ?? home.appending(path: "Library/Application Support/Vera03")

        var plugins: [String: URL] = [:]
        for name in pluginNames {
            let bundled = bundle.resourceURL?.appending(path: "plugins/\(name)")
            if let b = bundled, fm.fileExists(atPath: b.appending(path: "plugin.yaml").path) { plugins[name] = b }
            else if let repo = repositoryFile("hermes-plugin/\(name)") { plugins[name] = repo }
        }
        return HermesRuntime(payload: payload, dataRoot: dataRoot, plugins: plugins,
                             earsBinary: bundle.executableURL.flatMap { $0.lastPathComponent == "Vera" ? $0 : nil })
    }

    /// During development the executable sits in `<repo>/app/.build/…`: walk up to the repository.
    static func repositoryFile(_ relative: String) -> URL? {
        var dir = URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appending(path: relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}

/// `vera-payload.json`, written by `scripts/build-hermes.sh` next to the payload.
public struct PayloadStamp: Sendable, Codable, Equatable {
    public let tag: String
    public let commit: String
    public let builtAt: String?

    enum CodingKeys: String, CodingKey { case tag, commit; case builtAt = "built_at" }
}

/// What Vera runs.
public struct HermesInstall: Sendable, Equatable {
    public let runtime: HermesRuntime
    public let stamp: PayloadStamp?
    /// First line of `hermes --version`.
    public let versionLine: String?

    public init(runtime: HermesRuntime, stamp: PayloadStamp?, versionLine: String?) {
        self.runtime = runtime; self.stamp = stamp; self.versionLine = versionLine
    }

    public var commit: String? { stamp?.commit }
    public var stableTag: String? { stamp.map(\.tag).flatMap { HermesLocator.isStableTag($0) ? $0 : nil } }
    public var shortCommit: String { commit.map { String($0.prefix(12)) } ?? "—" }
}

public enum HermesLocator {
    /// nil when the payload is missing (`scripts/build-hermes.sh`).
    public static func locate(_ runtime: HermesRuntime) async -> HermesInstall? {
        guard FileManager.default.isExecutableFile(atPath: runtime.binary.path) else { return nil }
        let stamp = (try? Data(contentsOf: runtime.stampURL)).flatMap { try? JSONDecoder().decode(PayloadStamp.self, from: $0) }
        let version = try? await ProcessRunner.run(runtime.binary, ["--version"], environment: runtime.environment)
        let line = version.flatMap { $0.text.split(separator: "\n").first.map(String.init) }
        return HermesInstall(runtime: runtime, stamp: stamp, versionLine: line)
    }

    /// Stable channel = final releases only: `v0.23.3`, not `v0.23.3+canary.…`.
    public static func isStableTag(_ tag: String) -> Bool {
        tag.wholeMatch(of: /v\d+\.\d+\.\d+/) != nil
    }
}

/// First-run and every-run setup of Vera's Hermes data, idempotent: folders, launchers kept off PATH,
/// Vera's plugins linked (every start: the app may have moved) and enabled (once each). Touches only `runtime.dataRoot`.
public enum HermesBootstrap {
    public static func ensure(_ runtime: HermesRuntime) async -> [String] {
        let fm = FileManager.default
        var notes: [String] = []
        for dir in [runtime.hermesHome, runtime.home, runtime.workspace, runtime.pulseDirectory, runtime.hermesHome.appending(path: "plugins")] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let marker = runtime.hermesHome.appending(path: ".vera-bootstrap-1")
        let firstRun = !fm.fileExists(atPath: marker.path)
        if firstRun {
            // Hermes would otherwise offer its commands on PATH; inside Vera they stay private.
            _ = try? await ProcessRunner.run(runtime.binary, ["config", "set", "--force", "cli.expose_on_path", "false"],
                                             environment: runtime.environment)
        }
        for name in HermesRuntime.pluginNames {
            guard let source = runtime.plugins[name] else { notes.append("нет исходника плагина \(name)"); continue }
            let link = runtime.pluginLink(name)
            let current = try? fm.destinationOfSymbolicLink(atPath: link.path)
            if current != source.path {
                try? fm.removeItem(at: link)
                do { try fm.createSymbolicLink(at: link, withDestinationURL: source) }
                catch { notes.append("\(name) не связан: \(error.localizedDescription)"); continue }
            }
            let enabled = runtime.hermesHome.appending(path: ".vera-plugin-\(name)")
            if !fm.fileExists(atPath: enabled.path) {
                let out = try? await ProcessRunner.run(runtime.binary, ["plugins", "enable", name], environment: runtime.environment)
                if out?.status == 0 { fm.createFile(atPath: enabled.path, contents: Data()) }
                else { notes.append("\(name) не включён") }
            }
        }
        // Hermes' browser tools work in Vera's own browser window (MacBrowser, DevTools port on loopback), not in a hidden
        // throwaway one: the owner sees the pages and finishes what is his (a CAPTCHA, the final button). Once.
        let browserMarker = runtime.hermesHome.appending(path: ".vera-browser-1")
        if !fm.fileExists(atPath: browserMarker.path) {
            let out = try? await ProcessRunner.run(runtime.binary, ["config", "set", "browser.cdp_url", "http://127.0.0.1:9333"],
                                                   environment: runtime.environment)
            if out?.status == 0 { fm.createFile(atPath: browserMarker.path, contents: Data()) } else { notes.append("браузер Веры не прописан") }
        }
        if firstRun && notes.isEmpty { fm.createFile(atPath: marker.path, contents: Data()) }
        return notes
    }
}
