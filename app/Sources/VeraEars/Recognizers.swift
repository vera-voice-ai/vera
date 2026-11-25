import CSherpa
import Foundation

/// The two speech engines Vera can listen with; both live in the box. Which is better is decided by measurement.
public enum EarsEngine: String, CaseIterable, Sendable, Codable {
    /// GigaAM v3 with punctuation: not streaming by nature, so the phrase so far is re-read every half second.
    case gigaam
    /// T-one: streaming, the text grows as audio comes in.
    case tone

    public var title: String {
        switch self {
        case .gigaam: "GigaAM v3"
        case .tone: "T-one"
        }
    }
}

/// One phrase at a time: `begin`, `feed` audio (16 kHz mono float) and get the text so far, `end` for the final text.
public protocol PhraseRecognizer: AnyObject {
    func begin()
    /// The text so far, when there is something new to show.
    func feed(_ samples: [Float]) -> String?
    func end() -> String
}

private func take(_ p: UnsafeMutablePointer<CChar>?) -> String {
    guard let p else { return "" }
    defer { vera_sherpa_free(p) }
    return String(cString: p).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// GigaAM over a growing window: the whole phrase is decoded again every `interval` seconds of new audio.
public final class GigaAMRecognizer: PhraseRecognizer {
    private let handle: UnsafeMutableRawPointer
    private var audio: [Float] = []
    private var sinceDecode = 0
    private let interval: Int

    public init(runtime: EarsRuntime, interval: Double = 0.5, threads: Int32 = 2) throws {
        try SherpaLibrary.load(runtime)
        // GigaAM takes 64 mel bins.
        guard let h = vera_offline_create_nemo_ctc(runtime.gigaAMModel.path, runtime.gigaAMTokens.path, 64, threads) else {
            throw EarsError.model("GigaAM")
        }
        handle = h
        self.interval = Int(interval * 16_000)
    }
    deinit { vera_offline_destroy(handle) }

    public func begin() { audio.removeAll(keepingCapacity: true); sinceDecode = 0 }

    public func feed(_ samples: [Float]) -> String? {
        audio += samples
        sinceDecode += samples.count
        guard sinceDecode >= interval else { return nil }
        sinceDecode = 0
        return decode()
    }

    public func end() -> String { decode() }

    public func decode(_ samples: [Float]? = nil) -> String {
        let s = samples ?? audio
        return s.withUnsafeBufferPointer { take(vera_offline_decode(handle, $0.baseAddress, Int32($0.count), 16_000)) }
    }
}

/// T-one: a streaming recogniser; one stream per phrase.
public final class ToneRecognizer: PhraseRecognizer {
    private let handle: UnsafeMutableRawPointer
    private var stream: UnsafeMutableRawPointer?
    private var last = ""

    public init(runtime: EarsRuntime, threads: Int32 = 2) throws {
        try SherpaLibrary.load(runtime)
        // The model is trained on 8 kHz audio; sherpa resamples what we give it.
        guard let h = vera_online_create_tone(runtime.toneModel.path, runtime.toneTokens.path, 8_000, threads) else {
            throw EarsError.model("T-one")
        }
        handle = h
    }
    deinit {
        if let stream { vera_online_stream_destroy(stream) }
        vera_online_destroy(handle)
    }

    public func begin() {
        if let stream { vera_online_stream_destroy(stream) }
        stream = vera_online_stream(handle)
        last = ""
    }

    public func feed(_ samples: [Float]) -> String? {
        guard let stream else { return nil }
        samples.withUnsafeBufferPointer { vera_online_accept(handle, stream, $0.baseAddress, Int32($0.count), 16_000) }
        let text = take(vera_online_text(handle, stream))
        guard text != last else { return nil }
        last = text
        return text
    }

    public func end() -> String {
        guard let stream else { return last }
        // A little silence lets the model emit the last tokens it was holding back.
        let tail = [Float](repeating: 0, count: 8_000)
        tail.withUnsafeBufferPointer { vera_online_accept(handle, stream, $0.baseAddress, Int32($0.count), 16_000) }
        vera_online_finish(handle, stream)
        let text = take(vera_online_text(handle, stream))
        vera_online_stream_destroy(stream)
        self.stream = nil
        return text
    }
}

public enum Recognizers {
    public static func make(_ engine: EarsEngine, runtime: EarsRuntime) throws -> PhraseRecognizer {
        switch engine {
        case .gigaam: try GigaAMRecognizer(runtime: runtime)
        case .tone: try ToneRecognizer(runtime: runtime)
        }
    }
}
