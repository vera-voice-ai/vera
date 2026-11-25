import Foundation
import Testing
@testable import SileroVoice

/// The phone's Silero against the original Python. `golden.json` was made by the original model
/// (scripts/build-mouth-ios.sh → export.py): text → prepared → after homographs → accented → ids.
/// The voice files come from the build (`~/.vera03/build/mouth-ios/out`, not in git); without them these tests are
/// skipped. No network, no model calls beyond local ONNX.
enum VoiceFiles {
    static var dir: URL? {
        let env = ProcessInfo.processInfo.environment["VERA_MOUTH_IOS"]
        let d = env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".vera03/build/mouth-ios/out")
        return SileroVoice.isComplete(d) ? d : nil
    }
    /// onnxruntime from the ears' build (the same dylib the app carries).
    static var onnxruntime: URL? {
        let u = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".vera03/build/ears/lib/lib/libonnxruntime.dylib")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    static let text: SileroText? = dir.flatMap { try? SileroText(dir: $0) }
    static let voice: SileroVoice? = {
        guard let d = dir, let lib = onnxruntime else { return nil }
        try? OnnxRuntime.load(dylib: lib)
        return try? SileroVoice(dir: d)
    }()

    struct Case: Decodable { let text, prepared, homo, accented: String; let ids: [Int64] }
    static let golden: [Case] = {
        guard let url = Bundle.module.url(forResource: "golden", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Case].self, from: data)) ?? []
    }()
}

/// Homographs answered from the golden "after homographs" text: lets the n-gram accentor and the tokenizer path be
/// checked without onnxruntime.
@Suite struct SileroTextTests {
    @Test(.enabled(if: VoiceFiles.text != nil)) func preparesLikeTheOriginal() throws {
        let t = try #require(VoiceFiles.text)
        #expect(VoiceFiles.golden.count >= 30)
        for c in VoiceFiles.golden { #expect(t.prepare(c.text) == c.prepared, "\(c.text)") }
    }

    @Test(.enabled(if: VoiceFiles.text != nil)) func accentsLikeTheOriginal() throws {
        let t = try #require(VoiceFiles.text)
        for c in VoiceFiles.golden {
            #expect(t.accentor.accent(c.homo) == c.accented, "\(c.homo)")
            #expect(t.ids(accented: c.accented) == c.ids, "\(c.accented)")
        }
    }

    @Test(.enabled(if: VoiceFiles.text != nil)) func homographWordsAndTokens() throws {
        let t = try #require(VoiceFiles.text)
        let s = Array("мой замок, а +я".unicodeScalars)
        #expect(Homographs.words(s).map { str(s[$0.start..<$0.end]) } == ["мой", "замок", "а", "+я"])
        let ids = t.homographs.tokenizer.encode("мой [HOMO] замок [/HOMO] на двери.")
        #expect(ids.first == t.homographs.tokenizer.cls && ids.last == t.homographs.tokenizer.sep)
        #expect(ids.contains(t.homographs.startId) && ids.contains(t.homographs.endId))
    }

    @Test func durationRules() {
        let d = SileroVoice.durations([2.5, 0.1, -3, 1.0986123, 4, 1.0986123])  // exp-1: 11.2, .1, <0, 2, 53.6, 2
        #expect(d == [5, 0, 0, 2, 13, 2])  // first ≤ 5, last ≤ 7, one before it = 13, third from end ≤ 13
    }
}

@Suite struct SileroVoiceTests {
    @Test(.enabled(if: VoiceFiles.voice != nil)) func homographsLikeTheOriginal() throws {
        let v = try #require(VoiceFiles.voice)
        for c in VoiceFiles.golden { #expect(try v.text.homographs.solve(c.prepared, scorer: v) == c.homo, "\(c.prepared)") }
    }

    /// The whole voice against the original's audio for one sentence (written by the build script).
    @Test(.enabled(if: VoiceFiles.voice != nil)) func speaksLikeTheOriginal() throws {
        let v = try #require(VoiceFiles.voice), dir = try #require(VoiceFiles.dir)
        let refURL = dir.appending(path: "reference.f32")
        let sentence = try String(contentsOf: dir.appending(path: "reference.txt"), encoding: .utf8)
        let ref = try Data(contentsOf: refURL).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let audio = try v.synthesize(sentence)
        #expect(audio.count == ref.count)
        let diff = zip(audio, ref).map { abs($0 - $1) }.max() ?? 1
        #expect(diff < 2e-3, "max diff \(diff)")
    }
}
