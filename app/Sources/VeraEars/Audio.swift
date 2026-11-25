import AVFoundation
import Foundation

/// Audio to 16 kHz mono float — what the ears take.
public enum AudioInput {
    public static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    public static func readFile(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: input)
        return try convert(input)
    }

    public static func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return [] }
        return try convert(buffer, with: converter)
    }

    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) throws -> [Float] {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard let ch = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}

/// The microphone. With `voiceProcessing` (Vera active): the system's echo cancellation, so Vera does not hear her own
/// voice and can be interrupted; other apps' sound is ducked (`duck`). Without it (recording,
/// waiting for «Вера»): a plain input — no glitch of the system's sound when it opens, nothing ducked.
/// Chunks arrive on the audio thread, already 16 kHz mono.
public final class Microphone: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    public private(set) var echoCancelling = false

    public init() {}

    public private(set) var voiceProcessing = true
    private var onChunk: (@Sendable ([Float], Float) -> Void)?
    private var observer: NSObjectProtocol?

    public func start(voiceProcessing: Bool = true, _ onChunk: @escaping @Sendable (_ samples: [Float], _ level: Float) -> Void) throws {
        self.onChunk = onChunk
        try open(voiceProcessing: voiceProcessing)
        // macOS stops the engine by itself, silently, when the audio hardware changes: the Mac sleeps and wakes, a
        // device comes or goes (AirPods, the iPad as a display). Without this the microphone stays open but deaf —
        // Vera waited for «Привет, Вера» all night and heard nothing. Opened again on the same settings.
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                              queue: nil) { [weak self] _ in self?.reopen() }
        }
    }

    private let reopenQueue = DispatchQueue(label: "vera.microphone.reopen")
    private var reopened: [Date] = []

    private func reopen() {
        reopenQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.onChunk != nil, !self.engine.isRunning else { return }
            // Opening may itself change the configuration (voice processing): never more than 3 times in 10 s.
            let now = Date()
            self.reopened = self.reopened.filter { now.timeIntervalSince($0) < 10 } + [now]
            guard self.reopened.count <= 3 else { NSLog("VERA-EARS микрофон: слишком часто меняется звук"); return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            do { try self.open(voiceProcessing: self.voiceProcessing) }
            catch { NSLog("VERA-EARS микрофон не открылся после смены звука: %@", error.localizedDescription) }
        }
    }

    private func open(voiceProcessing: Bool) throws {
        guard let onChunk else { return }
        self.voiceProcessing = voiceProcessing
        let input = engine.inputNode
        if voiceProcessing {
            do { try input.setVoiceProcessingEnabled(true); echoCancelling = input.isVoiceProcessingEnabled } catch { echoCancelling = false }
        }
        // Voice processing ducks every other sound by default — Vera's own voice too, almost to silence while the
        // microphone is open. Keep other audio at full level; echo cancellation still works.
        if echoCancelling {
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let format = input.outputFormat(forBus: 0)
        // With voice processing the input comes as several identical channels; the converter's own down-mix of
        // them gives silence, so channel 0 is taken first and only a mono stream is resampled.
        guard format.sampleRate > 0, let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                                             channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: AudioInput.format) else {
            throw NSError(domain: "Vera", code: 2, userInfo: [NSLocalizedDescriptionKey: "микрофон не вернул аудиоформат"])
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 1600, format: format) { buffer, _ in
            guard let src = buffer.floatChannelData,
                  let first = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
                  let dst = first.floatChannelData else { return }
            first.frameLength = buffer.frameLength
            dst[0].update(from: src[0], count: Int(buffer.frameLength))
            guard let samples = try? AudioInput.convert(first, with: converter), !samples.isEmpty else { return }
            var sum: Float = 0
            for s in samples { sum += s * s }
            onChunk(samples, (sum / Float(samples.count)).squareRoot())
        }
        engine.prepare()
        try engine.start()
    }

    /// How much other apps' sound is pushed down while echo cancellation is on: `strong` — as far as macOS goes (Vera
    /// listens), otherwise the least. Vera's own voice plays from another engine and is pushed down too, so this is not
    /// strong while she speaks. (Playing her voice through this engine is not possible on macOS: with voice processing
    /// the engine's output node has no format — 0 channels, 0 Hz — and a player there is "disconnected".)
    public func duck(strong: Bool) {
        let input = engine.inputNode
        guard echoCancelling, input.isVoiceProcessingEnabled else { return }   // a plain input ducks nothing
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: strong ? .max : .min)
    }

    public func stop() {
        onChunk = nil
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
