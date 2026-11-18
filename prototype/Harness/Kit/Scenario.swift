import Foundation
import SignalBus

/// A replayable input: the messages of one recording or one corpus episode, sorted by time.
/// Recordings and corpus hold private speech. Nothing in HarnessKit prints or stores message text.
public struct Scenario: Sendable {
    public let name: String
    public let messages: [SignalMessage]
    /// Recording lines that could not be decoded. Counted, never printed.
    public let skippedLines: Int

    public init(name: String, messages: [SignalMessage], skippedLines: Int = 0) {
        self.name = name
        self.messages = messages.enumerated()
            .sorted { ($0.element.timestamp, $0.offset) < ($1.element.timestamp, $1.offset) }
            .map(\.element)
        self.skippedLines = skippedLines
    }

    public var hasVerdicts: Bool { messages.contains { $0.type == "scene.turn.verdict" } }

    public var durationSeconds: Double {
        guard let first = messages.first, let last = messages.last else { return 0 }
        return last.timestamp.timeIntervalSince(first.timestamp)
    }

    /// Loads a bus recording: JSON Lines of `SignalMessage` with millisecond dates.
    public static func load(recording url: URL) throws -> Scenario {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var messages: [SignalMessage] = []
        var skipped = 0
        for line in try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            if let message = try? decoder.decode(SignalMessage.self, from: Data(line)) {
                messages.append(message)
            } else {
                skipped += 1
            }
        }
        let name = url.deletingPathExtension().lastPathComponent
        return Scenario(name: name, messages: messages, skippedLines: skipped)
    }

    /// Loads Vera 1 corpus episodes (v1-episodes.jsonl), one scenario per episode. Each segment becomes
    /// segment started/ended plus a final raw transcript, as in the corpus replay test. No speaker information.
    public static func fromCorpus(url: URL) throws -> [Scenario] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var scenarios: [Scenario] = []
        for line in try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let episode = try? decoder.decode(CorpusEpisode.self, from: Data(line)) else { continue }
            scenarios.append(Scenario(name: episode.episodeId, messages: corpusMessages(episode.segments)))
        }
        return scenarios
    }

    private static func corpusMessages(_ segments: [CorpusSegment]) -> [SignalMessage] {
        var messages: [SignalMessage] = []
        for segment in segments {
            guard let finalAt = parseCaptured(segment.capturedAt) else { continue }
            let end = finalAt.addingTimeInterval(-0.8)
            let start = end.addingTimeInterval(-segment.durationS)
            let subject = "utterance/s1-seg\(segment.idx)"
            messages.append(SignalMessage(source: "corpus", type: "speech.segment.started", timestamp: start, subjectID: subject))
            messages.append(SignalMessage(source: "corpus", type: "speech.segment.ended", timestamp: end, subjectID: subject,
                                          payload: ["reason": "silence"]))
            messages.append(SignalMessage(source: "corpus", type: "speech.transcript.final", timestamp: finalAt, subjectID: subject,
                                          revision: 1, payload: ["lane": "raw", "text": segment.text]))
        }
        return messages
    }

    private static func parseCaptured(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

private struct CorpusSegment: Decodable {
    let idx: Int
    let capturedAt: String
    let durationS: Double
    let text: String
}

private struct CorpusEpisode: Decodable {
    let episodeId: String
    let segments: [CorpusSegment]
}
