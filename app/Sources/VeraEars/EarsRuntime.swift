import CSherpa
import Foundation

/// Where Vera's ears lie: inside the app (`Resources/ears`, made by `scripts/build-ears.sh` and copied by
/// `scripts/bundle.sh`), or the build output `~/.vera03/build/ears` for `swift run` / snapshots. Nothing else is
/// looked for: no Python, no models of other Veras, no system speech service.
public struct EarsRuntime: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var library: URL { root.appending(path: "lib/lib/libsherpa-onnx-c-api.dylib") }
    /// onnxruntime that sherpa-onnx brings — Vera's Swift voice runs on it too.
    public var onnxruntime: URL { root.appending(path: "lib/lib/libonnxruntime.dylib") }
    public var vadModel: URL { root.appending(path: "models/vad/silero_vad.onnx") }
    public var gigaAMModel: URL { root.appending(path: "models/gigaam/model.int8.onnx") }
    public var gigaAMTokens: URL { root.appending(path: "models/gigaam/tokens.txt") }
    public var toneModel: URL { root.appending(path: "models/t-one/model.onnx") }
    public var toneTokens: URL { root.appending(path: "models/t-one/tokens.txt") }
    public var stamp: URL { root.appending(path: "ears.stamp.json") }

    /// `VERA_EARS` → the app bundle → the build output. Returns nil when none of them has the library.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               bundle: Bundle = .main) -> EarsRuntime? {
        var candidates: [URL] = []
        if let path = environment["VERA_EARS"], !path.isEmpty { candidates.append(URL(fileURLWithPath: path)) }
        if let res = bundle.resourceURL { candidates.append(res.appending(path: "ears")) }
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".vera03/build/ears"))
        return candidates.map(EarsRuntime.init).first { FileManager.default.fileExists(atPath: $0.library.path) }
    }

    /// sherpa-onnx version from the stamp (what the lock pinned).
    public var version: String? {
        guard let data = try? Data(contentsOf: stamp),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["sherpa_onnx"] as? String
    }
}

public enum EarsError: LocalizedError, Equatable {
    case notBuilt
    case library(String)
    case model(String)

    public var errorDescription: String? {
        switch self {
        case .notBuilt: "ушей нет в сборке — scripts/build-ears.sh и scripts/bundle.sh"
        case .library(let why): "библиотека распознавания не загрузилась: \(why)"
        case .model(let name): "модель \(name) не загрузилась"
        }
    }
}

/// The C library is loaded once per process.
enum SherpaLibrary {
    nonisolated(unsafe) private static var loadedFrom: URL?
    private static let lock = NSLock()

    static func load(_ runtime: EarsRuntime) throws {
        lock.lock(); defer { lock.unlock() }
        if loadedFrom != nil { return }
        guard vera_sherpa_load(runtime.library.path) == 0 else {
            throw EarsError.library(String(cString: vera_sherpa_error()))
        }
        loadedFrom = runtime.library
    }
}
