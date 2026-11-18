import AVFoundation
import Foundation

/// Plays a WAV file into the sensor pipeline as if it were the microphone: 160 ms chunks of
/// 16 kHz mono audio at real-time pace, followed by a few seconds of silence so that the
/// speech gate closes and the last utterance is finalized. It makes the app drivable
/// without a person, a speaker or a microphone, for example from a launch argument.
public final class FileAudioFeed: @unchecked Sendable {
    private final class State: @unchecked Sendable { var cursor = 0 }

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "vera.sensors.file-feed", qos: .userInitiated)

    public init() {}

    public func start(url: URL, trailingSilenceSeconds: Double = 4,
                      onChunk: @escaping @Sendable (MicrophoneChunk) -> Void,
                      onFinished: @escaping @Sendable () -> Void) throws {
        let samples = try Self.load16k(url)
        let chunkSamples = 2_560
        let total = samples.count + Int(trailingSilenceSeconds * 16_000)
        let state = State()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.2, repeating: .milliseconds(160))
        source.setEventHandler { [weak self] in
            guard state.cursor < total else {
                self?.stop()
                onFinished()
                return
            }
            var chunk = [Float](repeating: 0, count: chunkSamples)
            let end = min(state.cursor + chunkSamples, samples.count)
            if state.cursor < end { chunk.replaceSubrange(0..<(end - state.cursor), with: samples[state.cursor..<end]) }
            state.cursor += chunkSamples
            var peak: Float = 0
            var sum: Double = 0
            for value in chunk { peak = max(peak, abs(value)); sum += Double(value * value) }
            let stride = max(1, chunkSamples / 96)
            let waveform = Swift.stride(from: 0, to: chunkSamples, by: stride).map { chunk[$0] }
            onChunk(MicrophoneChunk(samples16k: chunk, waveform: waveform,
                                    rms: Float((sum / Double(chunkSamples)).squareRoot()), peak: peak,
                                    inputSampleRate: 16_000, voiceProcessingActive: false))
        }
        timer = source
        source.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private static func load16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "VeraFileFeed", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось открыть аудиофайл"])
        }
        try file.read(into: input)
        let ratio = 16_000 / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw NSError(domain: "VeraFileFeed", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось выделить буфер"])
        }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
