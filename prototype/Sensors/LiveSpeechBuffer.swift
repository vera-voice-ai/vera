import Foundation

public enum LiveSpeechUpdate: Sendable {
    case interim(segmentID: Int, wav: Data, durationMilliseconds: Int)
    case final(segmentID: Int, wav: Data, durationMilliseconds: Int, reason: String)
}

/// Converts short microphone frames into revisable speech windows and finalized
/// utterances. This is an energy gate, not a learned VAD or speaker detector.
public struct LiveSpeechBuffer: Sendable {
    public static let sampleRate = 16_000
    public static let speechThreshold: Float = 0.010

    private let preRollLimitBytes = 16_000 * 2 * 9 / 10
    private let interimWindowLimitBytes = 16_000 * 2 * 8
    private let maxSegmentDurationMilliseconds = 14_000
    private let finalSilenceDuration: TimeInterval = 2.0
    private let interimInterval: TimeInterval = 0.5

    private var preRoll = Data()
    private var activePCM16 = Data()
    private var segmentStartedAt: Date?
    private var lastVoiceAt: Date?
    private var lastInterimAt: Date?
    private var activeSegmentID = 0

    public var isSpeechActive: Bool { segmentStartedAt != nil }
    public var currentSegmentID: Int { activeSegmentID }

    public func recentPCM16(milliseconds: Int) -> Data? {
        guard isSpeechActive, milliseconds > 0 else { return nil }
        let byteLimit = Self.sampleRate * 2 * milliseconds / 1_000
        guard activePCM16.count >= byteLimit else { return nil }
        return Data(activePCM16.suffix(byteLimit))
    }

    public init() {}

    public mutating func append(samples16k: [Float], rms: Float, at time: Date = .now) -> LiveSpeechUpdate? {
        guard !samples16k.isEmpty else { return nil }
        let pcm = Self.pcm16(samples16k)
        let hasVoice = rms >= Self.speechThreshold

        guard segmentStartedAt != nil else {
            if !hasVoice {
                preRoll.append(pcm)
                trimPreRoll()
                return nil
            }
            activeSegmentID &+= 1
            segmentStartedAt = time
            lastVoiceAt = time
            lastInterimAt = time
            activePCM16 = preRoll
            activePCM16.append(pcm)
            preRoll.removeAll(keepingCapacity: true)
            return makeInterimIfDue(at: time)
        }

        activePCM16.append(pcm)
        if hasVoice { lastVoiceAt = time }

        if activePCM16.count >= Self.sampleRate * 2 * maxSegmentDurationMilliseconds / 1_000 {
            return finish(reason: "max_duration", at: time)
        }
        if let lastVoiceAt, !hasVoice, time.timeIntervalSince(lastVoiceAt) >= finalSilenceDuration {
            return finish(reason: "silence", at: time)
        }
        return makeInterimIfDue(at: time)
    }

    public mutating func flush(at time: Date = .now) -> LiveSpeechUpdate? {
        guard segmentStartedAt != nil else { return nil }
        return finish(reason: "microphone_stopped", at: time)
    }

    public mutating func reset() {
        preRoll.removeAll(keepingCapacity: false)
        activePCM16.removeAll(keepingCapacity: false)
        segmentStartedAt = nil
        lastVoiceAt = nil
        lastInterimAt = nil
        activeSegmentID &+= 1
    }

    public static func pcm16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clipped = max(-1, min(1, sample))
            var value = Int16((clipped * 32_767).rounded()).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func wav(pcm16: Data, sampleRate: Int = sampleRate) -> Data {
        var wav = Data(capacity: pcm16.count + 44)
        wav.append(contentsOf: Array("RIFF".utf8))
        appendLE(UInt32(pcm16.count + 36), to: &wav)
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        appendLE(UInt32(16), to: &wav)
        appendLE(UInt16(1), to: &wav)
        appendLE(UInt16(1), to: &wav)
        appendLE(UInt32(sampleRate), to: &wav)
        appendLE(UInt32(sampleRate * 2), to: &wav)
        appendLE(UInt16(2), to: &wav)
        appendLE(UInt16(16), to: &wav)
        wav.append(contentsOf: Array("data".utf8))
        appendLE(UInt32(pcm16.count), to: &wav)
        wav.append(pcm16)
        return wav
    }

    private mutating func makeInterimIfDue(at time: Date) -> LiveSpeechUpdate? {
        guard let segmentStartedAt,
              activePCM16.count >= Self.sampleRate * 2,
              let lastInterimAt,
              time.timeIntervalSince(lastInterimAt) >= interimInterval else { return nil }
        self.lastInterimAt = time
        let window = Data(activePCM16.suffix(interimWindowLimitBytes))
        let durationMs = Int(Double(window.count / 2) / Double(Self.sampleRate) * 1_000)
        return .interim(segmentID: activeSegmentID,
                        wav: Self.wav(pcm16: window),
                        durationMilliseconds: min(durationMs, Int(time.timeIntervalSince(segmentStartedAt) * 1_000)))
    }

    private mutating func finish(reason: String, at time: Date) -> LiveSpeechUpdate? {
        guard let segmentStartedAt else { return nil }
        let segmentID = activeSegmentID
        let pcm = activePCM16
        activePCM16.removeAll(keepingCapacity: true)
        self.segmentStartedAt = nil
        lastVoiceAt = nil
        lastInterimAt = nil
        preRoll = Data(pcm.suffix(preRollLimitBytes))
        let durationMs = Int(time.timeIntervalSince(segmentStartedAt) * 1_000)
        guard pcm.count >= 2_000 else { return nil }
        return .final(segmentID: segmentID,
                      wav: Self.wav(pcm16: pcm),
                      durationMilliseconds: durationMs,
                      reason: reason)
    }

    private mutating func trimPreRoll() {
        if preRoll.count > preRollLimitBytes {
            preRoll = Data(preRoll.suffix(preRollLimitBytes))
        }
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
