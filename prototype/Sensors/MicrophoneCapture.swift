import AVFoundation
import Foundation

public struct MicrophoneChunk: Sendable {
    public let samples16k: [Float]
    public let waveform: [Float]
    public let rms: Float
    public let peak: Float
    public let inputSampleRate: Double
    public let voiceProcessingActive: Bool
}

/// Optional local microphone source. Raw PCM stays in-process and is never published on Signal Bus.
public final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "vera.sensors.microphone.capture", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var sourceRate: Double = 0
    private var pending: [Float] = []
    private var sourcePending: [Float] = []
    private var handler: (@Sendable (MicrophoneChunk) -> Void)?
    private var voiceProcessingActive = false
    private let chunkSamples = 2_560

    public init() {}

    @discardableResult
    public func start(onChunk: @escaping @Sendable (MicrophoneChunk) -> Void) throws -> Bool {
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
            voiceProcessingActive = input.isVoiceProcessingEnabled
        } catch {
            voiceProcessingActive = false
        }
        let sourceFormat = input.outputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw NSError(domain: "VeraMicrophone", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Микрофон не вернул аудиоформат"])
        }
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw NSError(domain: "VeraMicrophone", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Не удалось подготовить преобразование аудиопотока"])
        }
        self.converter = converter
        self.sourceRate = sourceFormat.sampleRate
        self.handler = onChunk
        self.pending.removeAll(keepingCapacity: true)
        self.sourcePending.removeAll(keepingCapacity: true)
        input.installTap(onBus: 0, bufferSize: 1_024, format: sourceFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        do { try engine.start() }
        catch {
            input.removeTap(onBus: 0)
            self.handler = nil
            throw error
        }
        return voiceProcessingActive
    }

    public func stop() {
        queue.sync {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
            handler = nil
            converter = nil
            pending.removeAll(keepingCapacity: false)
            sourcePending.removeAll(keepingCapacity: false)
        }
    }

    private func consume(_ input: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / max(1, sourceRate) + 256)
        guard let output = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                                      sampleRate: 16_000, channels: 1,
                                                                      interleaved: false)!,
                                               frameCapacity: capacity) else { return }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        appendSourceSamples(input)
        guard status != .error, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        let sourceChunkSamples = max(1, Int((sourceRate * 0.16).rounded()))
        while pending.count >= chunkSamples && sourcePending.count >= sourceChunkSamples {
            let samples = Array(pending.prefix(chunkSamples))
            pending.removeFirst(chunkSamples)
            let sourceSamples = Array(sourcePending.prefix(sourceChunkSamples))
            sourcePending.removeFirst(sourceChunkSamples)
            var peak: Float = 0
            var sum: Double = 0
            for sample in sourceSamples {
                let magnitude = abs(sample)
                peak = max(peak, magnitude)
                sum += Double(sample * sample)
            }
            let bins = 96
            let stride = max(1, sourceSamples.count / bins)
            var waveform: [Float] = []
            waveform.reserveCapacity(bins)
            for start in Swift.stride(from: 0, to: sourceSamples.count, by: stride) {
                waveform.append(sourceSamples[start])
            }
            handler?(MicrophoneChunk(samples16k: samples, waveform: waveform,
                                     rms: Float((sum / Double(sourceSamples.count)).squareRoot()),
                                     peak: peak, inputSampleRate: sourceRate,
                                     voiceProcessingActive: voiceProcessingActive))
        }
    }

    private func appendSourceSamples(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        if let channels = buffer.floatChannelData {
            let count = Int(buffer.format.channelCount)
            for frame in 0..<frames {
                var mono: Float = 0
                for channel in 0..<count { mono += channels[channel][frame] }
                sourcePending.append(mono / Float(max(1, count)))
            }
        } else if let channels = buffer.int16ChannelData {
            let count = Int(buffer.format.channelCount)
            for frame in 0..<frames {
                var mono: Float = 0
                for channel in 0..<count { mono += Float(channels[channel][frame]) / 32768 }
                sourcePending.append(mono / Float(max(1, count)))
            }
        }
    }
}
