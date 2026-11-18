import Foundation
import Observation
import SignalBus

@MainActor
@Observable
public final class SceneModel {
    public private(set) var messages: [SignalMessage] = []
    public private(set) var latestEmbedding: [Float]?
    public var selectedMessageID: UUID?

    public init() {}

    public var selectedMessage: SignalMessage? {
        guard let selectedMessageID else { return messages.first }
        return messages.first(where: { $0.id == selectedMessageID }) ?? messages.first
    }

    public var latestTranscript: SignalMessage? {
        messages.first(where: { $0.type == "speech.transcript.final" && $0.payload["lane"] == "raw" })
    }

    public var recentSpeakerSimilarities: [SignalMessage] {
        let runID = latestEmbeddingRunID
        return messages.filter { $0.type == "speaker.reference.similarity.computed" && $0.payload["run_id"] == runID }
    }

    public func consume(_ bus: SignalBus) async {
        let stream = await bus.subscribe()
        for await message in stream {
            guard message.domain == .sensors else { continue }
            messages.insert(message, at: 0)
            if messages.count > 600 { messages.removeLast(messages.count - 600) }
            if message.type == "speaker.embedding.extracted",
               let json = message.payload["embedding_json"],
               let data = json.data(using: .utf8),
               let values = try? JSONDecoder().decode([Float].self, from: data) {
                latestEmbedding = values
            }
        }
    }

    private var latestEmbeddingRunID: String? {
        messages.first(where: { $0.type == "speaker.embedding.extracted" })?.payload["run_id"]
    }
}
