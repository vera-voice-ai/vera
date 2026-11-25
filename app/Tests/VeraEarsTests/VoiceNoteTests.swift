import Foundation
import Testing
@testable import VeraEars

/// Speech while the window is loud; the phrase ends on the first quiet window.
fileprivate final class LevelGate: VoiceGate {
    func accept(_ w: [Float]) -> (speaking: Bool, ended: Bool) { ((w.map(abs).max() ?? 0) > 0.1, false) }
    func reset() {}
}

@Suite struct VoiceNoteTests {
    let rate = Listener.sampleRate

    @Test func cutsTheRecordingIntoPhrasesWithPreroll() {
        let quiet = [Float](repeating: 0, count: rate), voice = [Float](repeating: 0.5, count: rate)
        let pieces = VoiceNote.phrases(quiet + voice + quiet + voice, gate: LevelGate())
        #expect(pieces.count == 2)
        // each piece: 0.3 s before the voice, the voice, one closing window
        for p in pieces { #expect(abs(p.count - (rate * 3 / 10 + rate)) <= 2 * Listener.window) }
    }

    @Test func longSpeechIsCutAtMaxPhrase() {
        let pieces = VoiceNote.phrases([Float](repeating: 0.5, count: VoiceNote.maxPhrase * 2 + rate), gate: LevelGate())
        #expect(pieces.count == 3)
        #expect(pieces.allSatisfy { $0.count <= VoiceNote.maxPhrase })
    }

    @Test func silenceGivesNothing() {
        #expect(VoiceNote.phrases([Float](repeating: 0, count: rate * 3), gate: LevelGate()).isEmpty)
    }
}
