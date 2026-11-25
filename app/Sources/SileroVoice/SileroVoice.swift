import Foundation

/// Vera's voice — Silero TTS v5 (ru), the same model as the Mac's mouth, without Python: the text side in Swift
/// (`SileroText`) and three ONNX networks exported from `v5_ru.pt` by `scripts/build-mouth-ios.sh`:
///   silero-encoder.onnx  symbol ids, speaker → log durations, conditioned encoder rows (with pitch)
///   silero-decoder.onnx  rows repeated by duration → 48 kHz audio (decoder, mel, vocoder and ISTFT inside)
///   silero-homo.onnx     the homograph BERT
/// The export is checked against the original (tests in the build script): same audio to ~1e-4.
public final class SileroVoice: @unchecked Sendable {
    public static let sampleRate = 48_000
    public static let files = ["silero-encoder.onnx", "silero-decoder.onnx", "silero-homo.onnx",
                               "silero-text.json", "silero-ngrams.txt", "silero-ngrams.bin"]

    public let text: SileroText
    private let encoder: OnnxModel, decoder: OnnxModel, homo: OnnxModel

    /// True when `dir` has every file of the voice.
    public static func isComplete(_ dir: URL) -> Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: dir.appending(path: $0).path) }
    }

    /// onnxruntime must be ready (`OnnxRuntime.load` / `.use`). Loading takes a second or two.
    public init(dir: URL, threads: Int = 2) throws {
        text = try SileroText(dir: dir)
        encoder = try OnnxModel(url: dir.appending(path: "silero-encoder.onnx"), threads: threads)
        decoder = try OnnxModel(url: dir.appending(path: "silero-decoder.onnx"), threads: threads)
        homo = try OnnxModel(url: dir.appending(path: "silero-homo.onnx"), threads: threads)
    }

    /// One sentence (already through `SpeechText.forVoice`) → mono float samples at 48 kHz; empty when there is
    /// nothing to say.
    public func synthesize(_ sentence: String, speaker: String = "baya") throws -> [Float] {
        guard let prepared = text.prepare(sentence) else { return [] }
        let ids = text.ids(accented: try text.accent(prepared, scorer: self))
        guard ids.count >= 4 else { return [] }
        let spk = Int64(text.speakers[speaker] ?? text.speakers["baya"] ?? 1)
        let enc = try encoder.run([.int64("seq", ids, [1, Int64(ids.count)]), .int64("speaker", [spk], [1])],
                                  outputs: ["log_dur", "cond"])
        let durs = Self.durations(enc[0].data)
        let width = Int(enc[1].shape.last ?? 128)
        var frames: [Float] = []
        frames.reserveCapacity(durs.reduce(0, +) * width)
        for (t, d) in durs.enumerated() where d > 0 {
            let row = enc[1].data[(t * width)..<((t + 1) * width)]
            for _ in 0..<d { frames.append(contentsOf: row) }
        }
        let count = frames.count / width
        guard count >= 8 else { return [] }
        let audio = try decoder.run([.float("frames", frames, [1, Int64(count), Int64(width)])], outputs: ["audio"])
        return audio[0].data
    }

    /// The original's duration rules for a plain sentence: exp − 1, no negatives, rounded half to even, the first
    /// symbol ≤ 5 frames, the last ≤ 7, the one before it exactly 13, the third from the end ≤ 13.
    static func durations(_ logDur: [Float]) -> [Int] {
        var d = logDur.map { max(Foundation.exp($0) - 1, 0).rounded(.toNearestOrEven) }
        let n = d.count
        guard n >= 3 else { return d.map { Int($0) } }
        d[0] = min(d[0], 5); d[n - 1] = min(d[n - 1], 7); d[n - 2] = 13; d[n - 3] = min(d[n - 3], 13)
        return d.map { Int($0) }
    }
}

extension SileroVoice: HomographScorer {
    public func homographLogits(ids: [[Int64]], starts: [Int64], ends: [Int64]) throws -> [Float] {
        let n = ids.count, l = ids.first?.count ?? 0
        let out = try homo.run([.int64("input_ids", ids.flatMap { $0 }, [Int64(n), Int64(l)]),
                                .int64("start", starts, [Int64(n)]), .int64("end", ends, [Int64(n)])],
                               outputs: ["logit"])
        return out[0].data
    }
}
