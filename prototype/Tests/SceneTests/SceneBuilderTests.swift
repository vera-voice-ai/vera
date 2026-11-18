import Foundation
import Testing
import Scene
import SignalBus

private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let utteranceID = "utterance/s1-seg1"

private func at(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }

private func msg(
    _ type: String,
    at offset: TimeInterval = 0,
    subject: String? = nil,
    revision: UInt64? = nil,
    correlation: String? = nil,
    payload: [String: String] = [:]
) -> SignalMessage {
    SignalMessage(
        kind: .event,
        domain: .sensors,
        source: "test",
        type: type,
        timestamp: at(offset),
        subjectID: subject,
        revision: revision,
        correlationID: correlation,
        payload: payload
    )
}

private func transcript(_ type: String, at offset: TimeInterval, revision: UInt64, text: String) -> SignalMessage {
    msg(type, at: offset, subject: utteranceID, revision: revision, payload: ["lane": "raw", "text": text])
}

/// Feeds messages into a builder and keeps the latest emitted content, so assertions can
/// read the scene even after calls that returned nil because nothing changed.
/// `content` is nil until the first snapshot (SceneContent has no public initializer).
private struct Replay {
    var builder = SceneBuilder()
    var content: SceneContent?

    /// Returns true when the message produced a new snapshot.
    @discardableResult
    mutating func ingest(_ message: SignalMessage) -> Bool {
        guard let snapshot = builder.ingest(message) else { return false }
        content = snapshot.content
        return true
    }

    mutating func tick(_ offset: TimeInterval) {
        guard let snapshot = builder.tick(now: at(offset)) else { return }
        content = snapshot.content
    }
}

// MARK: - Utterance lifecycle

@Test func utteranceTextEvolvesThenEndsAndKeepsFinalText() {
    var scene = Replay()
    scene.ingest(msg("audio.microphone.started", at: 0))
    scene.ingest(msg("speech.segment.started", at: 1, subject: utteranceID))
    #expect(scene.content?.active?.id == utteranceID)
    #expect(scene.content?.active?.text == "")

    scene.ingest(transcript("speech.transcript.partial", at: 1.5, revision: 1, text: "при"))
    #expect(scene.content?.active?.text == "при")
    #expect(scene.content?.active?.textIsFinal == false)

    scene.ingest(transcript("speech.transcript.partial", at: 2, revision: 2, text: "привет"))
    #expect(scene.content?.active?.text == "привет")
    #expect(scene.content?.active?.textRevision == 2)

    scene.ingest(msg("speech.segment.ended", at: 3, subject: utteranceID, payload: ["reason": "silence"]))
    #expect(scene.content?.active == nil)
    #expect(scene.content?.recent.count == 1)
    #expect(scene.content?.recent.first?.state == SceneUtterance.State.ended(reason: "silence"))
    #expect(scene.content?.recent.first?.text == "привет")

    scene.ingest(transcript("speech.transcript.final", at: 3.5, revision: 3, text: "привет мир"))
    #expect(scene.content?.recent.first?.text == "привет мир")
    #expect(scene.content?.recent.first?.textIsFinal == true)
    #expect(scene.content?.recent.first?.textRevision == 3)
}

// MARK: - Stale and out-of-order transcripts

@Test func lateLowerRevisionAndPostFinalTranscriptsDoNotOverwriteText() {
    var scene = Replay()
    scene.ingest(msg("speech.segment.started", at: 0, subject: utteranceID))
    scene.ingest(transcript("speech.transcript.partial", at: 1, revision: 2, text: "привет"))

    let late = scene.ingest(transcript("speech.transcript.partial", at: 1.2, revision: 1, text: "при"))
    #expect(late == false)
    #expect(scene.content?.active?.text == "привет")
    #expect(scene.content?.active?.textRevision == 2)

    scene.ingest(transcript("speech.transcript.final", at: 2, revision: 3, text: "привет мир"))
    #expect(scene.content?.active?.textIsFinal == true)

    let partialAfterFinal = scene.ingest(transcript("speech.transcript.partial", at: 2.5, revision: 4, text: "другое"))
    #expect(partialAfterFinal == false)
    #expect(scene.content?.active?.text == "привет мир")

    let finalAfterFinal = scene.ingest(transcript("speech.transcript.final", at: 2.6, revision: 5, text: "другое"))
    #expect(finalAfterFinal == false)
    #expect(scene.content?.active?.text == "привет мир")
    #expect(scene.content?.active?.textRevision == 3)
}

// MARK: - Decay

@Test func finishedUtteranceLeavesRecentAfterThirtySeconds() {
    var scene = Replay()
    scene.ingest(msg("speech.segment.started", at: 0, subject: utteranceID))
    scene.ingest(msg("speech.segment.ended", at: 5, subject: utteranceID, payload: ["reason": "silence"]))

    // Ended at +5 s, so +34 s is 29 s later and +36 s is 31 s later.
    scene.tick(34)
    #expect(scene.content?.recent.map(\.id) == [utteranceID])

    scene.tick(36)
    #expect(scene.content?.recent.isEmpty == true)
}

@Test func audioLevelDecaysToNilSound() {
    var scene = Replay()
    scene.ingest(msg("audio.input.observed", at: 0, payload: ["rms": "0.05"]))
    #expect(scene.content?.sound == .sound)

    scene.tick(1)
    #expect(scene.content?.sound == .sound)

    scene.tick(2)
    #expect(scene.content?.sound == nil)
}

@Test func ownerScoresDecayToUnknown() {
    var scene = Replay()
    scene.ingest(msg("speaker.target.activity.scored", at: 0, payload: ["probability": "0.9"]))
    #expect(scene.content?.owner == .likely)
    #expect(scene.content?.ownerMean == 0.9)

    scene.tick(1.5)
    #expect(scene.content?.owner == .unknown)
    #expect(scene.content?.ownerMean == nil)
}

// MARK: - Determinism

@Test func identicalMessageStreamsReplayToIdenticalContents() {
    let messages: [SignalMessage] = [
        msg("audio.microphone.started", at: 0),
        msg("audio.input.observed", at: 0.2, payload: ["rms": "0.05"]),
        msg("speech.segment.started", at: 0.5, subject: utteranceID),
        transcript("speech.transcript.partial", at: 1, revision: 1, text: "при"),
        transcript("speech.transcript.partial", at: 1.5, revision: 2, text: "привет"),
        msg("speaker.live.similarity.computed", at: 1.6, correlation: utteranceID,
            payload: ["reference": "alex", "cosine_similarity": "0.8", "margin": "0.1"]),
        msg("speech.segment.ended", at: 2, subject: utteranceID, payload: ["reason": "silence"]),
        transcript("speech.transcript.final", at: 2.5, revision: 3, text: "привет мир"),
        msg("speaker.target.activity.scored", at: 2.6, payload: ["probability": "0.9"]),
        msg("audio.input.observed", at: 3, payload: ["rms": "0.001"]),
        msg("audio.microphone.stopped", at: 4)
    ]

    func run() -> (contents: [SceneContent], revisions: [UInt64]) {
        var builder = SceneBuilder()
        var contents: [SceneContent] = []
        var revisions: [UInt64] = []
        for message in messages {
            if let snapshot = builder.ingest(message) {
                contents.append(snapshot.content)
                revisions.append(snapshot.revision)
            }
        }
        for offset in [10.0, 40.0] {
            if let snapshot = builder.tick(now: at(offset)) {
                contents.append(snapshot.content)
                revisions.append(snapshot.revision)
            }
        }
        return (contents, revisions)
    }

    let first = run()
    let second = run()
    #expect(!first.contents.isEmpty)
    #expect(first.contents == second.contents)
    #expect(first.revisions == (0..<first.revisions.count).map { UInt64($0 + 1) })
    #expect(second.revisions == first.revisions)
}

// MARK: - Microphone stop

@Test func microphoneStopClosesActiveUtteranceAndClearsSoundAndOwner() {
    var scene = Replay()
    scene.ingest(msg("audio.microphone.started", at: 0))
    scene.ingest(msg("speech.segment.started", at: 1, subject: utteranceID))
    scene.ingest(transcript("speech.transcript.partial", at: 1.5, revision: 1, text: "при"))
    scene.ingest(msg("audio.input.observed", at: 2, payload: ["rms": "0.05"]))
    scene.ingest(msg("speaker.target.activity.scored", at: 2, payload: ["probability": "0.9"]))
    #expect(scene.content?.sound == .sound)
    #expect(scene.content?.owner == .likely)

    scene.ingest(msg("audio.microphone.stopped", at: 3))
    #expect(scene.content?.microphoneOn == false)
    #expect(scene.content?.active == nil)
    #expect(scene.content?.recent.count == 1)
    #expect(scene.content?.recent.first?.state == SceneUtterance.State.ended(reason: "microphone_stopped"))
    #expect(scene.content?.sound == nil)
    #expect(scene.content?.owner == .unknown)
    #expect(scene.content?.ownerMean == nil)
}

// MARK: - Change-only emission

@Test func identicalAudioLevelReturnsNilTheSecondTime() {
    var builder = SceneBuilder()
    let first = builder.ingest(msg("audio.input.observed", at: 0, payload: ["rms": "0.05"]))
    #expect(first != nil)

    let second = builder.ingest(msg("audio.input.observed", at: 0, payload: ["rms": "0.05"]))
    #expect(second == nil)
}
