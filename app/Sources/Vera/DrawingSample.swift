import Foundation
import HermesBridge

/// Only for `--snapshot-flows` (a drawing check, never a normal run): one sample turn and a few seconds of sound,
/// so every lane and wave can be seen drawn. Real data never mixes with it — the snapshot process exits right after.
@MainActor enum DrawingSample {
    static func fill(board: BoardModel, voice: VoiceModel) {
        let now = Date().timeIntervalSince1970
        let t0 = now - 8
        var r = TurnRecorder(); r.session = "sample"
        r.phrase(start: t0, end: t0 + 2.1, decodeMs: 59)
        r.submitted(at: t0 + 2.2, ack: t0 + 2.24)
        func p(_ ts: Double, _ k: String, _ id: String, _ n: String? = nil) {
            r.pulse(PulseEvent(ts: ts, kind: k, session: "sample", callId: id, name: n, status: "ok"))
        }
        p(t0 + 2.3, "llm.start", "a"); p(t0 + 3.9, "llm.end", "a")
        p(t0 + 3.92, "tool.start", "t", "read_file"); p(t0 + 3.98, "tool.end", "t", "read_file")
        p(t0 + 4.0, "llm.start", "b")
        r.messageStarted(at: t0 + 4.4)
        p(t0 + 5.2, "llm.end", "b")
        r.voiceStarted(at: t0 + 4.8)
        r.messageCompleted(at: t0 + 5.2, voicePending: true)
        r.voiceIdle(at: t0 + 7.6)
        board.pulse.turns = r
        voice.drawingSample(now: now)
    }
}
