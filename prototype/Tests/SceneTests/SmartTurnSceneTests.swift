import Foundation
import Testing
import Scene
import SignalBus

/// Smart Turn gives the audio's view of "has the speaker finished?". These tests pin how the scene uses it.
private struct AudioScene {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var builder: SceneBuilder
    var content = SceneContent()
    var decisions: [SceneTurn] = []
    var everNeededVerdict = false

    init(requireOwner: Bool = false) {
        var ttl = SceneTTL(); ttl.requireOwnerPresent = requireOwner
        ttl.turnEndShortcut = true   // pinned: these tests describe the shortcut itself, which is off by default
        builder = SceneBuilder(ttl: ttl)
    }
    mutating func send(_ type: String, at t: Double, subject: String? = nil, revision: UInt64? = nil, _ payload: [String: String] = [:]) {
        let m = SignalMessage(source: "t", type: type, timestamp: base.addingTimeInterval(t), subjectID: subject, revision: revision, payload: payload)
        if let snap = builder.ingest(m) { absorb(snap) }
    }
    mutating func tick(_ t: Double) { if let snap = builder.tick(now: base.addingTimeInterval(t)) { absorb(snap) } }
    private mutating func absorb(_ snap: SceneSnapshot) {
        content = snap.content; decisions += snap.decisions
        if snap.content.turns.contains(where: \.needsVerdict) { everNeededVerdict = true }
    }
    /// An utterance; Smart Turn's answer (if any) arrives right after the segment ends, before the ASR text.
    mutating func say(_ start: Double, _ end: Double, _ text: String, reason: String = "silence", turnEnd: Double? = nil) {
        let id = "utterance/s1-seg1"
        send("speech.segment.started", at: start, subject: id)
        send("speech.segment.ended", at: end, subject: id, ["reason": reason])
        if let turnEnd { send("speech.turn_end.estimated", at: end + 0.1, subject: id, ["probability": String(turnEnd)]) }
        send("speech.transcript.final", at: end + 1, subject: id, revision: 1, ["lane": "raw", "text": text])
    }
    var ready: [SceneTurn] { decisions.filter { if case .ready = $0.state { return true } else { return false } } }
    func basis(_ turn: SceneTurn) -> String? { if case let .ready(b) = turn.state { return b } else { return nil } }
}

@Test func aConfidentAudioModelHandsAnAddressedTurnOverAtOnceWithoutAskingTheTextJudge() {
    var scene = AudioScene()
    scene.send("audio.microphone.started", at: 0)
    scene.say(1, 4, "Вера, включи свет в гостиной", turnEnd: 0.96)
    #expect(scene.ready.count == 1)
    #expect(scene.basis(scene.ready[0]) == "smart_turn")
    #expect(scene.ready[0].turnEndProbability == 0.96)
    #expect(!scene.everNeededVerdict)
}

@Test func aDoubtfulAudioModelLeavesTheDecisionToTheTextJudgeAndTheTimeout() {
    var scene = AudioScene()
    scene.send("audio.microphone.started", at: 0)
    scene.say(1, 4, "Вера, включи свет", turnEnd: 0.4)
    #expect(scene.ready.isEmpty)
    #expect(scene.everNeededVerdict)
    scene.tick(9)   // no judge in this test: handed over after the no-verdict timeout
    #expect(scene.ready.count == 1)
    #expect(scene.basis(scene.ready[0]) == "no_verdict")
}

@Test func aConfidentAudioModelDoesNotOverrideTheAddresseeRule() {
    var scene = AudioScene()
    scene.send("audio.microphone.started", at: 0)
    scene.say(1, 4, "ну и погода сегодня", turnEnd: 0.99)
    #expect(scene.ready.isEmpty)
    #expect(scene.decisions.count == 1)
    if case let .heard(reason) = scene.decisions[0].state { #expect(reason == "not_addressed") } else { Issue.record("expected heard") }
}

@Test func aSegmentCutByTheLengthLimitStillWaitsEvenIfTheAudioModelIsSure() {
    var scene = AudioScene()
    scene.send("audio.microphone.started", at: 0)
    scene.say(1, 15, "Вера, запиши длинную мысль и потом", reason: "max_duration", turnEnd: 0.97)
    scene.tick(18)
    #expect(scene.ready.isEmpty)
}

@Test func theOwnerGateStillStopsAConfidentAudioModel() {
    var scene = AudioScene(requireOwner: true)
    scene.send("audio.microphone.started", at: 0)
    scene.say(1, 4, "Вера, включи свет в гостиной", turnEnd: 0.98)
    #expect(scene.ready.isEmpty)
}

@Test func byDefaultTheAudioEstimateIsRecordedButDoesNotDecide() {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var builder = SceneBuilder()    // default configuration: the shortcut is off
    var decisions: [SceneTurn] = []
    var lastTurn: SceneTurn?
    func send(_ type: String, at t: Double, subject: String? = nil, revision: UInt64? = nil, _ payload: [String: String] = [:]) {
        let m = SignalMessage(source: "t", type: type, timestamp: base.addingTimeInterval(t), subjectID: subject, revision: revision, payload: payload)
        if let snap = builder.ingest(m) { decisions += snap.decisions; lastTurn = snap.content.turns.first ?? lastTurn }
    }
    send("speech.segment.started", at: 1, subject: "utterance/s1-seg1")
    send("speech.segment.ended", at: 4, subject: "utterance/s1-seg1", ["reason": "silence"])
    send("speech.turn_end.estimated", at: 4.1, subject: "utterance/s1-seg1", ["probability": "0.99"])
    send("speech.transcript.final", at: 5, subject: "utterance/s1-seg1", revision: 1, ["lane": "raw", "text": "Вера, включи свет"])
    #expect(decisions.isEmpty)                       // it did not hand the turn over
    #expect(lastTurn?.turnEndProbability == 0.99)    // but it is kept for display and later analysis
    #expect(lastTurn?.needsVerdict == true)          // the text judge is still consulted
}
