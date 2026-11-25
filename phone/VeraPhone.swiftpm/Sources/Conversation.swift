import AVFAudio
import Foundation
import MediaPlayer
import UIKit
import Observation
import PhoneWire
import VeraListen

/// The phone's live conversation, as on the Mac — two layers on one microphone stream. **Vera**: inactive she sends
/// nothing and waits for the key phrase «Привет, Вера, …» (`WakePhrase`, shared with the Mac); active every finished phrase
/// goes to Hermes as spoken text, the answer is spoken sentence by sentence as it streams in, and speaking over Vera
/// stops her (and the agent's turn). The key phrase, the switch or the headset button make her active («Слушаю.»);
/// after `wakeIdle` seconds of nothing she waits again. **Запись** (its own switch, off by default on the phone):
/// everything heard is written to `Documents/Sensors/<day>/background.jsonl`, next to the activity log the Mac copies
/// home; never sent. Mechanics only — Hermes on the Mac decides and answers.
@MainActor @Observable
final class Conversation {
    enum Stage: String { case off = "выключен", starting = "включаю", listening = "слушаю", hearing = "слышу",
                          thinking = "думает", speaking = "говорит"
        /// The name on the wire (PhoneToVera.talk).
        var wire: String {
            switch self {
            case .off: "off"
            case .starting: "starting"
            case .listening: "listening"
            case .hearing: "hearing"
            case .thinking: "thinking"
            case .speaking: "speaking"
            }
        }
    }

    private(set) var stage: Stage = .off {
        didSet { if stage != oldValue { nowPlaying(); onStage?(stage.wire, paused); onVera?(active, stage == .speaking) } }
    }
    private(set) var problem: String?
    /// What the ears read so far in the phrase being said.
    private(set) var partial = ""
    private(set) var last: (text: String, seconds: Double, ms: Int)?
    private(set) var phrases = 0
    private(set) var interruptions = 0
    private(set) var vadOn = false
    private(set) var micLevel: Float = 0
    private(set) var voiceLevel: Float = 0
    /// The spectrogram: the last ~4 s, one column per 32 ms.
    private(set) var columns: [[Float]] = []
    private(set) var engine = ""
    /// The microphone's last second: buffers that came, the loudest sample (0…1), failed conversions.
    private(set) var micStatus = ""
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    /// The sentence Vera is saying now.
    private(set) var saying = "" { didSet { if !saying.isEmpty { nowPlaying() } } }
    /// When a phrase left for Hermes and when the voice last started a sentence — the board's flow dots.
    private(set) var phraseAt: Date?
    private(set) var sentenceAt: Date?
    /// Vera is active: every phrase goes to Hermes. Inactive (the microphone open) she waits for «Привет, Вера».
    private(set) var active = false {
        didSet { if active != oldValue { ears?.setWakeWatch(!active); onStage?(stage.wire, paused); nowPlaying(); onVera?(active, stage == .speaking) } }
    }
    /// «Привет, Вера» was heard in the words of the phrase still being said: Vera woke without waiting for its end.
    @ObservationIgnored private var wokeInPhrase = false
    /// «Я слушаю» without words: a word takes a second, and the next words would land on it.
    private func chime() { rig.earcon([(784, 60), (1175, 90)], volume: 0.3) }
    /// Waiting for «Вера» (the microphone open, Vera inactive) — the board's and the lock screen's «paused».
    var paused: Bool { on && !active }
    /// Vera was made active by the key word (not by the switch); how many times.
    private(set) var woke = false
    private(set) var wakes = 0
    static let wakeIdle: TimeInterval = 30
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var idleWatch: Task<Void, Never>?
    /// Recording: everything heard goes to the background journal (off by default on the phone: battery).
    private(set) var recording = UserDefaults.standard.bool(forKey: "vera.ears.recording") {
        didSet { UserDefaults.standard.set(recording, forKey: "vera.ears.recording") }
    }
    /// What the ears did, for finding faults: `Documents/Sensors/<day>/ears.jsonl` (the Mac copies it home with the
    /// activity log). Events, Vera's state, the phrase and what became of it, the link.
    @ObservationIgnored private let earsLog = DayLog(name: "ears.jsonl")
    func note(_ event: String, _ fields: [String: Any] = [:]) {
        var o = fields
        o["ev"] = event; o["active"] = active; o["stage"] = stage.wire; o["on"] = on
        o["link"] = "\(link.phase)" + (link.state.connected ? "+hermes" : "")
        earsLog.write(o)
    }

    private(set) var backgroundCount = 0
    private(set) var lastBackground: String?
    @ObservationIgnored private lazy var backgroundLog = BackgroundTranscript(
        directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Sensors"),
        dayFolders: true)
    /// Every change of stage or pause, for Vera's board (the iPhone tile on the Mac).
    @ObservationIgnored var onStage: ((String, Bool) -> Void)?
    /// Tell the board again (after a reconnect).
    func reportStage() { onStage?(stage.wire, paused) }
    /// Where the sound goes: «гарнитура» or «динамик».
    private(set) var route = "динамик"
    /// The models at work, for the lines under the ring.
    private(set) var vadSince: Date?
    private(set) var partialMs: Int?
    private(set) var tts: (latencyMs: Int, seconds: Double)?
    /// The voice as it sounds, for the ring (the last few seconds).
    private(set) var voiceTrace: [VoiceClip] = []
    var voiceSpeed: Float {
        get { rig.speed }
        set { rig.speed = newValue }
    }
    /// Vera's last answer, its first sentence (the ride screen).
    var lastAnswer: String? {
        link.items.last { $0.role == .assistant && $0.id > 0 }.map { Self.firstSentence($0.text) }
    }
    static let shownColumns = 125

    let link: Link
    /// The audio engine (microphone, voice, earcons — and the music while the microphone is open).
    @ObservationIgnored let rig = AudioRig()
    @ObservationIgnored private lazy var mouth = Mouth(rig: rig)
    @ObservationIgnored private var ears: Ears?
    @ObservationIgnored private var answerAfter = Int.max
    @ObservationIgnored private var spokenChars: [Int: Int] = [:]
    @ObservationIgnored private var speakingSince: Date?
    /// The music player takes the headset button while it plays (true — handled) and steps aside when talk starts.
    @ObservationIgnored var mediaButton: (() -> Bool)?
    @ObservationIgnored var willStart: (() -> Void)?
    /// The microphone opened / is about to close: the music moves onto the rig and back.
    @ObservationIgnored var didStart: (() -> Void)?
    @ObservationIgnored var willStop: (() -> Void)?
    /// Vera's state for the music's loudness: active, speaking.
    @ObservationIgnored var onVera: ((Bool, Bool) -> Void)?
    /// Listening starts by itself once per launch (not every time the first screen comes back).
    @ObservationIgnored var autostarted = false

    init(link: Link) {
        self.link = link
        if let v = UserDefaults.standard.object(forKey: "vera.voiceSpeed") as? Double { rig.speed = Float(v) }
        link.onItems = { [weak self] items in self?.answer(items) }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // Headphones in or out: the session policy depends on where the sound goes (no echo cancel only into them).
            MainActor.assumeIsolated { self?.updateRoute(); self?.refreshSession() }
        }
        let rc = MPRemoteCommandCenter.shared()
        for cmd in [rc.togglePlayPauseCommand, rc.playCommand, rc.pauseCommand] {
            cmd.isEnabled = true
            cmd.addTarget { [weak self] _ in
                MainActor.assumeIsolated { self?.headsetButton() }
                return .success
            }
        }
    }

    /// The headset's button: stop Vera if she speaks, otherwise make her active or waiting again.
    func headsetButton() {
        if mediaButton?() == true { return }
        guard on else { Task { await start(); setActive(true) }; return }
        if mouth.speaking || link.state.running {
            mouth.stop(); if link.state.running { link.send(.interrupt) }
            rig.earcon([(660, 70), (440, 90)])
            return
        }
        setActive(!active)
    }

    /// A navigation prompt: through Vera's mouth while the microphone is on (half-duplex keeps it out of the ears),
    /// otherwise the navigator's own speaker.
    func announce(_ text: String) {
        if on { mouth.sayFirst(text) } else { NavSpeaker.shared.say(text) }
    }

    static let bargeInAfter = 0.4

    private func bargeIn() {
        if mouth.speaking { mouth.stop(); interruptions += 1 }
        if link.state.running { link.send(.interrupt) }
        NSLog("VERA-TALK перебил")
    }

    /// Vera's switch: active — «Слушаю.» and every phrase goes to Hermes; inactive — waits for «Привет, Вера».
    /// `session: false` — the audio session is switched later (mid-phrase a switch in headphones over music restarts the
    /// engine and the words after «Привет, Вера» would be lost).
    func setActive(_ on: Bool, woke: Bool = false, session: Bool = true) {
        guard self.on else { note("activate-refused", ["want": on]); return }
        note(on ? "active" : "waiting", ["woke": woke])
        self.woke = on && woke
        if !on { idleWatch?.cancel(); active = false; ears?.reset(); partial = ""; rig.earcon([(520, 90), (390, 120)]); rig.applySession(chat: false, musicPlaying: musicPlaying()); return }
        let was = active
        active = true
        if session { rig.applySession(chat: true, musicPlaying: musicPlaying()) }
        lastActivity = Date()
        if !woke && !was { mouth.say("Слушаю.") }
        idleWatch?.cancel()
        idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.active else { return }
                if self.mouth.speaking || self.vadOn || self.link.state.running || self.stage == .thinking {
                    self.lastActivity = Date(); continue
                }
                if Date().timeIntervalSince(self.lastActivity) >= Self.wakeIdle { self.setActive(false); return }
            }
        }
    }

    /// Whether the music plays (wired by the tabs): the session policy depends on it —
    /// background listening over music keeps stereo A2DP instead of hands-free.
    @ObservationIgnored var musicPlaying: () -> Bool = { false }

    /// Re-asserts the audio session for the current use (call when the music starts or stops).
    func refreshSession() {
        guard on else { return }
        rig.applySession(chat: active, musicPlaying: musicPlaying())
    }

    /// Recording's switch (remembered), Mac semantics: recording owns the microphone.
    /// On — the mic opens by itself (Vera stays asleep, waits for «Привет, Вера»);
    /// off — if Vera is inactive, the mic closes fully.
    func toggleRecording() {
        recording.toggle()
        if recording {
            if !on { Task { await start() } }
        } else if on, !active {
            stop()
        }
    }

    private func updateRoute() {
        let out = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType
        let wearable: [AVAudioSession.Port] = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .headphones, .carAudio]
        route = out.map { wearable.contains($0) ? "гарнитура" : "динамик" } ?? "динамик"
    }

    /// The lock screen and the headset see Vera as what plays now.
    /// The lock screen and the headset see Vera as what plays now: the stage and the last words, at a glance.
    private func nowPlaying() {
        guard on else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        let words = !saying.isEmpty ? saying : (last?.text ?? "Hermes на Маке")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Вера · \(paused ? "жду «Привет, Вера»" : stage.rawValue)",
            MPMediaItemPropertyArtist: String(words.prefix(120)),
            MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : 1.0,
        ]
    }

    /// How strict the ears are about what counts as speech (the menu): "обычный", "ветер", "тихо".
    static func vadThreshold(_ mode: String) -> Float { mode == "ветер" ? 0.7 : mode == "тихо" ? 0.35 : 0.5 }

    func setHearing(_ mode: String) {
        UserDefaults.standard.set(mode, forKey: "vera.hearing")
        guard ears != nil else { return }
        let wasOn = on
        stop()
        ears = nil
        if wasOn { Task { await start() } }
    }

    var on: Bool { stage != .off }

    /// The app is on screen. In the background the ears decode only whole phrases (no words-as-spoken, no spectrogram):
    /// nobody sees them there, and they cost a core.
    @ObservationIgnored private var visible = true
    func setVisible(_ v: Bool) {
        visible = v
        ears?.setLive(v)
        note(v ? "foreground" : "background")
    }

    func toggle() { if on { stop() } else { Task { await start() } } }

    func start() async {
        guard stage == .off else { return }
        willStart?()
        stage = .starting; problem = nil
        // The microphone only after the owner said yes: touching the input before that hangs the audio engine.
        if AVAudioApplication.shared.recordPermission != .granted {
            let ok = await AVAudioApplication.requestRecordPermission()
            guard ok else { fail("нет доступа к микрофону: Настройки → Вера → Микрофон"); return }
        }
        do {
            if ears == nil {
                let threshold = Self.vadThreshold(UserDefaults.standard.string(forKey: "vera.hearing") ?? "обычный")
                let made: Result<Ears, Error> = await Task.detached {
                    Result { try Ears(threshold: threshold) { event in Task { @MainActor [weak self] in self?.heard(event) } } }
                }.value
                ears = try made.get()
                engine = "GigaAM v3 · sherpa-onnx \(ears?.version ?? "")"
            }
            let ears = ears!
            ears.setLive(visible)
            ears.setWakeWatch(!active)
            rig.onMic = { samples in ears.feed(samples) }
            rig.onSession = { [weak self] mode in self?.note("session", ["mode": mode]) }
            mouth.onLevel = { [weak self] l in self?.voiceLevel = l }
            mouth.onStats = { [weak self] ms, sec in self?.tts = (ms, sec) }
            mouth.onClip = { [weak self] clip in
                guard let self else { return }
                self.voiceTrace.append(clip)
                let cut = Date().addingTimeInterval(-3)
                self.voiceTrace.removeAll { $0.start.addingTimeInterval($0.seconds) < cut }
            }
            mouth.onSentence = { [weak self] t in self?.saying = t; if !t.isEmpty { self?.sentenceAt = Date() } }
            mouth.onSpeaking = { [weak self] s in
                guard let self else { return }
                if s { self.stage = .speaking } else if self.stage == .speaking { self.stage = .listening }
            }
            try rig.start(chat: false, musicPlaying: musicPlaying())
            stage = .listening
            active = false   // the microphone open, Vera waits for «Привет, Вера»
            didStart?()
            note("mic-on")
            updateRoute()
            nowPlaying()
            rig.earcon([(523, 70), (784, 110)])
            meterTask?.cancel()
            meterTask = Task { [weak self] in
                var tick = 0
                while !Task.isCancelled, let self, self.on {
                    try? await Task.sleep(for: .seconds(1))
                    let m = self.rig.meter.take()
                    self.micStatus = "\(self.rig.inputDescription) · \(m.buffers) буф/с · пик \(String(format: "%.3f", m.peak))\(m.dropped > 0 ? " · потеряно \(m.dropped)" : "")\(self.rig.engineRunning ? "" : " · движок стоит")\(self.rig.restarts > 0 ? " · перезапусков \(self.rig.restarts)" : "")"
                    tick += 1
                    if tick % 5 == 1 {
                        NSLog("VERA-MIC %@ · стадия %@", self.micStatus, self.stage.rawValue)
                        let h = await Task.detached { [ears = self.ears] in ears?.health() ?? (windows: -1, loudest: 0, speech: 0, nonFinite: 0) }.value
                        self.note("mic", ["buffers": m.buffers, "peak": Double(m.peak), "dropped": m.dropped,
                                          "engine": self.rig.engineRunning, "restarts": self.rig.restarts, "windows": h.windows,
                                          "earsLoudest": Double(h.loudest), "vadSpeech": h.speech, "nonFinite": h.nonFinite])
                    }
                }
            }
        } catch {
            fail("не включился: \(error.localizedDescription)")
        }
    }

    func stop() {
        if on { note("mic-off"); willStop?(); rig.earcon([(784, 70), (523, 110)]) }
        mouth.stop()
        rig.stop(keepSession: musicPlaying())
        ears?.reset()
        idleWatch?.cancel(); active = false; woke = false
        stage = .off
        partial = ""; vadOn = false; micLevel = 0; voiceLevel = 0; saying = ""
        nowPlaying()
    }

    private func fail(_ text: String) {
        NSLog("VERA-TALK ошибка: %@", text)
        rig.stop()
        stage = .off
        problem = text
    }

    // MARK: Ears → Hermes

    private func heard(_ e: Ears.Event) {
        guard on else { return }
        switch e {
        case .column(let c, let level):
            columns.append(c)
            if columns.count > Self.shownColumns { columns.removeFirst(columns.count - Self.shownColumns) }
            micLevel = level
        case .speaking(let s):
            NSLog("VERA-EARS %@", s ? "речь" : "тишина")
            note(s ? "speech" : "silence")
            vadOn = s
            vadSince = s ? Date() : nil
            if s {
                stage = .hearing; partial = ""; wokeInPhrase = false
                // Speaking over Vera stops her and the agent's turn — but only real speech, held for a moment:
                // wind or a bump on the road is short and must not cut her off.
                if active, mouth.speaking || link.state.running {
                    let at = vadSince
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(Int(Self.bargeInAfter * 1000)))
                        guard let self, self.vadOn, self.vadSince == at else { return }
                        self.bargeIn()
                    }
                }
            }
        case .partial(let t, let ms):
            partial = t
            partialMs = ms
            // The key phrase in the words so far: awake at once — no waiting for the pause after it; what is said on
            // goes as the request when the phrase ends.
            if !active, !wokeInPhrase, WakePhrase.match(t) != nil {
                wokeInPhrase = true
                note("wake-early", ["text": t])
                wakes += 1
                setActive(true, woke: true, session: false)
                chime()
            }
        case .final(let text, let seconds, let ms):
            partial = ""
            NSLog("VERA-EARS фраза «%@» %.1f с %d мс", text, seconds, ms)
            guard !text.isEmpty else { note("phrase", ["text": "", "action": "empty"]); if stage == .hearing { stage = .listening }; return }
            let wokeEarly = wokeInPhrase
            wokeInPhrase = false
            let request = active && !wokeEarly ? nil : WakePhrase.match(text)
            note("phrase", ["text": text, "seconds": seconds, "action": wokeEarly ? "woke-early" : active ? "send" : request == nil ? "ignore" : "wake"])
            if recording {
                backgroundLog.append(.init(ts: Date().timeIntervalSince1970, text: text, seconds: seconds, db: 0, woke: request != nil))
                backgroundCount += 1; lastBackground = text
            }
            if wokeEarly {
                rig.applySession(chat: true, musicPlaying: musicPlaying())
                if let request, !request.isEmpty { send(request, seconds: seconds, ms: ms) }
                else { lastActivity = Date(); if stage == .hearing { stage = .listening } }
                return
            }
            if !active {
                if stage == .hearing { stage = .listening }
                guard let request else { return }
                // The key word: Vera becomes active; the rest of the phrase goes on as the request.
                wakes += 1
                setActive(true, woke: true)
                if request.isEmpty { chime(); return }
                send(request, seconds: seconds, ms: ms)
                return
            }
            send(text, seconds: seconds, ms: ms)
        }
    }

    private func send(_ text: String, seconds: Double, ms: Int) {
        lastActivity = Date()
        last = (text, seconds, ms)
        phrases += 1
        answerAfter = link.items.map(\.id).max() ?? 0
        link.send(.spoken(text: text)) { [weak self] why in self?.note("sent", ["ok": why == nil, "error": why ?? ""]) }
        phraseAt = Date()
        rig.earcon([(880, 60)], volume: 0.18)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        stage = .thinking
    }

    // MARK: Hermes → voice

    /// Speak the answer to the last phrase as it streams: every finished sentence goes to the voice at once.
    private func answer(_ items: [PhoneItem]) {
        guard on else { return }
        for item in items where item.role == .assistant && item.id > answerAfter {
            let said = spokenChars[item.id] ?? 0
            let text = item.text
            guard text.count > said else { continue }
            let rest = String(text.dropFirst(said))
            let cut = item.done ? rest.count : Self.lastSentenceEnd(rest)
            guard cut > 0 else { continue }
            mouth.say(String(rest.prefix(cut)))
            spokenChars[item.id] = said + cut
        }
        if stage == .thinking, !link.state.running, !mouth.speaking { stage = .listening }
    }

    static func firstSentence(_ s: String) -> String {
        let t = Array(Mouth.clean(s))
        var i = 0
        while i < t.count {
            if ".!?…\n".contains(t[i]), i + 1 == t.count || t[i + 1] == " " || t[i + 1] == "\n" {
                return String(t[0...i]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            i += 1
        }
        return String(t.prefix(160))
    }

    /// Characters up to and including the last sentence end (. ! ? … or a line break) followed by a space.
    static func lastSentenceEnd(_ s: String) -> Int {
        var end = 0, i = 0
        let chars = Array(s)
        while i < chars.count {
            if ".!?…\n".contains(chars[i]), i + 1 < chars.count, chars[i + 1] == " " || chars[i + 1] == "\n" { end = i + 1 }
            i += 1
        }
        return end
    }
}

/// One JSON line per event into `Documents/Sensors/<day>/<name>` (the day folder the Mac copies home), written off the
/// main thread.
final class DayLog: @unchecked Sendable {
    private let name: String
    private let queue = DispatchQueue(label: "vera.daylog")
    private let day: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    init(name: String) { self.name = name }

    func write(_ fields: [String: Any]) {
        var o = fields
        let now = Date()
        o["ts"] = now.timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: o) else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Sensors").appending(path: day.string(from: now))
        queue.async { [name] in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appending(path: name)
            var line = data; line.append(0x0A)
            if let h = try? FileHandle(forWritingTo: url) { defer { try? h.close() }; _ = try? h.seekToEnd(); try? h.write(contentsOf: line) }
            else { try? line.write(to: url) }
        }
    }
}
