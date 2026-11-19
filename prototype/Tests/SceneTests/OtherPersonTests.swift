import Foundation
import Testing
import Scene
import SignalBus

private let otherBase = Date(timeIntervalSinceReferenceDate: 805_000_000)
private func moment(_ offset: TimeInterval) -> Date { otherBase.addingTimeInterval(offset) }

private func event(_ type: String, _ offset: TimeInterval, subject: String? = nil, correlation: String? = nil,
                   revision: UInt64? = nil, payload: [String: String] = [:]) -> SignalMessage {
    SignalMessage(kind: .event, domain: .sensors, source: "test", type: type, timestamp: moment(offset),
                  subjectID: subject, revision: revision, correlationID: correlation, payload: payload)
}

private func voice(_ utterance: String, person: String, label: String, role: String, _ offset: TimeInterval) -> SignalMessage {
    event("speaker.live.similarity.computed", offset, correlation: utterance, payload: [
        "reference": label, "person_id": person, "participant_role": role, "cosine_similarity": "0.8", "margin": "0.3"])
}

@Test func aGuestSpeakingToHerIsNotHandedOverEvenWhenTheOwnerWasHeardAMomentAgo() {
    var builder = SceneBuilder(ttl: .app)
    var decisions: [SceneTurn] = []
    func feed(_ message: SignalMessage) { if let snapshot = builder.ingest(message) { decisions += snapshot.decisions } }
    // The owner speaks first (two agreeing windows, then final text).
    feed(event("speech.segment.started", 0, subject: "u1"))
    feed(voice("u1", person: "p0", label: "Алексей", role: "owner", 1))
    feed(voice("u1", person: "p0", label: "Алексей", role: "owner", 2))
    feed(event("speech.transcript.final", 2.5, subject: "u1", revision: 1, payload: ["lane": "raw", "text": "Вера, привет"]))
    feed(event("speech.segment.ended", 3, subject: "u1", payload: ["reason": "silence"]))
    // Ten seconds later a guest, recognised as another person, asks her something by name.
    feed(event("speech.segment.started", 14, subject: "u2"))
    feed(voice("u2", person: "p1", label: "Валера", role: "human", 15))
    feed(voice("u2", person: "p1", label: "Валера", role: "human", 16))
    feed(event("speech.transcript.final", 16.5, subject: "u2", revision: 1, payload: ["lane": "raw", "text": "Вера, как дела"]))
    feed(event("speech.segment.ended", 17, subject: "u2", payload: ["reason": "silence"]))
    for second in stride(from: 18.0, through: 30.0, by: 0.5) { if let snapshot = builder.tick(now: moment(second)) { decisions += snapshot.decisions } }
    let guest = decisions.first { $0.text.contains("как дела") }
    #expect(guest?.heardReason == "other_person")
    #expect(guest?.readyBasis == nil)
}

private func ownerSpeaks(_ feed: (SignalMessage) -> Void, utterance: String, from start: TimeInterval, text: String) {
    feed(event("speech.segment.started", start, subject: utterance))
    feed(voice(utterance, person: "p0", label: "Алексей", role: "owner", start + 1))
    feed(voice(utterance, person: "p0", label: "Алексей", role: "owner", start + 2))
    feed(event("speech.transcript.final", start + 2.5, subject: utterance, revision: 1, payload: ["lane": "raw", "text": text]))
    feed(event("speech.segment.ended", start + 3, subject: utterance, payload: ["reason": "silence"]))
}

private func verdictMessage(_ turn: String, _ choice: String, _ confidence: Double, at offset: TimeInterval) -> SignalMessage {
    SignalMessage(kind: .reply, domain: .scene, source: "judge", type: "scene.turn.verdict", timestamp: moment(offset),
                  payload: ["turn_id": turn, "turn_revision": "1", "choice": choice, "confidence": String(confidence)])
}

/// Returns the second (after the speech ended at 3 s) at which the turn was handed over, or nil.
private func handoverSecond(confidence: Double) -> Double? {
    var builder = SceneBuilder(ttl: .app)
    var handedOver: Double?
    func collect(_ snapshot: SceneSnapshot?, _ second: Double) { if handedOver == nil, snapshot?.decisions.contains(where: { $0.readyBasis != nil }) == true { handedOver = second } }
    ownerSpeaks({ collect(builder.ingest($0), 0) }, utterance: "u1", from: 0, text: "Вера, мне нужно чтобы ты")
    collect(builder.ingest(verdictMessage("turn/1", "continue", confidence, at: 4)), 4)
    for second in stride(from: 4.0, through: 14.0, by: 0.5) { collect(builder.tick(now: moment(second)), second) }
    return handedOver
}

@Test func aConfidentContinueKeepsTheTurnOpenLongerThanAWeakOne() {
    let confident = handoverSecond(confidence: 0.95)
    let weak = handoverSecond(confidence: 0.6)
    #expect(weak != nil && weak! <= 7.5)                    // 3 s of silence after the end at 3 s, as before
    #expect(confident != nil && confident! >= 10.5)         // the fast brain was sure: waits up to 8 s of silence
}

@Test func aContinuationRightAfterTheHandoverIsCountedAsPremature() {
    var builder = SceneBuilder(ttl: .app)
    var premature = 0
    var turnID: String?
    func feed(_ message: SignalMessage) { if let snapshot = builder.ingest(message) { premature = snapshot.content.prematureHandovers; turnID = snapshot.content.lastPrematureTurnID ?? turnID } }
    ownerSpeaks(feed, utterance: "u1", from: 0, text: "Вера, открой браузер")
    feed(verdictMessage("turn/1", "complete", 0.9, at: 4))
    for second in stride(from: 4.0, through: 6.0, by: 0.5) { if let snapshot = builder.tick(now: moment(second)) { premature = snapshot.content.prematureHandovers } }
    feed(event("speech.segment.started", 7.5, subject: "u2"))         // he goes on a moment after it was handed over
    #expect(premature == 1 && turnID == "turn/1")
    feed(event("speech.segment.started", 30, subject: "u3"))          // much later: a new request, not a continuation
    #expect(premature == 1)
}
