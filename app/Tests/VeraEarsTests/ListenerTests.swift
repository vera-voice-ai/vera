import Foundation
import Testing
@testable import VeraEars

/// A gate that says «speech» while the window is loud and ends the phrase after `silence` quiet windows.
fileprivate final class LoudGate: VoiceGate {
    let silence: Int
    var quiet = 0
    var inSpeech = false
    init(silence: Int = 3) { self.silence = silence }
    func accept(_ w: [Float]) -> (speaking: Bool, ended: Bool) {
        let loud = (w.map(abs).max() ?? 0) > 0.1
        if loud { inSpeech = true; quiet = 0; return (true, false) }
        guard inSpeech else { return (false, false) }
        quiet += 1
        if quiet >= silence { inSpeech = false; return (false, true) }
        return (true, false)
    }
    func reset() { quiet = 0; inSpeech = false }
}

/// Reports how many samples it was given, so the test sees what audio reached it.
fileprivate final class CountingRecognizer: PhraseRecognizer {
    var count = 0
    var begins = 0
    func begin() { count = 0; begins += 1 }
    func feed(_ s: [Float]) -> String? { count += s.count; return "\(count)" }
    func end() -> String { "фраза \(count)" }
}

@Suite struct ListenerTests {
    fileprivate func run(_ audio: [Float], gate: VoiceGate = LoudGate()) -> ([HearingEvent], CountingRecognizer) {
        let r = CountingRecognizer()
        var events: [HearingEvent] = []
        let l = Listener(gate: gate, recognizer: r) { events.append($0) }
        var i = 0
        while i < audio.count { l.feed(Array(audio[i..<min(i + 1600, audio.count)])); i += 1600 }
        l.flush()
        return (events, r)
    }

    let quiet = [Float](repeating: 0, count: 512)
    let loud = [Float](repeating: 0.5, count: 512)

    @Test func silenceHearsNothing() {
        let (events, r) = run(Array(repeating: quiet, count: 40).flatMap { $0 })
        #expect(events.isEmpty)
        #expect(r.begins == 0)
    }

    @Test func onePhraseStartsPartialsAndOneFinal() {
        let audio = Array(repeating: quiet, count: 10).flatMap { $0 } + Array(repeating: loud, count: 10).flatMap { $0 }
            + Array(repeating: quiet, count: 10).flatMap { $0 }
        let (events, r) = run(audio)
        #expect(events.first == .started)
        let finals = events.compactMap { if case .final(let t, _, _, _) = $0 { t } else { nil } }
        #expect(finals.count == 1)
        #expect(r.begins == 1)
        // The words before the gate was sure are not lost: the pre-roll (up to 0.6 s) reaches the recogniser.
        #expect(r.count > 10 * 512)
    }

    @Test func phraseLoudnessIsMeasuredAgainstTheRoom() {
        let audio = Array(repeating: quiet.map { _ in Float(0.001) }, count: 30).flatMap { $0 } + Array(repeating: loud, count: 10).flatMap { $0 }
            + Array(repeating: quiet, count: 10).flatMap { $0 }
        let (events, _) = run(audio)
        let loudness = events.compactMap { if case .final(_, _, _, let l) = $0 { l } else { nil } }.first
        #expect(loudness.map { abs($0.db - Loudness.decibels(0.5)) < 1 } == true)   // ≈ −6 dBFS
        #expect((loudness?.aboveFloor ?? 0) > 30)
    }

    @Test func digitalSilenceIsNoFloor() {
        #expect(Loudness.measure(phrase: [0.1], recent: [0, 0, 0]).floorDB == nil)
    }

    /// A judge that answers from a script, one probability per call.
    fileprivate final class ScriptedJudge: TurnJudge {
        var answers: [Double]; var calls = 0
        init(_ a: [Double]) { answers = a }
        func completion(_ phrase: [Float]) -> Double? { calls += 1; return answers.isEmpty ? nil : answers.removeFirst() }
    }

    fileprivate func runJudged(_ audio: [Float], judge: TurnJudge) -> [HearingEvent] {
        var events: [HearingEvent] = []
        let l = Listener(gate: LoudGate(), recognizer: CountingRecognizer(), judge: judge) { events.append($0) }
        var i = 0
        while i < audio.count { l.feed(Array(audio[i..<min(i + 1600, audio.count)])); i += 1600 }
        return events
    }

    @Test func smartTurnSureEndsThePhraseAtOnce() {
        let audio = Array(repeating: loud, count: 8).flatMap { $0 } + Array(repeating: quiet, count: 6).flatMap { $0 }
        let events = runJudged(audio, judge: ScriptedJudge([0.9]))
        #expect(events.contains(.judged(0.9, finished: true)))
        #expect(events.filter { if case .final = $0 { true } else { false } }.count == 1)
    }

    @Test func smartTurnUnsureHoldsAndTheSpeakerGoesOn() {
        // «ну и…» — a pause, then more speech: one phrase, not two.
        let speech: [Float] = Array(repeating: loud, count: 6).flatMap { $0 }
        let pause: [Float] = Array(repeating: quiet, count: 10).flatMap { $0 }
        let tail: [Float] = Array(repeating: quiet, count: 8).flatMap { $0 }
        let phrase: [Float] = speech + pause + speech + tail
        let events = runJudged(phrase, judge: ScriptedJudge([0.1, 0.95]))
        #expect(events.contains(.judged(0.1, finished: false)))
        #expect(events.filter { if case .final = $0 { true } else { false } }.count == 1)
        #expect(events.filter { $0 == HearingEvent.started }.count == 1)
    }

    @Test func smartTurnUnsureButSilenceEndsAfterTheHold() {
        let audio = Array(repeating: loud, count: 6).flatMap { $0 } + Array(repeating: quiet, count: 60).flatMap { $0 }
        let events = runJudged(audio, judge: ScriptedJudge([0.2]))
        #expect(events.filter { if case .final = $0 { true } else { false } }.count == 1)   // 1.2 s of silence ≈ 38 windows
    }

    /// An async judge from a script: preset answers reply at once, otherwise the reply is kept for later.
    fileprivate final class ScriptedAsyncJudge: AsyncTurnJudge {
        var answers: [Double?]
        var pending: [(reply: (@Sendable (Double?) -> Void), samples: Int)] = []
        var calls = 0
        init(_ a: [Double?]) { answers = a }
        func judge(_ phrase: [Float], _ reply: @escaping @Sendable (Double?) -> Void) {
            calls += 1
            if answers.isEmpty { pending.append((reply, phrase.count)) } else { reply(answers.removeFirst()) }
        }
    }

    fileprivate func runAsync(_ audio: [Float], judge: ScriptedAsyncJudge) -> ([HearingEvent], ScriptedAsyncJudge) {
        var events: [HearingEvent] = []
        let l = Listener(gate: LoudGate(), recognizer: CountingRecognizer(), judgeAsync: judge) { events.append($0) }
        var i = 0
        while i < audio.count { l.feed(Array(audio[i..<min(i + 1600, audio.count)])); i += 1600 }
        return (events, judge)
    }

    @Test func asyncJudgeSureEndsThePhraseAtOnce() {
        // The reply runs on the same thread here; in the app the owner routes it onto the ears' queue.
        let audio = Array(repeating: loud, count: 8).flatMap { $0 } + Array(repeating: quiet, count: 6).flatMap { $0 }
        let (events, _) = runAsync(audio, judge: ScriptedAsyncJudge([0.9]))
        #expect(events.contains(.judged(0.9, finished: true)))
        #expect(events.filter { if case .final = $0 { true } else { false } }.count == 1)
    }

    @Test func asyncJudgeNoAnswerEndsByTheHold() {
        // Silence 1.2 s ≈ 38 windows: the hold limit ends the phrase even when the judge never answers,
        // and its late answer is ignored.
        let audio = Array(repeating: loud, count: 6).flatMap { $0 } + Array(repeating: quiet, count: 60).flatMap { $0 }
        var events: [HearingEvent] = []
        let judge = ScriptedAsyncJudge([])
        let l = Listener(gate: LoudGate(), recognizer: CountingRecognizer(), judgeAsync: judge) { events.append($0) }
        var i = 0
        while i < audio.count { l.feed(Array(audio[i..<min(i + 1600, audio.count)])); i += 1600 }
        #expect(judge.calls == 1)
        #expect(events.filter { if case .final = $0 { true } else { false } }.count == 1)
        let finals = events.filter { if case .final = $0 { true } else { false } }.count
        for p in judge.pending { p.reply(0.95) }
        #expect(events.filter { if case .final = $0 { true } else { false } }.count == finals)
        #expect(!events.contains(.judged(0.95, finished: true)))
    }

    @Test func asyncJudgeUnsureThenTheSpeakerGoesOn() {
        let speech: [Float] = Array(repeating: loud, count: 6).flatMap { $0 }
        let pause: [Float] = Array(repeating: quiet, count: 10).flatMap { $0 }
        var events: [HearingEvent] = []
        let judge = ScriptedAsyncJudge([0.1])
        let l = Listener(gate: LoudGate(), recognizer: CountingRecognizer(), judgeAsync: judge) { events.append($0) }
        func feed(_ a: [Float]) {
            var i = 0
            while i < a.count { l.feed(Array(a[i..<min(i + 1600, a.count)])); i += 1600 }
        }
        feed(speech + pause)
        #expect(events.contains(.judged(0.1, finished: false)))
        feed(speech)   // «ну и…» — the speaker goes on: still one phrase
        #expect(events.filter { $0 == HearingEvent.started }.count == 1)
        // Silent again and the judge does not answer this time: the hold (1.2 s ≈ 38 windows) still ends the phrase.
        feed(Array(repeating: quiet, count: 8).flatMap { $0 })
        #expect(events.filter { if case .final = $0 { true } else { false } }.isEmpty)
        feed(Array(repeating: quiet, count: 50).flatMap { $0 })
        #expect(events.filter { if case .final = $0 { true } else { false } }.count == 1)
    }

    @Test func theShadowReadsExactlyTheLivePhrase() {
        // Pre-roll silence, a phrase, silence: the shadow gets the live listener's framing, not its own.
        let audio = Array(repeating: quiet, count: 4).flatMap { $0 } + Array(repeating: loud, count: 6).flatMap { $0 }
            + Array(repeating: quiet, count: 8).flatMap { $0 }
        let live = CountingRecognizer(), other = CountingRecognizer()
        var events: [HearingEvent] = []
        let reader = ShadowReader(engine: .tone, recognizer: other, report: { _ in })
        let l = Listener(gate: LoudGate(), recognizer: live) { events.append($0) }
        nonisolated(unsafe) var mirrored: [Listener.Mirror] = []
        l.mirror = { m in mirrored.append(m) }
        var i = 0
        while i < audio.count { l.feed(Array(audio[i..<min(i + 1600, audio.count)])); i += 1600 }
        l.flush()
        // Same framing: one begin, one end, and the shadow reads as many samples as the live recogniser did.
        #expect(mirrored.filter { if case .begin = $0 { true } else { false } }.count == 1)
        #expect(mirrored.filter { if case .end = $0 { true } else { false } }.count == 1)
        for m in mirrored { reader.take(m) }
        #expect(other.begins == 1 && other.count == live.count)
        // The journal line is marked as the shadow's.
        nonisolated(unsafe) var line: EarsJournal.Phrase?
        let r2 = ShadowReader(engine: .tone, recognizer: CountingRecognizer(), report: { line = $0 })
        for m in mirrored { r2.take(m) }
        #expect(line?.shadow == true && line?.engine == "tone" && line?.sent == nil)
        #expect(events.filter { if case .final = $0 { true } else { false } }.count == 1)
    }

    @Test func twoPhrasesAreTwoFinals() {
        let phrase = Array(repeating: loud, count: 6).flatMap { $0 } + Array(repeating: quiet, count: 8).flatMap { $0 }
        let (events, r) = run(phrase + phrase)
        let finals = events.filter { if case .final = $0 { true } else { false } }
        #expect(finals.count == 2)
        #expect(r.begins == 2)
    }

    @Test func flushFinishesAPhraseInProgress() {
        let (events, _) = run(Array(repeating: loud, count: 8).flatMap { $0 })
        #expect(events.contains { if case .final = $0 { true } else { false } })
    }

    @Test func runtimeTakesOnlyTheGivenPlaces() {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "ears-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let rt = EarsRuntime(root: tmp)
        try? FileManager.default.createDirectory(at: rt.library.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: rt.library.path, contents: Data())
        #expect(EarsRuntime.resolve(environment: ["VERA_EARS": tmp.path])?.library.path == rt.library.path)
        #expect(rt.gigaAMModel.path.hasSuffix("models/gigaam/model.int8.onnx"))
    }
}

@Suite struct EarsJournalTests {
    @Test func writesAndSummarisesWithoutWords() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ears-j-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let j = EarsJournal(directory: dir)
        let now = Date().timeIntervalSince1970
        j.append(.init(ts: now, engine: "gigaam", seconds: 2, firstPartialMs: 500, decodeMs: 60, chars: 20, partials: 4))
        j.append(.init(ts: now, engine: "gigaam", seconds: 4, firstPartialMs: 300, decodeMs: 100, chars: 40, partials: 8))
        j.append(.init(ts: now, engine: "tone", seconds: 3, firstPartialMs: nil, decodeMs: 10, chars: 30, partials: 9))
        let all = j.read()
        #expect(all.count == 3)
        let s = EarsJournal.summarize(all)
        #expect(s["gigaam"]?.phrases == 2)
        #expect(s["gigaam"]?.avgDecodeMs == 80)
        #expect(s["gigaam"]?.avgFirstPartialMs == 400)
        #expect(s["tone"]?.avgFirstPartialMs == nil)
        let raw = try String(contentsOf: j.file(for: Date()), encoding: .utf8)
        #expect(!raw.contains("text"))
    }
}
