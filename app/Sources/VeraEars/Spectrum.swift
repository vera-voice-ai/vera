import Accelerate
import Foundation

/// The microphone's spectrogram: one column every 20 ms (320 samples at 16 kHz) over a 32 ms Hann window, folded into
/// `bands` linear bands from 0 to 8 kHz, each the loudest bin in dBFS (−100…0). Only for drawing — nothing listens to
/// it. Not thread-safe: the ears feed it on their own serial queue. Idea from Vera 2's `LiveSpectrumAnalyzer`.
public final class Spectrum {
    public static let bands = 64
    public static let hop = 320
    static let size = 512
    private let log2n = vDSP_Length(9)
    private let setup: FFTSetup
    private let window: [Float]
    private let windowSum: Float
    private var buffer: [Float] = []
    private var sinceColumn = 0

    public init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = (0..<Self.size).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(Self.size - 1)) }
        windowSum = window.reduce(0, +)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Takes a chunk of 16 kHz samples, returns the columns it completed (oldest first).
    public func feed(_ samples: [Float]) -> [[Float]] {
        var columns: [[Float]] = []
        for s in samples {
            buffer.append(s)
            sinceColumn += 1
            if sinceColumn >= Self.hop {
                sinceColumn = 0
                if buffer.count > Self.size { buffer.removeFirst(buffer.count - Self.size) }
                if buffer.count == Self.size { columns.append(column()) }
            }
        }
        if buffer.count > Self.size { buffer.removeFirst(buffer.count - Self.size) }
        return columns
    }

    private func column() -> [Float] {
        let half = Self.size / 2
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        for i in 0..<half {
            re[i] = buffer[2 * i] * window[2 * i]
            im[i] = buffer[2 * i + 1] * window[2 * i + 1]
        }
        var bands = [Float](repeating: -100, count: Self.bands)
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // vDSP's packed real FFT is scaled by 2; DC (and Nyquist in imagp[0]) are left out.
                for bin in 1..<half {
                    let amp = hypot(r[bin], i[bin]) / windowSum
                    let band = bin * Self.bands / half
                    bands[band] = max(bands[band], Self.dbfs(amp))
                }
            }
        }
        return bands
    }

    static func dbfs(_ a: Float) -> Float {
        guard a.isFinite, a > 0 else { return -100 }
        return max(-100, min(0, 20 * log10(a)))
    }
}
