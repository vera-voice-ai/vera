import Accelerate
import AVFoundation
import CSherpaPhone
import Foundation

/// The phone's ears, all on the phone: Silero VAD finds where a phrase begins and ends, GigaAM v3 reads it (live text
/// every half second while it lasts, the whole phrase at its end). Mechanics, no meaning: the text goes to Hermes.
/// Runs on its own queue; events come back on the main actor.
final class Ears: @unchecked Sendable {
    enum Event: Sendable {
        case speaking(Bool)
        case partial(String, decodeMs: Int)
        case final(String, seconds: Double, decodeMs: Int)
        /// One spectrogram column (64 bands 0–8 kHz) and the window's loudness 0…1, every 32 ms.
        case column([Float], level: Float)
    }

    static let rate = 16_000
    static let window = 512
    let version: String

    private let vad: UnsafeMutableRawPointer
    private let giga: UnsafeMutableRawPointer
    private let queue = DispatchQueue(label: "vera.ears", qos: .userInitiated)
    private var pending: [Float] = []
    private var preroll: [Float] = []
    private var phrase: [Float] = []
    private var inPhrase = false
    private var sinceDecode = 0
    /// Windows read so far (the journal's heartbeat: are the ears still fed?).
    private var windows = 0
    /// Since the last look: the loudest window the ears got (RMS) and how many windows the VAD called speech.
    private var loudest: Float = 0
    private var speechWindows = 0
    /// Samples that were not finite numbers (NaN, ±∞) — never given to the VAD: one such value spoils its recurrent
    /// state for good, and it never says «speech» again.
    private var nonFinite = 0
    var processed: Int { queue.sync { windows } }
    /// Windows read so far, the loudest window, the speech windows and the non-finite samples since the last call.
    func health() -> (windows: Int, loudest: Float, speech: Int, nonFinite: Int) {
        queue.sync { defer { loudest = 0; speechWindows = 0; nonFinite = 0 }; return (windows, loudest, speechWindows, nonFinite) }
    }
    private let onEvent: @Sendable (Event) -> Void
    /// Someone looks at the screen: the words as they are spoken (a decode of the whole phrase every half second) and
    /// the spectrogram (an FFT 31 times a second). In the background nobody sees them — only the phrase at its end is
    /// decoded; heard all day around people, the partial decodes alone ate a core and iOS killed the app.
    private var live = true
    func setLive(_ on: Bool) { queue.async { [self] in live = on } }
    /// Vera waits for «Привет, Вера»: the first seconds of a phrase are decoded as it goes even with the screen off, so
    /// she wakes on the words without waiting for the pause after them. Bounded (`wakeWindow`): a long talk nearby is
    /// decoded only at its end, as before.
    private var wakeWatch = false
    func setWakeWatch(_ on: Bool) { queue.async { [self] in wakeWatch = on } }
    static let wakeWindow = 4 * rate

    /// Sound kept before the VAD says «speech»: it says so a few hundred ms late, and «Привет» must not be cut to «т».
    static let prerollLimit = rate * 8 / 10
    static let partialEvery = rate / 2
    static let maxPhrase = 20 * rate

    enum Failure: LocalizedError {
        case model(String)
        var errorDescription: String? { if case .model(let m) = self { "модель \(m) не загрузилась" } else { nil } }
    }

    /// `threshold`: Silero VAD's speech probability; higher is stricter (wind, engine), lower hears quiet speech.
    init(threshold: Float = 0.5, onEvent: @escaping @Sendable (Event) -> Void) throws {
        guard let dir = Bundle.main.url(forResource: "Models", withExtension: nil) else { throw Failure.model("папка Models") }
        guard let v = vera_vad_create(dir.appending(path: "vad/silero_vad.onnx").path, threshold, 0.5, 0.25, 20) else { throw Failure.model("Silero VAD") }
        guard let g = vera_offline_create_nemo_ctc(dir.appending(path: "gigaam/model.int8.onnx").path,
                                                   dir.appending(path: "gigaam/tokens.txt").path, 64, 2) else {
            vera_vad_destroy(v); throw Failure.model("GigaAM")
        }
        vad = v; giga = g
        version = String(cString: vera_sherpa_version())
        self.onEvent = onEvent
    }

    deinit { vera_vad_destroy(vad); vera_offline_destroy(giga) }

    /// 16 kHz mono from the microphone, any chunk size.
    func feed(_ samples: [Float]) {
        queue.async { [self] in
            pending += samples
            while pending.count >= Self.window {
                let w = Array(pending.prefix(Self.window))
                pending.removeFirst(Self.window)
                step(w)
            }
        }
    }

    /// Drop what is being heard (the phrase is cancelled, e.g. the listening was switched off).
    func reset() {
        queue.async { [self] in
            vera_vad_reset(vad)
            pending.removeAll(); preroll.removeAll(); phrase.removeAll()
            if inPhrase { inPhrase = false; onEvent(.speaking(false)) }
        }
    }

    private func step(_ raw: [Float]) {
        windows += 1
        var w = raw
        for i in w.indices where !w[i].isFinite { w[i] = 0; nonFinite += 1 }
        var sum: Float = 0
        for x in w { sum += x * x }
        let rms = (sum / Float(w.count)).squareRoot()
        loudest = max(loudest, rms)
        if live { onEvent(.column(Spectrum.column(w), level: min(1, rms * 8))) }
        w.withUnsafeBufferPointer { vera_vad_accept(vad, $0.baseAddress, Int32($0.count)) }
        let ended = vera_vad_pop_all(vad) > 0
        let speaking = vera_vad_detected(vad) != 0
        if speaking { speechWindows += 1 }
        if inPhrase {
            phrase += w
            sinceDecode += w.count
            if ended || !speaking || phrase.count >= Self.maxPhrase {
                finish()
            } else if live || (wakeWatch && phrase.count <= Self.wakeWindow), sinceDecode >= Self.partialEvery {
                sinceDecode = 0
                let r = decode(phrase)
                if !r.text.isEmpty { onEvent(.partial(r.text, decodeMs: r.ms)) }
            }
        } else {
            preroll += w
            if preroll.count > Self.prerollLimit { preroll.removeFirst(preroll.count - Self.prerollLimit) }
            if speaking {
                inPhrase = true
                phrase = preroll; preroll.removeAll()
                sinceDecode = 0
                onEvent(.speaking(true))
            }
        }
    }

    private func finish() {
        let audio = phrase
        phrase.removeAll(); inPhrase = false
        onEvent(.speaking(false))
        let r = decode(audio)
        onEvent(.final(r.text, seconds: Double(audio.count) / Double(Self.rate), decodeMs: r.ms))
    }

    private func decode(_ s: [Float]) -> (text: String, ms: Int) {
        let t0 = DispatchTime.now()
        let p = s.withUnsafeBufferPointer { vera_offline_decode(giga, $0.baseAddress, Int32($0.count), Int32(Self.rate)) }
        let text = p.map { String(cString: $0) } ?? ""
        vera_sherpa_free(p)
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), Int((DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000))
    }
}

/// 64 bands 0–8 kHz of the last 32 ms, 0…1 — the spectrogram's column. Same idea as the Mac's «Сенсоры».
enum Spectrum {
    static let bands = 64
    private static let n = 512
    nonisolated(unsafe) private static let fft = vDSP.FFT(log2n: 9, radix: .radix2, ofType: DSPSplitComplex.self)!
    private static let hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)

    static func column(_ x: [Float]) -> [Float] {
        guard x.count >= n else { return [Float](repeating: 0, count: bands) }
        let w = vDSP.multiply(Array(x.suffix(n)), hann)
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                w.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                }
                fft.forward(input: split, output: &split)
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        let per = (n / 2) / bands
        return (0..<bands).map { b in
            let m = mags[(b * per)..<((b + 1) * per)].max() ?? 0
            return max(0, min(1, (20 * log10(max(m, 1e-6)) + 20) / 60))
        }
    }
}

/// `--ears-file <audio>` (debug launch argument): the recording through the same ears, results to the log —
/// a check of the iOS build of sherpa-onnx and GigaAM without speaking into the phone.
enum EarsFileCheck {
    static func runIfAsked() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--ears-file"), i + 1 < args.count else { return }
        let url = URL(filePath: args[i + 1])
        DispatchQueue.global().async {
            do {
                let file = try AVAudioFile(forReading: url)
                guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return }
                try file.read(into: buf)
                let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
                let conv = AVAudioConverter(from: buf.format, to: target)!
                let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * 16_000 / buf.format.sampleRate) + 1024)!
                var given = false
                conv.convert(to: out, error: nil) { _, st in
                    if given { st.pointee = .endOfStream; return nil }
                    given = true; st.pointee = .haveData; return buf
                }
                let samples = Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
                let ears = try Ears { e in
                    switch e {
                    case .final(let t, let s, let ms): NSLog("VERA-EARS final «%@» %.1fs %dms", t, s, ms)
                    case .partial(let t, _): NSLog("VERA-EARS partial «%@»", t)
                    default: break
                    }
                }
                NSLog("VERA-EARS file %.1fs sherpa %@", Double(samples.count) / 16_000, ears.version)
                ears.feed(samples + [Float](repeating: 0, count: 16_000))
                Thread.sleep(forTimeInterval: 8)
            } catch { NSLog("VERA-EARS error %@", error.localizedDescription) }
        }
    }
}
