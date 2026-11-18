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
    public let subjectID: String?
    public let revision: UInt64?
    public let correlationID: String?
    public let causationID: String?
    public let payload: [String: String]

    public init(kind: SignalKind = .event, domain: SignalDomain = .sensors,
                source: String, target: String? = nil, type: String,
                timestamp: Date = .now, subjectID: String? = nil,
                revision: UInt64? = nil, correlationID: String? = nil, causationID: String? = nil,
                payload: [String: String] = [:]) {
        self.id = UUID()
        self.kind = kind
        self.domain = domain
        self.source = source
        self.target = target
        self.type = type
        self.timestamp = timestamp
        self.subjectID = subjectID
        self.revision = revision
        self.correlationID = correlationID
        self.causationID = causationID
        self.payload = payload
    }
}
