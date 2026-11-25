import Foundation

/// `hermes gateway attach --json`: where the profile's gateway listens and a single-use ticket for one dial.
/// The ticket (and the ticket subprotocol carrying it) is a credential: it never appears in a description or log.
public struct GatewayAttachResult: Sendable, Decodable, CustomStringConvertible {
    public struct Endpoint: Sendable, Decodable, Equatable {
        public let apiOrigin: String?
        public let authorityEpoch: Int?
        public let capabilities: [String]?
        public let codeSha: String?
        public let instanceId: String?
        public let profileId: String?
        public let runtimeProtocol: Int?
        public let supervisor: String?

        enum CodingKeys: String, CodingKey {
            case apiOrigin = "api_origin", authorityEpoch = "authority_epoch", capabilities
            case codeSha = "code_sha", instanceId = "instance_id", profileId = "profile_id"
            case runtimeProtocol = "runtime_protocol", supervisor
        }
    }

    public let state: String
    public let url: String?
    public let `protocol`: String?
    /// WebSocket subprotocols to offer: the wire name and the ticket. Secret.
    public let protocols: [String]?
    public let endpoint: Endpoint?
    public let reasonCode: String?
    public let detail: String?

    enum CodingKeys: String, CodingKey {
        case state, url, `protocol`, protocols, endpoint
        case reasonCode = "reason_code", detail
    }

    public var isReady: Bool { state == "ready" && url != nil && protocols?.isEmpty == false }

    public var description: String {
        "attach(state: \(state), url: \(url ?? "—"), protocol: \(`protocol` ?? "—"), reason: \(reasonCode ?? "—"))"
    }
}

public enum GatewayAttach {
    public enum Failure: Error, CustomStringConvertible {
        case noOutput(status: Int32, stderr: String)
        public var description: String {
            switch self {
            case .noOutput(let status, let stderr): "attach exit \(status): \(stderr.prefix(300))"
            }
        }
    }

    /// `--recover`: the gateway is Vera's own (clean root), so she starts it when none serves the root, or replaces
    /// one an older Hermes left; it exits on its own once idle. Always runs under the root's environment.
    public static func attach(_ runtime: HermesRuntime, timeout: Int = 60) async throws -> GatewayAttachResult {
        let out = try await ProcessRunner.run(runtime.binary, ["gateway", "attach", "--json", "--recover", "--timeout", "\(timeout)"],
                                              environment: runtime.environment)
        guard let start = out.stdout.firstIndex(of: UInt8(ascii: "{")) else {
            throw Failure.noOutput(status: out.status, stderr: String(decoding: out.stderr, as: UTF8.self))
        }
        return try decode(out.stdout[start...])
    }

    public static func decode(_ data: Data) throws -> GatewayAttachResult {
        try JSONDecoder().decode(GatewayAttachResult.self, from: data)
    }
}
