import Foundation

/// A recorded voice message (a Telegram voice note, any file macOS reads) → text with GigaAM from the box.
/// GigaAM is trained on short utterances, so the recording is cut into phrases by Silero VAD — the same mechanics as
/// the live ears — and every phrase is decoded whole. Used by `Vera --transcribe` for Hermes' `vera-ears` plugin.
public enum VoiceNote {
    /// Longest piece handed to GigaAM at once; a longer phrase is cut there.
    public static let maxPhrase = 20 * Listener.sampleRate

    public static func transcribe(file: URL, runtime: EarsRuntime) throws -> String {
        try transcribe(AudioInput.readFile(file), runtime: runtime)
    }

    public static func transcribe(_ samples: [Float], runtime: EarsRuntime) throws -> String {
        let gate = try SileroGate(runtime: runtime, minSilence: 0.5, maxSpeech: 30)
        let giga = try GigaAMRecognizer(runtime: runtime, threads: 4)
        return phrases(samples, gate: gate).map { giga.decode($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The pieces with voice in them, each with 0.3 s before it (word onsets), at most `maxPhrase` long.
    static func phrases(_ samples: [Float], gate: VoiceGate) -> [[Float]] {
        let w = Listener.window, prerollLimit = Listener.sampleRate * 3 / 10
        var out: [[Float]] = [], phrase: [Float] = [], preroll: [Float] = []
        var inPhrase = false
        // A second of silence after the recording: the last phrase ends like a speaker who stopped talking.
        let audio = samples + [Float](repeating: 0, count: Listener.sampleRate)
        var i = 0
        while i + w <= audio.count {
            let win = Array(audio[i..<i + w]); i += w
            let (speaking, ended) = gate.accept(win)
            if inPhrase {
                phrase += win
                if ended || !speaking || phrase.count >= maxPhrase { out.append(phrase); phrase = []; inPhrase = false }
            } else {
                preroll += win
                if preroll.count > prerollLimit { preroll.removeFirst(preroll.count - prerollLimit) }
                if speaking { inPhrase = true; phrase = preroll; preroll = [] }
            }
        }
        if inPhrase, !phrase.isEmpty { out.append(phrase) }
        return out
    }
}
