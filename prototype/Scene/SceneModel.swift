import Foundation
import Observation
import SignalBus

/// One answer of the turn judge, kept so the scene can show what the judge is doing.
public struct VerdictRecord: Identifiable, Sendable {
    public let id = UUID()
    public let turnID: String
    public let text: String
    /// `complete` or `continue`.
    public let choice: String
    /// The model's own probability for its choice; not calibrated.
    public let confidence: Double
    public let modelMilliseconds: Int
    /// Wall time of the whole request, including the pipe to the worker.
    public let wallMilliseconds: Int
    public let at: Date
}

/// Answers one question about a turn of speech: has the person finished it?
/// The scene works without a judge (it then falls back to waiting); Jev is the first one.
public protocol TurnJudge: Sendable {
    func judge(transcript: String, context: [String]) async throws -> (choice: String, confidence: Double, modelMilliseconds: Int)
}

@MainActor
@Observable
public final class SceneModel {
    public private(set) var messages: [SignalMessage] = []
    public private(set) var latestEmbedding: [Float]?
    public var selectedMessageID: UUID?
    /// Latest scene picture and the last revisions, newest first.
    public private(set) var snapshot: SceneSnapshot?
    public private(set) var snapshots: [SceneSnapshot] = []
    private var builder = SceneBuilder()
    public var judge: (any TurnJudge)?
    /// Name of the judge for display, for example the model and precision.
    public var judgeName = ""
    /// Last answers of the judge, newest first, and counters for the whole session.
    public private(set) var verdicts: [VerdictRecord] = []
    public private(set) var judgeCalls = 0
    public private(set) var judgeFailures = 0
    /// Turns that went on without a verdict because the judge did not answer in time are counted by the builder
    /// as `no_verdict` decisions; this counts only requests that failed outright.
    private var requestedVerdicts: Set<String> = []

    public init(ttl: SceneTTL = SceneTTL()) { builder = SceneBuilder(ttl: ttl) }

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
        // Without new evidence nothing arrives, so a timer lets expired facts decay.
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if let snapshot = self.builder.tick(now: .now) { await self.accept(snapshot, bus: bus) }
            }
        }
        defer { ticker.cancel() }
        for await message in stream {
            // Core reads the scene by asking: the answer goes back on the bus, tied to the question.
            if message.kind == .query, message.type == "scene.snapshot.get" {
                await bus.publish(snapshotReply(to: message))
                continue
            }
            if message.domain == .sensors || message.type == "scene.turn.verdict",
               let snapshot = builder.ingest(message) { await accept(snapshot, bus: bus) }
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

    private func accept(_ snapshot: SceneSnapshot, bus: SignalBus) async {
        self.snapshot = snapshot
        snapshots.insert(snapshot, at: 0)
        if snapshots.count > 50 { snapshots.removeLast(snapshots.count - 50) }
        await bus.publish(SignalMessage(kind: .event, domain: .scene, source: "Scene.Builder",
                                        type: "scene.revision.created", subjectID: "scene/main",
                                        revision: snapshot.revision,
                                        causationID: snapshot.causes.last?.uuidString.lowercased(),
                                        payload: snapshot.payload))
        for turn in snapshot.decisions {
            let isReady: Bool
            let why: String
            switch turn.state {
            case let .ready(basis): isReady = true; why = basis
            case let .heard(reason): isReady = false; why = reason
            case .awaiting: continue
            }
            var payload: [String: String] = [
                "turn_id": turn.id, "text": turn.text, "addressed": turn.addressed.rawValue,
                "speaker_id": turn.speakerID ?? "", "speaker": turn.speakerLabel ?? "",
                "utterance_ids": turn.utteranceIDs.joined(separator: ","),
                isReady ? "basis" : "reason": why
            ]
            if let db = turn.loudnessDB {
                payload["loudness_db"] = String(format: "%.1f", db)
                payload["loudness_relative"] = turn.loudnessRelative ?? ""
            }
            if let above = turn.aboveFloorDB { payload["loudness_above_floor_db"] = String(format: "%.1f", above) }
            if let verdict = turn.verdict {
                payload["jev_choice"] = verdict.choice
                payload["jev_confidence"] = String(format: "%.2f", verdict.confidence)
            }
            await bus.publish(SignalMessage(kind: .event, domain: .scene, source: "Scene.Builder",
                                            type: isReady ? "scene.turn.ready" : "scene.turn.heard",
                                            subjectID: turn.id, revision: UInt64(turn.textRevision),
                                            causationID: snapshot.causes.last?.uuidString.lowercased(),
                                            payload: payload))
        }
        requestVerdicts(for: snapshot, bus: bus)
    }

    /// The situation in words, for a model: who is around and what was said lately, oldest first. The turn that is
    /// being handled right now is left out. Noise, Vera's own voice and turns without text are not shown. Unknown voices ARE shown, marked as such with the
    /// scene's estimate that it was the owner: the voice models can be wrong, so the model judges.
    func contextText(excluding turnID: String?) -> String {
        guard let content = snapshot?.content else { return "" }
        func role(_ role: SceneParticipant.Role) -> String {
            switch role { case .owner: return "владелец"; case .human: return "человек"; case .assistant: return "Вера"; case .unknown: return "неизвестный голос" }
        }
        func age(_ date: Date) -> String {
            let seconds = max(0, Int(Date().timeIntervalSince(date)))
            return seconds < 90 ? "\(seconds) с назад" : "\(seconds / 60) мин назад"
        }
        var lines = ["Рядом сейчас: " + (content.participants.isEmpty ? "никого не слышно"
                                          : content.participants.map { "\($0.label) (\(role($0.role)))" }.joined(separator: ", "))]
        let turns = content.turns.reversed().filter { turn in
            guard turn.id != turnID, !turn.text.isEmpty else { return false }
            switch turn.state {
            case .ready: return true
            case let .heard(reason): return reason == "not_addressed"
            case .awaiting: return false
            }
        }.suffix(6)
        if !turns.isEmpty {
            lines.append("Последние реплики (старые сверху):")
            for turn in turns {
                var kind = "фон"
                if case .ready = turn.state { kind = "к Вере" }
                var who = turn.speakerLabel ?? "кто-то (говорящий не определён)"
                if turn.speakerID == "unknown" {
                    who = "неопознанный голос" + (turn.ownerProbability.map { ", возможно владелец: \(Int(($0 * 100).rounded()))%" } ?? "")
                }
                lines.append("- \(who), \(kind), \(age(turn.endedAt)): \(String(turn.text.prefix(400)))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func snapshotReply(to query: SignalMessage) -> SignalMessage {
        var payload = snapshot?.payload ?? [:]
        let content = snapshot?.content
        payload["revision"] = snapshot.map { "\($0.revision)" } ?? "0"
        payload["status"] = (content?.status ?? .idle).rawValue
        payload["participants"] = (content?.participants ?? []).map { "\($0.label):\($0.role.rawValue)" }.joined(separator: ", ")
        payload["turn_count"] = "\(content?.turns.count ?? 0)"
        payload["context"] = contextText(excluding: query.payload["exclude_turn"].flatMap { $0.isEmpty ? nil : $0 })
        return SignalMessage(kind: .reply, domain: .scene, source: "Scene.Model", target: query.source,
                             type: "scene.snapshot", subjectID: "scene/main",
                             revision: snapshot?.revision, correlationID: query.id.uuidString,
                             causationID: query.id.uuidString.lowercased(), payload: payload)
    }

    /// Asks the judge about every turn that is waiting for a verdict on its current text.
    private func requestVerdicts(for snapshot: SceneSnapshot, bus: SignalBus) {
        guard let judge else { return }
        for turn in snapshot.content.turns where turn.needsVerdict {
            let key = "\(turn.id)#\(turn.textRevision)"
            guard requestedVerdicts.insert(key).inserted else { continue }
            let context = snapshot.content.turns
                .filter { $0.id != turn.id && $0.speakerID == turn.speakerID && !$0.text.isEmpty }
                .sorted { $0.endedAt < $1.endedAt }.suffix(6).map { "user: \($0.text)" }
            let id = turn.id, revision = turn.textRevision, text = turn.text
            judgeCalls += 1
            Task {
                let started = ContinuousClock.now
                do {
                    let answer = try await judge.judge(transcript: text, context: Array(context))
                    let wall = started.duration(to: .now)
                    verdicts.insert(VerdictRecord(turnID: id, text: text, choice: answer.choice, confidence: answer.confidence,
                                                  modelMilliseconds: answer.modelMilliseconds,
                                                  wallMilliseconds: Int(wall.components.seconds * 1_000 + wall.components.attoseconds / 1_000_000_000_000_000),
                                                  at: .now), at: 0)
                    if verdicts.count > 30 { verdicts.removeLast(verdicts.count - 30) }
                    await bus.publish(SignalMessage(kind: .event, domain: .scene, source: "Scene.Judge",
                                                    type: "scene.turn.verdict", subjectID: id,
                                                    payload: ["turn_id": id, "turn_revision": "\(revision)",
                                                              "choice": answer.choice,
                                                              "confidence": String(format: "%.3f", answer.confidence),
                                                              "model_ms": "\(answer.modelMilliseconds)"]))
                } catch {
                    judgeFailures += 1
                    // No verdict: the scene decides after its own timeout instead of waiting forever.
                }
            }
        }
    }

    private var latestEmbeddingRunID: String? {
        messages.first(where: { $0.type == "speaker.embedding.extracted" })?.payload["run_id"]
    }
}
