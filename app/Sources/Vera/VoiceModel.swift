import AppKit
import AVFoundation
import Foundation
import Observation
import HermesBridge
import VeraEars
import SileroVoice

/// Vera's own ears and mouth for the main session — a live conversation, not recorded pieces.
/// Ears: the microphone with echo cancellation, Silero VAD for where a phrase begins and ends (silence — mechanics,
/// not meaning), and GigaAM or T-one from the box reading the phrase while it is said. Nothing outside the app is
/// used: no Siri, no Dictation, no Apple speech service. The mouth speaks the answer sentence by sentence while the
/// agent is still writing it; starting to talk while Vera speaks stops her and interrupts the turn (barge-in).
/// Hermes' own voice (`voice.record`) is not used: it would open the microphone in the gateway's Python process.
@MainActor @Observable
final class VoiceModel {
    enum Phase: Equatable { case idle, listening, speaking }

    /// Two layers on one microphone stream.
    /// **Recording** (`background`, its own switch, on by default and remembered): the microphone is open and everything
    /// recognised is written to the background transcript (`ears/background-*.jsonl`) — never sent; other apps' sound
    /// is not ducked. **Vera** (its own switch, ⌘L): inactive — she sends nothing and waits for the key phrase («Привет, Вера, …»,
    /// `WakePhrase`); active — a conversation, every phrase goes to the agent (and is
    /// still recorded). The key phrase makes her active and its rest goes to the agent. Active goes back to inactive
    /// after `wakeIdle` seconds with nothing said, heard or running, or by the switch. With recording off the microphone
    /// is open only while Vera is active.
    /// `mode`: `.background` — open, Vera inactive; `.direct` — open, Vera active; `.off` — closed.
    enum Mode: Equatable { case off, direct, background }
    private(set) var mode: Mode = .off { didSet { if mode != oldValue { music.follow(active: mode == .direct, speaking: speaking) } } }
    /// Recording is switched on (the microphone stays open under a conversation and keeps writing).
    private(set) var background = UserDefaults.standard.object(forKey: "vera.ears.recording") as? Bool ?? true {
        didSet { UserDefaults.standard.set(background, forKey: "vera.ears.recording") }
    }
    /// Vera is active: every phrase goes to the agent.
    var active: Bool { mode == .direct }
    var listening: Bool { mode != .off }
    /// The loudness a background phrase must reach, dBFS (median level of the phrase).
    var thresholdDB: Double = UserDefaults.standard.object(forKey: "vera.ears.threshold") as? Double ?? -45 {
        didSet { UserDefaults.standard.set(thresholdDB, forKey: "vera.ears.threshold") }
    }
    private(set) var lastLoudness: Loudness?
    /// The last phrase written in background, how many were written, and how many opened the conversation.
    private(set) var lastBackground: (text: String, db: Double)?
    private(set) var backgroundCount = 0
    private(set) var wakes = 0
    /// Vera was made active by the key word (not by the switch).
    private(set) var woke = false
    static let wakeIdle: TimeInterval = 30
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var idleWatch: Task<Void, Never>?
    @ObservationIgnored private lazy var backgroundLog = BackgroundTranscript(directory: chat.board.runtime.dataRoot.appending(path: "ears"))
    private(set) var speaking = false {
        didSet { if speaking != oldValue { deafen(speaking); music.follow(active: mode == .direct, speaking: speaking) } }
    }
    var phase: Phase { speaking ? .speaking : listening ? .listening : .idle }
    /// The phrase being said, as the ears read it so far.
    private(set) var partial = ""
    private(set) var hearing = false
    private(set) var level: Float = 0
    private(set) var problem: String?
    private(set) var echoCancelling: Bool?
    /// The last phrase heard and the last one spoken (the board's voice tile).
    private(set) var lastHeard: String?
    private(set) var lastSpoken: String?
    /// The last phrase's length and how long the ears took to finish it after it ended.
    private(set) var lastTiming: (seconds: Double, decodeMs: Int)?
    private(set) var loadMs: Int?
    /// Signals of this run: phrases heard, times Vera was talked over.
    private(set) var phrases = 0
    private(set) var interruptions = 0
    private(set) var firstPartialMs: Int?
    /// Smart Turn's last word: probability the phrase was finished and whether it ended it; `holding` — the ears
    /// wait for the speaker to go on.
    private(set) var lastTurn: (probability: Double, finished: Bool)?
    private(set) var holding = false
    /// Who spoke the last phrase (CAM++ against the voice book) and the book itself (`voices.json`, local only).
    private(set) var lastSpeaker: (name: String?, cosine: Double, owner: Bool)?
    private(set) var enrollLeft = 0
    @ObservationIgnored private lazy var voicesURL = chat.board.runtime.dataRoot.appending(path: "voices.json")
    @ObservationIgnored private(set) lazy var voiceBook = VoiceBook.load(voicesURL)
    @ObservationIgnored private var pendingNote = ""
    /// Smart Turn is in the box (the mouth's build has it).
    var smartTurn: Bool { mouthRuntime.map { FileManager.default.fileExists(atPath: $0.root.appending(path: "smart-turn-worker.py").path) } ?? false }
    /// CAM++ is in the box (the ears' build has the speaker model).
    var speakersReady: Bool { earsRuntime.map { FileManager.default.fileExists(atPath: $0.root.appending(path: "models/speaker/campplus.onnx").path) } ?? false }
    /// The engines compared over the last week (from the ears' journal).
    private(set) var comparison: [String: EarsJournal.Summary] = [:]
    var speakReplies = true
    /// Compare the engines: the other one reads the same sound in the shadow, its counts go to the journal only.
    /// Off by default — it doubles the ears' work while the microphone is open.
    var compareEngines: Bool = UserDefaults.standard.bool(forKey: "vera.ears.compare") {
        didSet {
            UserDefaults.standard.set(compareEngines, forKey: "vera.ears.compare")
            if listening, oldValue != compareEngines { let m = mode; Task { stop(send: false); await listen(m) } }
        }
    }
    var engine: EarsEngine = EarsEngine(rawValue: UserDefaults.standard.string(forKey: "vera.ears.engine") ?? "") ?? .gigaam {
        didSet {
            UserDefaults.standard.set(engine.rawValue, forKey: "vera.ears.engine")
            if listening, oldValue != engine { let m = mode; Task { stop(send: false); await listen(m) } }
        }
    }

    let chat: ChatModel
    /// Music played by Vera herself (`MacMusic`): its loudness follows her — quiet while she is active.
    let music: MacMusic
    /// Vera's browser on the Mac (`MacBrowser`): Hermes fills forms in it, the owner finishes (CAPTCHA, the last button).
    let browser: MacBrowser
    let earsRuntime = EarsRuntime.resolve()
    @ObservationIgnored private lazy var ears: EarsSession? = earsRuntime.map(EarsSession.init)
    /// Silero (voice baya) from the box; without it, the system voice.
    let mouthRuntime = MouthRuntime.resolve()
    @ObservationIgnored private var mouth: Mouth?
    var speed: Double = UserDefaults.standard.object(forKey: "vera.mouth.speed") as? Double ?? 1.05 {
        didSet { UserDefaults.standard.set(speed, forKey: "vera.mouth.speed"); mouth?.speed = Float(speed) }
    }
    /// The answer's text as far as it has been spoken, per transcript item: the text appears with the voice.
    private(set) var revealed: [Int: String] = [:]
    /// The live picture: the microphone's outline (a point per 20 ms, with whether the VAD heard speech) and the
    /// mouth's sentences (outline per 20 ms of audio, when it started, how fast it plays). Last few seconds only.
    struct MicPoint { let t: Double; let v: Float; let speech: Bool }
    /// A spectrogram column (`Spectrum.bands` dBFS, low to high) and when it was heard.
    struct SpecColumn { let t: Double; let bands: [Float] }
    struct MouthClip { let start: Double; let peaks: [Float]; let seconds: Double }
    @ObservationIgnored private(set) var micTrace: [MicPoint] = []
    @ObservationIgnored private(set) var specTrace: [SpecColumn] = []
    @ObservationIgnored private(set) var mouthTrace: [MouthClip] = []
    /// Bumped on every new piece of the live picture (the views redraw from the two traces above).
    private(set) var liveTick = 0
    @ObservationIgnored private var replyOpen = false
    @ObservationIgnored private var spokeThisReply = false
    @ObservationIgnored private let synth = AVSpeechSynthesizer()
    @ObservationIgnored private let synthDelegate = SynthDelegate()
    @ObservationIgnored private var chunker = SpeechChunker()
    @ObservationIgnored private var phraseStarted: Date?
    /// «Привет, Вера» was heard in the words of the phrase still being said: Vera woke without waiting for its end.
    @ObservationIgnored private var wokeInPhrase = false
    @ObservationIgnored private var partialCount = 0
    @ObservationIgnored private lazy var journal = EarsJournal(directory: chat.board.runtime.dataRoot.appending(path: "ears"))

    init(chat: ChatModel) {
        self.chat = chat
        music = MacMusic(dataRoot: chat.board.runtime.dataRoot)
        browser = MacBrowser(dataRoot: chat.board.runtime.dataRoot)
        browser.watch()
        synth.delegate = synthDelegate
        if let rt = mouthRuntime {
            let m = Mouth(runtime: rt)
            m.speed = Float(speed)
            m.onSentence = { [weak self] s in Task { @MainActor in self?.sentenceStarted(s) } }
            m.onIdle = { [weak self] in Task { @MainActor in self?.speechFinished() } }
            m.onError = { [weak self] e in Task { @MainActor in self?.problem = "Голос: \(e)" } }
            m.warm()
            mouth = m
        }
        synthDelegate.onIdle = { [weak self] in Task { @MainActor in self?.speechFinished() } }
        chat.onAssistant = { [weak self] e in self?.assistant(e) }
        chat.onRequest = { [weak self] r in self?.question(r) }
        refreshComparison()
    }

    func refreshComparison() {
        comparison = EarsJournal.summarize(journal.read())
    }

    /// The shadow engine's phrase (same audio, other engine): journal only, never to the agent.
    private func shadowHeard(_ p: EarsJournal.Phrase) {
        journal.append(p)
        refreshComparison()
    }

    var voiceName: String {
        if let rt = mouthRuntime { return "Silero \(rt.speaker)\(mouth.map { $0.voiceEngine == "Swift" ? " · без Python" : " · Python" } ?? "")" }
        return AVSpeechSynthesisVoice(language: "ru-RU")?.name ?? "системный"
    }

    // MARK: Listening

    /// Vera's switch (⌘L): active ↔ inactive; becoming active she says «Слушаю.», as on the key word. With recording off,
    /// becoming inactive closes the microphone.
    func toggle() async {
        switch mode {
        case .direct: woke = false; idleWatch?.cancel(); if background { mode = .background } else { stop(send: true) }
        case .background: activate(woke: false); say("Слушаю.")
        case .off: await listen(.direct); if mode == .direct { activate(woke: false); say("Слушаю.") }
        }
    }

    /// Recording's switch: the always-open microphone that writes everything, on or off (remembered).
    func toggleBackground() async {
        background.toggle()
        if background {
            if mode == .off { await listen(.background) }
            if mode == .off { background = false }   // did not open
        } else if mode == .background {
            stop(send: false)
        }
    }

    /// At launch: recording starts if it was on.
    func startRecordingIfOn() async {
        guard background, mode == .off else { return }
        await listen(.background)
        if mode == .off { background = false }
    }

    func listen(_ mode: Mode = .direct) async {
        problem = nil
        guard let ears else { problem = EarsError.notBuilt.localizedDescription; return }
        guard await Self.microphonePermitted() else {
            problem = "Нет доступа к микрофону: Системные настройки → Конфиденциальность → Микрофон → Вера."
            return
        }
        let engine = self.engine
        let shadow: EarsEngine? = compareEngines ? (engine == .gigaam ? .tone : .gigaam) : nil
        do {
            let opened = try await Task.detached { [weak self] in
                try ears.start(engine: engine, shadow: shadow, voiceProcessing: false,
                               onEvent: { e in Task { @MainActor in self?.heard(e) } },
                               onLevel: { l, peaks, cols in Task { @MainActor in self?.heardLevel(l, peaks, cols) } },
                               onShadowPhrase: { p in Task { @MainActor in self?.shadowHeard(p) } })
            }.value
            echoCancelling = opened.echoCancelling
            loadMs = opened.loadMs
            partial = ""
            self.mode = mode
        } catch {
            problem = "Уши не открылись: \(error.localizedDescription)"
        }
    }

    /// Ends the conversation; with `send`, a phrase in progress is finished and sent.
    func stop(send: Bool) {
        guard listening else { return }
        mode = .off
        level = 0
        ears?.stop(finish: send)
        if !send { partial = ""; hearing = false }
    }

    /// `--snapshot-flows` only: a few seconds of sound to see the waves drawn.
    func drawingSample(now: Double) {
        micTrace = (0..<200).map { i in
            let speech = (60..<150).contains(i)
            return MicPoint(t: now - 4 + Double(i) * 0.02, v: Float(speech ? 0.06 + 0.1 * abs(sin(Double(i) * 0.7)) : 0.004), speech: speech)
        }
        specTrace = (0..<200).map { i in
            let speech = (60..<150).contains(i)
            return SpecColumn(t: now - 4 + Double(i) * 0.02, bands: (0..<Spectrum.bands).map { b in
                speech ? Float(-28 - Double(b) * 0.7 + 14 * sin(Double(b) * 0.9 + Double(i) * 0.3)) : -90 })
        }
        mouthTrace = [MouthClip(start: now - 2, peaks: (0..<150).map { Float(0.2 + 0.4 * abs(sin(Double($0) * 0.3))) }, seconds: 3)]
        liveTick &+= 1
    }

    private func heardLevel(_ rms: Float, _ peaks: [Float], _ columns: [[Float]]) {
        level = rms
        let now = Date().timeIntervalSince1970
        let step = 0.02
        for (i, p) in peaks.enumerated() {
            micTrace.append(MicPoint(t: now - Double(peaks.count - 1 - i) * step, v: p, speech: hearing))
        }
        if micTrace.count > 400 { micTrace.removeFirst(micTrace.count - 400) }
        for (i, c) in columns.enumerated() {
            specTrace.append(SpecColumn(t: now - Double(columns.count - 1 - i) * step, bands: c))
        }
        if specTrace.count > 300 { specTrace.removeFirst(specTrace.count - 300) }
        liveTick &+= 1
    }

    private func heard(_ e: HearingEvent) {
        switch e {
        case .started:
            hearing = true
            partial = ""
            phraseStarted = Date()
            wokeInPhrase = false
            partialCount = 0
            firstPartialMs = nil
            chat.board.noteFlow(.micToGate)
            chat.board.noteFlow(.gateToEars)
            // Barge-in: talking over Vera stops her voice and the turn she is speaking for. In background only a sound
            // over the threshold does it (the television must not silence her).
            let loudEnough = mode != .background || Loudness.decibels(level) >= thresholdDB
            if speaking && loudEnough {
                interruptions += 1
                chat.board.pulse.turns.abort(at: Date().timeIntervalSince1970)
                stopSpeaking()
                if chat.transcript.running { Task { await chat.interrupt() } }
            }
        case .voiceprint(let v):
            chat.board.noteFlow(.voiceprint)
            if enrollLeft > 0 {
                voiceBook.add(v, to: "владелец", owner: true); voiceBook.save(voicesURL); enrollLeft -= 1
                lastSpeaker = ("владелец", 1, true); pendingNote = ""
            } else if let m = voiceBook.identify(v) {
                lastSpeaker = (m.person?.name, m.cosine, m.person?.owner ?? false)
                pendingNote = SpeakerNote.prefix(book: voiceBook, match: m)
            }
        case .judged(let p, let finished):
            lastTurn = (p, finished)
            holding = !finished
            chat.board.noteFlow(.turnJudge)
            if finished { chat.board.noteFlow(.judgeToEars, at: Date().addingTimeInterval(FlowMonitor.flight * 0.6)) }
        case .partial(let text):
            partial = text
            partialCount += 1
            if firstPartialMs == nil, let t0 = phraseStarted { firstPartialMs = Int(Date().timeIntervalSince(t0) * 1000) }
            chat.board.noteFlow(.micToEars)
            // The key phrase in the words so far: awake at once — no waiting for the pause after the phrase; what is
            // said on goes as the request when the phrase ends.
            if mode == .background, !wokeInPhrase, WakePhrase.match(text) != nil {
                wokeInPhrase = true
                wakes += 1
                activate(woke: true)
                Self.chime()
            }
        case .final(let text, let seconds, let ms, let loudness):
            hearing = false
            holding = false
            partial = ""
            lastTiming = (seconds, ms)
            lastLoudness = loudness
            phrases += 1
            chat.board.noteFlow(.gateToEars)
            chat.board.noteFlow(.earsMerge)
            let wokeEarly = wokeInPhrase
            wokeInPhrase = false
            let inBackground = mode == .background || wokeEarly
            // The key word alone decides (no loudness gate: a short «Вера» is mostly silence, its median level is low).
            let request = inBackground ? WakePhrase.match(text) : nil
            let goes = !text.isEmpty && (!inBackground || request?.isEmpty == false)
            var entry = EarsJournal.Phrase(ts: Date().timeIntervalSince1970, engine: engine.rawValue, seconds: seconds,
                                           firstPartialMs: firstPartialMs, decodeMs: ms, chars: text.count, partials: partialCount)
            entry.db = (loudness.db * 10).rounded() / 10
            entry.sent = goes
            journal.append(entry)
            refreshComparison()
            if goes {
                let end = Date().timeIntervalSince1970 - Double(ms) / 1000
                chat.board.pulse.turns.phrase(start: end - seconds, end: end, decodeMs: ms)
            }
            if background, !text.isEmpty {
                backgroundLog.append(.init(ts: Date().timeIntervalSince1970, text: text, seconds: seconds,
                                           db: (loudness.db * 10).rounded() / 10, woke: request != nil))
                lastBackground = (text, loudness.db); backgroundCount += 1
            }
            if wokeEarly {
                lastActivity = Date()
                if let request, !request.isEmpty { deliver(request) }
            } else if inBackground {
                if let request { wake(request) }
            } else {
                lastActivity = Date()
                deliver(text)
            }
        }
    }

    private func deliver(_ text: String) {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        lastHeard = said
        // A short «да» / «нет» answers the agent's open approval question instead of becoming a message.
        if let approval = chat.transcript.pending.first(where: { $0.method == "approval" }),
           let answer = VoiceApproval.parse(said) {
            Task { await chat.answer(approval, result: .object(["choice": .string(answer == .once ? "once" : "deny")])) }
            say(answer == .once ? "Разрешила." : "Запретила.")
            return
        }
        let note = pendingNote; pendingNote = ""
        Task { await chat.sendText(note + said, display: "🎙 " + note + said, spoken: true) }
    }

    /// The microphone is a plain input (no system voice processing: opening it never glitches or ducks the Mac's
    /// sound, a call in Zoom is not touched). So while Vera speaks the ears do not listen — she would hear herself — and
    /// for a short tail after (the room's echo); she is interrupted by the switch or ⌘L, not by voice.
    @ObservationIgnored private var undeafen: Task<Void, Never>?
    static let deafTail: Duration = .milliseconds(500)
    private func deafen(_ on: Bool) {
        undeafen?.cancel()
        if on { ears?.deaf(true); return }
        undeafen = Task { [weak self] in
            try? await Task.sleep(for: Self.deafTail)
            guard !Task.isCancelled, let self, !self.speaking else { return }
            self.ears?.deaf(false)
        }
    }

    /// The key word while inactive: Vera becomes active; the rest of the phrase goes to the agent, or a short chime
    /// says she listens (not «Слушаю.»: a word takes a second, and the next words would land on it).
    private func wake(_ request: String) {
        wakes += 1
        activate(woke: true)
        if request.isEmpty { Self.chime() } else { deliver(request) }
    }

    /// «Я слушаю» without words: the system's short sound.
    static func chime() { NSSound(named: "Tink")?.play() }

    /// Vera active, and back to inactive after `wakeIdle` seconds of nothing (nothing said, heard, spoken or running).
    private func activate(woke: Bool) {
        self.woke = woke
        mode = .direct
        lastActivity = Date()
        idleWatch?.cancel()
        idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.mode == .direct else { return }
                if self.speaking || self.hearing || self.chat.transcript.running { self.lastActivity = Date(); continue }
                if Date().timeIntervalSince(self.lastActivity) >= Self.wakeIdle {
                    self.woke = false
                    if self.background { self.mode = .background } else { self.stop(send: false) }
                    return
                }
            }
        }
    }

    /// «Запомнить мой голос»: the next three phrases become the owner's voice in the book.
    func enrollOwner() { enrollLeft = 3 }
    func forgetVoices() { voiceBook = VoiceBook(); voiceBook.save(voicesURL); lastSpeaker = nil }

    // MARK: Speaking

    private func assistant(_ e: ChatModel.AssistantEvent) {
        let now = Date().timeIntervalSince1970
        switch e {
        case .start: chat.board.pulse.turns.messageStarted(at: now)
        case .delta: chat.board.pulse.turns.messageStarted(at: now)
        case .complete, .interim: break
        }
        defer { if case .complete = e { chat.board.pulse.turns.messageCompleted(at: now, voicePending: speaking) } }
        guard speakReplies else { return }
        let id = currentReplyId
        switch e {
        case .start:
            chunker.reset()
            replyOpen = true
            spokeThisReply = false
        case .delta(let t):
            replyOpen = true
            if mouth != nil, let id, revealed[id] == nil { revealed[id] = "" }
            let parts = chunker.add(t)
            if !parts.isEmpty { spokeThisReply = true }
            parts.forEach { say($0, reply: id) }
        case .interim(let text):
            // «Проверяю погоду…» — the agent's word in the middle of the turn, spoken as it comes.
            let said = SpeechChunker.speakable(text)
            if !said.isEmpty { say(said) }
        case .complete:
            let parts = chunker.flush()
            if !parts.isEmpty { spokeThisReply = true }
            parts.forEach { say($0, reply: id) }
            replyOpen = false
            if !speaking { revealed.removeAll() }
            // A reply of only code, paths or links has nothing to read aloud — say so instead of silent nothing.
            if !spokeThisReply { lastSpoken = "— нечего озвучить: в ответе только код или ссылки" }
        }
    }

    private func question(_ r: ChatTranscript.PendingRequest) {
        guard speakReplies else { return }
        if r.method == "approval" {
            let what = r.description ?? r.command ?? "действие"
            say("Агент просит разрешения: \(SpeechChunker.speakable(what)). Скажи «да» или «нет».")
        } else if let q = r.questions.first {
            say("Агент уточняет: \(SpeechChunker.speakable(q.question))")
        }
    }

    private var currentReplyId: Int? {
        chat.transcript.items.last(where: { if case .assistant = $0.kind { return true }; return false })?.id
    }

    /// `reply`: the transcript item this sentence belongs to (its text is shown as it is spoken).
    func say(_ text: String, reply: Int? = nil) {
        chat.board.noteFlow(.adapterToVoice)
        lastSpoken = text
        speaking = true
        if let mouth { mouth.say(text, voice: SpeechText.forVoice(text), tag: reply ?? -1); return }
        let utterance = AVSpeechUtterance(string: SpeechText.forVoice(text))
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synth.speak(utterance)
    }

    private func sentenceStarted(_ s: Mouth.Sentence) {
        let now = Date().timeIntervalSince1970
        mouthTrace.append(MouthClip(start: now, peaks: s.peaks, seconds: s.seconds))
        mouthTrace.removeAll { now - ($0.start + $0.seconds) > 6 }
        liveTick &+= 1
        chat.board.pulse.turns.voiceStarted(at: now)
        guard s.tag >= 0, revealed[s.tag] != nil else { return }
        revealed[s.tag] = (revealed[s.tag]!.isEmpty ? "" : revealed[s.tag]! + " ") + s.text
    }

    func stopSpeaking() {
        mouth?.stop()
        synth.stopSpeaking(at: .immediate)
        chunker.reset()
        speaking = false
        revealed.removeAll()
    }

    private func speechFinished() {
        guard mouth != nil || !synth.isSpeaking else { return }
        speaking = false
        if !replyOpen { revealed.removeAll() }
        chat.board.pulse.turns.voiceIdle(at: Date().timeIntervalSince1970)
    }

    // MARK: Permissions

    /// The system answers on its own queue, so nothing here may be bound to the main actor.
    nonisolated static func microphonePermitted() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

private final class SynthDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onIdle: (@Sendable () -> Void)?
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { onIdle?() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { onIdle?() }
}
