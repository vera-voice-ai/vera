import CSherpa
import Foundation

/// Speech or not, one 512-sample window (32 ms at 16 kHz) at a time.
public protocol VoiceGate: AnyObject {
    /// `speaking`: voice is on now; `ended`: a phrase has just finished (after the gate's own trailing silence).
    func accept(_ window: [Float]) -> (speaking: Bool, ended: Bool)
    func reset()
}

/// Silero VAD from the box. A phrase ends after `minSilence` without voice — mechanics, not meaning.
public final class SileroGate: VoiceGate {
    private let handle: UnsafeMutableRawPointer

    public init(runtime: EarsRuntime, threshold: Float = 0.5, minSilence: Float = 0.5,
                minSpeech: Float = 0.25, maxSpeech: Float = 20) throws {
        try SherpaLibrary.load(runtime)
        guard let h = vera_vad_create(runtime.vadModel.path, threshold, minSilence, minSpeech, maxSpeech) else {
            throw EarsError.model("Silero VAD")
        }
        handle = h
    }
    deinit { vera_vad_destroy(handle) }

    public func accept(_ window: [Float]) -> (speaking: Bool, ended: Bool) {
        window.withUnsafeBufferPointer { vera_vad_accept(handle, $0.baseAddress, Int32($0.count)) }
        let ended = vera_vad_pop_all(handle) > 0
        return (vera_vad_detected(handle) != 0, ended)
    }

    public func reset() { vera_vad_reset(handle) }
}

/// What the ears report. Text only leaves as `partial` / `final`; audio never leaves the listener.
public enum HearingEvent: Sendable, Equatable {
    case started
    case partial(String)
    /// Smart Turn's word on the phrase so far: probability it is finished, and whether the ears ended it (false —
    /// they wait for the speaker to go on).
    case judged(Double, finished: Bool)
    /// The phrase's voice vector (CAM++), just before `final`: who spoke is told from it against the voice book.
    case voiceprint([Float])
    /// The phrase, its length in seconds, how long the last decode took after the phrase ended (ms) and its loudness.
    case final(String, seconds: Double, decodeMs: Int, loudness: Loudness)
}

/// How loud a phrase was: its median level and the background (the quiet 20 % of the last 30 s), dBFS.
/// The microphone's voice processing can gate a quiet room to digital silence; then there is no floor.
public struct Loudness: Sendable, Equatable {
    public var db: Double
    public var floorDB: Double?
    public var aboveFloor: Double? { floorDB.map { db - $0 } }

    public init(db: Double, floorDB: Double?) { self.db = db; self.floorDB = floorDB }

    public static func decibels(_ rms: Float) -> Double { 20 * log10(Double(max(rms, 1e-5))) }

    static func measure(phrase: [Float], recent: [Float]) -> Loudness {
        let spoken = phrase.sorted()
        let db = spoken.isEmpty ? -100 : decibels(spoken[spoken.count / 2])
        let quiet = recent.sorted()
        let floor = quiet.isEmpty ? nil : decibels(quiet[quiet.count / 5])
        return Loudness(db: db, floorDB: floor.flatMap { $0 > -85 ? $0 : nil })
    }
}

/// The ears' state machine: audio in, gate decides speech / silence, the recogniser reads the phrase.
/// Not thread-safe: feed it from one queue.
public final class Listener {
    /// A Sendable box for the async judge's reply: it only dereferences the listener on its queue
    /// (the owner routes the reply there; tests answer on the same thread).
    private final class ReplyBox: @unchecked Sendable {
        weak var listener: Listener?
        var gen = 0
    }
    public static let sampleRate = 16_000
    public static let window = 512

    /// The phrase as this listener frames it, for a second reader of the same sound (the shadow engine): it gets the
    /// same start (with the same pre-roll), the same audio and the same end, so both engines read identical phrases.
    public enum Mirror: Sendable {
        case begin([Float])
        case audio([Float])
        case end
        case cancel
    }
    /// Called on the listener's queue; the owner hops it to the reader's own queue.
    public var mirror: (@Sendable (Mirror) -> Void)?

    private let gate: VoiceGate
    private let recognizer: PhraseRecognizer
    private let judge: TurnJudge?
    /// When set, the judge is asked off the queue and the phrase stays open (`holding`) until it answers;
    /// the 1.2 s hold is then also the timeout. Preferred over `judge` when both are set.
    private let judgeAsync: AsyncTurnJudge?
    private let speakers: SpeakerEmbedder?
    /// When set (a serial queue), CAM++ runs here and `voiceprint` arrives after `final`, on that queue.
    /// Nil keeps the old order: `voiceprint` just before `final`, on the caller's queue.
    private let speakerWork: DispatchQueue?
    /// Below this, the phrase is held open for `holdLimit` more samples of silence.
    public static let finishedAt = 0.5
    private let holdLimit = Int(1.2 * 16_000)
    private var holding = false
    private var heldSilence = 0
    private var phraseAudio: [Float] = []
    private let onEvent: (HearingEvent) -> Void
    private var pending: [Float] = []
    /// The last ~0.6 s before voice was detected: the gate needs a little speech to be sure, the words must not lose it.
    private var preroll: [Float] = []
    private let prerollLimit = 9_600
    private var inPhrase = false
    private var phraseSamples = 0
    /// The phrase's generation: every begin/finish/cancel bumps it, so a late async answer cannot end the next phrase.
    private var phraseGen = 0
    private var awaitingJudge = false
    private var lastSpeaking = false
    /// Window levels (RMS): of the phrase, and of the last 30 s for the background floor.
    private var phraseLevels: [Float] = []
    private var recentLevels: [Float] = []
    private let recentLimit = 30 * 16_000 / 512

    public init(gate: VoiceGate, recognizer: PhraseRecognizer, judge: TurnJudge? = nil, judgeAsync: AsyncTurnJudge? = nil,
                speakers: SpeakerEmbedder? = nil, speakerWork: DispatchQueue? = nil,
                onEvent: @escaping (HearingEvent) -> Void) {
        self.speakers = speakers
        self.gate = gate
        self.recognizer = recognizer
        self.judge = judge
        self.judgeAsync = judgeAsync
        self.speakerWork = speakerWork
        self.onEvent = onEvent
    }

    public var hearing: Bool { inPhrase }

    public func feed(_ samples: [Float]) {
        pending += samples
        while pending.count >= Self.window {
            let w = Array(pending.prefix(Self.window))
            pending.removeFirst(Self.window)
            step(w)
        }
    }

    private func step(_ w: [Float]) {
        let (speaking, ended) = gate.accept(w)
        lastSpeaking = speaking
        var sum: Float = 0
        for x in w { sum += x * x }
        let rms = (sum / Float(w.count)).squareRoot()
        recentLevels.append(rms)
        if recentLevels.count > recentLimit { recentLevels.removeFirst(recentLevels.count - recentLimit) }
        if inPhrase {
            phraseSamples += w.count
            phraseLevels.append(rms)
            phraseAudio += w
            mirror?(.audio(w))
            if let text = recognizer.feed(w) { onEvent(.partial(text)) }
            if holding {
                // Smart Turn said «not finished»: the phrase stays open while the speaker may go on.
                if speaking && !ended { holding = false; heldSilence = 0 }
                else { heldSilence += w.count; if heldSilence >= holdLimit { finishPhrase() } }
            } else if ended || !speaking {
                if let judgeAsync, !awaitingJudge {
                    // Ask off the queue; the hold below is the timeout. Audio keeps flowing meanwhile.
                    awaitingJudge = true
                    holding = true; heldSilence = 0
                    let snap = phraseAudio, gen = phraseGen
                    // The reply must run on this queue: the owner wraps the judge with that hop.
                    let box = ReplyBox(); box.listener = self; box.gen = gen
                    judgeAsync.judge(snap) { [weak box] p in box?.listener?.judgeAnswered(p, gen: box?.gen ?? -1) }
                } else if let judge, !awaitingJudge, let p = judge.completion(phraseAudio) {
                    let finished = p >= Self.finishedAt
                    onEvent(.judged(p, finished: finished))
                    if finished { finishPhrase() } else { holding = true; heldSilence = 0 }
                } else if !awaitingJudge {
                    finishPhrase()
                } else {
                    // Still waiting for the judge after the speaker went on and stopped again: the hold is the timeout,
                    // so a judge that never answers cannot keep the phrase open.
                    holding = true; heldSilence = 0
                }
            }
        } else {
            preroll += w
            if preroll.count > prerollLimit { preroll.removeFirst(preroll.count - prerollLimit) }
            if speaking {
                inPhrase = true
                phraseGen += 1
                awaitingJudge = false
                recognizer.begin()
                phraseSamples = preroll.count
                phraseLevels = [rms]
                phraseAudio = preroll
                mirror?(.begin(preroll))
                onEvent(.started)
                if let text = recognizer.feed(preroll) { onEvent(.partial(text)) }
                preroll.removeAll(keepingCapacity: true)
            }
        }
    }

    /// An async judge's answer. Must run on the Listener's queue (the owner wraps the judge with that hop);
    /// a late answer (another generation, no phrase, no longer waiting) is ignored.
    func judgeAnswered(_ p: Double?, gen: Int) {
        guard gen == phraseGen, inPhrase, awaitingJudge else { return }
        awaitingJudge = false
        guard let p else {
            // No opinion: end a silent hold, keep a resumed phrase open.
            if holding && !lastSpeaking { finishPhrase() } else { holding = false }
            return
        }
        let finished = p >= Self.finishedAt
        onEvent(.judged(p, finished: finished))
        if finished {
            // Never cut live speech: a resumed phrase stays open and the next silence asks again.
            if holding || !lastSpeaking { finishPhrase() }
        }
        // Unfinished: stay holding, the hold limit ends it.
    }

    private func finishPhrase() {
        phraseGen += 1
        awaitingJudge = false
        if let speakers, let work = speakerWork {
            // CAM++ off the queue: the final text goes out now, the voice vector follows.
            // The owner's handler is thread-safe (it hops to its own actor); the listener itself is not touched there.
            let snap = phraseAudio
            nonisolated(unsafe) let emit = onEvent
            work.async {
                guard let v = speakers.embed(snap) else { return }
                emit(.voiceprint(v))
            }
        } else if let speakers, let v = speakers.embed(phraseAudio) { onEvent(.voiceprint(v)) }
        inPhrase = false
        holding = false
        heldSilence = 0
        phraseAudio.removeAll(keepingCapacity: true)
        mirror?(.end)
        let t0 = Date()
        let text = recognizer.end()
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        onEvent(.final(text, seconds: Double(phraseSamples) / Double(Self.sampleRate), decodeMs: ms,
                       loudness: .measure(phrase: phraseLevels, recent: recentLevels)))
        phraseSamples = 0
        phraseLevels.removeAll(keepingCapacity: true)
    }

    /// Drop the phrase in progress (stop listening without sending).
    public func cancel() {
        if inPhrase { _ = recognizer.end(); mirror?(.cancel) }
        inPhrase = false
        holding = false
        awaitingJudge = false
        phraseGen += 1
        phraseAudio.removeAll()
        pending.removeAll(); preroll.removeAll()
        gate.reset()
    }

    /// End of input (a file, or the microphone closing): a phrase in progress is finished.
    public func flush() {
        if !pending.isEmpty { feed([Float](repeating: 0, count: Self.window - pending.count)) }
        if inPhrase { finishPhrase() }
        gate.reset()
    }
}
