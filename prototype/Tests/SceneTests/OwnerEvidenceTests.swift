import Foundation
import Testing
import Scene
import SignalBus

/// Owner evidence adds up window by window. These tests pin their own evidence table, so they keep
/// meaning the same thing when the scene's default table is recalibrated.
private struct EvidenceScene {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var builder: SceneBuilder
    var content = SceneContent()
    var decisions: [SceneTurn] = []

    init(requireOwner: Bool = false) {
        var ttl = SceneTTL()
        ttl.ownerCosineSteps = [.init(below: 0.35, llr: -1.5), .init(below: 0.45, llr: 0), .init(below: 0.55, llr: 1), .init(below: .infinity, llr: 3)]
        ttl.ownerNomoSteps = [.init(below: 0.4, llr: -1), .init(below: 0.8, llr: 0), .init(below: .infinity, llr: 1)]
        ttl.ownerPrior = 1.5
        ttl.ownerPriorHalfLife = 120
        ttl.requireOwnerPresent = requireOwner
        builder = SceneBuilder(ttl: ttl)
    }

    mutating func send(_ type: String, at t: Double, subject: String? = nil, correlation: String? = nil,
                       revision: UInt64? = nil, _ payload: [String: String] = [:]) {
        let m = SignalMessage(source: "t", type: type, timestamp: base.addingTimeInterval(t), subjectID: subject,
                              revision: revision, correlationID: correlation, payload: payload)
        if let snap = builder.ingest(m) { content = snap.content; decisions += snap.decisions }
    }
    mutating func tick(_ t: Double) {
        if let snap = builder.tick(now: base.addingTimeInterval(t)) { content = snap.content; decisions += snap.decisions }
    }

    /// One utterance with CAM++ windows. `owner` is each window's cosine to the owner's profile.
    mutating func utterance(_ n: Int, from start: Double, ownerCosines: [Double], bestPerson: String = "p9", text: String = "Вера, привет") {
        let id = "utterance/s1-seg\(n)"
        send("speech.segment.started", at: start, subject: id)
        for (i, cosine) in ownerCosines.enumerated() {
            send("speaker.live.similarity.computed", at: start + 1 + Double(i) * 0.5, correlation: id,
                 ["reference": bestPerson, "person_id": bestPerson, "participant_role": "human",
                  "cosine_similarity": "0.35", "margin": "0.02", "owner_cosine": String(cosine)])
        }
        let end = start + 2 + Double(ownerCosines.count) * 0.5
        send("speech.segment.ended", at: end, subject: id, ["reason": "silence"])
        send("speech.transcript.final", at: end + 0.5, subject: id, revision: 1, ["lane": "raw", "text": text])
    }

    func ownerIsPresent() -> Bool { content.participants.contains { $0.role == .owner } }
    var lastUtterance: SceneUtterance? { content.recent.first ?? content.active }
    var heardReasons: [String] { decisions.compactMap { if case let .heard(r) = $0.state { return r } else { return nil } } }
}

@Test func theOwnerIsConfirmedFromStrongWindowsDespiteWeakEdgeWindows() {
    // The real numbers of a clip of the owner from a replay: two weak edge windows, three strong ones in the middle.
    // Their mean (0.54) is below the identification threshold; their sum of evidence is not.
    var scene = EvidenceScene()
    scene.send("audio.microphone.started", at: 0)
    scene.utterance(1, from: 1, ownerCosines: [0.41, 0.67, 0.71, 0.56, 0.31, 0.34])
    scene.tick(10)
    #expect(scene.ownerIsPresent())
    #expect(scene.lastUtterance?.speakerBasis == "owner_evidence")
    #expect((scene.lastUtterance?.ownerLogOdds ?? 0) > 2.94)
}

@Test func anotherVoiceNeverAddsUpToTheOwner() {
    var scene = EvidenceScene()
    scene.send("audio.microphone.started", at: 0)
    scene.utterance(1, from: 1, ownerCosines: [0.30, 0.28, 0.33, 0.31, 0.29])
    scene.tick(10)
    #expect(!scene.ownerIsPresent())
    #expect((scene.lastUtterance?.ownerLogOdds ?? 0) < 0)
}

@Test func twoModerateWindowsAreNotEnoughAndAreReportedAsUnconfirmed() {
    var scene = EvidenceScene(requireOwner: true)
    scene.send("audio.microphone.started", at: 0)
    scene.utterance(1, from: 1, ownerCosines: [0.5, 0.5])   // +1 +1 = 2 < 2.94
    scene.tick(12)
    #expect(!scene.ownerIsPresent())
    #expect(scene.heardReasons == ["owner_unconfirmed"])
    #expect(scene.decisions.allSatisfy { if case .ready = $0.state { return false } else { return true } })
}

@Test func recentlyConfirmedOwnerNeedsLessEvidenceNextTimeAndTheHeadStartFades() {
    var scene = EvidenceScene()
    scene.send("audio.microphone.started", at: 0)
    scene.utterance(1, from: 1, ownerCosines: [0.7, 0.7])            // +6, confirmed
    #expect(scene.lastUtterance?.speakerBasis == "owner_evidence")
    // Right after: two moderate windows (+2) plus the head start (+1.5 fading) reach 2.94.
    scene.utterance(2, from: 12, ownerCosines: [0.5, 0.5])
    scene.tick(20)
    #expect(scene.content.recent.first?.speakerBasis == "owner_evidence")
    // Ten minutes later the head start is gone and the same two windows are not enough.
    scene.utterance(3, from: 700, ownerCosines: [0.5, 0.5])
    scene.tick(710)
    #expect(scene.content.recent.first?.speakerBasis != "owner_evidence")
}

@Test func strongEvidenceForAnotherKnownPersonWinsOverOwnerEvidence() {
    var scene = EvidenceScene()
    scene.send("audio.microphone.started", at: 0)
    // Three windows all name "p1" confidently; the owner's cosine on them is high too (similar voices).
    let id = "utterance/s1-seg1"
    scene.send("speech.segment.started", at: 1, subject: id)
    for i in 0..<3 {
        scene.send("speaker.live.similarity.computed", at: 2 + Double(i), correlation: id,
                   ["reference": "Оля", "person_id": "p1", "participant_role": "human",
                    "cosine_similarity": "0.8", "margin": "0.3", "owner_cosine": "0.6"])
    }
    scene.send("speech.segment.ended", at: 6, subject: id, ["reason": "silence"])
    scene.tick(8)
    #expect(scene.content.recent.first?.speakerID == "p1")
    #expect(!scene.ownerIsPresent())
}
