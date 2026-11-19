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
