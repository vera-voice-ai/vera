import Foundation
import Observation
import SignalBus

/// The receiving end of the scene, nothing more: it subscribes to the bus, keeps what the scene hands over,
/// and can ask the scene for its current picture (query `scene.snapshot.get`, reply `scene.snapshot`).
/// It decides nothing; Core's own logic will read from here.
@MainActor
@Observable
public final class CoreInbox {
    public struct Received: Identifiable, Sendable {
        public let id = UUID()
        public let at: Date
        /// `scene.turn.ready` (handed over for action) or `scene.turn.heard` (context only).
        public let type: String
        public let turnID: String
        public let text: String
        public let speaker: String
        public let addressed: String
        /// `basis` for ready turns, `reason` for heard ones.
        public let why: String
        /// Loudness of the turn, ready to show: "−31 дБFS · +9 над фоном · обычно"; empty when it was not measured.
        public let loudness: String
        public var isReady: Bool { type == "scene.turn.ready" }
    }

    public struct SceneReply: Sendable {
        public let at: Date
        public let revision: String
        public let status: String
        public let participants: String
        public let turns: String
        public let roundTripMilliseconds: Int
    }

    /// Newest first, the last 50.
    public private(set) var received: [Received] = []
    public private(set) var readyCount = 0
    public private(set) var heardCount = 0
    public private(set) var lastReply: SceneReply?
    public private(set) var isSubscribed = false

    private var pending: [String: ContinuousClock.Instant] = [:]

    public init() {}

    public func consume(_ bus: SignalBus) async {
        let stream = await bus.subscribe()
        isSubscribed = true
        for await message in stream {
            if message.kind == .reply, message.type == "scene.snapshot", let id = message.correlationID,
               let started = pending.removeValue(forKey: id) {
                let elapsed = started.duration(to: .now)
                lastReply = SceneReply(at: .now, revision: message.payload["revision"] ?? "",
                                       status: message.payload["status"] ?? "",
                                       participants: message.payload["participants"] ?? "",
                                       turns: message.payload["turn_count"] ?? "",
                                       roundTripMilliseconds: Int(elapsed.components.seconds * 1_000
                                                                  + elapsed.components.attoseconds / 1_000_000_000_000_000))
                continue
            }
            guard message.domain == .scene, message.kind == .event,
                  message.type == "scene.turn.ready" || message.type == "scene.turn.heard" else { continue }
            let ready = message.type == "scene.turn.ready"
            if ready { readyCount += 1 } else { heardCount += 1 }
            received.insert(Received(at: message.timestamp, type: message.type, turnID: message.payload["turn_id"] ?? "",
                                     text: message.payload["text"] ?? "", speaker: message.payload["speaker"] ?? "",
                                     addressed: message.payload["addressed"] ?? "",
                                     why: message.payload[ready ? "basis" : "reason"] ?? "",
                                     loudness: Self.loudnessText(message.payload)), at: 0)
            if received.count > 50 { received.removeLast(received.count - 50) }
            await askForSnapshot(bus)
        }
    }

    static func loudnessText(_ payload: [String: String]) -> String {
        guard let db = payload["loudness_db"], let value = Double(db) else { return "" }
        var parts = [String(format: "%.0f дБFS", value)]
        if let above = payload["loudness_above_floor_db"], let delta = Double(above) { parts.append(String(format: "%+.0f над фоном", delta)) }
        if let relative = payload["loudness_relative"], !relative.isEmpty { parts.append(relative) }
        return parts.joined(separator: " · ")
    }

    /// Asks the scene for its current picture; the answer arrives on the bus and lands in `lastReply`.
    public func askForSnapshot(_ bus: SignalBus) async {
        let query = SignalMessage(kind: .query, domain: .core, source: "Core.Inbox", target: "Scene",
                                  type: "scene.snapshot.get")
        pending[query.id.uuidString] = .now
        await bus.publish(query)
    }
}
