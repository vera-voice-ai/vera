import Foundation
import Testing
import Sensors

/// 160 ms chunk of 16 kHz audio.
private func chunk(_ amplitude: Float) -> [Float] { [Float](repeating: amplitude, count: 2_560) }

private func finalTime(silence: TimeInterval) -> Double? {
    var gate = LiveSpeechBuffer(finalSilenceDuration: silence)
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var t = 0.0
    // two seconds of speech
    for _ in 0..<13 { _ = gate.append(samples16k: chunk(0.05), rms: 0.05, at: base.addingTimeInterval(t)); t += 0.16 }
    let lastVoice = t - 0.16
    // then silence, until the utterance closes
    for _ in 0..<40 {
        if case let .final(_, _, _, reason)? = gate.append(samples16k: chunk(0), rms: 0, at: base.addingTimeInterval(t)) {
            #expect(reason == "silence")
            return t - lastVoice
        }
        t += 0.16
    }
    return nil
}

@Test func theGateClosesAnUtteranceAfterTheConfiguredSilence() {
    for silence in [0.5, 1.0, 2.0] {
        let waited = finalTime(silence: silence)
        #expect(waited != nil)
        // The close happens on the first chunk at or past the silence: within one chunk (0.16 s) of it.
        #expect((waited ?? 0) >= silence && (waited ?? 0) < silence + 0.17)
    }
}

@Test func theDefaultGateIsOneSecond() {
    let waited = finalTime(silence: LiveSpeechBuffer().finalSilenceForTests)
    #expect((waited ?? 0) >= 1.0 && (waited ?? 0) < 1.17)
}

@Test func aPauseShorterThanTheGateDoesNotSplitTheUtterance() {
    var gate = LiveSpeechBuffer(finalSilenceDuration: 1.0)
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var t = 0.0
    var finals = 0
    func feed(_ amplitude: Float, _ count: Int) {
        for _ in 0..<count {
            if case .final? = gate.append(samples16k: chunk(amplitude), rms: amplitude, at: base.addingTimeInterval(t)) { finals += 1 }
            t += 0.16
        }
    }
    feed(0.05, 10); feed(0, 4)      // 0.64 s pause: shorter than the gate
    feed(0.05, 10); feed(0, 12)     // then the real end
    #expect(finals == 1)
}
