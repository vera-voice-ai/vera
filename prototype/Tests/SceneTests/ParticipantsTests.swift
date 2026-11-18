import Foundation
import Testing
import Scene
import SignalBus

private let participantsBase = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let utterance = "utterance/s1-seg1"

private func at(_ offset: TimeInterval) -> Date { participantsBase.addingTimeInterval(offset) }

private func msg(
    _ type: String,
    at offset: TimeInterval = 0,
    subject: String? = nil,
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
        correlationID: correlation,
        payload: payload
    )
}

private func segmentStarted(_ offset: TimeInterval) -> SignalMessage {
    msg("speech.segment.started", at: offset, subject: utterance)
}

private func segmentEnded(_ offset: TimeInterval) -> SignalMessage {
    msg("speech.segment.ended", at: offset, subject: utterance, payload: ["reason": "silence"])
}

/// One CAM++ window for the utterance. Defaults describe a confident match for "p1".
private func window(
    _ offset: TimeInterval,
    person: String = "p1",
    label: String = "Оля",
    role: String = "human",
    cosine: Double = 0.7,
    margin: Double = 0.2
) -> SignalMessage {
    msg("speaker.live.similarity.computed", at: offset, correlation: utterance, payload: [
        "reference": label,
        "person_id": person,
        "participant_role": role,
        "cosine_similarity": "\(cosine)",
        "margin": "\(margin)"
    ])
}

/// One Nomo-PVAD target-speaker score (160 ms sample).
private func nomo(_ offset: TimeInterval, _ probability: Double) -> SignalMessage {
    msg("speaker.target.activity.scored", at: offset, payload: ["probability": "\(probability)"])
}

/// Feeds messages into a builder and keeps the latest emitted content, so assertions can
/// read the scene even after calls that returned nil because nothing changed.
private struct ParticipantReplay {
    var builder = SceneBuilder()
    var content: SceneContent?

    mutating func ingest(_ message: SignalMessage) {
        if let snapshot = builder.ingest(message) { content = snapshot.content }
    }

    mutating func tick(_ offset: TimeInterval) {
        if let snapshot = builder.tick(now: at(offset)) { content = snapshot.content }
    }
}

// MARK: - Attribution from CAM++ windows

@Test func twoAgreeingWindowsAttributeUtteranceToParticipant() {
    var scene = ParticipantReplay()
    scene.ingest(segmentStarted(0))
    scene.ingest(window(1))
    scene.ingest(window(2))

    #expect(scene.content?.active?.speakerID == "p1")
    #expect(scene.content?.active?.speakerBasis == "campp")
    let participants = scene.content?.participants ?? []
    #expect(participants.map(\.id) == ["p1"])
    #expect(participants.first?.label == "Оля")
    #expect(participants.first?.role == .human)
    #expect(participants.first?.utteranceCount == 1)
}

@Test func singleWindowDoesNotAttributeUtterance() {
    var scene = ParticipantReplay()
    scene.ingest(segmentStarted(0))
    scene.ingest(window(1))

    #expect(scene.content?.active?.speakerID == nil)
    #expect(scene.content?.active?.speakerBasis == nil)
    #expect(scene.content?.participants.isEmpty == true)
}

@Test func lowCosineWindowsAreNotConfirmedAndEndAsUnknown() {
    var scene = ParticipantReplay()
    scene.ingest(segmentStarted(0))
    scene.ingest(window(1, cosine: 0.40))
    scene.ingest(window(2, cosine: 0.40))

    #expect(scene.content?.active?.speakerBasis != "campp")
    #expect(scene.content?.active?.speakerID != "p1")

    scene.ingest(segmentEnded(3))
    #expect(scene.content?.active == nil)
    let finished = scene.content?.recent.first
    #expect(finished?.speakerID == "unknown")
    #expect(finished?.speakerBasis == "no_match")
    let unknown = scene.content?.participants.first { $0.id == "unknown" }
    #expect(unknown?.role == .unknown)
    #expect(scene.content?.participants.contains { $0.id == "p1" } == false)
}

@Test func disagreeingWindowsDoNotConfirmAnyone() {
    var scene = ParticipantReplay()
    scene.ingest(segmentStarted(0))
    scene.ingest(window(1, person: "p1"))
    scene.ingest(window(2, person: "p2", label: "Вася"))

    #expect(scene.content?.active?.speakerID == nil)
    #expect(scene.content?.active?.speakerBasis == nil)

    scene.ingest(segmentEnded(3))
    #expect(scene.content?.recent.first?.speakerBasis == "no_match")
    #expect(scene.content?.recent.first?.speakerID == "unknown")
    #expect(scene.content?.participants.contains { $0.id == "p1" || $0.id == "p2" } == false)
}

// MARK: - Owner attribution from Nomo-PVAD

@Test func highNomoScoresAttributeUtteranceToOwnerWithoutLearnedIdentity() {
    var scene = ParticipantReplay()
    scene.ingest(segmentStarted(0))
    for offset in 1...6 { scene.ingest(nomo(Double(offset), 0.9)) }

    #expect(scene.content?.active?.speakerID == "owner")
    #expect(scene.content?.active?.speakerBasis == "nomo")
    let owner = scene.content?.participants.first { $0.id == "owner" }
    #expect(owner?.role == .owner)
    #expect(owner?.utteranceCount == 1)
}

@Test func highNomoScoresUseOwnerIdentityLearnedFromEarlierSimilarity() {
    var scene = ParticipantReplay()
    // Learns the owner's identity from a similarity message that is not tied to this utterance.
    scene.ingest(msg("speaker.live.similarity.computed", at: 0, payload: [
        "reference": "Alex",
        "person_id": "me",
        "participant_role": "owner",
        "cosine_similarity": "0.6",
        "margin": "0.1"
    ]))
    scene.ingest(segmentStarted(0.5))
    for offset in 1...6 { scene.ingest(nomo(Double(offset), 0.9)) }

    #expect(scene.content?.active?.speakerID == "me")
    #expect(scene.content?.active?.speakerBasis == "nomo")
    #expect(scene.content?.participants.first { $0.id == "me" }?.role == .owner)
}

@Test func moderateNomoScoresDoNotAttributeUtteranceToOwner() {
    var scene = ParticipantReplay()
    scene.ingest(segmentStarted(0))
    for offset in 1...6 { scene.ingest(nomo(Double(offset), 0.5)) }

    #expect(scene.content?.active?.speakerID == nil)
    #expect(scene.content?.participants.contains { $0.id == "owner" } == false)
}

// MARK: - Precedence

@Test func camppConfirmationWinsOverNomoOwnerScores() {
    var scene = ParticipantReplay()
    scene.ingest(segmentStarted(0))
    scene.ingest(window(1))
    scene.ingest(window(2))
    for offset in 3...8 { scene.ingest(nomo(Double(offset), 0.9)) }

    #expect(scene.content?.active?.speakerID == "p1")
    #expect(scene.content?.active?.speakerBasis == "campp")
    #expect(scene.content?.participants.first { $0.id == "p1" }?.role == .human)
}

// MARK: - Presence

@Test func participantLeavesAfterThreeHundredSeconds() {
    var scene = ParticipantReplay()
    // Heard at t = 0 and the utterance closes at once, so presence is measured from t = 0.
    scene.ingest(segmentStarted(0))
    scene.ingest(window(0))
    scene.ingest(window(0))
    scene.ingest(segmentEnded(0))
    #expect(scene.content?.participants.map(\.id) == ["p1"])

    scene.tick(299)
    #expect(scene.content?.participants.map(\.id) == ["p1"])

    scene.tick(301)
    #expect(scene.content?.participants.isEmpty == true)
}

// MARK: - Re-attribution

@Test func reattributionMovesUtteranceCountFromOwnerToParticipant() {
    var scene = ParticipantReplay()
    scene.ingest(segmentStarted(0))
    for offset in 1...6 { scene.ingest(nomo(Double(offset), 0.9)) }
    #expect(scene.content?.participants.first { $0.id == "owner" }?.utteranceCount == 1)

    scene.ingest(window(7))
    scene.ingest(window(8))

    #expect(scene.content?.active?.speakerID == "p1")
    #expect(scene.content?.active?.speakerBasis == "campp")
    #expect(scene.content?.participants.contains { $0.id == "owner" } == false)
    #expect(scene.content?.participants.first { $0.id == "p1" }?.utteranceCount == 1)
}

// MARK: - Determinism

@Test func participantsReplayIdenticallyForIdenticalStreams() {
    let messages: [SignalMessage] = [
        msg("audio.microphone.started", at: 0),
        segmentStarted(0.5),
        window(1),
        window(1.5),
        segmentEnded(2),
        segmentStarted(3),
        window(3.5, person: "p2", label: "Вася", role: "human", cosine: 0.6, margin: 0.15),
        window(4, person: "p2", label: "Вася", role: "human", cosine: 0.6, margin: 0.15),
        segmentEnded(4.5),
        segmentStarted(5),
        nomo(5.5, 0.9), nomo(6, 0.9), nomo(6.5, 0.9), nomo(7, 0.9), nomo(7.5, 0.9),
        segmentEnded(8),
        msg("audio.microphone.stopped", at: 9)
    ]

    func run() -> [SceneContent] {
        var builder = SceneBuilder()
        var contents: [SceneContent] = []
        for message in messages {
            if let snapshot = builder.ingest(message) { contents.append(snapshot.content) }
        }
        for offset in [100.0, 400.0] {
            if let snapshot = builder.tick(now: at(offset)) { contents.append(snapshot.content) }
        }
        return contents
    }

    let first = run()
    let second = run()
    #expect(first.contains { !$0.participants.isEmpty })
    #expect(first == second)
}

@Test func evenSplitBetweenTwoPeopleIsNotConfirmedAndIsStableAcrossRuns() {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    func run() -> [String?] {
        var builder = SceneBuilder()
        var speakers: [String?] = []
        func feed(_ m: SignalMessage) { _ = builder.ingest(m) }
        feed(SignalMessage(source: "t", type: "speech.segment.started", timestamp: base, subjectID: "utterance/s1-seg1"))
        for i in 0..<4 {
            let person = i % 2 == 0 ? "p1" : "p2"
            feed(SignalMessage(source: "t", type: "speaker.live.similarity.computed", timestamp: base.addingTimeInterval(Double(i)),
                               correlationID: "utterance/s1-seg1",
                               payload: ["reference": person, "person_id": person, "participant_role": "human",
                                         "cosine_similarity": "0.70", "margin": "0.20"]))
            if let snap = builder.tick(now: base.addingTimeInterval(Double(i) + 0.1)) { speakers.append(snap.content.active?.speakerID) }
        }
        return speakers
    }
    let results = (0..<5).map { _ in run() }
    #expect(results.allSatisfy { $0 == results[0] })
    #expect(results[0].last ?? nil != "p1" && results[0].last ?? nil != "p2")
}

// MARK: - A conversation with several participants

private struct Conversation {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var builder = SceneBuilder()
    var content = SceneContent()

    func time(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }

    mutating func send(_ type: String, at seconds: Double, subject: String? = nil, correlation: String? = nil,
                       revision: UInt64? = nil, _ payload: [String: String] = [:]) {
        let message = SignalMessage(source: "test", type: type, timestamp: time(seconds), subjectID: subject,
                                    revision: revision, correlationID: correlation, payload: payload)
        if let snapshot = builder.ingest(message) { content = snapshot.content }
    }

    mutating func tick(at seconds: Double) {
        if let snapshot = builder.tick(now: time(seconds)) { content = snapshot.content }
    }

    /// One utterance: segment boundaries, optional CAM++ windows or Nomo-PVAD samples, final text.
    mutating func speak(_ n: Int, from start: Double, to end: Double, text: String,
                        windows: [(id: String, label: String, role: String, cosine: Double, margin: Double)] = [],
                        nomo: Double? = nil) {
        let id = "utterance/s1-seg\(n)"
        send("speech.segment.started", at: start, subject: id)
        for (i, window) in windows.enumerated() {
            send("speaker.live.similarity.computed", at: start + 1 + Double(i), correlation: id,
                 ["reference": window.label, "person_id": window.id, "participant_role": window.role,
                  "cosine_similarity": String(window.cosine), "margin": String(window.margin)])
        }
        if let nomo {
            for i in 0..<6 { send("speaker.target.activity.scored", at: start + 1 + Double(i) * 0.16, ["probability": String(nomo)]) }
        }
        send("speech.transcript.partial", at: end - 1, subject: id, revision: 1, ["lane": "raw", "text": String(text.prefix(4))])
        send("speech.segment.ended", at: end, subject: id, ["reason": "silence"])
        send("speech.transcript.final", at: end + 0.5, subject: id, revision: 2, ["lane": "raw", "text": text])
    }
}

@Test func fourUtterancesFromThreeVoicesBuildParticipantsAndAttributeEachReply() {
    var chat = Conversation()
    let me = (id: "me", label: "Алексей", role: "owner")
    let olya = (id: "p1", label: "Оля", role: "human")
    chat.send("audio.microphone.started", at: 0)

    // 1. the owner, recognised by voice; 2. a known person; 3. a voice that matches nobody;
    // 4. the owner again, this time only by the target-speaker score.
    chat.speak(1, from: 0, to: 5, text: "привет вера",
               windows: [(me.id, me.label, me.role, 0.80, 0.30), (me.id, me.label, me.role, 0.78, 0.28)])
    #expect(chat.content.participants.map(\.id) == ["me"])

    chat.speak(2, from: 6, to: 11, text: "а мы уже идём",
               windows: [(olya.id, olya.label, olya.role, 0.66, 0.20), (olya.id, olya.label, olya.role, 0.70, 0.22)])
    chat.speak(3, from: 12, to: 17, text: "кто-то посторонний",
               windows: [("p9", "Незнакомец", "human", 0.35, 0.02), ("p9", "Незнакомец", "human", 0.33, 0.01)])
    chat.speak(4, from: 18, to: 23, text: "включи свет", nomo: 0.9)

    // Each reply belongs to the right participant, newest reply first, with its own text.
    let replies = chat.content.recent
    #expect(replies.map(\.text) == ["включи свет", "кто-то посторонний", "а мы уже идём", "привет вера"])
    #expect(replies.map(\.speakerID) == ["me", "unknown", "p1", "me"])
    #expect(replies.map(\.speakerBasis) == ["nomo", "no_match", "campp", "campp"])
    #expect(replies.allSatisfy { $0.textIsFinal })

    // Three participants, most recently heard first, with the right roles and utterance counts.
    let who = chat.content.participants
    #expect(who.map(\.id) == ["me", "unknown", "p1"])
    #expect(who.map(\.role) == [.owner, .unknown, .human])
    #expect(who.map(\.utteranceCount) == [2, 1, 1])
    #expect(who.first(where: { $0.id == "me" })?.label == "Алексей")

    // The scene forgets the replies after 30 s, but people stay for 5 minutes after the last time they spoke.
    chat.tick(at: 54)    // 31 s after the last reply ended at t=23
    #expect(chat.content.recent.isEmpty)
    #expect(chat.content.participants.map(\.id) == ["me", "unknown", "p1"])
    #expect(chat.content.participants.map(\.utteranceCount) == [2, 1, 1])

    chat.tick(at: 310)
    #expect(chat.content.participants.map(\.id) == ["me", "unknown", "p1"])
    chat.tick(at: 312)   // 301 s after the known person's last reply ended at t=11
    #expect(chat.content.participants.map(\.id) == ["me", "unknown"])
    chat.tick(at: 316)
    #expect(chat.content.participants.map(\.id) == ["me", "unknown"])
    chat.tick(at: 318)   // the unknown voice, last heard at t=17
    #expect(chat.content.participants.map(\.id) == ["me"])
    chat.tick(at: 322)
    #expect(chat.content.participants.map(\.id) == ["me"])
    chat.tick(at: 324)   // the owner, last heard at t=23
    #expect(chat.content.participants.isEmpty)
}

@Test func twoPeopleSpeakingInTurnsKeepSeparateCountsAndSurviveAnInterleavedOwner() {
    var chat = Conversation()
    let a = (id: "p1", label: "Оля", role: "human")
    let b = (id: "p2", label: "Игорь", role: "human")
    chat.send("audio.microphone.started", at: 0)
    chat.speak(1, from: 0, to: 6, text: "раз", windows: [(a.id, a.label, a.role, 0.7, 0.2), (a.id, a.label, a.role, 0.7, 0.2)])
    chat.speak(2, from: 8, to: 14, text: "два", windows: [(b.id, b.label, b.role, 0.7, 0.2), (b.id, b.label, b.role, 0.7, 0.2)])
    chat.speak(3, from: 16, to: 22, text: "три", windows: [(a.id, a.label, a.role, 0.7, 0.2), (a.id, a.label, a.role, 0.7, 0.2)])

    let counts = Dictionary(uniqueKeysWithValues: chat.content.participants.map { ($0.id, $0.utteranceCount) })
    #expect(counts == ["p1": 2, "p2": 1])
    #expect(chat.content.participants.map(\.id) == ["p1", "p2"])     // Оля spoke last
    #expect(chat.content.recent.map(\.speakerID) == ["p1", "p2", "p1"])
}
