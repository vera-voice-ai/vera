import Foundation
import SignalBus

/// How long each kind of evidence stays in the scene after it was last observed.
/// The values are provisional engineering defaults, not calibrated measurements.
public struct SceneTTL: Sendable {
    /// Microphone level counts as "current" this long after the last chunk.
    public var audioLevel: TimeInterval = 1.5
    /// Target-speaker scores are averaged over this trailing window.
    public var ownerWindow: TimeInterval = 1.0
    /// A speaker-similarity hypothesis stays visible this long.
    public var speakerCandidate: TimeInterval = 10
    /// A finished utterance stays in `recent` this long, then is forgotten.
    public var finishedUtterance: TimeInterval = 30
    /// An utterance that never received `speech.segment.ended` is closed as stale after this.
    public var activeUtteranceMax: TimeInterval = 20
    /// Same threshold as the energy gate in Sensors; used to name the sound state.
    public var speechLevel: Double = 0.010
    /// A participant stays in the scene this long after they were last heard.
    public var participantPresence: TimeInterval = 300
    /// Speaker attribution from CAM++ windows: at least this many windows must agree on one person,
    /// with mean cosine and mean margin above the thresholds measured on the "Голоса" corpus.
    public var speakerMinWindows = 2
    public var speakerMinCosine = 0.55
    public var speakerMinMargin = 0.07
    /// Owner attribution from Nomo-PVAD: mean score over the utterance and the least number of 160 ms samples.
    public var ownerNomoMean = 0.7
    public var ownerNomoMinSamples = 5
    /// Windows with no confirmed person before the utterance is called "unknown voice" while still active.
    public var unknownAfterWindows = 3
    /// A new utterance by the same speaker within this gap after the previous one joins the same turn.
    public var turnMergeWindow: TimeInterval = 8
    /// Wait for the judge this long after the text is final; then decide without it.
    public var verdictTimeout: TimeInterval = 3
    /// A turn the judge keeps calling unfinished is handed over anyway after this long.
    public var maxHold: TimeInterval = 8
    /// An utterance whose final text never arrives is dropped as `no_text` after this long.
    public var finalTimeout: TimeInterval = 6
    /// After handing a turn to Core, the next turn of a person counts as addressed for this long.
    public var engagedWindow: TimeInterval = 45
    /// How long the "handed over" / "background" status is shown after a decision.
    public var statusFlash: TimeInterval = 3
    /// Forms of the assistant's name that mark a turn as addressed to her.
    /// A step of a piecewise-constant evidence table: a score below `below` adds `llr` (log-likelihood ratio,
    /// natural log) to the case for "this is the owner". Steps are checked in order; the last one is `.infinity`.
    public struct EvidenceStep: Sendable, Equatable {
        public let below: Double
        public let llr: Double
        public init(below: Double, llr: Double) { self.below = below; self.llr = llr }
    }
    /// Owner evidence from one CAM++ window, by cosine similarity to the owner's profile.
    /// Calibrated on the "Голоса" corpus (90 owner windows, 256 of other people): the owner never scored below 0.42
    /// and other people never above 0.40, so the corpus alone would justify steeper steps. These are deliberately
    /// milder, for three reasons: (1) the corpus clips are trimmed, while live utterances also give weak genuine
    /// edge windows (0.3-0.4 seen live), so low scores are only mildly negative; (2) no single window may confirm the
    /// owner by itself (the maximum, 2.5, is below the confirmation level 2.94); (3) similar-sounding people are
    /// not in the corpus. Provisional until checked on live and hand-labelled data.
    public var ownerCosineSteps: [EvidenceStep] = [
        .init(below: 0.25, llr: -2), .init(below: 0.40, llr: -0.5), .init(below: 0.50, llr: 1),
        .init(below: 0.60, llr: 2), .init(below: .infinity, llr: 2.5)
    ]
    /// Owner evidence from the mean target-speaker score of the whole utterance (one term, not one per 160 ms
    /// chunk, because neighbouring chunks are strongly correlated). It is also weighted down, as it hears the same audio.
    /// Utterance means on the corpus: owner 0.76-0.92 (one clip is the enrollment itself), other people up to 0.58.
    public var ownerNomoSteps: [EvidenceStep] = [
        .init(below: 0.3, llr: -2), .init(below: 0.5, llr: -0.5), .init(below: 0.65, llr: 0), .init(below: 0.8, llr: 1), .init(below: .infinity, llr: 2)
    ]
    public var ownerNomoWeight = 0.5
    /// The owner is confirmed at this posterior and rejected below the lower one; in between the scene is not sure.
    public var ownerConfirmPosterior = 0.95
    public var ownerRejectPosterior = 0.10
    /// Log-odds head start for the next utterance after the owner was confirmed; it halves every `ownerPriorHalfLife` s.
    public var ownerPrior = 1.5
    public var ownerPriorHalfLife: TimeInterval = 120
    /// A turn that looks like background talk waits this long after it ended before it is filed as such. The gate
    /// closes an utterance after about a second of silence, so a person who pauses and goes on produces two pieces;
    /// the second ("Вера, включи свет") must be able to join the first before the first is decided. Not latency-critical:
    /// background turns are context only. Zero in the pure logic, set by the app.
    public var heardSettle: TimeInterval = 0
    /// When true, nothing is handed to Core unless the owner is in the scene: attributed to a recent utterance
    /// (within `participantPresence`) or seen by the target-speaker model. Off by default for the pure logic;
    /// the app turns it on.
    public var requireOwnerPresent = false
    /// When the audio model is at least this sure the speaker has finished, an addressed turn is handed over at
    /// once, without waiting for the text judge. On Vera 1 clips 89 % of finished turns scored 0.8 or more; its
    /// ability to spot unfinished speech was not validated (only 5 negatives, all cut by the length limit).
    public var turnEndConfident = 0.9
    /// Off by default. The signal is recorded and shown but does not decide: on 112 balanced pauses from the Vera 1
    /// tape, run 0.4 s into the pause, it separated "speech resumes" from "real end" barely above chance
    /// (ROC-AUC 0.60) and at 0.9 would have cut 61 % of the continuing speakers off. The earlier 93 % on finished
    /// segments mostly reflected the 2 s of silence at their end. Turn on only after validation on labelled data.
    public var turnEndShortcut = false
    /// How long after Vera stops speaking the room still carries her voice (reverb, a late echo).
    public var speechTail: TimeInterval = 1.5
    public var wakeWords: Set<String> = ["вера", "веры", "вере", "веру", "верой", "верочка", "верка", "вер"]
    /// ASR artifacts on silence and noise; a turn made only of these is dropped as `noise`.
    public var noisePhrases: [String] = ["продолжение следует", "субтитры сделал", "субтитры создавал", "спасибо за просмотр"]
    public init() {}
}

public struct SceneUtterance: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable { case active, ended(reason: String) }
    public let id: String
    public var state: State
    public var text: String
    /// `final` ends the ASR stage for this utterance; it is not a claim that the text is correct.
    public var textIsFinal: Bool
    public var textRevision: UInt64
    public let startedAt: Date
    public var endedAt: Date?
    /// Participant this utterance is attributed to, once enough evidence agrees; nil while undecided.
    public var speakerID: String? = nil
    /// What the attribution rests on: `campp`, `nomo` or `no_match`.
    public var speakerBasis: String? = nil
    /// Accumulated log-odds that the owner is speaking (0 = even odds), rounded for readability.
    public var ownerLogOdds: Double? = nil
    /// Smart Turn's probability, from the audio of this utterance, that the speaker has finished.
    public var turnEndProbability: Double? = nil

    public var isActive: Bool { state == .active }
}

public struct SceneParticipant: Sendable, Equatable, Identifiable {
    public enum Role: String, Sendable { case owner, human, assistant, unknown }
    public let id: String
    public var label: String
    public var role: Role
    public var firstHeard: Date
    public var lastHeard: Date
    /// Utterances attributed to this participant since they entered the scene. It is not reduced when
    /// the scene forgets the utterances themselves; it drops only when an utterance is re-attributed elsewhere.
    public var utteranceCount: Int
}

public struct SceneSpeaker: Sendable, Equatable {
    public let label: String
    /// Raw cosine similarity, not a calibrated probability or a confirmed identity.
    public let similarity: Double
    public let margin: Double?
    public let utteranceID: String?
}

public enum SceneSound: String, Sendable { case silence, sound }

/// Whether a turn is meant for the assistant. Rules only for now; no model has judged it.
public enum Addressed: String, Sendable { case likely, possible, unlikely }

/// One thing a person said, possibly made of several utterances close together, and what the scene
/// decided to do with it.
public struct SceneTurn: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        /// Waiting: for final text, for more speech, or for the judge.
        case awaiting
        /// Handed to Core as `scene.turn.ready`; `basis` is `jev`, `no_verdict` or `hold_expired`.
        case ready(basis: String)
        /// Kept as context only (`scene.turn.heard`): `not_addressed`, `noise`, `assistant_voice` or `no_text`.
        case heard(reason: String)
    }
    public struct Verdict: Sendable, Equatable {
        public let choice: String          // "complete" or "continue"
        public let confidence: Double      // the model's own probability, not calibrated
        public let textRevision: Int
    }
    public let id: String
    public var utteranceIDs: [String]
    public var speakerID: String?
    public var speakerLabel: String?
    public var text: String
    public var textRevision: Int
    public var addressed: Addressed
    public var state: State
    public var verdict: Verdict?
    public var startedAt: Date
    public var endedAt: Date
    public var decidedAt: Date?
    /// True while the scene waits for a judge verdict on the current text.
    public var needsVerdict: Bool
    /// Smart Turn's probability for the turn's last utterance, when known.
    public var turnEndProbability: Double? = nil

    public var isAwaiting: Bool { state == .awaiting }
}

/// The scene in one word, for a person to read at a glance.
public enum SceneStatus: String, Sendable {
    /// Nothing is happening.
    case idle
    /// Someone is speaking; no turn is complete yet.
    case listening
    /// A turn has ended and the scene is deciding whether it is complete.
    case forming
    /// A turn was just handed to Core.
    case handedOver
    /// Speech was just heard that is not for the assistant.
    case background
}

public enum OwnerActivity: String, Sendable {
    /// No fresh target-speaker scores.
    case unknown
    case absent, possible, likely
}

/// Everything the scene currently believes. Two snapshots with equal content are the
/// same picture, whatever their revision numbers and timestamps are.
public struct SceneContent: Sendable, Equatable {
    public var microphoneOn = false
    public var sound: SceneSound?
    public var owner: OwnerActivity = .unknown
    public var ownerMean: Double?
    public var active: SceneUtterance?
    public var recent: [SceneUtterance] = []
    public var speaker: SceneSpeaker?
    public var status: SceneStatus = .idle
    /// Turns of the last `finishedUtterance` seconds, newest first, whatever their state.
    public var turns: [SceneTurn] = []
    /// Who is around: heard within `participantPresence`, newest first. Unrecognised voices are one
    /// shared "unknown voice" entry: without clustering of embeddings they cannot be told apart.
    public var participants: [SceneParticipant] = []

    public init() {}
}

public struct SceneSnapshot: Sendable, Identifiable {
    public var id: UInt64 { revision }
    public let revision: UInt64
    public let at: Date
    public let content: SceneContent
    /// Names of the content fields that differ from the previous snapshot.
    public let changed: [String]
    /// Messages that contributed since the previous snapshot (level telemetry excluded).
    public let causes: [UUID]
    /// Turns the scene decided about in this step: these become `scene.turn.ready` / `scene.turn.heard`.
    public let decisions: [SceneTurn]

    public var payload: [String: String] {
        var result: [String: String] = [
            "microphone": content.microphoneOn ? "on" : "off",
            "sound": content.sound?.rawValue ?? "unknown",
            "owner_activity": content.owner.rawValue,
            "recent_count": "\(content.recent.count)",
            "changed": changed.joined(separator: ","),
            "trigger": causes.isEmpty ? "expiry" : "evidence",
            "cause_ids": causes.map { $0.uuidString.lowercased() }.joined(separator: ",")
        ]
        if let mean = content.ownerMean { result["owner_mean"] = String(format: "%.1f", mean) }
        if let active = content.active {
            result["utterance_id"] = active.id
            result["utterance_text"] = active.text
            result["utterance_text_final"] = "\(active.textIsFinal)"
        }
        if let active = content.active, let id = active.speakerID {
            result["utterance_speaker"] = id
            result["utterance_speaker_basis"] = active.speakerBasis ?? ""
        }
        result["participants"] = content.participants.map { "\($0.id):\($0.role.rawValue)" }.joined(separator: ",")
        if let speaker = content.speaker {
            result["speaker_candidate"] = speaker.label
            result["speaker_similarity"] = String(format: "%.2f", speaker.similarity)
        }
        return result
    }
}

/// Accumulates sensor messages into short-lived facts and emits a new snapshot whenever
/// the resulting picture changes. Facts expire on their own: with no new evidence the
/// scene decays toward "unknown" instead of keeping stale beliefs.
///
/// The builder is deterministic. Time comes only from `SignalMessage.timestamp` and the
/// explicit `now` passed to `tick`, so a recorded message stream replays to the same
/// sequence of contents.
public struct SceneBuilder: Sendable {
    public private(set) var revision: UInt64 = 0

    private let ttl: SceneTTL
    private var microphoneOn = false
    private var level: (value: Double, at: Date)?
    private var ownerScores: [(at: Date, probability: Double)] = []
    private var speaker: (value: SceneSpeaker, at: Date)?
    private var utterances: [SceneUtterance] = []
    private var lastContent: SceneContent?
    private var pendingCauses: [UUID] = []
    private struct Evidence {
        struct Window { let personID: String; let label: String; let role: SceneParticipant.Role; let cosine: Double; let margin: Double; let ownerCosine: Double? }
        var windows: [Window] = []
        var nomoSum = 0.0
        var nomoCount = 0
    }
    private var evidence: [String: Evidence] = [:]
    private var participants: [String: SceneParticipant] = [:]
    private var attributedTo: [String: String] = [:]
    private var knownOwner: (id: String, label: String)?
    private var turns: [SceneTurn] = []
    private var turnOfUtterance: [String: String] = [:]
    private var textReadyAt: [String: Date] = [:]
    private var membersAtText: [String: Int] = [:]
    private var lastHandedOverAt: Date?
    /// When Vera spoke: (start, end), end nil while she still does. Her voice reaching the microphone must not become a request.
    private var ownSpeech: [(start: Date, end: Date?)] = []
    private var lastOwnerSeenAt: Date?
    private var lastOwnerConfirmedAt: Date?
    private var lastHeardAt: Date?
    private var pendingDecisions: [SceneTurn] = []
    private var turnCounter = 0
    private var lastLevelCause: UUID?
    private var lastOwnerCause: UUID?

    public init(ttl: SceneTTL = SceneTTL()) { self.ttl = ttl }

    public mutating func ingest(_ message: SignalMessage) -> SceneSnapshot? {
        // The only message from the scene's own domain that the builder consumes: the judge's answer.
        // It is an ordinary recorded message, so replaying a session reproduces the model's decisions.
        if message.domain == .scene, message.type == "scene.turn.verdict" {
            applyVerdict(message)
            return commit(now: message.timestamp)
        }
        // Response reports what Vera actually does with her voice.
        if message.domain == .response, message.type.hasPrefix("output.speech.") {
            switch message.type {
            case "output.speech.started": ownSpeech.append((message.timestamp, nil))
            case "output.speech.ended", "output.speech.failed":
                if let index = ownSpeech.lastIndex(where: { $0.end == nil }) { ownSpeech[index].end = message.timestamp }
            default: break
            }
            if ownSpeech.count > 20 { ownSpeech.removeFirst(ownSpeech.count - 20) }
            return commit(now: message.timestamp)
        }
        guard message.domain == .sensors else { return nil }
        let time = message.timestamp
        var isCause = true
        switch message.type {
        case "audio.microphone.started":
            microphoneOn = true
        case "audio.microphone.stopped":
            microphoneOn = false
            level = nil
            ownerScores.removeAll()
            speaker = nil
            closeActive(at: time, reason: "microphone_stopped")
        case "audio.input.observed":
            guard let rms = message.payload["rms"].flatMap(Double.init) else { return nil }
            level = (rms, time)
            lastLevelCause = message.id
            isCause = false
        case "speaker.target.activity.scored":
            guard let probability = message.payload["probability"].flatMap(Double.init) else { return nil }
            ownerScores.append((time, probability))
            let recent = ownerScores.filter { time.timeIntervalSince($0.at) <= ttl.ownerWindow }
            if recent.count >= 3, recent.reduce(0, { $0 + $1.probability }) / Double(recent.count) >= ttl.ownerNomoMean {
                lastOwnerSeenAt = time
            }
            lastOwnerCause = message.id
            isCause = false
            if let active = utterances.last(where: { $0.isActive }) {
                evidence[active.id, default: Evidence()].nomoSum += probability
                evidence[active.id, default: Evidence()].nomoCount += 1
                attribute(active.id, at: time)
            }
        case "speech.segment.started":
            guard let id = message.subjectID, !utterances.contains(where: { $0.id == id }) else { return nil }
            utterances.append(SceneUtterance(id: id, state: .active, text: "", textIsFinal: false,
                                             textRevision: 0, startedAt: time, endedAt: nil))
            evidence[id] = Evidence()
        case "speech.segment.ended":
            guard let id = message.subjectID, let index = utterances.firstIndex(where: { $0.id == id }) else { return nil }
            end(index, at: time, reason: message.payload["reason"] ?? "unknown")
            attribute(id, at: time)
        case "speech.transcript.partial", "speech.transcript.final":
            guard message.payload["lane"] == "raw",
                  let id = message.subjectID,
                  let index = utterances.firstIndex(where: { $0.id == id }) else { return nil }
            let revision = message.revision ?? 0
            let isFinal = message.type.hasSuffix(".final")
            // A late or duplicate revision never overwrites newer text, and nothing
            // overwrites a final.
            if utterances[index].textIsFinal || revision < utterances[index].textRevision { return nil }
            utterances[index].text = message.payload["text"] ?? ""
            utterances[index].textRevision = revision
            utterances[index].textIsFinal = isFinal
        case "speech.turn_end.estimated":
            guard let id = message.subjectID, let index = utterances.firstIndex(where: { $0.id == id }),
                  let probability = message.payload["probability"].flatMap(Double.init) else { return nil }
            utterances[index].turnEndProbability = probability
        case "speaker.live.similarity.computed":
            guard let label = message.payload["reference"],
                  let similarity = message.payload["cosine_similarity"].flatMap(Double.init) else { return nil }
            let margin = message.payload["margin"].flatMap(Double.init)
            speaker = (SceneSpeaker(label: label, similarity: similarity, margin: margin,
                                    utteranceID: message.correlationID), time)
            if message.payload["participant_role"] == "owner", let personID = message.payload["person_id"] {
                knownOwner = (personID, label)
            }
            if let utteranceID = message.correlationID, utterances.contains(where: { $0.id == utteranceID }),
               let personID = message.payload["person_id"] {
                let role = SceneParticipant.Role(rawValue: message.payload["participant_role"] ?? "human") ?? .human
                // The owner's own similarity for this window. Older recordings lack the field: then it is known
                // only if the owner happened to be the best or the second candidate.
                let ownerCosine = message.payload["owner_cosine"].flatMap(Double.init)
                    ?? (role == .owner ? similarity
                        : (message.payload["second_role"] == "owner" ? message.payload["second_cosine_similarity"].flatMap(Double.init) : nil))
                evidence[utteranceID, default: Evidence()].windows.append(
                    .init(personID: personID, label: label, role: role, cosine: similarity, margin: margin ?? 0,
                          ownerCosine: ownerCosine))
                attribute(utteranceID, at: time)
            }
        default:
            return nil
        }
        if isCause {
            pendingCauses.append(message.id)
            if pendingCauses.count > 32 { pendingCauses.removeFirst(pendingCauses.count - 32) }
        }
        return commit(now: time)
    }

    /// Advances time without new evidence so that expired facts drop out of the scene.
    public mutating func tick(now: Date) -> SceneSnapshot? { commit(now: now) }

    // MARK: - Internals

    private mutating func commit(now: Date) -> SceneSnapshot? {
        expire(now)
        updateTurns(now)
        let content = makeContent(now)
        guard content != lastContent else { return nil }
        let changed = Self.changedFields(from: lastContent, to: content)
        lastContent = content
        revision += 1
        let decisions = pendingDecisions
        pendingDecisions.removeAll()
        var causes = pendingCauses
        pendingCauses.removeAll()
        // Telemetry is not a cause by itself, but when it is what moved the picture the
        // latest sample is named; a change that comes from expiry has no cause at all.
        if changed.contains("owner_activity"), !ownerScores.isEmpty, let id = lastOwnerCause, !causes.contains(id) { causes.append(id) }
        if changed.contains("sound"), level != nil, let id = lastLevelCause, !causes.contains(id) { causes.append(id) }
        return SceneSnapshot(revision: revision, at: now, content: content, changed: changed, causes: causes,
                             decisions: decisions)
    }

    private mutating func expire(_ now: Date) {
        if let level, now.timeIntervalSince(level.at) > ttl.audioLevel { self.level = nil }
        let ttl = self.ttl
        ownerScores.removeAll { now.timeIntervalSince($0.at) > ttl.ownerWindow }
        if let speaker, now.timeIntervalSince(speaker.at) > ttl.speakerCandidate { self.speaker = nil }
        for index in utterances.indices where utterances[index].isActive
            && now.timeIntervalSince(utterances[index].startedAt) > ttl.activeUtteranceMax {
            end(index, at: now, reason: "stale")
            attribute(utterances[index].id, at: now)
        }
        utterances.removeAll { utterance in
            guard let endedAt = utterance.endedAt else { return false }
            return now.timeIntervalSince(endedAt) > ttl.finishedUtterance
        }
        let remembered = Set(utterances.map(\.id))
        evidence = evidence.filter { remembered.contains($0.key) }
        attributedTo = attributedTo.filter { remembered.contains($0.key) }
        participants = participants.filter { now.timeIntervalSince($0.value.lastHeard) <= ttl.participantPresence }
        let keepTurns = ttl.finishedUtterance
        turns.removeAll { turn in
            guard let decidedAt = turn.decidedAt else { return false }
            return now.timeIntervalSince(decidedAt) > keepTurns
        }
        let liveTurnIDs = Set(turns.map(\.id))
        turnOfUtterance = turnOfUtterance.filter { liveTurnIDs.contains($0.value) }
        textReadyAt = textReadyAt.filter { liveTurnIDs.contains($0.key) }
        membersAtText = membersAtText.filter { liveTurnIDs.contains($0.key) }
    }

    // MARK: - Turns

    private mutating func applyVerdict(_ message: SignalMessage) {
        guard let id = message.payload["turn_id"], let index = turns.firstIndex(where: { $0.id == id }),
              turns[index].isAwaiting,
              let choice = message.payload["choice"],
              let revision = message.payload["turn_revision"].flatMap(Int.init),
              revision == turns[index].textRevision else { return }
        turns[index].verdict = .init(choice: choice,
                                     confidence: message.payload["confidence"].flatMap(Double.init) ?? 0,
                                     textRevision: revision)
        turns[index].needsVerdict = false
        pendingCauses.append(message.id)
    }

    /// Groups finished utterances into turns, keeps each turn's text current and decides what to do with it.
    private mutating func updateTurns(_ now: Date) {
        // 1. every finished utterance belongs to a turn: join an open one of the same speaker, or start one
        for utterance in utterances where !utterance.isActive && turnOfUtterance[utterance.id] == nil {
            let ended = utterance.endedAt ?? now
            let window = ttl.turnMergeWindow
            if let index = turns.lastIndex(where: {
                $0.isAwaiting && $0.speakerID == utterance.speakerID && utterance.startedAt.timeIntervalSince($0.endedAt) <= window
            }) {
                turns[index].utteranceIDs.append(utterance.id)
                turns[index].endedAt = ended
                turnOfUtterance[utterance.id] = turns[index].id
            } else {
                turnCounter += 1
                let id = "turn/\(turnCounter)"
                turns.append(SceneTurn(id: id, utteranceIDs: [utterance.id], speakerID: utterance.speakerID,
                                       speakerLabel: nil, text: "", textRevision: 0, addressed: .unlikely,
                                       state: .awaiting, verdict: nil, startedAt: utterance.startedAt,
                                       endedAt: ended, decidedAt: nil, needsVerdict: false))
                turnOfUtterance[utterance.id] = id
            }
        }
        // 2. refresh and decide the turns that are still open
        for index in turns.indices where turns[index].isAwaiting {
            let members = turns[index].utteranceIDs.compactMap { id in utterances.first { $0.id == id } }
            turns[index].speakerID = members.first?.speakerID ?? turns[index].speakerID
            turns[index].speakerLabel = turns[index].speakerID.flatMap { participants[$0]?.label }
            let allFinal = members.count == turns[index].utteranceIDs.count && members.allSatisfy(\.textIsFinal)
            guard allFinal else {
                if now.timeIntervalSince(turns[index].endedAt) > ttl.finalTimeout { decide(index, .heard(reason: "no_text"), now) }
                continue
            }
            let text = members.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            // A turn that gained an utterance is a new question for the judge even if the text did not change.
            if text != turns[index].text || membersAtText[turns[index].id] != members.count {
                membersAtText[turns[index].id] = members.count
                turns[index].text = text
                turns[index].textRevision += 1
                turns[index].verdict = nil
                textReadyAt[turns[index].id] = now
            }
            turns[index].addressed = addressed(turns[index], now)
            if Self.isNoise(text, ttl.noisePhrases) { decide(index, .heard(reason: "noise"), now); continue }
            if members.contains(where: { veraWasSpeaking(at: $0.startedAt, until: $0.endedAt ?? now) }) {
                decide(index, .heard(reason: "vera_voice"), now); continue
            }
            if let speakerID = turns[index].speakerID, participants[speakerID]?.role == .assistant {
                decide(index, .heard(reason: "assistant_voice"), now); continue
            }
            if turns[index].addressed == .unlikely {
                if now.timeIntervalSince(turns[index].endedAt) >= ttl.heardSettle { decide(index, .heard(reason: "not_addressed"), now) }
                continue
            }
            // Without the owner in the scene a request is not handed over, however it is worded.
            if ttl.requireOwnerPresent, !ownerPresent(now) {
                // "unconfirmed": there was some evidence for the owner but not enough; "absent": there was none.
                let best = members.compactMap(\.ownerLogOdds).max() ?? -.infinity
                decide(index, .heard(reason: best > Self.logit(ttl.ownerRejectPosterior) ? "owner_unconfirmed" : "owner_absent"), now)
                continue
            }
            // A segment cut by the maximum length is mid-speech by construction: wait for the rest
            // (it joins this turn if it starts within the merge window) instead of asking anyone.
            if let last = members.last, last.state == .ended(reason: "max_duration"),
               now.timeIntervalSince(turns[index].endedAt) < ttl.maxHold {
                turns[index].needsVerdict = false
                continue
            }
            turns[index].turnEndProbability = members.last?.turnEndProbability
            if ttl.turnEndShortcut, let p = members.last?.turnEndProbability, p >= ttl.turnEndConfident {
                turns[index].needsVerdict = false
                decide(index, .ready(basis: "smart_turn"), now)
                continue
            }
            if let verdict = turns[index].verdict, verdict.textRevision == turns[index].textRevision {
                turns[index].needsVerdict = false
                if verdict.choice == "complete" {
                    decide(index, .ready(basis: "jev"), now)
                } else if now.timeIntervalSince(turns[index].endedAt) >= ttl.maxHold {
                    decide(index, .ready(basis: "hold_expired"), now)
                }
            } else {
                turns[index].needsVerdict = true
                if now.timeIntervalSince(textReadyAt[turns[index].id] ?? now) >= ttl.verdictTimeout {
                    decide(index, .ready(basis: "no_verdict"), now)
                }
            }
        }
    }

    private mutating func decide(_ index: Int, _ state: SceneTurn.State, _ now: Date) {
        turns[index].state = state
        turns[index].decidedAt = now
        turns[index].needsVerdict = false
        if case .ready = state { lastHandedOverAt = now } else { lastHeardAt = now }
        pendingDecisions.append(turns[index])
    }

    /// Rules only: the assistant's name in the text, or a person continuing a conversation she just had.
    private func addressed(_ turn: SceneTurn, _ now: Date) -> Addressed {
        let words = Self.words(turn.text)
        if words.contains(where: { ttl.wakeWords.contains($0) }) { return .likely }
        if let handed = lastHandedOverAt, now.timeIntervalSince(handed) <= ttl.engagedWindow,
           turn.speakerID != "unknown" { return .possible }
        return .unlikely
    }

    /// Whether any of Vera's own speech (plus its tail) overlaps the span of an utterance.
    private func veraWasSpeaking(at start: Date, until end: Date) -> Bool {
        ownSpeech.contains { speech in
            let speechEnd = (speech.end ?? .distantFuture).addingTimeInterval(ttl.speechTail)
            return speech.start <= end && start <= speechEnd
        }
    }

    private func ownerPresent(_ now: Date) -> Bool {
        if participants.values.contains(where: { $0.role == .owner }) { return true }
        if let seen = lastOwnerSeenAt, now.timeIntervalSince(seen) <= ttl.participantPresence { return true }
        return false
    }

    private func status(_ now: Date) -> SceneStatus {
        if turns.contains(where: { $0.isAwaiting }) { return .forming }
        if utterances.contains(where: { $0.isActive }) { return .listening }
        if let handed = lastHandedOverAt, now.timeIntervalSince(handed) <= ttl.statusFlash { return .handedOver }
        if let heard = lastHeardAt, now.timeIntervalSince(heard) <= ttl.statusFlash { return .background }
        return .idle
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    private static func isNoise(_ text: String, _ phrases: [String]) -> Bool {
        let letters = words(text).joined()
        if letters.count < 2 { return true }
        let normalized = words(text).joined(separator: " ")
        return phrases.contains { normalized.hasPrefix($0) && normalized.count <= $0.count + 24 }
    }

    /// Decides who an utterance belongs to from the evidence gathered so far. CAM++ windows count
    /// only when several agree; Nomo-PVAD alone can name the owner; otherwise the voice is unknown.
    private mutating func attribute(_ utteranceID: String, at time: Date) {
        guard let index = utterances.firstIndex(where: { $0.id == utteranceID }),
              let e = evidence[utteranceID] else { return }
        let ended = !utterances[index].isActive
        var resolved: (id: String, label: String, role: SceneParticipant.Role, basis: String)?

        let groups = Dictionary(grouping: e.windows, by: \.personID)
        let best = groups.map { (id: $0.key, windows: $0.value,
                                 meanCosine: $0.value.reduce(0) { $0 + $1.cosine } / Double($0.value.count),
                                 meanMargin: $0.value.reduce(0) { $0 + $1.margin } / Double($0.value.count)) }
            // Total order (count, cosine, id) so ties never depend on dictionary iteration order.
            .max { ($0.windows.count, $0.meanCosine, $1.id) < ($1.windows.count, $1.meanCosine, $0.id) }
        // A strict majority of all windows must agree, so 2 of 4 split between two people is not a verdict.
        if let best, best.windows.count >= ttl.speakerMinWindows, best.windows.count * 2 > e.windows.count,
           best.meanCosine >= ttl.speakerMinCosine, best.meanMargin >= ttl.speakerMinMargin {
            resolved = (best.id, best.windows[0].label, best.windows[0].role, "campp")
        }
        // Owner evidence adds up window by window; a confirmed other person (above) is stricter and wins.
        let logOdds = ownerLogOdds(e, at: time)
        utterances[index].ownerLogOdds = logOdds.map { ($0 * 100).rounded() / 100 }
        if resolved == nil, let logOdds, logOdds >= Self.logit(ttl.ownerConfirmPosterior) {
            let owner = knownOwner ?? (id: "owner", label: "Владелец")
            resolved = (owner.id, owner.label, .owner, "owner_evidence")
        }
        if resolved == nil, e.nomoCount >= ttl.ownerNomoMinSamples, e.nomoSum / Double(e.nomoCount) >= ttl.ownerNomoMean {
            let owner = knownOwner ?? (id: "owner", label: "Владелец")
            resolved = (owner.id, owner.label, .owner, "nomo")
        }
        if resolved == nil, (ended && !e.windows.isEmpty) || e.windows.count >= ttl.unknownAfterWindows {
            resolved = ("unknown", "Неизвестный голос", .unknown, "no_match")
        }
        guard let resolved else { return }

        if resolved.role == .owner { lastOwnerConfirmedAt = time }
        let previous = attributedTo[utteranceID]
        utterances[index].speakerID = resolved.id
        utterances[index].speakerBasis = resolved.basis
        if let previous, previous != resolved.id, var old = participants[previous] {
            old.utteranceCount -= 1
            if old.utteranceCount <= 0 { participants[previous] = nil } else { participants[previous] = old }
        }
        var participant = participants[resolved.id]
            ?? SceneParticipant(id: resolved.id, label: resolved.label, role: resolved.role,
                                firstHeard: time, lastHeard: time, utteranceCount: 0)
        participant.label = resolved.label
        participant.role = resolved.role
        if previous != resolved.id { participant.utteranceCount += 1; participant.lastHeard = max(participant.lastHeard, time) }
        if ended { participant.lastHeard = max(participant.lastHeard, utterances[index].endedAt ?? time) }
        participants[resolved.id] = participant
        attributedTo[utteranceID] = resolved.id
    }

    /// Log-odds that the owner is speaking: a decaying head start, plus one term per CAM++ window, plus the
    /// utterance-level target-speaker score.
    /// Nil when there is no direct evidence at all: a head start alone is not evidence.
    private func ownerLogOdds(_ e: Evidence, at time: Date) -> Double? {
        guard e.windows.contains(where: { $0.ownerCosine != nil }) || e.nomoCount >= ttl.ownerNomoMinSamples else { return nil }
        var total = 0.0
        if let confirmed = lastOwnerConfirmedAt {
            total += ttl.ownerPrior * pow(0.5, max(0, time.timeIntervalSince(confirmed)) / ttl.ownerPriorHalfLife)
        }
        for window in e.windows { if let cosine = window.ownerCosine { total += Self.step(ttl.ownerCosineSteps, cosine) } }
        if e.nomoCount >= ttl.ownerNomoMinSamples {
            total += ttl.ownerNomoWeight * Self.step(ttl.ownerNomoSteps, e.nomoSum / Double(e.nomoCount))
        }
        return total
    }

    private static func step(_ steps: [SceneTTL.EvidenceStep], _ value: Double) -> Double {
        steps.first { value < $0.below }?.llr ?? steps.last?.llr ?? 0
    }

    private static func logit(_ p: Double) -> Double { log(p / (1 - p)) }

    private mutating func end(_ index: Int, at time: Date, reason: String) {
        guard utterances[index].isActive else { return }
        utterances[index].state = .ended(reason: reason)
        utterances[index].endedAt = time
    }

    private mutating func closeActive(at time: Date, reason: String) {
        for index in utterances.indices where utterances[index].isActive {
            end(index, at: time, reason: reason)
            attribute(utterances[index].id, at: time)
        }
    }

    private func makeContent(_ now: Date) -> SceneContent {
        var content = SceneContent()
        content.microphoneOn = microphoneOn
        content.sound = level.map { $0.value >= ttl.speechLevel ? .sound : .silence }
        if !ownerScores.isEmpty {
            let mean = ownerScores.reduce(0) { $0 + $1.probability } / Double(ownerScores.count)
            // Rounded so that small jitter does not create a new snapshot each 160 ms.
            content.ownerMean = (mean * 10).rounded() / 10
            // Provisional thresholds: the target-speaker score is not calibrated yet.
            content.owner = mean < 0.3 ? .absent : (mean < 0.7 ? .possible : .likely)
        }
        content.active = utterances.last(where: { $0.isActive })
        content.recent = utterances.filter { !$0.isActive }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
            .prefix(8).map { $0 }
        content.speaker = speaker?.value
        content.turns = turns.sorted { $0.endedAt > $1.endedAt }
        content.status = status(now)
        content.participants = participants.values.sorted {
            $0.lastHeard != $1.lastHeard ? $0.lastHeard > $1.lastHeard : $0.id < $1.id
        }
        return content
    }

    private static func changedFields(from old: SceneContent?, to new: SceneContent) -> [String] {
        guard let old else { return ["initial"] }
        var names: [String] = []
        if old.microphoneOn != new.microphoneOn { names.append("microphone") }
        if old.sound != new.sound { names.append("sound") }
        if old.owner != new.owner || old.ownerMean != new.ownerMean { names.append("owner_activity") }
        if old.active != new.active { names.append("utterance") }
        if old.recent != new.recent { names.append("recent") }
        if old.speaker != new.speaker { names.append("speaker") }
        if old.participants != new.participants { names.append("participants") }
        if old.turns != new.turns { names.append("turns") }
        if old.status != new.status { names.append("status") }
        return names
    }
}

public extension SceneTTL {
    /// The settings the app runs with. One place, so the app and the evaluation harness cannot drift apart.
    static var app: SceneTTL {
        var ttl = SceneTTL()
        // Requests reach Core only while the owner is in the scene.
        ttl.requireOwnerPresent = true
        // Jev answered "continue" for two thirds of finished turns on real data: do not let it hold a turn long.
        ttl.maxHold = 3
        // The gate closes after ~1 s of silence; background talk waits 2 s for a continuation before it is filed.
        ttl.heardSettle = 2
        return ttl
    }
}
