import AppKit
import AVFoundation
import Darwin
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import Sensors
import SignalBus
import Scene
import SceneAnalyzers
import Browser
import Core
import Response

struct AnalyzerUsage: Sendable {
    var cpuPercent: Double
    var rssMB: Double
}

@MainActor
@Observable
final class PrototypeModel {
    struct LiveCAMMatch: Identifiable {
        let personID: String
        let label: String
        let similarity: Double
        var role: String = "human"
        var id: String { personID }
    }
    private struct PendingLiveGigaAM {
        enum Kind { case interim, final(reason: String) }
        let kind: Kind
        let sessionID: Int
        let segmentID: Int
        let wav: Data
        let durationMilliseconds: Int
    }

    private struct PendingLiveCAMWindow {
        let segmentID: Int
        let wav: Data
        let durationMilliseconds: Int
    }

    private struct PendingLiveVoxLock {
        let wav: Data
        let durationMilliseconds: Int
        let reason: String
    }

    let bus = SignalBus()
    let busMonitor = BusMonitorModel()
    let core = CoreInbox()
    /// Core's hands. Works only in a small sandbox folder for now, and only when started with `--agent`.
    let agent: CoreAgent
    /// Response: speaks the agent's answers aloud (Silero, voice baya) on Core's command.
    let speaker: ResponseSpeaker
    private let sileroSpeech: SileroSpeech
    var speechAvailable: Bool { SileroSpeech.isAvailable(runtime) }
    let workspaceURL: URL
    private let recorder = BusRecorder()
    private let tape: AudioTape
    private var lastTapePosition: AudioTape.Position?
    var recordingFileName: String?
    var recordedMessageCount = 0

    /// One-line recording status: audio goes to the tape, messages to the bus recording.
    var recordingStatusText: String {
        guard recordingFileName != nil else { return "" }
        if !isMicrophoneListening { return "записано · \(recordedMessageCount) сообщ. шины" }
        var text = "пишется: звук + шина"
        if let file = lastTapePosition?.file,
           let size = (try? FileManager.default.attributesOfItem(atPath: tape.directory.appending(path: file).path))?[.size] as? NSNumber {
            text += String(format: " · лента %.1f МБ", size.doubleValue / 1_048_576)
        }
        return text
    }
    /// Requests reach Core only while the owner is in the scene.
    let scene = SceneModel(ttl: .app)
    let runtime: ModelRuntime
    private let sensorAnalysis: SensorAnalysis
    private let gigaAMAnalyzer: GigaAMAnalyzer
    private let camPlusAnalyzer: SpeakerEmbeddingAnalyzer
    private let jevAnalyzer: JevAnalyzer
    private let smartTurnAnalyzer: SmartTurnAnalyzer
    private let vadAnalyzer: SileroVADAnalyzer
    private var vadContinuation: AsyncStream<(samples: [Float], energyVoiced: Bool)>.Continuation?
    private var vadTask: Task<Void, Never>?
    private var lastVadPublish = Date.distantPast
    private var lastVadSpeech = false
    private var player: AVAudioPlayer?
    private var microphoneCapture: MicrophoneCapture?
    private var audioFeed: FileAudioFeed?
    private let spectrumAnalyzer = LiveSpectrumAnalyzer()
    private var spectrumWorkInFlight = false
    private var spectrumNeedsReset = false
    private var feedURL: URL?
    private var automationStarted = false
    private var nomoPVAD: NomoPVADAnalyzer?
    private var liveSpeechBuffer = LiveSpeechBuffer()
    private var liveSessionID = 0
    private var pendingLiveGigaAMInterim: PendingLiveGigaAM?
    private var pendingLiveGigaAMFinals: [PendingLiveGigaAM] = []
    private var liveGigaAMDrainTask: Task<Void, Never>?
    private var liveCAMWindow: PendingLiveCAMWindow?
    private var liveCAMDrainTask: Task<Void, Never>?
    private var lastLiveCAMEnqueueAt = Date.distantPast
    private var liveVoxLockAnalyzer: VoxLockAnalyzer?
    private var pendingLiveVoxLock: PendingLiveVoxLock?
    private var liveVoxLockDrainTask: Task<Void, Never>?
    private var liveGigaAMDisplayedSegmentID = 0
    private var liveSimilarityRevision: UInt64 = 0
    private var transcriptRevisions: [String: UInt64] = [:]
    private var liveSegmentStartedAt: Date?
    private var nomoInFlight = false
    private var nomoSkippedWindows = 0
    private var pipelineLogHandle: FileHandle?
    private var lastPipelineHeartbeat = Date.distantPast

    var audioFiles: [WaveAudioFile] = []
    var selectedAudioID: UUID?
    var segmentStart = 0.0
    var segmentEnd = 10.0
    var isAnalyzing = false
    var status = "Добавь WAV-фрагменты для анализа"
    var useGigaAM = true
    var useCAMPlus = true
    var useVoxLock = true
    var useNomoPVAD = true
    var nomoEnrollmentURL: URL?
    var isMicrophoneStarting = false
    var isMicrophoneListening = false
    var microphoneAECActive: Bool?
    var microphoneStatus = "Микрофон выключен"
    var microphoneWaveform: [Float] = []
    var microphoneRMS: Float = 0
    var microphonePeak: Float = 0
    var microphoneDBFS: Float = -120
    var microphoneSpectrum: [LiveSpectrumFrame] = []
    var targetSpeakerProbability: Double?
    var targetSpeakerHistory: [Double] = []
    var liveGigaAMText = ""
    var liveGigaAMStatus = "Микрофон выключен"
    var gigaAMReady = false
    var liveGigaAMLastLatencyMilliseconds: Int?
    var liveCAMStatus = "Ожидание микрофона"
    var liveCAMSimilarity: Double?
    var liveCAMMatches: [LiveCAMMatch] = []
    var liveNomoStatus = "Ожидание микрофона"
    var liveVoxLockStatus = "Ожидание завершённой речи"
    var voxLockGigaAMText = ""
    var voxLockGigaAMLastLatencyMilliseconds: Int?
    var voxLockHistory: [Double] = []
    var usageGigaAM: AnalyzerUsage?
    var usageCAMPP: AnalyzerUsage?
    var usageVoxLock: AnalyzerUsage?
    var usageNomo: AnalyzerUsage?
    var usageJev: AnalyzerUsage?
    var usageSmartTurn: AnalyzerUsage?
    var usageVAD: AnalyzerUsage?
    /// Silero VAD in the shadow: it runs next to the energy gate and decides nothing.
    var vadProbability: Double?
    var vadHistory: [Double] = []
    /// Seconds of this session in which the VAD heard speech but the energy gate did not (and the reverse).
    var vadOnlySeconds = 0.0
    var energyOnlySeconds = 0.0
    /// Last Smart Turn estimates (probability that the speaker has finished), oldest first, at most 8.
    var smartTurnHistory: [Double] = []
    private var usagePollTask: Task<Void, Never>?
    var ownerVoiceSample: URL?
    var speakerLabel = ""
    var references: [SpeakerReference]
    var fileErrors: [String] = []

    init() {
        let runtime = ModelRuntime()
        self.runtime = runtime
        let workspace = runtime.appSupportURL.appending(path: "Workspace", directoryHint: .isDirectory)
        self.workspaceURL = workspace
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (name, content) in ["notes.txt": "первая строка заметок\nкодовое слово: сокол\n42\n", "status.txt": "статус: draft\nавтор: тест\n"]
        where !FileManager.default.fileExists(atPath: workspace.appending(path: name).path) {
            try? content.write(to: workspace.appending(path: name), atomically: true, encoding: .utf8)
        }
        let hasKey = Secrets.key(named: "OPENCODE_API_KEY") != nil
        self.sileroSpeech = SileroSpeech(runtime: runtime, voice: "baya")
        self.speaker = ResponseSpeaker(synthesizer: SileroSynthesizer(speech: sileroSpeech), player: WavPlayer(), voice: "baya")
        if let saved = UserDefaults.standard.object(forKey: "VeraVoiceSpeed") as? Double, ResponseSpeaker.speedRange.contains(saved) {
            self.speaker.speed = saved
        }
        let repoRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VERA_REPO"] ?? "/Users/alex/Projects/vera-v2")
        let selfModifier = SelfModifier(repo: repoRoot, worktree: runtime.appSupportURL.appending(path: "Self/vera", directoryHint: .isDirectory),
                                        applyScript: repoRoot.appending(path: "prototype/Evaluation/apply-self.sh"))
        let skillStore = SkillStore(directory: runtime.appSupportURL.appending(path: "Skills", directoryHint: .isDirectory))
        Self.seedSkills(in: skillStore.directory)
        let memory = MemoryStore(directory: runtime.appSupportURL.appending(path: "Memory", directoryHint: .isDirectory))
        let browser = BrowserEngine()
        let notes = NoteStore(directory: runtime.appSupportURL.appending(path: "Notes", directoryHint: .isDirectory))
        let agentBox = AgentBox()
        let commandApproval = CommandApproval(workingDirectory: workspace)
        let reminders = ReminderStore(url: runtime.appSupportURL.appending(path: "Memory/reminders.json"))
        self.agent = CoreAgent(
            loop: hasKey ? AgentLoop(model: OpenAICompatibleClient(journal: ModelJournal(directory: runtime.appSupportURL.appending(path: "Journal", directoryHint: .isDirectory))),
                                     tools: WorkspaceTools(root: workspace).registry.adding(.memoryTools(memory)).adding(skillStore.registry).adding(skillStore.writeRegistry).adding(selfModifier.registry)
                                         .adding(WebTools.registry).adding(.browserTools(BrowserSession(driver: browser))).adding(.commandTools(commandApproval)).adding(.macTools).adding(.noteTools(notes))
                                         .adding(.taskTools { await MainActor.run { agentBox.agent?.statusText() ?? "" } }).adding(.reminderTools(reminders)), systemPrompt: VeraPrompt.system) : nil,
            unavailableReason: "нет ключа OPENCODE_API_KEY (окружение или Keychain: space.vera.v2)", memory: memory)
        self.agent.skills = skillStore
        agentBox.agent = self.agent
        self.agent.selfModifier = selfModifier
        self.agent.commandApproval = commandApproval
        self.agent.reminders = reminders
        self.agent.restartHandler = { NSApplication.shared.terminate(nil) }
        self.tape = AudioTape(directory: runtime.appSupportURL.appending(path: "Tape", directoryHint: .isDirectory))
        let gigaAMAnalyzer = GigaAMAnalyzer(runtime: runtime)
        let camPlusAnalyzer = SpeakerEmbeddingAnalyzer(runtime: runtime)
        self.gigaAMAnalyzer = gigaAMAnalyzer
        self.camPlusAnalyzer = camPlusAnalyzer
        self.jevAnalyzer = JevAnalyzer(runtime: runtime)
        self.smartTurnAnalyzer = SmartTurnAnalyzer(runtime: runtime)
        self.vadAnalyzer = SileroVADAnalyzer(runtime: runtime)
        self.sensorAnalysis = SensorAnalysis(runtime: runtime, gigaAM: gigaAMAnalyzer, camPlus: camPlusAnalyzer)
        references = SpeakerReferenceStore.load(from: runtime.appSupportURL)
        let targetVoice = Self.validDefaultTargetVoiceURL(runtime.alexTargetVoiceURL)
        ownerVoiceSample = targetVoice
        nomoEnrollmentURL = targetVoice
        if runtime.voxLockAvailable, let targetVoice {
            liveVoxLockAnalyzer = VoxLockAnalyzer(runtime: runtime, ownerVoiceSample: targetVoice)
        }
        try? runtime.createRuntimeDirectories()
        if runtime.jevAvailable {
            scene.judge = JevTurnJudge(analyzer: jevAnalyzer)
            scene.judgeName = "Jev-Style-2B v4 · MLX 8 бит"
        }
        Task { await busMonitor.consume(bus) }
        Task { await core.consume(bus) }
        Task { await agent.consume(bus) }
        Task { await speaker.consume(bus) }
        // Core asks Sensors to stop the microphone when she goes to sleep; switching it on again wakes her.
        Task { @MainActor [weak self] in
            guard let bus = self?.bus else { return }
            for await message in await bus.subscribe() where message.kind == .command && message.type == "sensors.microphone.stop" {
                self?.stopMicrophone()
            }
        }
        // Launch arguments work without a window: a locked screen creates none, and the microphone does not need one.
        Task { @MainActor [weak self] in self?.runAutomationIfRequested() }
        Task { await scene.consume(bus) }
    }

    private static func validDefaultTargetVoiceURL(_ url: URL) -> URL? {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let file = try? WaveAudioFile.open(url),
              file.duration >= 10 else { return nil }
        return url
    }

    var selectedAudio: WaveAudioFile? {
        audioFiles.first(where: { $0.id == selectedAudioID }) ?? audioFiles.first
    }

    var analyzerAvailability: [(String, Bool)] {
        [("GigaAM v3 · русский ASR", runtime.gigaAMAvailable),
         ("CAM++ · голосовой отпечаток", runtime.speakerModelAvailable),
         ("VoxLock · дорожка владельца", runtime.voxLockAvailable),
         ("Nomo-PVAD · голос Алексея", runtime.nomoPVADAvailable)]
    }

    func importAudio() {
        let panel = NSOpenPanel()
        panel.title = "Добавить аудиофрагменты"
        panel.message = "Выбери один или несколько WAV PCM 16-bit. Исходные файлы не копируются и не изменяются."
        panel.allowedContentTypes = [.wav]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        var added: [WaveAudioFile] = []
        var errors: [String] = []
        for url in panel.urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { added.append(try WaveAudioFile.open(url)) }
            catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        audioFiles.append(contentsOf: added)
        audioFiles.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedDescending }
        fileErrors = errors
        if selectedAudioID == nil, let first = audioFiles.first { select(first) }
        status = added.isEmpty ? "Подходящих файлов не найдено" : "Добавлено WAV-файлов: \(added.count)"
    }

    func select(_ audio: WaveAudioFile) {
        selectedAudioID = audio.id
        segmentStart = 0
        segmentEnd = min(audio.duration, 12)
        status = "Выбран \(audio.displayName) · \(formatDuration(audio.duration))"
    }

    func chooseOwnerSample() {
        let panel = NSOpenPanel()
        panel.title = "Выбрать образец голоса для VoxLock"
        panel.message = "Нужен чистый WAV с голосом целевого участника, минимум 3 секунды."
        panel.allowedContentTypes = [.wav]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let file = try WaveAudioFile.open(url)
            guard file.duration >= 3 else { throw WaveFileError.emptySelection }
            ownerVoiceSample = url
            status = "Образец VoxLock выбран: \(url.lastPathComponent)"
        } catch { status = error.localizedDescription }
        if scoped { url.stopAccessingSecurityScopedResource() }
    }

    func chooseNomoEnrollment() {
        let panel = NSOpenPanel()
        panel.title = "Выбрать голосовой эталон для Nomo-PVAD"
        panel.message = "Нужна чистая запись целевого голоса не короче 10 секунд."
        panel.allowedContentTypes = [.wav]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try WaveAudioFile.open(url)
            guard file.duration >= 10 else {
                status = "Для Nomo-PVAD выбери WAV не короче 10 секунд"
                return
            }
            nomoEnrollmentURL = url
            status = "Эталон Nomo-PVAD выбран: \(url.lastPathComponent)"
        } catch { status = error.localizedDescription }
    }

    func toggleMicrophone() {
        if isMicrophoneListening || isMicrophoneStarting {
            stopMicrophone()
            return
        }
        isMicrophoneStarting = true
        microphoneStatus = "Запускаю микрофон…"
        startMicrophoneCapture()
    }

    private func startMicrophoneCapture() {
        liveSessionID += 1
        spectrumAnalyzer.beginSession(liveSessionID)
        spectrumWorkInFlight = false
        spectrumNeedsReset = false
        microphoneSpectrum.removeAll(keepingCapacity: true)
        liveSpeechBuffer.reset()
        pendingLiveGigaAMInterim = nil
        gigaAMReady = false
        microphoneWaveform.removeAll(keepingCapacity: true)
        targetSpeakerHistory.removeAll(keepingCapacity: true)
        voxLockHistory.removeAll(keepingCapacity: true)
        targetSpeakerProbability = nil
        let capture = MicrophoneCapture()
        do {
            let aec: Bool
            if let feedURL {
                // Automation: a WAV file stands in for the microphone, at real-time pace.
                let feed = FileAudioFeed()
                try feed.start(url: feedURL, onChunk: { [weak self] chunk in
                    Task { @MainActor in self?.receiveMicrophoneChunk(chunk) }
                }, onFinished: { [weak self] in
                    Task { @MainActor in self?.pipelineLog("feed finished"); self?.stopMicrophone() }
                })
                audioFeed = feed
                aec = false
            } else {
                aec = try capture.start { [weak self] chunk in
                    Task { @MainActor in self?.receiveMicrophoneChunk(chunk) }
                }
                microphoneCapture = capture
            }
            microphoneAECActive = aec
            isMicrophoneStarting = false
            isMicrophoneListening = true
            microphoneStatus = aec ? "Микрофон активен · Voice Processing / AEC включён" : "Микрофон активен · AEC недоступен"
            liveGigaAMStatus = runtime.gigaAMAvailable ? "Ожидание речи · русский GigaAM v3" : "Нет GigaAM runtime или модели"
            liveCAMStatus = runtime.speakerModelAvailable
                ? (references.contains(where: { $0.personID == "alex" }) ? "Ожидание речевого окна" : "Ожидание эталона CAM++")
                : "CAM++ runtime или модель недоступны"
            liveVoxLockStatus = liveVoxLockAnalyzer == nil ? "Недоступен: нет модели или эталона" : "Ожидание завершённой речи"
            Task {
                // The recorder subscribes first so the very first message of the session is in the file.
                do {
                    let file = try await recorder.start(bus: bus, directory: runtime.appSupportURL.appending(path: "Recordings", directoryHint: .isDirectory), name: audioFeed == nil ? "live" : "feed")
                    recordingFileName = file.lastPathComponent
                    recordedMessageCount = 0
                } catch {
                    recordingFileName = nil
                    pipelineLog("bus recording FAILED: \(error.localizedDescription)")
                }
                await bus.publish(SignalMessage(source: "Sensors.Microphone", type: "audio.microphone.started",
                                                payload: ["sample_rate_hz": "16000", "aec": "\(aec)",
                                                          "input": "shared_raw_post_voice_processing",
                                                          "analyzers": "GigaAM,CAM++,Nomo-PVAD,VoxLock"]))
            }
            status = microphoneStatus
            startNomoIfAvailable(sessionID: liveSessionID)
            startPipelineLog()
            if runtime.jevAvailable { Task { try? await jevAnalyzer.warm() } }
            if runtime.smartTurnAvailable { Task { try? await smartTurnAnalyzer.warm() } }
            startVAD()
            startAnalyzerWarmup()
            startUsagePolling()
        } catch {
            isMicrophoneStarting = false
            microphoneAECActive = false
            microphoneStatus = "Микрофон не запустился: \(error.localizedDescription)"
            status = microphoneStatus
        }
    }

    private func startNomoIfAvailable(sessionID: Int) {
        guard runtime.nomoPVADAvailable else {
            liveNomoStatus = "Nomo-PVAD runtime или веса недоступны"
            return
        }
        guard let nomoEnrollmentURL else {
            liveNomoStatus = "Nomo-PVAD ждёт целевой WAV-эталон"
            return
        }
        liveNomoStatus = "Загружаю Nomo-PVAD"
        Task { @MainActor in
            let analyzer = NomoPVADAnalyzer(runtime: runtime, enrollmentWAV: nomoEnrollmentURL)
            do {
                try await analyzer.warm()
                guard isMicrophoneListening, liveSessionID == sessionID else {
                    await analyzer.stop()
                    return
                }
                nomoPVAD = analyzer
                liveNomoStatus = "Работает · окно 160 мс"
                await bus.publish(SignalMessage(source: "Sensors.NomoPVAD", type: "analyzer.ready",
                                                payload: ["target": "Alexey", "window_ms": "160"]))
            } catch {
                guard isMicrophoneListening, liveSessionID == sessionID else {
                    await analyzer.stop()
                    return
                }
                liveNomoStatus = "Не запустился: \(error.localizedDescription)"
                await analyzer.stop()
                await bus.publish(SignalMessage(source: "Sensors.NomoPVAD", type: "analyzer.failed",
                                                payload: ["error": error.localizedDescription]))
            }
        }
    }

    private func startPipelineLog() {
        let url = runtime.appSupportURL.appending(path: "Logs/live-pipeline.log")
        try? Data().write(to: url, options: .atomic)
        pipelineLogHandle = try? FileHandle(forWritingTo: url)
        pipelineLog("mic started session=\(liveSessionID)")
    }

    private func pipelineLog(_ line: String) {
        guard let handle = pipelineLogHandle else { return }
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        try? handle.write(contentsOf: Data("\(stamp) \(line)\n".utf8))
    }

    private func startAnalyzerWarmup() {
        Task { @MainActor in
            if runtime.gigaAMAvailable {
                do {
                    let note = try await gigaAMAnalyzer.warm()
                    gigaAMReady = true
                    pipelineLog("gigaam warm ok: \(note)")
                } catch {
                    gigaAMReady = false
                    pipelineLog("gigaam warm FAILED: \(error.localizedDescription)")
                    if isMicrophoneListening {
                        liveGigaAMStatus = "Прогрев GigaAM не удался: \(error.localizedDescription)"
                    }
                }
            }
            if runtime.speakerModelAvailable {
                do {
                    let note = try await camPlusAnalyzer.warm()
                    pipelineLog("campp warm ok: \(note)")
                } catch {
                    pipelineLog("campp warm FAILED: \(error.localizedDescription)")
                    if isMicrophoneListening {
                        liveCAMStatus = "Прогрев CAM++ не удался: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func startUsagePolling() {
        stopUsagePolling()
        usagePollTask = Task { @MainActor [weak self] in
            var last: [String: (at: Date, seconds: Double)] = [:]
            while self?.isMicrophoneListening == true {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.isMicrophoneListening else { break }
                self.usageGigaAM = Self.currentUsage(pid: self.gigaAMAnalyzer.processIdentifier, key: "gigaam", last: &last)
                self.usageCAMPP = Self.currentUsage(pid: self.camPlusAnalyzer.processIdentifier, key: "campp", last: &last)
                self.usageVoxLock = Self.currentUsage(pid: self.liveVoxLockAnalyzer?.processIdentifier, key: "voxlock", last: &last)
                self.usageNomo = Self.currentUsage(pid: self.nomoPVAD?.processIdentifier, key: "nomo", last: &last)
                self.usageJev = Self.currentUsage(pid: self.jevAnalyzer.processIdentifier, key: "jev", last: &last)
                self.usageSmartTurn = Self.currentUsage(pid: self.smartTurnAnalyzer.processIdentifier, key: "smartturn", last: &last)
                self.usageVAD = Self.currentUsage(pid: self.vadAnalyzer.processIdentifier, key: "vad", last: &last)
            }
        }
    }

    private func stopUsagePolling() {
        usagePollTask?.cancel()
        usagePollTask = nil
        usageGigaAM = nil
        usageCAMPP = nil
        usageVoxLock = nil
        usageNomo = nil
        usageJev = nil
        usageSmartTurn = nil
        usageVAD = nil
    }

    private static func currentUsage(pid: Int32?, key: String,
                                     last: inout [String: (at: Date, seconds: Double)]) -> AnalyzerUsage? {
        guard let pid, let sample = sampleTaskUsage(pid: pid) else { return nil }
        let now = Date()
        defer { last[key] = (now, sample.cpuSeconds) }
        guard let prev = last[key], now.timeIntervalSince(prev.at) > 0.1 else {
            return AnalyzerUsage(cpuPercent: 0, rssMB: sample.rssMB)
        }
        let cpu = max(0, (sample.cpuSeconds - prev.seconds) / now.timeIntervalSince(prev.at) * 100)
        return AnalyzerUsage(cpuPercent: cpu, rssMB: sample.rssMB)
    }

    private static func sampleTaskUsage(pid: Int32) -> (cpuSeconds: Double, rssMB: Double)? {
        var info = proc_taskinfo()
        let bytes = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, bytes) == bytes else { return nil }
        return (Double(info.pti_total_user + info.pti_total_system) / 1_000_000_000,
                Double(info.pti_resident_size) / 1_000_000)
    }

    private func receiveMicrophoneChunk(_ chunk: MicrophoneChunk) {
        guard isMicrophoneListening else { return }
        microphoneWaveform.append(contentsOf: chunk.waveform)
        let waveformLimit = 1_800 // 3 s at 96 samples per 160 ms audio chunk
        if microphoneWaveform.count > waveformLimit {
            microphoneWaveform.removeFirst(microphoneWaveform.count - waveformLimit)
        }
        // Everything heard goes to the tape first, before any gate or analyzer decides what matters.
        // Fed test audio is not written to the tape: the tape holds only what the microphone heard.
        if audioFeed == nil, let position = tape.append(pcm16: LiveSpeechBuffer.pcm16(chunk.samples16k)) { lastTapePosition = position }
        microphoneRMS = chunk.rms
        microphonePeak = chunk.peak
        microphoneDBFS = chunk.rms > 0
            ? max(-120, min(0, 20 * log10(chunk.rms)))
            : -120
        microphoneAECActive = chunk.voiceProcessingActive
        if spectrumWorkInFlight {
            spectrumNeedsReset = true
        } else {
            spectrumWorkInFlight = true
            let resetHistory = spectrumNeedsReset
            spectrumNeedsReset = false
            let analyzer = spectrumAnalyzer
            let sessionID = liveSessionID
            let timestamp = Date()
            let samples16k = chunk.samples16k
            Task.detached(priority: .utility) { [weak self] in
                let frame = analyzer.analyze(samples16k, at: timestamp, sessionID: sessionID,
                                             resetHistoryBeforeAppend: resetHistory)
                await self?.completeSpectrumWork(frame, sessionID: sessionID)
            }
        }
        let payload = ["sample_rate_hz": "16000", "input_rate_hz": "\(Int(chunk.inputSampleRate))",
                       "duration_ms": "160", "rms": String(format: "%.4f", chunk.rms),
                       "peak": String(format: "%.4f", chunk.peak), "aec": "\(chunk.voiceProcessingActive)"]
        Task { await bus.publish(SignalMessage(source: "Sensors.Microphone", type: "audio.input.observed", payload: payload)) }

        // One Nomo-PVAD request in flight at a time: if inference is slower than the
        // 160 ms chunk cadence, newer windows are dropped (counted) instead of queueing
        // unbounded tasks whose results would arrive late and out of order.
        if nomoPVAD != nil, nomoInFlight {
            nomoSkippedWindows += 1
        } else if let analyzer = nomoPVAD {
            let sessionID = liveSessionID
            let skipped = nomoSkippedWindows
            nomoSkippedWindows = 0
            nomoInFlight = true
            Task { @MainActor in
                defer { if liveSessionID == sessionID { nomoInFlight = false } }
                do {
                    let probability = try await analyzer.score(chunk.samples16k)
                    guard isMicrophoneListening, liveSessionID == sessionID else { return }
                    targetSpeakerProbability = probability
                    targetSpeakerHistory.append(probability)
                    if targetSpeakerHistory.count > 30 {
                        targetSpeakerHistory.removeFirst(targetSpeakerHistory.count - 30)
                    }
                    await bus.publish(SignalMessage(source: "Sensors.NomoPVAD", type: "speaker.target.activity.scored",
                                                    payload: ["target": "Alexey", "probability": String(format: "%.3f", probability),
                                                              "window_ms": "160",
                                                              "skipped_windows": "\(skipped)"]))
                } catch {
                    liveNomoStatus = "Ошибка: \(error.localizedDescription)"
                    await bus.publish(SignalMessage(source: "Sensors.NomoPVAD", type: "analyzer.failed",
                                                    payload: ["error": error.localizedDescription]))
                }
            }
        }

        let speechRMS = Self.rms(chunk.samples16k)
        vadContinuation?.yield((chunk.samples16k, speechRMS >= LiveSpeechBuffer.speechThreshold))
        let wasSpeechActive = liveSpeechBuffer.isSpeechActive
        let update = liveSpeechBuffer.append(samples16k: chunk.samples16k, rms: speechRMS)
        let isNowActive = liveSpeechBuffer.isSpeechActive
        if isNowActive != wasSpeechActive {
            pipelineLog(isNowActive ? String(format: "GATE OPEN rms=%.4f", speechRMS) : String(format: "GATE CLOSED rms=%.4f", speechRMS))
            if isNowActive {
                publishSegmentStarted(segmentID: liveSpeechBuffer.currentSegmentID, rms: speechRMS)
            } else {
                var reason = "too_short"
                if case let .final(_, _, _, finalReason)? = update { reason = finalReason }
                publishSegmentEnded(segmentID: liveSpeechBuffer.currentSegmentID, reason: reason)
            }
        } else if Date().timeIntervalSince(lastPipelineHeartbeat) >= 1 {
            lastPipelineHeartbeat = Date()
            pipelineLog(String(format: "rms=%.4f active=%@ seg=%d", speechRMS, isNowActive ? "yes" : "no", liveSpeechBuffer.currentSegmentID))
        }
        if !wasSpeechActive, liveSpeechBuffer.isSpeechActive {
            liveGigaAMText = ""
            liveGigaAMDisplayedSegmentID = liveSpeechBuffer.currentSegmentID
            liveGigaAMStatus = "Речь обнаружена · собираю 1 с контекста"
            liveCAMStatus = "Собираю голосовое окно"
        } else if !liveSpeechBuffer.isSpeechActive, runtime.gigaAMAvailable {
            liveGigaAMStatus = String(format: "Ожидает речь · RMS %.3f / порог %.3f", speechRMS,
                                      LiveSpeechBuffer.speechThreshold)
        } else if liveSpeechBuffer.isSpeechActive, liveGigaAMText.isEmpty,
                  liveGigaAMStatus.hasPrefix("Ожидает") {
            liveGigaAMStatus = "Речь обнаружена · собираю 1 с контекста"
        }
        if let update { handleLiveSpeechUpdate(update) }
    }

    // MARK: - Silero VAD in the shadow

    private func startVAD() {
        guard runtime.sileroVADAvailable else { return }
        stopVAD()
        vadProbability = nil; vadHistory.removeAll(); vadOnlySeconds = 0; energyOnlySeconds = 0; lastVadSpeech = false
        let (stream, continuation) = AsyncStream<(samples: [Float], energyVoiced: Bool)>.makeStream(bufferingPolicy: .bufferingNewest(64))
        vadContinuation = continuation
        let analyzer = vadAnalyzer
        vadTask = Task { @MainActor [weak self] in
            await analyzer.reset()
            // One consumer, chunks in order: the VAD carries state from one chunk to the next.
            for await item in stream {
                guard let self else { return }
                guard let score = try? await analyzer.score(item.samples) else { continue }
                let speech = score.maximum >= 0.5
                self.vadProbability = score.maximum
                self.vadHistory.append(score.maximum)
                if self.vadHistory.count > 30 { self.vadHistory.removeFirst(self.vadHistory.count - 30) }
                if speech && !item.energyVoiced { self.vadOnlySeconds += 0.16 }
                if !speech && item.energyVoiced { self.energyOnlySeconds += 0.16 }
                // The bus gets a change of state, or a sample every 0.5 s: not six messages a second.
                if speech != self.lastVadSpeech || Date().timeIntervalSince(self.lastVadPublish) >= 0.5 {
                    self.lastVadSpeech = speech
                    self.lastVadPublish = Date()
                    await self.bus.publish(SignalMessage(source: "Sensors.SileroVAD", type: "audio.speech.estimated",
                                                         payload: ["probability_max": String(format: "%.3f", score.maximum),
                                                                   "probability_mean": String(format: "%.3f", score.mean),
                                                                   "speech": "\(speech)", "energy_voiced": "\(item.energyVoiced)",
                                                                   "window_ms": "160", "model": "silero-vad-v5"]))
                }
            }
        }
    }

    private func stopVAD() {
        vadContinuation?.finish()
        vadContinuation = nil
        vadTask = nil
    }

    private func nextTranscriptRevision(_ subject: String) -> UInt64 {
        let next = (transcriptRevisions[subject] ?? 0) + 1
        transcriptRevisions[subject] = next
        return next
    }

    private func utteranceSubject(sessionID: Int, segmentID: Int) -> String {
        "utterance/s\(sessionID)-seg\(segmentID)"
    }

    /// Boundaries come from the energy gate in `LiveSpeechBuffer`: they mark acoustic
    /// activity above a fixed RMS threshold, not confirmed speech.
    private func publishSegmentStarted(segmentID: Int, rms: Float) {
        liveSegmentStartedAt = Date()
        let subject = utteranceSubject(sessionID: liveSessionID, segmentID: segmentID)
        let payload = ["segment_id": "\(segmentID)", "detector": "energy_gate",
                       "rms": String(format: "%.4f", rms),
                       "threshold": String(format: "%.4f", LiveSpeechBuffer.speechThreshold),
                       "pre_roll_ms": "900"]
            .merging(tapeStartReference()) { _, new in new }
        Task { await bus.publish(SignalMessage(source: "Sensors.SpeechGate", type: "speech.segment.started",
                                               subjectID: subject, correlationID: subject, payload: payload)) }
    }

    /// Where the segment begins on the tape, including the 0.9 s pre-roll that the gate keeps.
    private func tapeStartReference() -> [String: String] {
        guard let position = lastTapePosition else { return [:] }
        let preRollSamples = 14_400
        return ["tape_file": position.file,
                "tape_start_sample": "\(max(0, position.sampleOffset - preRollSamples))"]
    }

    private func publishSegmentEnded(segmentID: Int, reason: String) {
        let duration = liveSegmentStartedAt.map { Int(Date().timeIntervalSince($0) * 1_000) }
        liveSegmentStartedAt = nil
        let subject = utteranceSubject(sessionID: liveSessionID, segmentID: segmentID)
        var payload = ["segment_id": "\(segmentID)", "detector": "energy_gate", "reason": reason]
        if let duration { payload["duration_ms"] = "\(duration)" }
        if let position = lastTapePosition {
            payload["tape_file"] = position.file
            payload["tape_end_sample"] = "\(position.endSampleOffset)"
        }
        Task { await bus.publish(SignalMessage(source: "Sensors.SpeechGate", type: "speech.segment.ended",
                                               subjectID: subject, correlationID: subject, payload: payload)) }
    }

    private func handleLiveSpeechUpdate(_ update: LiveSpeechUpdate) {
        switch update {
        case let .interim(segmentID, wav, durationMilliseconds):
            pipelineLog("interim seg=\(segmentID) dur=\(durationMilliseconds)ms wav=\(wav.count)B")
            if runtime.gigaAMAvailable {
                pendingLiveGigaAMInterim = PendingLiveGigaAM(kind: .interim, sessionID: liveSessionID,
                                                              segmentID: segmentID, wav: wav,
                                                              durationMilliseconds: durationMilliseconds)
                liveGigaAMStatus = "Обновляю гипотезу · окно до 8 с"
                drainLiveGigaAMIfNeeded()
            } else {
                liveGigaAMStatus = "Нет GigaAM runtime или модели"
            }
            scheduleLiveCAMWindow(segmentID: segmentID)
        case let .final(segmentID, wav, durationMilliseconds, reason):
            pipelineLog("final seg=\(segmentID) dur=\(durationMilliseconds)ms reason=\(reason) wav=\(wav.count)B")
            pendingLiveGigaAMInterim = nil
            liveGigaAMStatus = "Реплика завершена · распознаю финал"
            if runtime.gigaAMAvailable {
                pendingLiveGigaAMFinals.append(PendingLiveGigaAM(kind: .final(reason: reason), sessionID: liveSessionID,
                                                                  segmentID: segmentID, wav: wav,
                                                                  durationMilliseconds: durationMilliseconds))
                drainLiveGigaAMIfNeeded()
            }
            estimateTurnEnd(wav: wav, segmentID: segmentID, durationMilliseconds: durationMilliseconds, reason: reason)
            processVoxLockFinal(wav: wav, durationMilliseconds: durationMilliseconds, reason: reason)
        }
    }

    private func drainLiveGigaAMIfNeeded() {
        guard liveGigaAMDrainTask == nil else { return }
        liveGigaAMDrainTask = Task { @MainActor [weak self] in
            await self?.drainLiveGigaAMRequests()
        }
    }

    private func drainLiveGigaAMRequests() async {
        while true {
            let request: PendingLiveGigaAM
            if !pendingLiveGigaAMFinals.isEmpty {
                request = pendingLiveGigaAMFinals.removeFirst()
            } else if let interim = pendingLiveGigaAMInterim {
                request = interim
                pendingLiveGigaAMInterim = nil
            } else {
                break
            }
            if case .interim = request.kind,
               (!liveSpeechBuffer.isSpeechActive || liveSpeechBuffer.currentSegmentID != request.segmentID) {
                continue
            }
            let started = ContinuousClock.now
            do {
                let text = try await gigaAMAnalyzer.transcribe(wav: request.wav)
                let elapsed = Self.milliseconds(since: started)
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                switch request.kind {
                case .interim:
                    guard liveSpeechBuffer.isSpeechActive,
                          liveSpeechBuffer.currentSegmentID == request.segmentID else { continue }
                    guard !clean.isEmpty else { continue }
                    liveGigaAMText = clean
                    liveGigaAMLastLatencyMilliseconds = elapsed
                    gigaAMReady = true
                    liveGigaAMStatus = "Черновая гипотеза · \(elapsed) мс обработки"
                    let subject = utteranceSubject(sessionID: request.sessionID, segmentID: request.segmentID)
                    await bus.publish(SignalMessage(source: "Sensors.GigaAM.Live", type: "speech.transcript.partial",
                                                    subjectID: subject, revision: nextTranscriptRevision(subject),
                                                    correlationID: subject,
                                                    payload: ["text": clean, "lane": "raw", "language": "ru-RU",
                                                              "model": "gigaam-v3-e2e-ctc",
                                                              "window_ms": "\(request.durationMilliseconds)",
                                                              "recognition_ms": "\(elapsed)"]))
                case let .final(reason):
                    if request.segmentID >= liveGigaAMDisplayedSegmentID {
                        liveGigaAMDisplayedSegmentID = request.segmentID
                        liveGigaAMText = clean
                        liveGigaAMLastLatencyMilliseconds = elapsed
                        gigaAMReady = true
                        liveGigaAMStatus = clean.isEmpty ? "Финал: текст не распознан" : "Финальная реплика · \(elapsed) мс обработки"
                    }
                    let subject = utteranceSubject(sessionID: request.sessionID, segmentID: request.segmentID)
                    let revision = nextTranscriptRevision(subject)
                    transcriptRevisions[subject] = nil
                    await bus.publish(SignalMessage(source: "Sensors.GigaAM.Live", type: "speech.transcript.final",
                                                    subjectID: subject, revision: revision,
                                                    correlationID: subject,
                                                    payload: ["text": clean, "lane": "raw",
                                                              "source": "GigaAM v3 · общий микрофон",
                                                              "language": "ru-RU",
                                                              "model": "gigaam-v3-e2e-ctc",
                                                              "duration_ms": "\(request.durationMilliseconds)",
                                                              "recognition_ms": "\(elapsed)", "reason": reason,
                                                              "speaker": "unassigned"]))
                }
            } catch {
                switch request.kind {
                case .interim where liveSpeechBuffer.isSpeechActive && liveSpeechBuffer.currentSegmentID == request.segmentID:
                    pipelineLog("gigaam interim FAILED: \(error.localizedDescription)")
                    gigaAMReady = false
                    liveGigaAMStatus = "Ошибка GigaAM: \(error.localizedDescription)"
                case let .final(reason):
                    pipelineLog("gigaam FINAL FAILED reason=\(reason): \(error.localizedDescription)")
                    gigaAMReady = false
                    liveGigaAMStatus = "Ошибка финального распознавания"
                    await bus.publish(SignalMessage(source: "Sensors.GigaAM.Live", type: "analyzer.failed",
                                                    payload: ["error": error.localizedDescription,
                                                              "reason": reason,
                                                              "duration_ms": "\(request.durationMilliseconds)"]))
                default:
                    break
                }
            }
        }
        liveGigaAMDrainTask = nil
        if !pendingLiveGigaAMFinals.isEmpty || pendingLiveGigaAMInterim != nil {
            drainLiveGigaAMIfNeeded()
        }
    }

    private func scheduleLiveCAMWindow(segmentID: Int) {
        guard runtime.speakerModelAvailable, !references.isEmpty else {
            liveCAMStatus = runtime.speakerModelAvailable ? "Нет профилей CAM++ в локальной базе" : "CAM++ runtime или модель недоступны"
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastLiveCAMEnqueueAt) >= 1 else { return }
        guard let pcm16 = liveSpeechBuffer.recentPCM16(milliseconds: 1_600), pcm16.count >= 16_000 * 2 else { return }
        lastLiveCAMEnqueueAt = now
        liveCAMWindow = PendingLiveCAMWindow(segmentID: segmentID,
                                             wav: LiveSpeechBuffer.wav(pcm16: pcm16), durationMilliseconds: 1_600)
        liveCAMStatus = "Сравниваю окно 1,6 с с профилями из локальной базы"
        guard liveCAMDrainTask == nil else { return }
        liveCAMDrainTask = Task { @MainActor [weak self] in
            await self?.drainLiveCAMWindows()
        }
    }

    private func drainLiveCAMWindows() async {
        while let window = liveCAMWindow {
            liveCAMWindow = nil
            guard !references.isEmpty else {
                liveCAMStatus = "Нет профилей CAM++ в локальной базе"
                continue
            }
            let started = ContinuousClock.now
            do {
                let embedding = try await camPlusAnalyzer.embed(wav: window.wav)
                let ranked = references.compactMap { reference -> LiveCAMMatch? in
                    guard let best = SpeakerReferenceStore.bestCosine(embedding.values, against: reference) else { return nil }
                    return LiveCAMMatch(personID: reference.personID, label: reference.label,
                                        similarity: best.similarity, role: reference.role)
                }.sorted { $0.similarity > $1.similarity }
                guard let best = ranked.first else { continue }
                let elapsed = Self.milliseconds(since: started)
                liveCAMSimilarity = best.similarity
                liveCAMMatches = Array(ranked.prefix(2))
                liveCAMStatus = "Сравнено профилей: \(ranked.count) · сырое сходство, не подтверждение личности · \(elapsed) мс"
                liveSimilarityRevision += 1
                await bus.publish(SignalMessage(source: "Sensors.CAM++", type: "speaker.live.similarity.computed",
                                                subjectID: "speaker-window/seg-\(window.segmentID)",
                                                revision: liveSimilarityRevision,
                                                correlationID: utteranceSubject(sessionID: liveSessionID, segmentID: window.segmentID),
                                                payload: ["reference": best.label,
                                                          "person_id": best.personID,
                                                          "participant_role": best.role,
                                                          "owner_cosine": ranked.first(where: { $0.role == "owner" }).map { String(format: "%.4f", $0.similarity) } ?? "",
                                                          "second_person_id": ranked.dropFirst().first?.personID ?? "",
                                                          "second_role": ranked.dropFirst().first?.role ?? "",
                                                          "cosine_similarity": String(format: "%.4f", best.similarity),
                                                          "candidate_count": "\(ranked.count)",
                                                          "second_person": ranked.dropFirst().first?.label ?? "",
                                                          "second_cosine_similarity": ranked.dropFirst().first.map { String(format: "%.4f", $0.similarity) } ?? "",
                                                          "margin": ranked.count > 1 ? String(format: "%.4f", ranked[0].similarity - ranked[1].similarity) : "",
                                                          "window_ms": "\(window.durationMilliseconds)",
                                                          "inference_ms": "\(elapsed)",
                                                          "interpretation": "raw similarity; not a confirmed identity"]))
            } catch {
                pipelineLog("campp FAILED: \(error.localizedDescription)")
                liveCAMStatus = "Ошибка CAM++: \(error.localizedDescription)"
                await bus.publish(SignalMessage(source: "Sensors.CAM++", type: "analyzer.failed",
                                                payload: ["error": error.localizedDescription,
                                                          "window_ms": "\(window.durationMilliseconds)"]))
            }
        }
        liveCAMDrainTask = nil
        if liveCAMWindow != nil {
            liveCAMDrainTask = Task { @MainActor [weak self] in await self?.drainLiveCAMWindows() }
        }
    }

    /// Smart Turn reads the audio of a finished utterance and says how likely the speaker is done. It does not
    /// wait for the transcript, so the scene often has the answer before the text arrives.
    private func estimateTurnEnd(wav: Data, segmentID: Int, durationMilliseconds: Int, reason: String) {
        guard runtime.smartTurnAvailable else { return }
        let subject = utteranceSubject(sessionID: liveSessionID, segmentID: segmentID)
        let analyzer = smartTurnAnalyzer
        Task {
            do {
                let estimate = try await analyzer.estimate(wav: wav)
                smartTurnHistory.append(estimate.probability)
                if smartTurnHistory.count > 8 { smartTurnHistory.removeFirst(smartTurnHistory.count - 8) }
                await bus.publish(SignalMessage(source: "Sensors.SmartTurn", type: "speech.turn_end.estimated",
                                                subjectID: subject, correlationID: subject,
                                                payload: ["probability": String(format: "%.3f", estimate.probability),
                                                          "model": "smart-turn-v3.2-cpu", "elapsed_ms": "\(estimate.milliseconds)",
                                                          "audio_ms": "\(durationMilliseconds)", "segment_end_reason": reason]))
            } catch {
                await bus.publish(SignalMessage(source: "Sensors.SmartTurn", type: "analyzer.failed",
                                                payload: ["error": error.localizedDescription]))
            }
        }
    }

    private func processVoxLockFinal(wav: Data, durationMilliseconds: Int, reason: String) {
        guard let analyzer = liveVoxLockAnalyzer else {
            liveVoxLockStatus = "Недоступен: нет модели или целевого WAV"
            return
        }
        if let superseded = pendingLiveVoxLock {
            Task {
                await bus.publish(SignalMessage(source: "Sensors.VoxLock", type: "analyzer.request.coalesced",
                                                payload: ["discarded_duration_ms": "\(superseded.durationMilliseconds)",
                                                          "reason": "newer_final_segment_arrived_before_processing"]))
            }
        }
        pendingLiveVoxLock = PendingLiveVoxLock(wav: wav, durationMilliseconds: durationMilliseconds, reason: reason)
        liveVoxLockStatus = "Ожидаю финальный сегмент для выделения"
        guard liveVoxLockDrainTask == nil else { return }
        liveVoxLockDrainTask = Task { @MainActor [weak self] in
            await self?.drainLiveVoxLockRequests(using: analyzer)
        }
    }

    private func drainLiveVoxLockRequests(using analyzer: VoxLockAnalyzer) async {
        while let request = pendingLiveVoxLock {
            pendingLiveVoxLock = nil
            voxLockGigaAMText = ""
            voxLockGigaAMLastLatencyMilliseconds = nil
            liveVoxLockStatus = "Выделяю целевой голос из завершённой реплики"
            let started = ContinuousClock.now
            await bus.publish(SignalMessage(source: "Sensors.VoxLock", type: "analyzer.started",
                                            payload: ["input": "shared_raw_post_voice_processing",
                                                      "duration_ms": "\(request.durationMilliseconds)", "reason": request.reason]))
            do {
                let output = try await analyzer.isolate(wav: request.wav)
                if let rms = Self.wavPCM16MonoRMS(output.wav) {
                    voxLockHistory.append(min(1, Double(rms) * 5))
                    if voxLockHistory.count > 30 { voxLockHistory.removeFirst(voxLockHistory.count - 30) }
                }
                let isolationElapsed = Self.milliseconds(since: started)
                liveVoxLockStatus = "Дорожка выделена · \(output.wav.count) байт · ASR после разделения"
                await bus.publish(SignalMessage(source: "Sensors.VoxLock", type: "audio.speaker.isolated",
                                                payload: ["duration_ms": "\(request.durationMilliseconds)",
                                                          "inference_ms": "\(output.inferenceMilliseconds)",
                                                          "elapsed_ms": "\(isolationElapsed)",
                                                          "output_bytes": "\(output.wav.count)",
                                                          "output_sample_rate_hz": "16000",
                                                          "storage": "memory_only"]))

                liveVoxLockStatus = "Распознаю выделенную дорожку через GigaAM"
                let asrStarted = ContinuousClock.now
                do {
                    let text = try await gigaAMAnalyzer.transcribe(wav: output.wav)
                    let asrElapsed = Self.milliseconds(since: asrStarted)
                    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    voxLockGigaAMText = clean
                    voxLockGigaAMLastLatencyMilliseconds = asrElapsed
                    liveVoxLockStatus = clean.isEmpty
                        ? "Дорожка выделена · GigaAM не распознал текст · \(asrElapsed) мс"
                        : "Дорожка выделена · изоляция \(output.inferenceMilliseconds) мс · ASR \(asrElapsed) мс"
                    await bus.publish(SignalMessage(source: "Sensors.GigaAM.VoxLock", type: "speech.transcript.final",
                                                    payload: ["text": clean, "lane": "voxlock",
                                                              "source": "GigaAM v3 · VoxLock · выделенный голос",
                                                              "language": "ru-RU", "model": "gigaam-v3-e2e-ctc",
                                                              "duration_ms": "\(request.durationMilliseconds)",
                                                              "isolation_ms": "\(output.inferenceMilliseconds)",
                                                              "recognition_ms": "\(asrElapsed)"]))
                } catch {
                    liveVoxLockStatus = "Дорожка выделена · ошибка GigaAM: \(error.localizedDescription)"
                    await bus.publish(SignalMessage(source: "Sensors.GigaAM.VoxLock", type: "analyzer.failed",
                                                    payload: ["lane": "voxlock", "error": error.localizedDescription,
                                                              "duration_ms": "\(request.durationMilliseconds)",
                                                              "isolation_ms": "\(output.inferenceMilliseconds)"]))
                }
            } catch {
                liveVoxLockStatus = "Ошибка VoxLock: \(error.localizedDescription)"
                await bus.publish(SignalMessage(source: "Sensors.VoxLock", type: "analyzer.failed",
                                                payload: ["error": error.localizedDescription,
                                                          "duration_ms": "\(request.durationMilliseconds)"]))
            }
        }
        liveVoxLockDrainTask = nil
    }

    // MARK: - Automation (launch arguments)
    //
    //   --feed <file.wav>              play the file as microphone input (starts listening by itself)
    //   --snapshot-dir <dir>           write PNG snapshots of the window into <dir>
    //   --snapshot-after <s,s,...>     seconds after launch at which to take them
    //   --quit-after <s>               stop and quit after that many seconds
    //   --listen                       start the real microphone by itself (for remote use)
    //   --agent                        let Core run handed-over turns as tasks (sandbox folder only); answers are spoken
    //   --mute                         do not speak answers aloud
    //   --snapshot-interval <s>        with --snapshot-dir: keep overwriting latest.png (and latest-bottom.png)
    func runAutomationIfRequested() {
        guard !automationStarted else { return }
        automationStarted = true
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        if let feed = value("--feed") {
            feedURL = URL(fileURLWithPath: feed)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                toggleMicrophone()
            }
        }
        if let directory = value("--snapshot-dir"), let after = value("--snapshot-after") {
            for seconds in after.split(separator: ",").compactMap({ Double($0) }) {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(seconds))
                    saveWindowSnapshot(to: URL(fileURLWithPath: directory).appending(path: "shot-\(Int(seconds))s.png"))
                }
            }
        }
        if args.contains("--mute") { speaker.isMuted = true }
        if args.contains("--agent") {
            agent.setEnabled(true)
            if speechAvailable { let speech = sileroSpeech; Task { try? await speech.warm() } }   // the first answer should not wait for a cold start
        }
        if args.contains("--listen") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                if !isMicrophoneListening { toggleMicrophone() }
            }
        }
        if let directory = value("--snapshot-dir"), let interval = value("--snapshot-interval").flatMap(Double.init), interval >= 2 {
            Task { @MainActor in
                while true {
                    try? await Task.sleep(for: .seconds(interval))
                    // Always off screen: grabbing the real window would move the user's scroll position.
                    renderInterfaceWithoutWindow(to: URL(fileURLWithPath: directory).appending(path: "latest.png"))
                }
            }
        }
        if let quit = value("--quit-after").flatMap(Double.init) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(quit))
                stopMicrophone()
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        }
    }

    /// Draws the whole interface into a PNG without any window, tall enough that nothing needs scrolling.
    private func renderInterfaceWithoutWindow(to url: URL) {
        let renderer = ImageRenderer(content: ContentView(model: self, scrollable: false).frame(width: 1640).fixedSize(horizontal: false, vertical: true).background(Color.black))
        renderer.scale = 1
        guard let image = renderer.cgImage else {
            fputs("[vera] snapshot FAILED: no window and offscreen render failed\n", stderr)
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            fputs("[vera] snapshot saved offscreen \(url.lastPathComponent)\n", stderr)
        } catch {
            fputs("[vera] snapshot FAILED: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, (scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height { return scroll }
        for child in view.subviews { if let found = firstScrollView(in: child) { return found } }
        return nil
    }

    /// Renders the app's own window content to a PNG. It draws the view hierarchy directly, so it
    /// needs neither Screen Recording permission nor an unlocked screen.
    private func saveWindowSnapshot(to url: URL) {
        guard let view = NSApp.windows.compactMap(\.contentView).max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }),
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            // No window (a locked screen creates none): render the interface off screen instead.
            renderInterfaceWithoutWindow(to: url)
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            fputs("[vera] snapshot saved \(url.lastPathComponent)\n", stderr)
            // The window is a scroll view: also save the bottom part, where the Scene tile lives.
            if let scroll = Self.firstScrollView(in: view), let document = scroll.documentView {
                let original = scroll.contentView.bounds.origin
                let bottom = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
                scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
                scroll.reflectScrolledClipView(scroll.contentView)
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                if let lower = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: lower)
                    let name = url.deletingPathExtension().lastPathComponent + "-bottom.png"
                    try lower.representation(using: .png, properties: [:])?.write(to: url.deletingLastPathComponent().appending(path: name))
                    fputs("[vera] snapshot saved \(name)\n", stderr)
                }
                scroll.contentView.scroll(to: original)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        } catch {
            fputs("[vera] snapshot FAILED: \(error.localizedDescription)\n", stderr)
        }
    }

    func stopMicrophone() {
        guard isMicrophoneListening || isMicrophoneStarting else { return }
        spectrumAnalyzer.endSession(liveSessionID)
        spectrumWorkInFlight = false
        spectrumNeedsReset = false
        microphoneSpectrum.removeAll(keepingCapacity: true)
        microphoneRMS = 0
        microphonePeak = 0
        microphoneDBFS = -120
        let wasSpeechActive = liveSpeechBuffer.isSpeechActive
        if let update = liveSpeechBuffer.flush() { handleLiveSpeechUpdate(update) }
        if wasSpeechActive {
            publishSegmentEnded(segmentID: liveSpeechBuffer.currentSegmentID, reason: "microphone_stopped")
        }
        nomoInFlight = false
        nomoSkippedWindows = 0
        transcriptRevisions.removeAll()
        tape.finalize()
        lastTapePosition = nil
        stopVAD()
        microphoneCapture?.stop()
        microphoneCapture = nil
        audioFeed?.stop()
        audioFeed = nil
        let analyzer = nomoPVAD
        nomoPVAD = nil
        isMicrophoneListening = false
        isMicrophoneStarting = false
        microphoneAECActive = nil
        targetSpeakerProbability = nil
        targetSpeakerHistory.removeAll(keepingCapacity: true)
        voxLockHistory.removeAll(keepingCapacity: true)
        pipelineLog("mic stopped")
        stopUsagePolling()
        try? pipelineLogHandle?.close()
        pipelineLogHandle = nil
        microphoneStatus = "Микрофон выключен"
        liveSpeechBuffer.reset()
        pendingLiveGigaAMInterim = nil
        gigaAMReady = false
        liveGigaAMStatus = "Микрофон выключен"
        liveCAMStatus = "Микрофон выключен"
        liveNomoStatus = "Микрофон выключен"
        liveVoxLockStatus = "Ожидание завершённой речи"
        if let analyzer { Task { await analyzer.stop() } }
        Task {
            await bus.publish(SignalMessage(source: "Sensors.Microphone", type: "audio.microphone.stopped"))
            recordedMessageCount = await recorder.recordedCount
            await recorder.stop()
            recordedMessageCount = await recorder.recordedCount
        }
    }

    private func completeSpectrumWork(_ frame: LiveSpectrumFrame?, sessionID: Int) {
        guard sessionID == liveSessionID else { return }
        spectrumWorkInFlight = false
        guard isMicrophoneListening, let frame else { return }
        let cutoff = frame.timestamp.addingTimeInterval(-5)
        microphoneSpectrum.append(frame)
        microphoneSpectrum.removeAll { $0.timestamp < cutoff }
        if microphoneSpectrum.count > 32 {
            microphoneSpectrum.removeFirst(microphoneSpectrum.count - 32)
        }
    }

    func runAnalysis() {
        guard let audio = selectedAudio else { status = "Сначала добавь WAV-фрагмент"; return }
        guard useGigaAM || useCAMPlus || useVoxLock else { status = "Включи хотя бы один анализатор"; return }
        guard !useVoxLock || ownerVoiceSample != nil else { status = "Для VoxLock выбери образец голоса"; return }
        guard !(useGigaAM || useVoxLock) || runtime.gigaAMAvailable else { status = "GigaAM не найден в Vera 1"; return }
        guard !useCAMPlus || runtime.speakerModelAvailable else { status = "Модель CAM++ не найдена в Vera 1"; return }
        guard !useVoxLock || runtime.voxLockAvailable else { status = "Модели VoxLock не найдены в Vera 1"; return }
        let start = max(0, min(segmentStart, audio.duration))
        let end = max(start, min(segmentEnd, audio.duration))
        guard end - start <= 180 else { status = "Для одного прогона выбери отрезок не длиннее 180 секунд"; return }
        guard end > start else { status = "Проверь границы выбранного отрезка"; return }
        isAnalyzing = true
        status = "Читаю отрезок и запускаю независимые анализаторы…"
        let selection = AnalyzerSelection(gigaAM: useGigaAM || useVoxLock, camPlus: useCAMPlus, voxLock: useVoxLock)
        let sample = ownerVoiceSample
        let bus = self.bus
        let analysis = sensorAnalysis
        let refs = references
        Task { @MainActor in
            defer { isAnalyzing = false }
            do {
                let segment = try await Task.detached(priority: .userInitiated) { try audio.readSegment(start: start, end: end) }.value
                let result = await analysis.run(segment: segment, selection: selection, bus: bus,
                                                ownerVoiceSample: sample, references: refs)
                status = "Прогон завершён · \(segment.sourceURL.lastPathComponent) · \(formatDuration(segment.duration))"
                if let wav = result.isolatedWav { player = try? AVAudioPlayer(data: wav) }
            } catch { status = error.localizedDescription }
        }
    }

    func playSelectedSegment() {
        guard let audio = selectedAudio else { return }
        let start = max(0, min(segmentStart, audio.duration))
        let end = max(start, min(segmentEnd, audio.duration))
        do {
            let segment = try audio.readSegment(start: start, end: end)
            player = try AVAudioPlayer(data: segment.wav)
            player?.prepareToPlay()
            player?.play()
        } catch { status = error.localizedDescription }
    }

    func addSpeakerReference() {
        guard let embedding = scene.latestEmbedding else { status = "Сначала извлеки голосовой отпечаток"; return }
        let label = speakerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { status = "Введи имя голосового эталона"; return }
        do {
            references = try SpeakerReferenceStore.appendTemplate(embedding, label: label,
                                                                  appSupportDirectory: runtime.appSupportURL)
            speakerLabel = ""
            status = "Эталон сохранён локально · \(label)"
        } catch { status = "Не удалось сохранить эталон: \(error.localizedDescription)" }
    }

    func removeReference(_ reference: SpeakerReference) {
        do {
            references = try SpeakerReferenceStore.disableProfile(personID: reference.personID,
                                                                  appSupportDirectory: runtime.appSupportURL)
        } catch { status = "Не удалось удалить голосовой профиль: \(error.localizedDescription)" }
    }

    private static func milliseconds(since instant: ContinuousClock.Instant) -> Int {
        let duration = instant.duration(to: .now)
        return Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1 * $1) }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    private static func wavPCM16MonoRMS(_ wav: Data) -> Float? {
        guard wav.count > 46 else { return nil }
        var sum: Double = 0
        var count = 0
        wav.dropFirst(44).withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self)
            for i in 0..<ptr.count {
                let s = Float(Int16(littleEndian: ptr[i])) / 32768
                sum += Double(s * s)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return Float((sum / Double(count)).squareRoot())
    }

    func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// A starting skill, written only if the folder is empty; the owner and Vera edit these files afterwards.
    nonisolated static func seedSkills(in directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty else { return }
        let text = """
        ---
        name: edit-file
        description: как менять существующий файл в рабочей папке и убедиться, что получилось
        ---
        1. Сначала прочитай файл целиком (read_file), не угадывай содержимое.
        2. Меняй точечно через replace_in_file; write_file только для новых файлов или полной замены.
        3. После правки прочитай файл ещё раз и сверь результат с просьбой.
        4. В ответе скажи одной фразой, что именно изменено.
        """
        try? text.write(to: directory.appending(path: "edit-file.md"), atomically: true, encoding: .utf8)
    }
}


/// Lets the tool that reports on the tasks reach the agent that is built after the tools.
final class AgentBox: @unchecked Sendable {
    weak var agent: CoreAgent?
}
