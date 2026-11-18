import Foundation

public enum SignalKind: String, Codable, Sendable, CaseIterable {
    case event, command, query, reply
}

public enum SignalDomain: String, Codable, Sendable, CaseIterable {
    case sensors, scene, core, response
}

public struct SignalMessage: Identifiable, Codable, Sendable {
    public let id: UUID
    public let kind: SignalKind
    public let domain: SignalDomain
    public let source: String
    public let target: String?
    public let type: String
    public let timestamp: Date
    public let payload: [String: String]

    public init(kind: SignalKind = .event, domain: SignalDomain = .sensors,
                source: String, target: String? = nil, type: String,
                timestamp: Date = .now, payload: [String: String] = [:]) {
        self.id = UUID()
        self.kind = kind
        self.domain = domain
        self.source = source
        self.target = target
        self.type = type
        self.timestamp = timestamp
        self.payload = payload
    }
}
