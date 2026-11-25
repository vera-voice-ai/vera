import Foundation

/// The live ears: microphone → gate → recogniser on one serial queue, events out on the caller's handler.
/// Models stay loaded between conversations (first load ~0.5–1 s per engine).
public final class EarsSession: @unchecked Sendable {
    public let runtime: EarsRuntime
    private let queue = DispatchQueue(label: "vera.ears", qos: .userInitiated)
    /// The shadow engine's queue: the second recogniser reads the same chunks here, never slowing the live one.
    private let shadowQueue = DispatchQueue(label: "vera.ears.shadow", qos: .userInitiated)
    /// Serial: CAM++ vectors are computed here, one phrase at a time.
    private let speakerQueue = DispatchQueue(label: "vera.ears.voiceprint", qos: .userInitiated)
    /// The async judge answers on its own thread; this hop routes the reply onto the ears' queue,
    /// where the listener owns its state.
    private final class HoppedJudge: AsyncTurnJudge, @unchecked Sendable {
        let queue: DispatchQueue
        let inner: AsyncTurnJudge
        init(queue: DispatchQueue, _ inner: AsyncTurnJudge) { self.queue = queue; self.inner = inner }
        func judge(_ phrase: [Float], _ reply: @escaping @Sendable (Double?) -> Void) {
            inner.judge(phrase) { p in self.queue.async { reply(p) } }
        }
    }
    private var recognizers: [EarsEngine: PhraseRecognizer] = [:]
    private var gate: SileroGate?
    /// The spectrogram's columns, for drawing only (fed on `queue`).
    private let spectrum = Spectrum()
    /// Smart Turn from the mouth's box, if it is there: then the VAD offers an end after 0.3 s of silence and Smart
    /// Turn confirms it, or the phrase waits up to 1.2 s more for the speaker to go on.
    private lazy var judge: SmartTurn? = MouthRuntime.resolve().flatMap { SmartTurn(mouth: $0) }
    private lazy var speakers: SpeakerEmbedder? = try? SpeakerEmbedder(runtime: runtime)
    /// «Кто говорит» (CAM++) is in the box but switched off for now (the owner, 2026-11-22): no voiceprints are taken and
    /// Hermes gets no speaker notes. Turning it on is this one switch.
    public static let identifiesSpeakers = false
    public var judging: Bool { queue.sync { judge != nil } }
    private var listener: Listener?
    private var mic: Microphone?
    /// The shadow reader lives on `shadowQueue` and only there.
    private var shadow: ShadowReader?

    public init(runtime: EarsRuntime) { self.runtime = runtime }

    /// Opens the microphone and listens until `stop`. Throws if a model or the microphone does not open.
    /// `onEvent` and `onLevel` are called on the ears' queue.
    /// `shadow`: the other engine reads the very phrases the live listener frames (same start with the same pre-roll,
    /// same audio, same end — it has no VAD of its own) on its own queue, for an honest A/B in the journal; its
    /// phrases are reported through `onShadowPhrase` and never go to the agent.
    /// `onLevel` brings the chunk's loudness, its outline (a peak per 20 ms) and its spectrogram columns (one per 20 ms,
    /// `Spectrum.bands` dBFS values). `onEvent` and `onLevel` are called on the ears' queue; `onShadowPhrase` — on the shadow queue.
    public func start(engine: EarsEngine, shadow: EarsEngine? = nil, voiceProcessing: Bool = true,
                      onEvent: @escaping @Sendable (HearingEvent) -> Void,
                      onLevel: @escaping @Sendable (_ rms: Float, _ peaks: [Float], _ spectrum: [[Float]]) -> Void,
                      onShadowPhrase: (@Sendable (EarsJournal.Phrase) -> Void)? = nil) throws -> (echoCancelling: Bool, loadMs: Int) {
        try queue.sync {
            let t0 = Date()
            let recognizer = try recognizers[engine] ?? Recognizers.make(engine, runtime: runtime)
            recognizers[engine] = recognizer
            let judge = self.judge
            judge?.warm()
            let gate = try self.gate ?? SileroGate(runtime: runtime, minSilence: judge == nil ? 0.5 : 0.3)
            self.gate = gate
            gate.reset()
            let hop = judge.map { HoppedJudge(queue: queue, $0) }
            let listener = Listener(gate: gate, recognizer: recognizer, judgeAsync: hop,
                                    speakers: Self.identifiesSpeakers ? speakers : nil, speakerWork: speakerQueue,
                                    onEvent: onEvent)
            self.listener = listener
            if let shadow, shadow != engine, let onShadowPhrase {
                let srec = try recognizers[shadow] ?? Recognizers.make(shadow, runtime: runtime)
                recognizers[shadow] = srec
                let reader = ShadowReader(engine: shadow, recognizer: srec, report: onShadowPhrase)
                shadowQueue.sync { self.shadow = reader }
                let sq = shadowQueue
                listener.mirror = { m in sq.async { reader.take(m) } }
            } else {
                shadowQueue.sync { self.shadow = nil }
            }
            let loadMs = Int(Date().timeIntervalSince(t0) * 1000)
            let chunk: @Sendable ([Float], Float) -> Void = { [weak self] samples, level in
                guard let self else { return }
                self.queue.async {
                    onLevel(level, Self.peaks(samples, per: 320), self.spectrum.feed(samples))
                    if !self.deafened { self.listener?.feed(samples) }
                }
            }
            let mic = Microphone()
            try mic.start(voiceProcessing: voiceProcessing, chunk)
            self.mic = mic
            return (mic.echoCancelling, loadMs)
        }
    }

    /// The waveform's outline: the loudest sample of every `per` samples (320 = 20 ms at 16 kHz).
    static func peaks(_ s: [Float], per: Int) -> [Float] {
        stride(from: 0, to: s.count, by: per).map { i in s[i..<min(i + per, s.count)].reduce(0) { max($0, abs($1)) } }
    }

    /// Closes the microphone; with `finish`, a phrase in progress is read to the end and reported, else dropped.
    private var deafened = false

    /// Not listening (Vera speaks, no echo cancellation): the sound is not read and a phrase in progress is dropped.
    public func deaf(_ on: Bool) {
        queue.async {
            guard on != self.deafened else { return }
            self.deafened = on
            if on { self.listener?.cancel() }
        }
    }

    public func stop(finish: Bool) {
        queue.sync {
            mic?.stop(); mic = nil
            if finish { listener?.flush() } else { listener?.cancel() }
            listener = nil
        }
        // The live listener's flush / cancel above already told the reader how the phrase ended; let it finish.
        shadowQueue.sync { shadow = nil }
    }
}

/// The shadow engine: reads the live listener's phrases (`Listener.Mirror`) with the other recogniser, on the shadow
/// queue only. Only timings and counts reach the journal — never the words — marked `shadow`.
final class ShadowReader: @unchecked Sendable {
    private let engine: EarsEngine
    private let recognizer: PhraseRecognizer
    private let report: @Sendable (EarsJournal.Phrase) -> Void
    private var start: Date?
    private var firstPartial: Date?
    private var partials = 0
    private var samples = 0

    init(engine: EarsEngine, recognizer: PhraseRecognizer, report: @escaping @Sendable (EarsJournal.Phrase) -> Void) {
        self.engine = engine; self.recognizer = recognizer; self.report = report
    }

    func take(_ m: Listener.Mirror) {
        switch m {
        case .begin(let preroll):
            recognizer.begin()
            start = Date(); firstPartial = nil; partials = 0; samples = 0
            read(preroll)
        case .audio(let w):
            guard start != nil else { return }
            read(w)
        case .end:
            guard let t0 = start else { return }
            let d0 = Date()
            let text = recognizer.end()
            var p = EarsJournal.Phrase(ts: Date().timeIntervalSince1970, engine: engine.rawValue,
                                       seconds: Double(samples) / Double(Listener.sampleRate),
                                       firstPartialMs: firstPartial.map { Int($0.timeIntervalSince(t0) * 1000) },
                                       decodeMs: Int(Date().timeIntervalSince(d0) * 1000), chars: text.count, partials: partials)
            p.shadow = true
            report(p)
            start = nil
        case .cancel:
            if start != nil { _ = recognizer.end() }
            start = nil
        }
    }

    private func read(_ w: [Float]) {
        samples += w.count
        if recognizer.feed(w) != nil {
            partials += 1
            if firstPartial == nil { firstPartial = Date() }
        }
    }
}
