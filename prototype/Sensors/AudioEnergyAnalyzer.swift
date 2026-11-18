import Foundation

public struct AudioEnergyResult: Sendable {
    public let rms: Double
    public let peak: Double
    public let activePercent: Double
    public let windows: [Double]
    public let threshold: Double
}

/// Energy-only baseline. This is not a trained VAD and does not classify meaning.
public enum AudioEnergyAnalyzer {
    public static func analyze(_ segment: AudioSegment, windowMilliseconds: Int = 20) -> AudioEnergyResult {
        let values = segment.pcm16.withUnsafeBytes { raw -> [Int16] in
            Array(raw.bindMemory(to: Int16.self))
        }
        let channels = max(1, segment.channels)
        let samplesPerWindow = max(channels, segment.sampleRate * windowMilliseconds / 1_000 * channels)
        var energies: [Double] = []
        var sumSquares = 0.0
        var total = 0.0
        var peak = 0.0
        var cursor = 0
        while cursor < values.count {
            let end = min(values.count, cursor + samplesPerWindow)
            var windowSquares = 0.0
            var windowCount = 0
            for index in stride(from: cursor, to: end, by: channels) {
                let sample = Double(values[index]) / 32768.0
                windowSquares += sample * sample
                windowCount += 1
                peak = max(peak, abs(sample))
            }
            let rms = windowCount > 0 ? sqrt(windowSquares / Double(windowCount)) : 0
            energies.append(rms)
            sumSquares += windowSquares
            total += Double(windowCount)
            cursor = end
        }
        let threshold = max(0.008, (energies.max() ?? 0) * 0.08)
        let active = energies.filter { $0 >= threshold }.count
        return AudioEnergyResult(rms: total > 0 ? sqrt(sumSquares / total) : 0,
                                 peak: peak,
                                 activePercent: energies.isEmpty ? 0 : Double(active) / Double(energies.count) * 100,
                                 windows: energies,
                                 threshold: threshold)
    }
}
