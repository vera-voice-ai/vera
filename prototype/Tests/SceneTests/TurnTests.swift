import Foundation
import Testing
import Scene
import SignalBus

private let turnBase = Date(timeIntervalSinceReferenceDate: 810_000_000)

private func turnTime(_ seconds: Double) -> Date { turnBase.addingTimeInterval(seconds) }

private func utteranceID(_ n: Int) -> String { "utterance/s1-seg\(n)" }

private func micStarted(at seconds: Double) -> SignalMessage {
    SignalMessage(kind: .event, domain: .sensors, source: "test", type: "audio.microphone.started",
                  timestamp: turnTime(seconds))
}

private func segmentStarted(_ n: Int, at seconds: Double) -> SignalMessage {
    SignalMessage(kind: .event, domain: .sensors, source: "test", type: "speech.segment.started",
                  timestamp: turnTime(seconds), subjectID: utteranceID(n))
}

private func segmentEnded(_ n: Int, at seconds: Double) -> SignalMessage {
    SignalMessage(kind: .event, domain: .sensors, source: "test", type: "speech.segment.ended",
                  timestamp: turnTime(seconds), subjectID: utteranceID(n), payload: ["reason": "silence"])
}

private func finalText(_ n: Int, at seconds: Double, _ text: String) -> SignalMessage {
    SignalMessage(kind: .event, domain: .sensors, source: "test", type: "speech.transcript.final",
                  timestamp: turnTime(seconds), subjectID: utteranceID(n), revision: 1,
                  payload: ["lane": "raw", "text": text])
}

/// The judge's answer about one turn. `revision` is the text revision the judge saw.
private func verdict(_ turnID: String, revision: Int, _ choice: String, at seconds: Double) -> SignalMessage {
    SignalMessage(kind: .reply, domain: .scene, source: "judge", type: "scene.turn.verdict",
                  timestamp: turnTime(seconds), payload: [
                      "turn_id": turnID,
                      "turn_revision": String(revision),
                      "choice": choice,
                      "confidence": "0.9"
                  ])
}

/// Feeds messages into a builder and keeps the latest picture and every decision it made.
private struct TurnScene {
    var builder = SceneBuilder()
    var content = SceneContent()
    var decisions: [SceneTurn] = []

    mutating func feed(_ message: SignalMessage) {
        guard let snapshot = builder.ingest(message) else { return }
        content = snapshot.content
        decisions += snapshot.decisions
    }

    mutating func tick(at seconds: Double) {
        guard let snapshot = builder.tick(now: turnTime(seconds)) else { return }
        content = snapshot.content
        decisions += snapshot.decisions
    }

    /// The turn that currently holds the given utterance.
    func turn(_ n: Int) -> SceneTurn? {
        content.turns.first { $0.utteranceIDs.contains(utteranceID(n)) }
    }

    var states: [SceneTurn.State] { decisions.map(\.state) }
}

/// One utterance that ends at 2 s with final text at 2.5 s.
private func singleUtterance(_ text: String) -> TurnScene {
    var scene = TurnScene()
    scene.feed(segmentStarted(1, at: 0))
    scene.feed(segmentEnded(1, at: 2))
    scene.feed(finalText(1, at: 2.5, text))
    return scene
}

/// A turn "Вера, привет" that the judge completed at 2.6 s, so it was handed to Core.
private func sceneAfterHandover() throws -> TurnScene {
    var scene = singleUtterance("Вера, привет")
    let id = try #require(scene.turn(1)).id
    scene.feed(verdict(id, revision: 1, "complete", at: 2.6))
    return scene
}

// MARK: - Wake word and judge

@Test func wakeWordTurnWaitsForJudgeThenIsHandedOver() throws {
    var scene = singleUtterance("Вера, включи свет")

    let turn = try #require(scene.turn(1))
    #expect(turn.addressed == .likely)
    #expect(turn.needsVerdict == true)
    #expect(turn.text == "Вера, включи свет")
    #expect(scene.decisions.isEmpty)

    scene.feed(verdict(turn.id, revision: 1, "complete", at: 3.6))
    #expect(scene.states == [.ready(basis: "jev")])
    #expect(scene.decisions.first?.id == turn.id)
    #expect(scene.decisions.first?.text == "Вера, включи свет")
    #expect(scene.turn(1)?.needsVerdict == false)
}

@Test func silentJudgeHandsOverAfterVerdictTimeout() throws {
    var scene = singleUtterance("Вера, включи свет")
    #expect(try #require(scene.turn(1)).needsVerdict == true)

    scene.tick(at: 2.5 + 2.9)
    #expect(scene.decisions.isEmpty)
    #expect(try #require(scene.turn(1)).needsVerdict == true)

    scene.tick(at: 2.5 + 3.1)
    #expect(scene.states == [.ready(basis: "no_verdict")])
}

@Test func utteranceWithoutWakeWordIsHeardNotAddressed() throws {
    let scene = singleUtterance("ну и погода сегодня")

    let turn = try #require(scene.turn(1))
    #expect(turn.addressed == .unlikely)
    #expect(turn.needsVerdict == false)
    #expect(turn.verdict == nil)
    #expect(scene.states == [.heard(reason: "not_addressed")])
}

// MARK: - Noise

@Test func fillerPhraseAndSingleLetterAreNoise() throws {
    for text in ["Продолжение следует...", "а"] {
        let scene = singleUtterance(text)
        let turn = try #require(scene.turn(1))
        #expect(turn.needsVerdict == false, "text: \(text)")
        #expect(scene.states == [.heard(reason: "noise")], "text: \(text)")
    }
}

// MARK: - Merging

@Test func followUpBySameSpeakerMergesIntoOneTurnAndInvalidatesOldVerdict() throws {
    var scene = singleUtterance("Вера, слушай")
    let id = try #require(scene.turn(1)).id
    scene.feed(verdict(id, revision: 1, "continue", at: 2.6))
    #expect(scene.decisions.isEmpty)
    #expect(scene.turn(1)?.needsVerdict == false)

    // Second utterance starts 3 s after the first one ended, within the 8 s merge window.
    scene.feed(segmentStarted(2, at: 5))
    scene.feed(segmentEnded(2, at: 7))
    scene.feed(finalText(2, at: 7.5, "включи свет"))

    let merged = try #require(scene.turn(2))
    #expect(merged.id == id)
    #expect(merged.utteranceIDs == [utteranceID(1), utteranceID(2)])
    #expect(merged.text == "Вера, слушай включи свет")
    #expect(merged.textRevision == 2)
    #expect(merged.addressed == .likely)
    #expect(merged.needsVerdict == true)
    #expect(scene.decisions.isEmpty)

    // A verdict for the older text is ignored.
    scene.feed(verdict(id, revision: 1, "complete", at: 7.6))
    #expect(scene.decisions.isEmpty)
    #expect(scene.turn(2)?.needsVerdict == true)

    // A verdict for the current text gives one decision for the whole merged turn.
    scene.feed(verdict(id, revision: 2, "complete", at: 7.7))
    #expect(scene.states == [.ready(basis: "jev")])
    #expect(scene.decisions.first?.utteranceIDs == [utteranceID(1), utteranceID(2)])
    #expect(scene.decisions.first?.text == "Вера, слушай включи свет")
}

@Test func nineSecondGapStartsSeparateTurn() throws {
    var scene = singleUtterance("Вера, слушай")
    scene.feed(segmentStarted(2, at: 11))
    scene.feed(segmentEnded(2, at: 13))
    scene.feed(finalText(2, at: 13.5, "Вера, включи свет"))

    let first = try #require(scene.turn(1))
    let second = try #require(scene.turn(2))
    #expect(first.id != second.id)
    #expect(first.utteranceIDs == [utteranceID(1)])
    #expect(second.utteranceIDs == [utteranceID(2)])
    #expect(second.text == "Вера, включи свет")
    #expect(second.textRevision == 1)
    // The first turn had no verdict and its 3 s wait ran out by the time the next utterance started.
    #expect(first.state == .ready(basis: "no_verdict"))
}

// MARK: - Hold

@Test func continueVerdictHoldsTurnUntilHoldExpires() throws {
    var scene = singleUtterance("Вера, слушай")
    let id = try #require(scene.turn(1)).id
    scene.feed(verdict(id, revision: 1, "continue", at: 2.6))

    scene.tick(at: 2 + 7.9)
    #expect(scene.decisions.isEmpty)

    scene.tick(at: 2 + 8.1)
    #expect(scene.states == [.ready(basis: "hold_expired")])
}

// MARK: - Engaged conversation

@Test func followUpShortlyAfterHandoverIsPossiblyAddressed() throws {
    var scene = try sceneAfterHandover()
    #expect(scene.states == [.ready(basis: "jev")])

    // Starts 10 s after the handover, no wake word.
    scene.feed(segmentStarted(2, at: 12.6))
    scene.feed(segmentEnded(2, at: 13.6))
    scene.feed(finalText(2, at: 14.1, "а что у тебя нового"))

    let turn = try #require(scene.turn(2))
    #expect(turn.addressed == .possible)
    #expect(turn.needsVerdict == true)
    #expect(turn.isAwaiting)
    #expect(scene.decisions.count == 1)
}

@Test func sameTextSixtySecondsAfterHandoverIsNotAddressed() throws {
    var scene = try sceneAfterHandover()

    // Starts 60 s after the handover, beyond the 45 s engaged window.
    scene.feed(segmentStarted(2, at: 62.6))
    scene.feed(segmentEnded(2, at: 63.6))
    scene.feed(finalText(2, at: 64.1, "а что у тебя нового"))

    let turn = try #require(scene.turn(2))
    #expect(turn.addressed == .unlikely)
    #expect(scene.states == [.ready(basis: "jev"), .heard(reason: "not_addressed")])
}

// MARK: - Status

@Test func statusFollowsSpeechJudgeAndFlashes() throws {
    var scene = TurnScene()
    scene.feed(micStarted(at: 0))
    #expect(scene.content.status == .idle)

    scene.feed(segmentStarted(1, at: 1))
    #expect(scene.content.status == .listening)

    scene.feed(segmentEnded(1, at: 2))
    #expect(scene.content.status == .forming)

    scene.feed(finalText(1, at: 2.5, "Вера, включи свет"))
    #expect(scene.content.status == .forming)

    let id = try #require(scene.turn(1)).id
    scene.feed(verdict(id, revision: 1, "complete", at: 2.6))
    #expect(scene.content.status == .handedOver)

    scene.tick(at: 5.5)
    #expect(scene.content.status == .handedOver)

    scene.tick(at: 5.7)
    #expect(scene.content.status == .idle)
}

@Test func notAddressedStatusIsBackgroundThenIdle() {
    var scene = singleUtterance("ну и погода сегодня")
    #expect(scene.content.status == .background)

    scene.tick(at: 2.5 + 3.1)
    #expect(scene.content.status == .idle)
}

// MARK: - Missing text

@Test func utteranceWithoutFinalTextIsDroppedAsNoText() {
    var scene = TurnScene()
    scene.feed(segmentStarted(1, at: 0))
    scene.feed(segmentEnded(1, at: 2))

    scene.tick(at: 2 + 5.9)
    #expect(scene.decisions.isEmpty)

    scene.tick(at: 2 + 6.1)
    #expect(scene.states == [.heard(reason: "no_text")])
}

// MARK: - Determinism

private struct TurnRecord: Equatable {
    let id: String
    let state: SceneTurn.State
    let text: String
}

private func records(_ turns: [SceneTurn]) -> [TurnRecord] {
    turns.map { TurnRecord(id: $0.id, state: $0.state, text: $0.text) }
}

@Test func identicalMessageStreamsGiveIdenticalTurnsAndDecisions() {
    let messages: [SignalMessage] = [
        micStarted(at: 0),
        segmentStarted(1, at: 0.5),
        segmentEnded(1, at: 2),
        finalText(1, at: 2.5, "Вера, слушай"),
        verdict("turn/1", revision: 1, "continue", at: 2.6),
        segmentStarted(2, at: 5),
        segmentEnded(2, at: 7),
        finalText(2, at: 7.5, "включи свет"),
        verdict("turn/1", revision: 2, "complete", at: 7.7),
        segmentStarted(3, at: 20),
        segmentEnded(3, at: 22),
        finalText(3, at: 22.5, "ну и погода сегодня")
    ]

    func run() -> TurnScene {
        var scene = TurnScene()
        for message in messages { scene.feed(message) }
        scene.tick(at: 30)
        scene.tick(at: 60)
        return scene
    }

    let first = run()
    let second = run()
    #expect(!first.decisions.isEmpty)
    #expect(first.content.turns == second.content.turns)
    #expect(records(first.content.turns) == records(second.content.turns))
    #expect(records(first.decisions) == records(second.decisions))
}

// MARK: - Cut by the maximum length

@Test func aSegmentCutByMaximumLengthWaitsForTheRestInsteadOfBeingHandedOver() {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var builder = SceneBuilder()
    var decisions: [SceneTurn] = []
    func send(_ type: String, at t: Double, subject: String? = nil, revision: UInt64? = nil, _ payload: [String: String] = [:]) {
        let message = SignalMessage(source: "t", type: type, timestamp: base.addingTimeInterval(t), subjectID: subject,
                                    revision: revision, payload: payload)
        if let snapshot = builder.ingest(message) { decisions += snapshot.decisions }
    }
    func tick(_ t: Double) { if let snapshot = builder.tick(now: base.addingTimeInterval(t)) { decisions += snapshot.decisions } }

    send("speech.segment.started", at: 0, subject: "utterance/s1-seg1")
    send("speech.segment.ended", at: 14, subject: "utterance/s1-seg1", ["reason": "max_duration"])
    send("speech.transcript.final", at: 14.5, subject: "utterance/s1-seg1", revision: 1,
         ["lane": "raw", "text": "Вера, слушай, я хочу чтобы ты записала длинную мысль и потом"])
    // Neither the no-verdict timeout (3 s) nor a verdict hands it over while the cut is fresh.
    tick(18)
    #expect(decisions.isEmpty)
    // The rest arrives and joins the same turn.
    send("speech.segment.started", at: 19, subject: "utterance/s1-seg2")
    send("speech.segment.ended", at: 23, subject: "utterance/s1-seg2", ["reason": "silence"])
    send("speech.transcript.final", at: 23.5, subject: "utterance/s1-seg2", revision: 1, ["lane": "raw", "text": "сохранила её в заметки."])
    tick(27)
    let ready = decisions.filter { if case .ready = $0.state { return true } else { return false } }
    #expect(ready.count == 1)
    #expect(ready.first?.utteranceIDs == ["utterance/s1-seg1", "utterance/s1-seg2"])
}

@Test func aCutSegmentIsHandedOverAfterTheHoldIfNothingFollows() {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var builder = SceneBuilder()
    var decisions: [SceneTurn] = []
    func send(_ type: String, at t: Double, subject: String? = nil, revision: UInt64? = nil, _ payload: [String: String] = [:]) {
        let message = SignalMessage(source: "t", type: type, timestamp: base.addingTimeInterval(t), subjectID: subject,
                                    revision: revision, payload: payload)
        if let snapshot = builder.ingest(message) { decisions += snapshot.decisions }
    }
    send("speech.segment.started", at: 0, subject: "utterance/s1-seg1")
    send("speech.segment.ended", at: 14, subject: "utterance/s1-seg1", ["reason": "max_duration"])
    send("speech.transcript.final", at: 14.5, subject: "utterance/s1-seg1", revision: 1, ["lane": "raw", "text": "Вера, включи свет в гостиной и на кухне"])
    if let snapshot = builder.tick(now: base.addingTimeInterval(21)) { decisions += snapshot.decisions }
    #expect(decisions.isEmpty)
    if let snapshot = builder.tick(now: base.addingTimeInterval(22.5)) { decisions += snapshot.decisions }
    #expect(decisions.count == 1)
    if case let .ready(basis)? = decisions.first?.state { #expect(basis == "no_verdict") } else { Issue.record("expected ready") }
}

// MARK: - Owner presence

private struct OwnerScene {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var builder: SceneBuilder
    var decisions: [SceneTurn] = []
    init(requireOwner: Bool, ttl base: SceneTTL = SceneTTL()) {
        var ttl = base; ttl.requireOwnerPresent = requireOwner
        builder = SceneBuilder(ttl: ttl)
    }
    mutating func send(_ type: String, at t: Double, subject: String? = nil, correlation: String? = nil,
                       revision: UInt64? = nil, _ payload: [String: String] = [:]) {
        let m = SignalMessage(source: "t", type: type, timestamp: base.addingTimeInterval(t), subjectID: subject,
                              revision: revision, correlationID: correlation, payload: payload)
        if let snap = builder.ingest(m) { decisions += snap.decisions }
    }
    mutating func tick(_ t: Double) { if let snap = builder.tick(now: base.addingTimeInterval(t)) { decisions += snap.decisions } }
    /// An utterance of `text` between start and end (final text 0.5 s after the end).
    mutating func say(_ n: Int, _ start: Double, _ end: Double, _ text: String) {
        let id = "utterance/s1-seg\(n)"
        send("speech.segment.started", at: start, subject: id)
        send("speech.segment.ended", at: end, subject: id, ["reason": "silence"])
        send("speech.transcript.final", at: end + 0.5, subject: id, revision: 1, ["lane": "raw", "text": text])
    }
    var readyCount: Int { decisions.filter { if case .ready = $0.state { return true } else { return false } }.count }
    var heardReasons: [String] { decisions.compactMap { if case let .heard(r) = $0.state { return r } else { return nil } } }
}

@Test func aRequestFromAGuestIsHeldBackWhenTheOwnerIsNotInTheScene() {
    var scene = OwnerScene(requireOwner: true)
    scene.send("audio.microphone.started", at: 0)
    scene.say(1, 1, 4, "Вера, расскажи, какая завтра погода?")
    scene.tick(8)
    #expect(scene.readyCount == 0)
    #expect(scene.heardReasons == ["owner_absent"])
}

@Test func theSameRequestGoesThroughOnceTheOwnerWasHeard() {
    var scene = OwnerScene(requireOwner: true)
    scene.send("audio.microphone.started", at: 0)
    // The owner speaks first and is recognised by voice (two agreeing CAM++ windows).
    scene.send("speech.segment.started", at: 1, subject: "utterance/s1-seg1")
    for i in 0..<2 {
        scene.send("speaker.live.similarity.computed", at: 2 + Double(i), correlation: "utterance/s1-seg1",
                   ["reference": "Алексей", "person_id": "me", "participant_role": "owner",
                    "cosine_similarity": "0.8", "margin": "0.3"])
    }
    scene.send("speech.segment.ended", at: 5, subject: "utterance/s1-seg1", ["reason": "silence"])
    scene.send("speech.transcript.final", at: 5.5, subject: "utterance/s1-seg1", revision: 1, ["lane": "raw", "text": "слушай что-то"])
    scene.say(2, 12, 15, "Вера, расскажи, какая завтра погода?")
    scene.tick(19)   // no judge in this test: the request is handed over after the no-verdict timeout
    #expect(scene.readyCount == 1)
}

@Test func theOwnerSeenOnlyByTheTargetSpeakerModelCountsAsPresent() {
    var scene = OwnerScene(requireOwner: true)
    scene.send("audio.microphone.started", at: 0)
    for i in 0..<6 { scene.send("speaker.target.activity.scored", at: 1 + Double(i) * 0.16, ["probability": "0.9"]) }
    scene.say(1, 3, 6, "Вера, включи свет")
    scene.tick(11)
    #expect(scene.readyCount == 1)
    #expect(scene.heardReasons.isEmpty)
}

@Test func withoutTheRuleTheScenePassesGuestRequestsAsBefore() {
    var scene = OwnerScene(requireOwner: false)
    scene.send("audio.microphone.started", at: 0)
    scene.say(1, 1, 4, "Вера, расскажи, какая завтра погода?")
    scene.tick(9)
    #expect(scene.readyCount == 1)
}

// MARK: - Settling of background talk

@Test func aPieceWithoutTheNameWaitsForAContinuationThatBringsIt() {
    var ttl = SceneTTL(); ttl.heardSettle = 2
    var scene = OwnerScene(requireOwner: false, ttl: ttl)
    scene.send("audio.microphone.started", at: 0)
    scene.say(1, 1, 3, "Слушай, мне нужно")           // ends at 3, final text at 3.5: no name, looks like background
    scene.say(2, 4.2, 6, "Вера, включи свет")         // starts 1.2 s after the first ended: inside the settle time
    scene.tick(12)
    #expect(scene.heardReasons.isEmpty)               // the first piece was never filed as background
    #expect(scene.readyCount == 1)
    #expect(scene.decisions.first?.utteranceIDs.count == 2)
}

@Test func backgroundTalkIsStillFiledAfterTheSettleTime() {
    var ttl = SceneTTL(); ttl.heardSettle = 2
    var scene = OwnerScene(requireOwner: false, ttl: ttl)
    scene.send("audio.microphone.started", at: 0)
    scene.say(1, 1, 3, "ну и погода сегодня")
    scene.tick(4)
    #expect(scene.decisions.isEmpty)                  // still settling, 1 s after it ended
    scene.tick(6)
    #expect(scene.heardReasons == ["not_addressed"])
}
