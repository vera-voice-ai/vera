import Foundation
import Testing
import Scene
import HarnessKit
import SignalBus

// A tiny synthetic scenario: one utterance with the wake word, one without, one ASR noise phrase.
// No owner is in the scenario. Only counts and ids are asserted; the text is never printed.

private let origin = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }

private func utterance(_ id: String, start: Double, end: Double, finalAt: Double, text: String) -> [SignalMessage] {
    [
        SignalMessage(source: "test", type: "speech.segment.started", timestamp: at(start), subjectID: id),
        SignalMessage(source: "test", type: "speech.segment.ended", timestamp: at(end), subjectID: id,
                      payload: ["reason": "silence"]),
        SignalMessage(source: "test", type: "speech.transcript.final", timestamp: at(finalAt), subjectID: id,
                      revision: 1, payload: ["lane": "raw", "text": text])
    ]
}

private let addressedID = "utterance/s1-seg1"
private let plainID = "utterance/s1-seg2"
private let noiseID = "utterance/s1-seg3"

private func syntheticScenario() -> Scenario {
    var messages = [SignalMessage(source: "test", type: "audio.microphone.started", timestamp: at(0))]
    messages += utterance(addressedID, start: 1, end: 3, finalAt: 3.5, text: "Вера, включи свет.")
    messages += utterance(plainID, start: 60, end: 62, finalAt: 62.5, text: "Погода сегодня хорошая.")
    messages += utterance(noiseID, start: 120, end: 121, finalAt: 121.5, text: "Продолжение следует")
    return Scenario(name: "synthetic", messages: messages)
}

private func configuration(_ name: String) -> Configuration {
    Configurations.all.first { $0.name == name }!
}

/// An open-gate configuration with a chosen judge, so the judge is the only difference between two runs.
private func openGate(judge: Judge?) -> Configuration {
    Configuration(name: "open-\(judge?.rawValue ?? "default")", judge: judge) { $0.requireOwnerPresent = false }
}

private func readyTurns(_ result: RunResult) -> [SceneTurn] {
    result.decisions.filter { if case .ready = $0.state { return true } else { return false } }
}

private func heardReasons(_ result: RunResult) -> [String] {
    result.decisions.compactMap { turn -> String? in
        if case let .heard(reason) = turn.state { return reason } else { return nil }
    }
}

@Test func ownerGateHoldsBackEverythingWithoutOwner() {
    let scenario = syntheticScenario()
    let baseline = Replayer.run(scenario, Configurations.baseline)
    let open = Replayer.run(scenario, configuration("noOwnerGate"))

    // The scenario has no verdicts, so the baseline judge is `none`.
    #expect(baseline.judge == .none)
    #expect(readyTurns(baseline).isEmpty)
    #expect(heardReasons(baseline).contains("owner_absent"))

    // Without the gate only the addressed turn is handed over, after the judge timeout.
    let ready = readyTurns(open)
    #expect(ready.count == 1)
    #expect(ready.first?.utteranceIDs == [addressedID])
    #expect(ready.first.map { if case let .ready(basis) = $0.state { basis } else { "" } } == "no_verdict")
    #expect(!heardReasons(open).contains("owner_absent"))
    #expect(Metrics(open).ready == 1)
    #expect(Metrics(open).utterances == 3)
}

@Test func alwaysCompleteHandsOverEarlierThanNoJudge() {
    let scenario = syntheticScenario()
    let none = Replayer.run(scenario, openGate(judge: Judge.none))
    let complete = Replayer.run(scenario, openGate(judge: .alwaysComplete))

    let early = readyTurns(complete).first, late = readyTurns(none).first
    #expect(early != nil && late != nil)
    #expect(complete.injectedVerdicts > 0)
    if let early, let late, let earlyAt = early.decidedAt, let lateAt = late.decidedAt {
        #expect(earlyAt < lateAt)
        // The verdict arrives 0.3 s after the text is final; the timeout is 3 s.
        #expect(earlyAt.timeIntervalSince(at(3.5)) < 1)
        #expect(lateAt.timeIntervalSince(at(3.5)) >= 3)
    }
    if case let .ready(basis)? = early?.state { #expect(basis == "jev") }
}

@Test func labelMetricsOnHandMadeLabels() {
    let result = Replayer.run(syntheticScenario(), openGate(judge: .alwaysComplete))

    // The scene hands over the addressed turn; the labels also say the plain one was addressed (a miss).
    let correct: [String: UtteranceLabel] = [
        addressedID: UtteranceLabel(utterance: addressedID, addressed: true, complete: true),
        plainID: UtteranceLabel(utterance: plainID, addressed: true, complete: true),
        noiseID: UtteranceLabel(utterance: noiseID, addressed: false, complete: nil)
    ]
    let good = Metrics(result, labels: correct)
    #expect(good.labelled)
    #expect(good.precision == 1.0)
    #expect(good.recall == 0.5)
    #expect(good.earlyCuts == 0)

    // The same ready turn labelled as not addressed and cut too early: precision 0, one early cut.
    let wrong: [String: UtteranceLabel] = [
        addressedID: UtteranceLabel(utterance: addressedID, addressed: false, complete: false)
    ]
    let bad = Metrics(result, labels: wrong)
    #expect(bad.precision == 0.0)
    #expect(bad.recall == nil)
    #expect(bad.earlyCuts == 1)

    // Without labels nothing is claimed.
    let unlabelled = Metrics(result)
    #expect(!unlabelled.labelled)
    #expect(unlabelled.precision == nil)
}

@Test func scoreboardContainsNoMessageText() {
    let scenario = syntheticScenario()
    let labels: [String: UtteranceLabel] = [addressedID: UtteranceLabel(utterance: addressedID, addressed: true, complete: true)]
    let base = Replayer.run(scenario, Configurations.baseline)
    let open = Replayer.run(scenario, configuration("noOwnerGate"))
    let rows = [
        ScoreRow(name: "baseline", metrics: Metrics(base, labels: labels), difference: nil),
        ScoreRow(name: "noOwnerGate", metrics: Metrics(open, labels: labels),
                 difference: ReadyDifference.between(baseline: base, configuration: open))
    ]
    let output = Scoreboard.markdown(title: "test", rows: rows)

    #expect(output.contains("| baseline |"))
    #expect(output.contains("noOwnerGate: 1 (1 only here, 0 only in baseline)"))
    for word in ["Вера", "включи", "свет", "Погода", "хорошая", "Продолжение", "следует"] {
        #expect(!output.contains(word))
    }
    for id in [addressedID, plainID, noiseID] {
        #expect(!output.contains(id))
    }
}
