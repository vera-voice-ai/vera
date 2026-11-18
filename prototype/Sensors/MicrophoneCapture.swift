import Accelerate
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
    private var sourceRate: Double = 0
    private var sourcePending: [Float] = []
    private var handler: (@Sendable (MicrophoneChunk) -> Void)?
    private var voiceProcessingActive = false
    private let chunkSamples = 2_560
    private var lowPassKernel: [Float] = []
    private var lowPassHistory: [Float] = []

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
        self.sourceRate = sourceFormat.sampleRate
        self.lowPassKernel = Self.lowPassKernel(sourceRate: sourceFormat.sampleRate)
        self.lowPassHistory = [Float](repeating: 0, count: max(0, lowPassKernel.count - 1))
        self.handler = onChunk
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
            sourcePending.removeAll(keepingCapacity: false)
        }
    }

    private func consume(_ input: AVAudioPCMBuffer) {
        appendSourceSamples(input)
        let sourceChunkSamples = max(2, Int((sourceRate * 0.16).rounded()))
        while sourcePending.count >= sourceChunkSamples {
            let sourceSamples = Array(sourcePending.prefix(sourceChunkSamples))
            sourcePending.removeFirst(sourceChunkSamples)
            let samples = Self.resample(antiAlias(sourceSamples), from: sourceRate, outputCount: chunkSamples)
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

    /// Low-pass before decimation: without it, content above 8 kHz in a 48 kHz
    /// capture folds back into the 0–8 kHz speech band and degrades ASR and
    /// speaker embeddings. Stateful across chunks, so there is no seam per 160 ms.
    private func antiAlias(_ input: [Float]) -> [Float] {
        guard lowPassKernel.count > 1 else { return input }
        let padded = lowPassHistory + input
        lowPassHistory = Array(padded.suffix(lowPassKernel.count - 1))
        // Symmetric kernel, so vDSP correlation equals convolution.
        return vDSP.convolve(padded, withKernel: lowPassKernel)
    }

    /// Hann-windowed sinc, cutoff 7.2 kHz (below the 8 kHz Nyquist of 16 kHz output).
    private static func lowPassKernel(sourceRate: Double) -> [Float] {
        guard sourceRate > 16_001 else { return [] }
        let taps = 63
        let cutoff = 7_200 / sourceRate
        let mid = Double(taps - 1) / 2
        var kernel = (0..<taps).map { index -> Double in
            let x = Double(index) - mid
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            let window = 0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(taps - 1))
            return sinc * window
        }
        let sum = kernel.reduce(0, +)
        kernel = kernel.map { $0 / sum }
        return kernel.map(Float.init)
    }

    /// Linear-interpolation downsampler in the style of Vera 1 (`AcousticEchoDetector.resample`):
    /// deterministic, no OS converter involved.
    private static func resample(_ input: [Float], from sourceRate: Double, outputCount: Int) -> [Float] {
        guard input.count >= 2, sourceRate > 0, outputCount > 0 else {
            return [Float](repeating: 0, count: max(outputCount, 0))
        }
        if abs(sourceRate - 16_000) < 1 {
            if input.count >= outputCount { return Array(input.prefix(outputCount)) }
            return input + [Float](repeating: 0, count: outputCount - input.count)
        }
        let step = sourceRate / 16_000
        var output: [Float] = []
        output.reserveCapacity(outputCount)
        for index in 0..<outputCount {
            let position = Double(index) * step
            let lower = min(input.count - 1, Int(position))
            let upper = min(input.count - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            output.append(input[lower] * (1 - fraction) + input[upper] * fraction)
        }
        return output
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
