import Foundation
import Scene
import SignalBus

/// Everything one replay produced. Holds decisions and utterance ids, never transcript text for output.
public struct RunResult: Sendable {
    public let scenario: String
    public let configuration: String
    public let judge: Judge
    public let durationSeconds: Double
    /// Ids of utterances that received `speech.segment.ended` in the scenario.
    public let endedUtterances: Set<String>
    /// Every turn the scene decided (ready or heard), in decision order.
    public let decisions: [SceneTurn]
    /// Turns still waiting when the replay ended.
    public let awaitingAtEnd: [SceneTurn]
    public let snapshots: Int
    /// Verdicts the replay injected (not the recorded ones).
    public let injectedVerdicts: Int

    public init(scenario: String, configuration: String, judge: Judge, durationSeconds: Double,
                endedUtterances: Set<String>, decisions: [SceneTurn], awaitingAtEnd: [SceneTurn],
                snapshots: Int, injectedVerdicts: Int) {
        self.scenario = scenario
        self.configuration = configuration
        self.judge = judge
        self.durationSeconds = durationSeconds
        self.endedUtterances = endedUtterances
        self.decisions = decisions
        self.awaitingAtEnd = awaitingAtEnd
        self.snapshots = snapshots
        self.injectedVerdicts = injectedVerdicts
    }
}

/// Feeds a scenario into a fresh SceneBuilder on a virtual clock. Ticks every 0.5 s of virtual time
/// between messages, and injects judge answers 0.3 s after each snapshot that asks for one.
public enum Replayer {
    static let tickInterval: TimeInterval = 0.5
    static let verdictDelay: TimeInterval = 0.3
    static let tailAfterLast: TimeInterval = 20

    public static func run(_ scenario: Scenario, _ configuration: Configuration) -> RunResult {
        let judge = configuration.resolvedJudge(for: scenario)
        var driver = Driver(builder: SceneBuilder(ttl: configuration.ttl()), judge: judge)
        var ended: Set<String> = []
        guard let first = scenario.messages.first, let last = scenario.messages.last else {
            return RunResult(scenario: scenario.name, configuration: configuration.name, judge: judge,
                             durationSeconds: 0, endedUtterances: [], decisions: [], awaitingAtEnd: [],
                             snapshots: 0, injectedVerdicts: 0)
        }
        driver.nextTick = first.timestamp
        for message in scenario.messages {
            // Only the recorded verdicts are replayed, and only under the `.recorded` policy.
            if message.type == "scene.turn.verdict", judge != .recorded { continue }
            driver.pump(until: message.timestamp)
            driver.ingest(message)
            if message.type == "speech.segment.ended", let id = message.subjectID { ended.insert(id) }
        }
        driver.pump(until: last.timestamp.addingTimeInterval(tailAfterLast))
        let awaiting = driver.lastContent?.turns.filter(\.isAwaiting) ?? []
        return RunResult(scenario: scenario.name, configuration: configuration.name, judge: judge,
                         durationSeconds: scenario.durationSeconds, endedUtterances: ended,
                         decisions: driver.decisions, awaitingAtEnd: awaiting,
                         snapshots: driver.snapshots, injectedVerdicts: driver.injected)
    }
}

private struct PendingVerdict {
    let due: Date
    let message: SignalMessage
}

private struct Driver {
    var builder: SceneBuilder
    let judge: Judge
    var nextTick = Date.distantPast
    var pending: [PendingVerdict] = []
    var scheduled: Set<String> = []
    var decisions: [SceneTurn] = []
    var lastContent: SceneContent?
    var snapshots = 0
    var injected = 0

    init(builder: SceneBuilder, judge: Judge) {
        self.builder = builder
        self.judge = judge
    }

    mutating func pump(until time: Date) {
        while true {
            let earliest = pending.indices.min { pending[$0].due < pending[$1].due }
            if let index = earliest, pending[index].due <= time, pending[index].due <= nextTick {
                let verdict = pending.remove(at: index)
                ingest(verdict.message)
            } else if nextTick <= time {
                absorb(builder.tick(now: nextTick))
                nextTick = nextTick.addingTimeInterval(Replayer.tickInterval)
            } else {
                break
            }
        }
    }

    mutating func ingest(_ message: SignalMessage) {
        absorb(builder.ingest(message))
    }

    mutating func absorb(_ snapshot: SceneSnapshot?) {
        guard let snapshot else { return }
        snapshots += 1
        decisions += snapshot.decisions
        lastContent = snapshot.content
        for turn in snapshot.content.turns where turn.needsVerdict {
            let key = "\(turn.id)#\(turn.textRevision)"
            guard let choice = judge.answer(for: turn.text), scheduled.insert(key).inserted else { continue }
            let message = SignalMessage(
                kind: .event, domain: .scene, source: "Harness.Judge", type: "scene.turn.verdict",
                timestamp: snapshot.at.addingTimeInterval(Replayer.verdictDelay), subjectID: turn.id,
                payload: ["turn_id": turn.id, "turn_revision": "\(turn.textRevision)",
                          "choice": choice, "confidence": "0.9"])
            pending.append(PendingVerdict(due: message.timestamp, message: message))
            injected += 1
        }
    }
}
