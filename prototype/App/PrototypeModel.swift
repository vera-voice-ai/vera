import AppKit
import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers
import Sensors
import SignalBus
import Scene

@MainActor
@Observable
final class PrototypeModel {
    struct LiveCAMMatch: Identifiable {
        let personID: String
        let label: String
        let similarity: Double
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
    let scene = SceneModel()
    let runtime: ModelRuntime
    private let sensorAnalysis: SensorAnalysis
    private let gigaAMAnalyzer: GigaAMAnalyzer
    private let camPlusAnalyzer: SpeakerEmbeddingAnalyzer
    private var player: AVAudioPlayer?
    private var microphoneCapture: MicrophoneCapture?
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
    var targetSpeakerProbability: Double?
    var targetSpeakerHistory: [Double] = []
    var liveGigaAMText = ""
    var liveGigaAMStatus = "Микрофон выключен"
    var liveGigaAMLastLatencyMilliseconds: Int?
    var liveCAMStatus = "Ожидание микрофона"
    var liveCAMSimilarity: Double?
    var liveCAMMatches: [LiveCAMMatch] = []
    var liveNomoStatus = "Ожидание микрофона"
    var liveVoxLockStatus = "Ожидание завершённой речи"
    var voxLockGigaAMText = ""
    var voxLockGigaAMLastLatencyMilliseconds: Int?
    var ownerVoiceSample: URL?
    var speakerLabel = ""
    var references: [SpeakerReference]
    var fileErrors: [String] = []

    init() {
        let runtime = ModelRuntime()
        self.runtime = runtime
        let gigaAMAnalyzer = GigaAMAnalyzer(runtime: runtime)
        let camPlusAnalyzer = SpeakerEmbeddingAnalyzer(runtime: runtime)
        self.gigaAMAnalyzer = gigaAMAnalyzer
        self.camPlusAnalyzer = camPlusAnalyzer
        self.sensorAnalysis = SensorAnalysis(runtime: runtime, gigaAM: gigaAMAnalyzer, camPlus: camPlusAnalyzer)
        references = SpeakerReferenceStore.load(from: runtime.appSupportURL)
        let targetVoice = Self.validDefaultTargetVoiceURL(runtime.alexTargetVoiceURL)
        ownerVoiceSample = targetVoice
        nomoEnrollmentURL = targetVoice
        if runtime.voxLockAvailable, let targetVoice {
            liveVoxLockAnalyzer = VoxLockAnalyzer(runtime: runtime, ownerVoiceSample: targetVoice)
        }
        try? runtime.createRuntimeDirectories()
        Task { await busMonitor.consume(bus) }
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
        liveSpeechBuffer.reset()
        pendingLiveGigaAMInterim = nil
        microphoneWaveform.removeAll(keepingCapacity: true)
        targetSpeakerHistory.removeAll(keepingCapacity: true)
        targetSpeakerProbability = nil
        let capture = MicrophoneCapture()
        do {
            let aec = try capture.start { [weak self] chunk in
                Task { @MainActor in self?.receiveMicrophoneChunk(chunk) }
            }
            microphoneCapture = capture
            microphoneAECActive = aec
            isMicrophoneStarting = false
            isMicrophoneListening = true
            microphoneStatus = aec ? "Микрофон активен · Voice Processing / AEC включён" : "Микрофон активен · AEC недоступен"
            liveGigaAMStatus = runtime.gigaAMAvailable ? "Ожидание речи · русский GigaAM v3" : "Нет GigaAM runtime или модели"
            liveCAMStatus = runtime.speakerModelAvailable
                ? (references.contains(where: { $0.personID == "alex" }) ? "Ожидание речевого окна" : "Ожидание эталона CAM++")
                : "CAM++ runtime или модель недоступны"
            liveVoxLockStatus = liveVoxLockAnalyzer == nil ? "Недоступен: нет модели или эталона" : "Ожидание завершённой речи"
            Task { await bus.publish(SignalMessage(source: "Sensors.Microphone", type: "audio.microphone.started",
                                                    payload: ["sample_rate_hz": "16000", "aec": "\(aec)",
                                                              "input": "shared_raw_post_voice_processing",
                                                              "analyzers": "GigaAM,CAM++,Nomo-PVAD,VoxLock"])) }
            status = microphoneStatus
            startNomoIfAvailable(sessionID: liveSessionID)
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

    private func receiveMicrophoneChunk(_ chunk: MicrophoneChunk) {
        guard isMicrophoneListening else { return }
        microphoneWaveform.append(contentsOf: chunk.waveform)
        let waveformLimit = 1_800 // 3 s at 96 samples per 160 ms audio chunk
        if microphoneWaveform.count > waveformLimit {
            microphoneWaveform.removeFirst(microphoneWaveform.count - waveformLimit)
        }
        microphoneRMS = chunk.rms
        microphonePeak = chunk.peak
        microphoneAECActive = chunk.voiceProcessingActive
        let payload = ["sample_rate_hz": "16000", "input_rate_hz": "\(Int(chunk.inputSampleRate))",
                       "duration_ms": "160", "rms": String(format: "%.4f", chunk.rms),
                       "peak": String(format: "%.4f", chunk.peak), "aec": "\(chunk.voiceProcessingActive)"]
        Task { await bus.publish(SignalMessage(source: "Sensors.Microphone", type: "audio.input.observed", payload: payload)) }

        if let analyzer = nomoPVAD {
            let sessionID = liveSessionID
            Task { @MainActor in
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
                                                              "window_ms": "160"]))
                } catch {
                    liveNomoStatus = "Ошибка: \(error.localizedDescription)"
                    await bus.publish(SignalMessage(source: "Sensors.NomoPVAD", type: "analyzer.failed",
                                                    payload: ["error": error.localizedDescription]))
                }
            }
        }

        let speechRMS = Self.rms(chunk.samples16k)
        let wasSpeechActive = liveSpeechBuffer.isSpeechActive
        let update = liveSpeechBuffer.append(samples16k: chunk.samples16k, rms: speechRMS)
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

    private func handleLiveSpeechUpdate(_ update: LiveSpeechUpdate) {
        switch update {
        case let .interim(segmentID, wav, durationMilliseconds):
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
            pendingLiveGigaAMInterim = nil
            liveGigaAMStatus = "Реплика завершена · распознаю финал"
            if runtime.gigaAMAvailable {
                pendingLiveGigaAMFinals.append(PendingLiveGigaAM(kind: .final(reason: reason), sessionID: liveSessionID,
                                                                  segmentID: segmentID, wav: wav,
                                                                  durationMilliseconds: durationMilliseconds))
                drainLiveGigaAMIfNeeded()
            }
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
                    liveGigaAMStatus = "Черновая гипотеза · \(elapsed) мс обработки"
                case let .final(reason):
                    if request.segmentID >= liveGigaAMDisplayedSegmentID {
                        liveGigaAMDisplayedSegmentID = request.segmentID
                        liveGigaAMText = clean
                        liveGigaAMLastLatencyMilliseconds = elapsed
                        liveGigaAMStatus = clean.isEmpty ? "Финал: текст не распознан" : "Финальная реплика · \(elapsed) мс обработки"
                    }
                    await bus.publish(SignalMessage(source: "Sensors.GigaAM.Live", type: "speech.transcript.final",
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
                    liveGigaAMStatus = "Ошибка GigaAM: \(error.localizedDescription)"
                case let .final(reason):
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
                                        similarity: best.similarity)
                }.sorted { $0.similarity > $1.similarity }
                guard let best = ranked.first else { continue }
                let elapsed = Self.milliseconds(since: started)
                liveCAMSimilarity = best.similarity
                liveCAMMatches = Array(ranked.prefix(2))
                liveCAMStatus = "Сравнено профилей: \(ranked.count) · сырое сходство, не подтверждение личности · \(elapsed) мс"
                await bus.publish(SignalMessage(source: "Sensors.CAM++", type: "speaker.live.similarity.computed",
                                                payload: ["reference": best.label,
                                                          "person_id": best.personID,
                                                          "cosine_similarity": String(format: "%.4f", best.similarity),
                                                          "candidate_count": "\(ranked.count)",
                                                          "second_person": ranked.dropFirst().first?.label ?? "",
                                                          "second_cosine_similarity": ranked.dropFirst().first.map { String(format: "%.4f", $0.similarity) } ?? "",
                                                          "margin": ranked.count > 1 ? String(format: "%.4f", ranked[0].similarity - ranked[1].similarity) : "",
                                                          "window_ms": "\(window.durationMilliseconds)",
                                                          "inference_ms": "\(elapsed)",
                                                          "interpretation": "raw similarity; not a confirmed identity"]))
            } catch {
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

    func stopMicrophone() {
        guard isMicrophoneListening || isMicrophoneStarting else { return }
        if let update = liveSpeechBuffer.flush() { handleLiveSpeechUpdate(update) }
        microphoneCapture?.stop()
        microphoneCapture = nil
        let analyzer = nomoPVAD
        nomoPVAD = nil
        isMicrophoneListening = false
        isMicrophoneStarting = false
        microphoneAECActive = nil
        targetSpeakerProbability = nil
        targetSpeakerHistory.removeAll(keepingCapacity: true)
        microphoneStatus = "Микрофон выключен"
        liveSpeechBuffer.reset()
        pendingLiveGigaAMInterim = nil
        liveGigaAMStatus = "Микрофон выключен"
        liveCAMStatus = "Микрофон выключен"
        liveNomoStatus = "Микрофон выключен"
        liveVoxLockStatus = "Ожидание завершённой речи"
        if let analyzer { Task { await analyzer.stop() } }
        Task { await bus.publish(SignalMessage(source: "Sensors.Microphone", type: "audio.microphone.stopped")) }
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

    func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
