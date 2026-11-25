import Foundation

/// `hermes.lock.json`: the Hermes build Vera was checked against (docs/hermes-updates.md).
public struct HermesLock: Sendable, Codable, Equatable {
    public let version: String
    public let tag: String
    public let commit: String
    public let gatewayProtocol: String
    public let runtimeProtocol: Int
    public let contractPaths: [String]
    public let hooksUsed: [String]
    /// Where the tag comes from (the public repository).
    public var source: String?

    enum CodingKeys: String, CodingKey {
        case version, tag, commit, source
        case gatewayProtocol = "gateway_protocol"
        case runtimeProtocol = "runtime_protocol"
        case contractPaths = "contract_paths"
        case hooksUsed = "hooks_used"
    }

    public static func load(_ url: URL) throws -> HermesLock {
        try JSONDecoder().decode(HermesLock.self, from: Data(contentsOf: url))
    }

    /// The app bundle's copy, else the repository's (found upwards from the executable during development).
    public static func find(bundle: Bundle = .main) -> URL? {
        if let url = bundle.url(forResource: "hermes.lock", withExtension: "json") { return url }
        var dir = URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appending(path: "hermes.lock.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}

/// How the running Hermes compares with the lock.
public enum LockStatus: Sendable, Equatable {
    case unknown
    case verified
    /// Each reason is one short Russian line for the header's help text.
    case unverified([String])

    public static func check(lock: HermesLock?, install: HermesInstall?, gatewayCodeSha: String?,
                             gatewayProtocol: String?) -> LockStatus {
        guard let lock else { return .unknown }
        guard install != nil || gatewayCodeSha != nil else { return .unknown }
        var reasons: [String] = []
        if let commit = install?.commit, commit != lock.commit {
            reasons.append("установка \(commit.prefix(12)) ≠ замок \(lock.commit.prefix(12))")
        }
        if let sha = gatewayCodeSha, sha != lock.commit {
            reasons.append("шлюз \(sha.prefix(12)) ≠ замок \(lock.commit.prefix(12))")
        }
        if let proto = gatewayProtocol, proto != lock.gatewayProtocol {
            reasons.append("протокол \(proto) ≠ \(lock.gatewayProtocol)")
        }
        return reasons.isEmpty ? .verified : .unverified(reasons)
    }
}
