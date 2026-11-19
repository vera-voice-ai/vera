import Accelerate
import Foundation

public struct LiveSpectrumFrame: Sendable {
    public let timestamp: Date
    /// Linear-frequency bands from 0 Hz to the 16 kHz PCM Nyquist limit (8 kHz).
    /// Values are band peak levels in dBFS, clamped to [-100, 0].
    public let bandsDBFS: [Float]
}

/// Produces one bounded spectrum frame from each microphone PCM chunk.
/// Calls are serialized internally; callers should run `analyze` off the audio and UI threads.
public final class LiveSpectrumAnalyzer: @unchecked Sendable {
    public static let sampleRate = 16_000
    public static let fftSize = 4_096
    public static let bandCount = 128

    private let lock = NSLock()
    private let fftSetup: FFTSetup?
    private let log2Size = vDSP_Length(12)
    private let window: [Float]
    private let windowSum: Float
    private var rollingSamples: [Float] = []
    private var activeSessionID: Int?

    public init() {
        fftSetup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))
        window = (0..<Self.fftSize).map { index in
            0.5 - 0.5 * cos(2 * .pi * Float(index) / Float(Self.fftSize - 1))
        }
        windowSum = window.reduce(0, +)
        rollingSamples.reserveCapacity(Self.fftSize)
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    public func beginSession(_ sessionID: Int) {
        lock.lock()
        defer { lock.unlock() }
        activeSessionID = sessionID
        rollingSamples.removeAll(keepingCapacity: true)
    }

    public func endSession(_ sessionID: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard activeSessionID == sessionID else { return }
        activeSessionID = nil
        rollingSamples.removeAll(keepingCapacity: true)
    }

    public func analyze(_ samples16k: [Float], at timestamp: Date, sessionID: Int,
                        resetHistoryBeforeAppend: Bool = false) -> LiveSpectrumFrame? {
        lock.lock()
        defer { lock.unlock() }

        guard activeSessionID == sessionID, samples16k.count == 2_560, let fftSetup else { return nil }
        if resetHistoryBeforeAppend { rollingSamples.removeAll(keepingCapacity: true) }
        rollingSamples.append(contentsOf: samples16k)
        if rollingSamples.count > Self.fftSize {
            rollingSamples.removeFirst(rollingSamples.count - Self.fftSize)
        }
        guard rollingSamples.count == Self.fftSize else { return nil }

        var real = [Float](repeating: 0, count: Self.fftSize / 2)
        var imaginary = [Float](repeating: 0, count: Self.fftSize / 2)
        for index in 0..<(Self.fftSize / 2) {
            real[index] = rollingSamples[index * 2] * window[index * 2]
            imaginary[index] = rollingSamples[index * 2 + 1] * window[index * 2 + 1]
        }

        let transformed = real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer -> [Float] in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                vDSP_fft_zrip(fftSetup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))

                var bands = [Float](repeating: -100, count: Self.bandCount)
                // vDSP's real FFT stores Nyquist in imagp[0]; DC is omitted because it is
                // not useful for this speech view and shares that packed slot.
                for bin in 1..<(Self.fftSize / 2) {
                    let amplitude = hypot(realBuffer[bin], imaginaryBuffer[bin]) / windowSum
                    let band = min(Self.bandCount - 1, bin * Self.bandCount / (Self.fftSize / 2))
                    bands[band] = max(bands[band], Self.dbfs(amplitude))
                }
                let nyquistAmplitude = abs(imaginaryBuffer[0]) / (2 * windowSum)
                bands[Self.bandCount - 1] = max(bands[Self.bandCount - 1], Self.dbfs(nyquistAmplitude))
                return bands
            }
        }
        return LiveSpectrumFrame(timestamp: timestamp, bandsDBFS: transformed)
    }

    private static func dbfs(_ amplitude: Float) -> Float {
        guard amplitude.isFinite, amplitude > 0 else { return -100 }
        return max(-100, min(0, 20 * log10(amplitude)))
    }
}
