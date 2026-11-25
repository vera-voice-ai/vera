import AVFoundation
import CSherpaPhone
import Foundation
import SileroVoice

/// One audio engine for the microphone and the voice, with the system's voice processing on: echo cancellation, so
/// the ears do not hear Vera's own voice and the owner can interrupt her. The microphone goes to the ears as 16 kHz
/// mono (channel 0 — voice processing may hand several channels); the voice is played by a player node on the same
/// engine, which is what lets the echo canceller subtract it.
@MainActor
final class AudioRig {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Vera's voice speed, pitch kept (×1.15 like the Mac's Silero); earcons go around it.
    private let pitch = AVAudioUnitTimePitch()
    private let beeper = AVAudioPlayerNode()
    var speed: Float = 1.0 { didSet { pitch.rate = speed } }
    /// The microphone's path through the graph, silenced: with voice processing on, an input that leads nowhere is
    /// never pulled and its tap stays quiet.
    private let sink = AVAudioMixerNode()
    private(set) var running = false
    let meter = MicMeter()
    /// The input format voice processing handed out (for the log and the scheme).
    private(set) var inputDescription = ""
    /// 16 kHz mono chunks (called on the audio thread).
    var onMic: (@Sendable ([Float]) -> Void)?
    /// Every audio-session decision, for the day's journal (which mode, why, where the sound goes).
    var onSession: ((String) -> Void)?
    nonisolated static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    /// The voice's and the signals' own format, fixed: their nodes are connected once with it and the mixer converts
    /// to whatever the session gives. (Taken from the mixer, it changed when the session switched — voice processing on
    /// or off — and scheduling a buffer in the new format on a node connected in the old one threw and killed the app.)
    let playerFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    var engineRunning: Bool { engine.isRunning }
    private(set) var restarts = 0

    init() {
        engine.attach(player)
        engine.attach(pitch)
        engine.attach(beeper)
        engine.attach(sink)
        pitch.rate = speed
        // A route or session change stops the engine (and silences the tap): start it again with the new format.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconfigure() }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            nonisolated(unsafe) let n = n
            MainActor.assumeIsolated { self?.interrupted(n) }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconfigure() }
        }
    }

    /// A call, Siri or another app took the audio: when it gives it back, the engine starts again by itself.
    private func interrupted(_ n: Notification) {
        guard running, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        NSLog("VERA-MIC прерывание звука: %@", type == .began ? "началось" : "кончилось")
        if type == .ended { reconfigure() }
    }

    private func reconfigure() {
        guard running else { return }
        NSLog("VERA-MIC конфигурация звука сменилась — перезапускаю движок")
        running = false
        let held = holdMusic()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sessionApplied = false
        applySession(chat: lastChat, musicPlaying: lastMusicPlaying)
        defer { resumeMusic(held) }
        restarts += 1
        do { try launchEngine() } catch { NSLog("VERA-MIC перезапуск не удался: %@", error.localizedDescription) }
    }

    /// Opens the microphone straight in the mode it is for: background over music must not pass through the
    /// conversation mode first — that flipped Bluetooth headphones into hands-free (phone-call sound) for a moment.
    func start(chat: Bool, musicPlaying: Bool) throws {
        guard !running else { return }
        applySession(chat: chat, musicPlaying: musicPlaying)
        try launchEngine()
    }

    /// The session policy: conversation-grade (voiceChat + HFP + echo cancel, the headset's mic) or
    /// background listening over music (measurement + A2DP, the music stays stereo, the phone's or wired mic).
    /// Without music there is nothing to protect, so the conversation grade stays (headset mic for the wake word).
    private var lastChat = true
    private var lastMusicPlaying = false
    private var sessionApplied = false

    /// Re-asserts the audio session for the current use. Only touches AVAudioSession when the policy changed;
    /// restarts the engine if it runs so the new mode takes effect.
    func applySession(chat: Bool, musicPlaying: Bool) {
        // The music-grade session has no echo cancelling: only when the sound goes into headphones. From the phone's
        // speaker the microphone would hear the music — lyrics in the background journal, a «Вера» in a song waking her.
        let wantChat = chat || !musicPlaying || !Self.headphonesOut()
        lastChat = chat; lastMusicPlaying = musicPlaying
        guard !sessionApplied || wantChat != lastAppliedChat else { return }
        lastAppliedChat = wantChat
        let wasRunning = running
        // A restart stops every node: the music is held at its place and goes on after (it used to fall silent).
        let held = wasRunning ? holdMusic() : nil
        if wasRunning { engine.inputNode.removeTap(onBus: 0); engine.stop(); running = false }
        defer { resumeMusic(held) }
        let session = AVAudioSession.sharedInstance()
        // Only what differs is set: setting the same category again, or voice processing «off» again, still
        // restarted the sound path — the music in the headphones paused for half a second when the microphone opened.
        let mode: AVAudioSession.Mode = wantChat ? .voiceChat : .measurement
        let options: AVAudioSession.CategoryOptions = wantChat ? [.defaultToSpeaker, .allowBluetoothHFP]
                                                               : [.defaultToSpeaker, .mixWithOthers, .allowBluetoothA2DP]
        if session.category != .playAndRecord || session.mode != mode || session.categoryOptions != options {
            // Фон поверх музыки: без HFP шина не уезжает в hands-free, музыка остаётся стерео.
            try? session.setCategory(.playAndRecord, mode: mode, options: options)
        }
        try? session.setActive(true)
        if engine.inputNode.isVoiceProcessingEnabled != wantChat { try? engine.inputNode.setVoiceProcessingEnabled(wantChat) }
        // Voice processing ducks the rest of the phone's sound by default; Vera sets the music's level herself.
        if wantChat { engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min) }
        sessionApplied = true
        onSession?("\(wantChat ? "chat" : "music") · просили chat=\(chat) музыка=\(musicPlaying) наушники=\(Self.headphonesOut()) · \(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: ","))")
        NSLog("VERA-MIC сессия: %@%@", wantChat ? "разговор (voiceChat+HFP)" : "фон поверх музыки (measurement+A2DP)", wasRunning ? " · движок перезапущен" : "")
        if wasRunning {
            restarts += 1
            do { try launchEngine() } catch { NSLog("VERA-MIC перезапуск не удался: %@", error.localizedDescription) }
        }
    }
    private var lastAppliedChat = true

    /// The music's own session when it plays into headphones: the same as background listening over music, so opening
    /// or closing the microphone changes nothing in the sound (no reroute, no half-second gap).
    static func musicSession() {
        let s = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .mixWithOthers, .allowBluetoothA2DP]
        if s.category != .playAndRecord || s.mode != .measurement || s.categoryOptions != options {
            try? s.setCategory(.playAndRecord, mode: .measurement, options: options)
        }
        try? s.setActive(true)
    }

    /// Sound goes into headphones (wired, Bluetooth, USB, AirPlay), not the phone's own speaker or earpiece.
    static func headphonesOut() -> Bool {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        return !outs.isEmpty && outs.allSatisfy { $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver }
    }

    /// Connections that never change (the player's chain and the sink into the mixer): built once.
    /// The mic's own connection is rebuilt on every launch — the format follows the session.
    private var engineBuilt = false
    private func buildEngine() {
        guard !engineBuilt else { return }
        engine.connect(player, to: pitch, format: playerFormat)
        engine.connect(pitch, to: engine.mainMixerNode, format: playerFormat)
        engine.connect(beeper, to: engine.mainMixerNode, format: playerFormat)
        engine.connect(sink, to: engine.mainMixerNode, format: nil)
        sink.outputVolume = 0
        engineBuilt = true
    }

    private func launchEngine() throws {
        // Idempotent: a tap or connection left from a failed start must not throw an NSException
        // (Swift cannot catch those) — remove first, then install.
        buildEngine()
        engine.inputNode.removeTap(onBus: 0)
        engine.disconnectNodeOutput(engine.inputNode)
        let input = engine.inputNode
        // The hardware's format (what the microphone gives now); the connection takes the node's own format (nil):
        // forcing one read before the session's switch settled made the input node throw (NSException, a crash).
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { throw RigError("микрофон не отдаёт звук (частота 0)") }
        guard inFormat.channelCount > 0 else { throw RigError("микрофон не отдаёт звук (каналов 0)") }
        engine.connect(input, to: sink, format: nil)
        inputDescription = "\(Int(inFormat.sampleRate)) Гц · \(inFormat.channelCount) кан · \(inFormat.commonFormat.rawValue)\(inFormat.isInterleaved ? " · interleaved" : "")"
        NSLog("VERA-MIC input %@ · route %@", inputDescription,
              AVAudioSession.sharedInstance().currentRoute.inputs.map { "\($0.portType.rawValue)" }.joined(separator: ","))
        // No format of ours on the tap: the node's own. Read right after the session's mode changed (voice processing
        // on/off, HFP ↔ A2DP), a format can disagree with the microphone, and installTap then raises an exception
        // Swift cannot catch (the crash on «Слушаю фон»). The conversion to 16 kHz follows the buffers that come.
        input.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.tap(meter: meter, onMic: onMic))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    /// Closes the microphone; `keepSession` — the music plays on in its own player, the session stays active.
    func stop(keepSession: Bool = false) {
        guard running else { return }
        player.stop(); beeper.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        // Voice processing left on keeps the phone's sound in call mode (the music played on its own after the
        // microphone closed stayed quiet): off with the microphone; the next start sets the session again.
        if engine.inputNode.isVoiceProcessingEnabled { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        sessionApplied = false; lastAppliedChat = true
        if !keepSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        onSession?("off · микрофон закрыт\(keepSession ? " · музыка играет дальше" : "")")
    }

    func play(_ buffer: AVAudioPCMBuffer, done: @escaping @Sendable () -> Void) {
        guard running else { done(); return }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in done() }
        if !player.isPlaying { player.play() }
    }

    func silence() { player.stop() }

    // MARK: Music through the rig

    /// The music, while the microphone is open, plays here — on the voice-processing engine — so the echo canceller
    /// subtracts it from the microphone (the ears do not hear the songs, «Вера» is not caught from lyrics) and Vera
    /// sets its loudness. With the microphone off the music plays on its own (`Music`), untouched.
    private let music = AVAudioPlayerNode()
    private var musicAttached = false
    private var musicStart: AVAudioFramePosition = 0
    private var musicRate: Double = 44_100
    private var musicRamp: Task<Void, Never>?
    private var musicFile: AVAudioFile?
    private var musicDone: (@Sendable () -> Void)?
    /// Bumped on every (re)schedule: the completion of a replaced schedule is not «the track ended».
    private var musicGen = 0

    /// Where the music is before the engine stops: the frame and whether it played.
    private func holdMusic() -> (frame: AVAudioFramePosition, playing: Bool)? {
        guard musicFile != nil, musicAttached else { return nil }
        return (musicFrame, music.isPlaying)
    }

    /// After a restart: the same file from the same frame, playing if it played.
    private func resumeMusic(_ held: (frame: AVAudioFramePosition, playing: Bool)?) {
        guard let held, running, let file = musicFile, let done = musicDone else { return }
        let volume = music.volume
        playMusic(file, from: held.frame, volume: volume, done: done)
        if !held.playing { music.pause() }
    }

    /// Plays `file` from `frame`; `done` once it has played to the end (not when stopped).
    func playMusic(_ file: AVAudioFile, from frame: AVAudioFramePosition, volume: Float, done: @escaping @Sendable () -> Void) {
        guard running else { return }
        if !musicAttached { engine.attach(music); musicAttached = true }
        music.stop()
        engine.disconnectNodeOutput(music)
        engine.connect(music, to: engine.mainMixerNode, format: file.processingFormat)
        musicStart = max(0, min(frame, file.length - 1))
        musicRate = file.processingFormat.sampleRate
        let count = AVAudioFrameCount(max(1, file.length - musicStart))
        musicFile = file; musicDone = done
        musicGen += 1
        let gen = musicGen
        music.scheduleSegment(file, startingFrame: musicStart, frameCount: count, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in if self?.musicGen == gen { done() } }
        }
        music.volume = volume
        music.play()
    }

    func pauseMusic() { music.pause() }
    func resumeMusic() { if running { music.play() } }
    func stopMusic() { musicGen += 1; musicFile = nil; musicDone = nil; music.stop() }
    var musicPlaying: Bool { music.isPlaying }

    /// The frame of the file playing now.
    var musicFrame: AVAudioFramePosition {
        guard let t = music.lastRenderTime, let p = music.playerTime(forNodeTime: t) else { return musicStart }
        return musicStart + p.sampleTime
    }
    var musicPosition: Double { Double(musicFrame) / musicRate }

    /// Loudness, ramped: down fast, back up slower.
    func musicVolume(_ target: Float) {
        let from = music.volume
        guard abs(from - target) > 0.001 else { return }
        musicRamp?.cancel()
        let seconds = target < from ? 0.25 : 0.8
        musicRamp = Task { [weak self] in
            for i in 1...20 {
                try? await Task.sleep(for: .seconds(seconds / 20))
                guard !Task.isCancelled, let self else { return }
                self.music.volume = from + (target - from) * Float(i) / 20
            }
        }
    }

    /// A short sound instead of a glance at the screen (riding): a few sine notes, played like the voice.
    func earcon(_ notes: [(hz: Double, ms: Double)], volume: Float = 0.25) {
        guard running else { return }
        let f = playerFormat
        let rate = f.sampleRate
        let total = notes.reduce(0) { $0 + Int(rate * $1.ms / 1000) }
        guard total > 0, let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(total)) else { return }
        b.frameLength = AVAudioFrameCount(total)
        var i = 0
        for n in notes {
            let len = Int(rate * n.ms / 1000)
            for k in 0..<len {
                let env = Float(min(1, Double(min(k, len - k)) / (rate * 0.008)))
                let v = Float(sin(2 * .pi * n.hz * Double(k) / rate)) * volume * env
                for c in 0..<Int(f.channelCount) { b.floatChannelData![c][i] = v }
                i += 1
            }
        }
        beeper.scheduleBuffer(b, completionHandler: nil)
        if !beeper.isPlaying { beeper.play() }
    }

    /// Runs on the audio thread: channel 0 (float or int16, interleaved or not — voice processing decides the format on
    /// the device) → 16 kHz mono → the ears. Counts what arrives, so a silent microphone shows up in the log.
    /// The mono format and the converter to 16 kHz for the rate the buffers come at (rebuilt when it changes).
    private final class Conversion: @unchecked Sendable {
        var rate: Double = 0
        var mono: AVAudioFormat?
        var conv: AVAudioConverter?
    }

    private nonisolated static func tap(meter: MicMeter, onMic: (@Sendable ([Float]) -> Void)?) -> AVAudioNodeTapBlock {
        let c = Conversion()
        return { buffer, _ in
            let n = Int(buffer.frameLength)
            let rate = buffer.format.sampleRate
            guard let onMic, n > 0, rate > 0 else { return }
            if c.rate != rate {
                c.rate = rate
                c.mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
                c.conv = c.mono.flatMap { AVAudioConverter(from: $0, to: target) }
            }
            guard let mono = c.mono, let conv = c.conv, let one = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength) else {
                meter.note(frames: n, peak: 0, dropped: true); return
            }
            one.frameLength = buffer.frameLength
            let dst = one.floatChannelData![0]
            let fmt = buffer.format
            let stride = fmt.isInterleaved ? Int(fmt.channelCount) : 1
            if let f = buffer.floatChannelData {
                for i in 0..<n { dst[i] = f[0][i * stride] }
            } else if let s16 = buffer.int16ChannelData {
                for i in 0..<n { dst[i] = Float(s16[0][i * stride]) / 32768 }
            } else if let s32 = buffer.int32ChannelData {
                for i in 0..<n { dst[i] = Float(s32[0][i * stride]) / 2_147_483_648 }
            } else { meter.note(frames: 0, peak: 0, dropped: true); return }
            var peak: Float = 0
            for i in 0..<n { peak = max(peak, abs(dst[i])) }
            let cap = AVAudioFrameCount(Double(n) * target.sampleRate / mono.sampleRate) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
            var given = false
            var error: NSError?
            conv.convert(to: out, error: &error) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true; status.pointee = .haveData
                return one
            }
            guard error == nil, let ch = out.floatChannelData, out.frameLength > 0 else {
                meter.note(frames: n, peak: peak, dropped: true); return
            }
            meter.note(frames: n, peak: peak, dropped: false)
            onMic(Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))))
        }
    }
}

/// What the microphone delivered: buffers, the loudest sample, conversions that failed. Read once a second.
final class MicMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = 0, dropped = 0
    private var peak: Float = 0
    func note(frames: Int, peak p: Float, dropped d: Bool) {
        lock.lock(); buffers += 1; if d { dropped += 1 }; peak = max(peak, p); lock.unlock()
    }
    func take() -> (buffers: Int, dropped: Int, peak: Float) {
        lock.lock(); defer { buffers = 0; dropped = 0; peak = 0; lock.unlock() }
        return (buffers, dropped, peak)
    }
}

struct RigError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

/// Silero baya — the Mac's voice — on the phone: SileroVoice (app/) on this app's onnxruntime, models in
/// `Models/silero` (scripts/build-mouth-ios.sh → scripts/phone-assets.sh). Loaded once, in the background; every
/// sentence is made on its own serial queue (a few hundred ms for a sentence on the phone's CPU).
final class PhoneSilero: @unchecked Sendable {
    static let shared = PhoneSilero()
    private let queue = DispatchQueue(label: "vera.silero", qos: .userInitiated)
    private var voice: SileroVoice?          // only on `queue`
    private var failure: String?             // only on `queue`

    static var dir: URL? { Bundle.main.url(forResource: "Models", withExtension: nil)?.appending(path: "silero") }
    /// The voice's files are in the app.
    static let present: Bool = dir.map(SileroVoice.isComplete) ?? false

    func warmUp() { queue.async { _ = self.loaded() } }

    private func loaded() -> SileroVoice? {
        if let voice { return voice }
        guard failure == nil, let dir = Self.dir else { return nil }
        do {
            try OnnxRuntime.use(apiBase: vera_ort_api_base())
            voice = try SileroVoice(dir: dir, threads: 2)
        } catch { failure = error.localizedDescription }
        return voice
    }

    /// Samples at 48 kHz, mono; empty when there is nothing to say; an error when the voice cannot load or run.
    func synthesize(_ sentence: String, done: @escaping @Sendable (Result<[Float], Error>) -> Void) {
        queue.async {
            guard let v = self.loaded() else { done(.failure(RigError(self.failure ?? "голоса Silero нет"))); return }
            done(Result { try v.synthesize(SpeechText.forVoice(sentence)) })
        }
    }
}

/// `--say <text>` (debug launch argument): Silero speaks the text into `tmp/vera-say.wav` and logs the timings —
/// a check of the voice on the phone's onnxruntime without a conversation.
enum VoiceCheck {
    static func runIfAsked() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--say"), i + 1 < args.count else { return }
        let text = args[i + 1], t0 = Date()
        NSLog("VERA-VOICE present %d", PhoneSilero.present ? 1 : 0)
        PhoneSilero.shared.warmUp()
        PhoneSilero.shared.synthesize("Да.") { _ in
            let loaded = Date()
            PhoneSilero.shared.synthesize(text) { result in
                switch result {
                case .success(let samples):
                    let url = URL.temporaryDirectory.appending(path: "vera-say.wav")
                    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SileroVoice.sampleRate), channels: 1, interleaved: false)!
                    if let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))),
                       let file = try? AVAudioFile(forWriting: url, settings: format.settings) {
                        pcm.frameLength = AVAudioFrameCount(samples.count)
                        samples.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
                        try? file.write(from: pcm)
                    }
                    NSLog("VERA-VOICE load %dms say %dms audio %.2fs → %@", Int(loaded.timeIntervalSince(t0) * 1000),
                          Int(Date().timeIntervalSince(loaded) * 1000), Double(samples.count) / Double(SileroVoice.sampleRate), url.path)
                case .failure(let e): NSLog("VERA-VOICE error %@", e.localizedDescription)
                }
            }
        }
    }
}

/// Vera's voice on the phone: Silero baya, as on the Mac, when its files are in the app and no system voice is picked
/// in Settings; otherwise the system's Russian voice (on the device, no network). Rendered to buffers and played
/// through the rig, sentence by sentence. Interrupting stops it at once.
@MainActor
final class Mouth {
    private let synth = AVSpeechSynthesizer()
    private let rig: AudioRig
    private var queue: [String] = []
    private var busy = false
    private var generation = 0
    private var pendingBuffers = 0
    private var rendered = false
    /// 0…1 loudness of what is playing, for the voice ring.
    var onLevel: ((Float) -> Void)?
    var onSpeaking: ((Bool) -> Void)?
    /// The sentence being spoken now ("" when silent).
    var onSentence: ((String) -> Void)?
    /// After each sentence: how long until its first sound was ready (ms) and how long it sounds (s, before speed).
    var onStats: ((Int, Double) -> Void)?
    /// Each piece of sound as it will play: when it starts, how long it lasts (at the speed) and its peaks per 20 ms —
    /// the voice ring draws the last 1.4 s from these, as on the Mac.
    var onClip: ((VoiceClip) -> Void)?
    private var playhead = Date.distantPast
    private var startedAt = Date()
    private var firstBufferMs: Int?
    private var frames = 0
    private var sampleRate = 22_050.0
    private(set) var speaking = false { didSet { if speaking != oldValue { onSpeaking?(speaking) } } }

    init(rig: AudioRig) {
        self.rig = rig
        if Self.usesSilero { PhoneSilero.shared.warmUp() }
    }

    /// Silero is the voice unless a system voice is picked in Settings.
    static var usesSilero: Bool { PhoneSilero.present && (UserDefaults.standard.string(forKey: "vera.voiceId") ?? "").isEmpty }

    static var voiceName: String {
        if usesSilero { return "Silero baya" }
        return voice.map { "\($0.name) · \(qualityName($0))" } ?? "голос iOS"
    }

    /// Russian voices installed on the phone, the best first (premium, enhanced, then the default ones).
    static var russianVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ru") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    static func qualityName(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality { case .premium: "премиум"; case .enhanced: "улучшенный"; default: "обычный" }
    }

    /// The voice picked in the menu (`vera.voiceId`), else the best installed one.
    static var voice: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: "vera.voiceId"), !id.isEmpty,
           let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return russianVoices.first ?? AVSpeechSynthesisVoice(language: "ru-RU")
    }

    func say(_ text: String) {
        let clean = Self.clean(text)
        guard !clean.isEmpty else { return }
        queue.append(clean)
        next()
    }

    /// Said next, before what is queued (a navigation prompt must not wait for a long answer).
    func sayFirst(_ text: String) {
        let clean = Self.clean(text)
        guard !clean.isEmpty else { return }
        queue.insert(clean, at: 0)
        next()
    }

    func stop() {
        generation += 1
        queue.removeAll()
        synth.stopSpeaking(at: .immediate)
        rig.silence()
        busy = false; pendingBuffers = 0; rendered = false
        playhead = .distantPast
        speaking = false
        onLevel?(0)
        onSentence?("")
    }

    private func next() {
        guard !busy else { return }
        guard !queue.isEmpty else { speaking = false; onLevel?(0); onSentence?(""); return }
        busy = true; speaking = true
        pendingBuffers = 0; rendered = false
        let sentence = queue.removeFirst()
        onSentence?(sentence)
        startedAt = Date(); firstBufferMs = nil; frames = 0
        let gen = generation
        if Self.usesSilero {
            PhoneSilero.shared.synthesize(sentence) { [weak self] result in
                Task { @MainActor in self?.silero(result, sentence: sentence, gen: gen) }
            }
            return
        }
        system(sentence, gen: gen)
    }

    /// Silero's sentence as one buffer, then the end mark — the same path as the system voice's buffers. If Silero
    /// fails, this sentence goes to the system voice.
    private func silero(_ result: Result<[Float], Error>, sentence: String, gen: Int) {
        guard gen == generation else { return }
        guard case .success(let samples) = result else { system(sentence, gen: gen); return }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SileroVoice.sampleRate), channels: 1, interleaved: false)!
        if !samples.isEmpty, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) {
            pcm.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            rendered(pcm, gen: gen)
        }
        if let end = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) { rendered(end, gen: gen) }
    }

    private func system(_ sentence: String, gen: Int) {
        let u = AVSpeechUtterance(string: sentence)
        u.voice = Self.voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate   // speed is the rig's (×1.15, pitch kept)
        synth.write(u, toBufferCallback: Self.writer(self, gen: gen))
    }

    /// Called on the synthesizer's own thread: built outside the main actor, it only hops back.
    private nonisolated static func writer(_ owner: Mouth, gen: Int) -> AVSpeechSynthesizer.BufferCallback {
        { [weak owner] buffer in
            nonisolated(unsafe) let buffer = buffer
            Task { @MainActor in owner?.rendered(buffer, gen: gen) }
        }
    }

    private func rendered(_ buffer: AVAudioBuffer, gen: Int) {
        guard gen == generation, let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 {
            rendered = true
            onStats?(firstBufferMs ?? 0, Double(frames) / sampleRate)
            if pendingBuffers == 0 { busy = false; next() }
            return
        }
        if firstBufferMs == nil { firstBufferMs = Int(Date().timeIntervalSince(startedAt) * 1000) }
        frames += Int(pcm.frameLength); sampleRate = pcm.format.sampleRate
        guard let out = Self.convert(pcm, to: rig.playerFormat) else { return }
        pendingBuffers += 1
        onLevel?(Self.level(pcm))
        let seconds = Double(pcm.frameLength) / pcm.format.sampleRate / Double(max(0.1, rig.speed))
        let start = max(Date(), playhead)
        playhead = start.addingTimeInterval(seconds)
        onClip?(VoiceClip(start: start, seconds: seconds, peaks: Self.peaks(pcm)))
        rig.play(out) { [weak self] in
            Task { @MainActor in self?.played(gen: gen) }
        }
    }

    private func played(gen: Int) {
        guard gen == generation else { return }
        pendingBuffers -= 1
        if rendered && pendingBuffers == 0 { busy = false; next() }
    }

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "*", with: "")
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "ссылка", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func peaks(_ b: AVAudioPCMBuffer) -> [Float] {
        guard let ch = b.floatChannelData else { return [] }
        let n = Int(b.frameLength), per = max(1, Int(b.format.sampleRate / 50))
        return stride(from: 0, to: n, by: per).map { i in
            var m: Float = 0
            for k in i..<min(i + per, n) { m = max(m, abs(ch[0][k])) }
            return m
        }
    }

    private static func level(_ b: AVAudioPCMBuffer) -> Float {
        guard let ch = b.floatChannelData else { return 0 }
        var m: Float = 0
        for i in 0..<Int(b.frameLength) { m = max(m, abs(ch[0][i])) }
        return min(1, m * 1.5)
    }

    private static func convert(_ b: AVAudioPCMBuffer, to f: AVAudioFormat) -> AVAudioPCMBuffer? {
        if b.format == f { return b }
        guard let conv = AVAudioConverter(from: b.format, to: f),
              let out = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(Double(b.frameLength) * f.sampleRate / b.format.sampleRate) + 64)
        else { return nil }
        var given = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData
            return b
        }
        return error == nil ? out : nil
    }
}

/// A piece of Vera's voice as it sounds: start, length, peaks per 20 ms.
struct VoiceClip: Sendable {
    let start: Date
    let seconds: Double
    let peaks: [Float]
}
