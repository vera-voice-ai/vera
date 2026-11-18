import SwiftUI
import Scene
import Sensors
import SignalBus

/// ScrollView, or its plain content: ImageRenderer cannot draw a ScrollView, and the off-screen snapshot needs the content.
private struct MaybeScroll<Content: View>: View {
    let scrollable: Bool
    @ViewBuilder let content: () -> Content
    var body: some View {
        if scrollable { ScrollView { content() } } else { content() }
    }
}

struct ContentView: View {
    @Bindable var model: PrototypeModel
    var scrollable = true
    private let background = Color(red: 0.035, green: 0.025, blue: 0.047)
    private let panel = Color(red: 0.085, green: 0.068, blue: 0.102)
    private let accent = Color(red: 0.94, green: 0.13, blue: 0.61)

    var body: some View {
        VStack(spacing: 0) {
            header
            MaybeScroll(scrollable: scrollable) {
                VStack(spacing: 12) {
                    moduleContour(name: "vera-sensors", title: "Sensors", color: Color(hex: 0x38BDF8)) {
                        sensorsBody
                    }
                    .frame(maxWidth: .infinity).frame(height: 440)

                    busContour
                        .frame(maxWidth: .infinity).frame(height: 165)

                    moduleContour(name: "vera-scene", title: "Scene", color: Color(hex: 0xA78BFA)) {
                        ScenePanel(snapshot: model.scene.snapshot,
                                   sceneModel: model.scene,
                                   judgeUsage: model.usageJev,
                                   judgeAvailable: model.runtime.jevAvailable)
                    }
                    .frame(maxWidth: .infinity).frame(height: 500)

                    HStack(alignment: .top, spacing: 12) {
                        moduleContour(name: "vera-core", title: "Core", color: Color(hex: 0xFACC15)) {
                            CorePanel(inbox: model.core, agent: model.agent)
                        }
                        .frame(maxWidth: .infinity).frame(height: 300)

                        moduleContour(name: "vera-response", title: "Response", color: Color(hex: 0x4ADE80)) {
                            ResponsePanel(speaker: model.speaker, available: model.speechAvailable)
                        }
                        .frame(maxWidth: .infinity).frame(height: 300)
                    }

                    storageContour
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(minWidth: 1220, minHeight: 920)
        .background(background.ignoresSafeArea())
        .onAppear { model.runAutomationIfRequested() }
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.12)).frame(width: 31, height: 31)
                Image(systemName: "waveform.path").font(.system(size: 15, weight: .semibold)).foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("ВЕРА · КОНТУР СИСТЕМЫ").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(1.5)
                    .foregroundStyle(.white.opacity(0.91))
                Text("Четыре модуля и Signal Bus · сенсорный прототип подключён")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.42))
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(model.isAnalyzing ? .orange : .green).frame(width: 7, height: 7)
                Text(model.isAnalyzing ? "PROCESSING" : "READY")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(0.8)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.white.opacity(0.04), in: Capsule())
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Color.black.opacity(0.16))
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
    }

    private var sensorsBody: some View {
        earsContour
    }

    private var micContent: some View {
        VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button(action: model.toggleMicrophone) {
                            Image(systemName: model.isMicrophoneListening ? "mic.fill" : "mic.slash.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.94))
                                .frame(width: 38, height: 38)
                                .background(
                                    model.isMicrophoneListening ? Color(hex: 0x3B82F6) : .white.opacity(0.09),
                                    in: Circle()
                                )
                                .overlay(Circle().stroke(.white.opacity(model.isMicrophoneListening ? 0.22 : 0.1), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(model.isMicrophoneListening ? "Выключить микрофон" : "Включить микрофон")
                        .accessibilityValue(model.isMicrophoneListening ? "Включён" : "Выключен")
                        .accessibilityHint("Включает или выключает потоковый захват микрофона")
                        .disabled(model.isMicrophoneStarting)
                        waveformView(model.microphoneWaveform)
                            .frame(width: 250, height: 42)
                            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.06), lineWidth: 1))
                        Spacer(minLength: 0)
                        Circle().fill(model.isMicrophoneListening ? .green : .white.opacity(0.25)).frame(width: 7, height: 7)
                    }
                    HStack(spacing: 7) {
                        Circle().fill(model.microphoneAECActive == true ? .green : .orange).frame(width: 6, height: 6)
                        if model.microphoneAECActive == true {
                            Text("AEC")
                        } else if model.microphoneAECActive == false {
                            // Without echo cancellation Vera would hear her own voice as the user's.
                            Text("AEC не активен · Вера может слышать себя").foregroundStyle(.orange)
                        } else {
                            Text("AEC выключен")
                        }
                        Spacer()
                        if model.isMicrophoneListening {
                            Text("RMS \(model.microphoneRMS, format: .number.precision(.fractionLength(3))) · пик \(model.microphonePeak, format: .number.precision(.fractionLength(2)))")
                        }
                    }
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.52))
                    if model.recordingFileName != nil {
                        HStack(spacing: 7) {
                            Circle().fill(model.isMicrophoneListening ? .red : .white.opacity(0.25)).frame(width: 6, height: 6)
                            TimelineView(.periodic(from: .now, by: 2)) { _ in
                                Text(model.recordingStatusText).lineLimit(1)
                            }
                            Spacer()
                        }
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.52))
                    }
                }
    }

    private var earsContour: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "ear.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: 0x38BDF8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Уши").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.88))
                    Text("поток с микрофона · живой разбор")
                        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.46))
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    micContent
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Image(systemName: "waveform.path.ecg").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                        Text("Анализаторы").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.88))
                    }
                    ScrollView {
                        analyzersContent
                    }
                    .scrollIndicators(.automatic)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 348)
        }
        .padding(10)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0x38BDF8).opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }

    private var analyzersContent: some View {
        VStack(alignment: .leading, spacing: 10) {
                    let gigaAMLive = model.runtime.gigaAMAvailable && model.gigaAMReady
                    HStack(spacing: 9) {
                        Text("GigaAM v3").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(gigaAMLive ? .white.opacity(0.86) : .white.opacity(0.36))
                        Spacer(minLength: 0)
                        Text(usageSuffix(model.usageGigaAM))
                            .font(.system(size: 7, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.42))
                        Text(gigaAMLive ? "ДОСТУПЕН" : "НЕДОСТУПЕН")
                            .font(.system(size: 7, weight: .semibold, design: .monospaced))
                            .foregroundStyle(gigaAMLive ? .green.opacity(0.9) : .white.opacity(0.38))
                        Circle().fill(gigaAMLive ? .green.opacity(0.8) : .white.opacity(0.2)).frame(width: 6, height: 6)
                    }
                    .padding(.vertical, 2)
                    Text(model.liveGigaAMText.isEmpty ? model.liveGigaAMStatus : model.liveGigaAMText)
                        .font(.system(size: 11, weight: model.liveGigaAMText.isEmpty ? .regular : .medium))
                        .foregroundStyle(model.liveGigaAMText.isEmpty ? .white.opacity(0.52) : .white.opacity(0.92))
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.leading, 27).padding(.vertical, 3)
                    separator
                    let camppAvailable = model.runtime.speakerModelAvailable
                    HStack(spacing: 9) {
                        Text("CAM++").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(camppAvailable ? .white.opacity(0.86) : .white.opacity(0.36))
                        Spacer(minLength: 0)
                        Text(usageSuffix(model.usageCAMPP))
                            .font(.system(size: 7, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.42))
                        Text(camppAvailable ? "ДОСТУПЕН" : "НЕДОСТУПЕН")
                            .font(.system(size: 7, weight: .semibold, design: .monospaced))
                            .foregroundStyle(camppAvailable ? .green.opacity(0.9) : .white.opacity(0.38))
                        Circle().fill(camppAvailable ? .green.opacity(0.8) : .white.opacity(0.2)).frame(width: 6, height: 6)
                    }
                    .padding(.vertical, 2)
                    Group {
                        if let first = model.liveCAMMatches.first {
                            Text("Наиболее похожий профиль: \(first.label) · cosine \(String(format: "%.3f", first.similarity))")
                                .foregroundStyle(.white.opacity(0.86))
                            if model.liveCAMMatches.count > 1, let second = model.liveCAMMatches.dropFirst().first {
                                let margin = first.similarity - second.similarity
                                Text("Следующий: \(second.label) · cosine \(String(format: "%.3f", second.similarity)) · разница \(String(format: "%.3f", margin))")
                                    .foregroundStyle(.white.opacity(0.57))
                            }
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.12))
                                    .overlay(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 2).fill(.cyan)
                                            .frame(width: geo.size.width * CGFloat(max(0, min(1, first.similarity))))
                                    }
                            }
                            .frame(height: 5)
                        } else {
                            Text(model.liveCAMStatus).foregroundStyle(.white.opacity(0.48))
                        }
                    }
                    .font(.system(size: 9, design: .monospaced)).lineLimit(2)
                    .padding(.leading, 27)
                    separator
                    let voxlockAvailable = model.runtime.voxLockAvailable
                    HStack(spacing: 9) {
                        Text("VoxLock").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(voxlockAvailable ? .white.opacity(0.86) : .white.opacity(0.36))
                        Spacer(minLength: 0)
                        Text(usageSuffix(model.usageVoxLock))
                            .font(.system(size: 7, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.42))
                        Text(voxlockAvailable ? "ДОСТУПЕН" : "НЕДОСТУПЕН")
                            .font(.system(size: 7, weight: .semibold, design: .monospaced))
                            .foregroundStyle(voxlockAvailable ? .green.opacity(0.9) : .white.opacity(0.38))
                        Circle().fill(voxlockAvailable ? .green.opacity(0.8) : .white.opacity(0.2)).frame(width: 6, height: 6)
                    }
                    .padding(.vertical, 2)
                    Text(model.voxLockGigaAMText.isEmpty ? model.liveVoxLockStatus : model.voxLockGigaAMText)
                        .font(.system(size: 11, weight: model.voxLockGigaAMText.isEmpty ? .regular : .medium))
                        .foregroundStyle(model.voxLockGigaAMText.isEmpty ? .white.opacity(0.52) : .white.opacity(0.92))
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.leading, 27).padding(.vertical, 3)
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(Array(model.voxLockHistory.enumerated()), id: \.offset) { _, value in
                            Capsule().fill(accent.opacity(0.3 + 0.7 * value))
                                .frame(maxWidth: .infinity)
                                .frame(height: max(2, CGFloat(value) * 18))
                        }
                        if model.voxLockHistory.isEmpty {
                            RoundedRectangle(cornerRadius: 1).fill(accent.opacity(0.18)).frame(maxWidth: .infinity).frame(height: 2)
                        }
                    }
                    .frame(height: 20, alignment: .bottom)
                    .padding(.leading, 27)
                    separator
                    let nomoAvailable = model.runtime.nomoPVADAvailable
                    HStack(spacing: 9) {
                        Text("Nomo-PVAD").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(nomoAvailable ? .white.opacity(0.86) : .white.opacity(0.36))
                        Spacer(minLength: 0)
                        Text(nomoAvailable ? "ДОСТУПЕН" : "НЕДОСТУПЕН")
                            .font(.system(size: 7, weight: .semibold, design: .monospaced))
                            .foregroundStyle(nomoAvailable ? .green.opacity(0.9) : .white.opacity(0.38))
                        Circle().fill(nomoAvailable ? .green.opacity(0.8) : .white.opacity(0.2)).frame(width: 6, height: 6)
                    }
                    .padding(.vertical, 2)
                    analyzerActivity("Nomo-PVAD", sources: ["Sensors.NomoPVAD"], live: true)
                    separator
                    smartTurnRow
                    separator
                    vadRow
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").foregroundStyle(.cyan.opacity(0.85))
                        Text("Распознавание и голосовой анализ работают параллельно. Groq/облачная отправка не включены.")
                            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.top, 3)
        }
    }

    /// Smart Turn reads the audio of each finished utterance: an audio analyzer, so it lives with the sensors.
    /// It estimates, from intonation and pauses, how likely the speaker is done. The scene only observes it.
    private var smartTurnRow: some View {
        let available = model.runtime.smartTurnAvailable
        let running = model.usageSmartTurn != nil
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Text("Smart Turn · конец по звуку").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(available ? .white.opacity(0.86) : .white.opacity(0.36))
                Spacer(minLength: 0)
                Text(model.usageSmartTurn.map { String(format: "CPU %.0f%% · %.1f ГБ", $0.cpuPercent, $0.rssMB / 1024) } ?? "")
                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                Text(!available ? "НЕДОСТУПЕН" : running ? "ДОСТУПЕН" : "ЖДЁТ")
                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                    .foregroundStyle(running ? .green.opacity(0.9) : .white.opacity(0.38))
                Circle().fill(running ? .green.opacity(0.8) : .white.opacity(0.2)).frame(width: 6, height: 6)
            }
            .padding(.vertical, 2)
            if let last = model.smartTurnHistory.last {
                HStack(spacing: 10) {
                    Text(String(format: "%.0f %%", last * 100))
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .foregroundStyle(last >= 0.9 ? .green : (last >= 0.5 ? .orange : .red.opacity(0.85)))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.08))
                            Capsule().fill((last >= 0.9 ? Color.green : (last >= 0.5 ? Color.orange : Color.red)).opacity(0.8))
                                .frame(width: geo.size.width * CGFloat(min(1, max(0, last))))
                        }
                    }
                    .frame(height: 4)
                }
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(model.smartTurnHistory.enumerated()), id: \.offset) { _, value in
                        Capsule().fill((value >= 0.9 ? Color.green : (value >= 0.5 ? Color.orange : Color.red)).opacity(0.8))
                            .frame(width: 8, height: 2 + 12 * CGFloat(min(1, max(0, value))))
                    }
                }
                .frame(height: 16, alignment: .bottom)
            } else {
                Text("оценок ещё нет").font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
            }
            Text("вероятность, что человек договорил, по интонации и паузам (не по тексту); сцена только наблюдает, не решает")
                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.45)).lineLimit(2)
        }
        .padding(.leading, 27)
    }

    /// Silero VAD runs next to the energy gate on the same chunks and decides nothing: this row shows where they differ.
    private var vadRow: some View {
        let available = model.runtime.sileroVADAvailable
        let running = model.usageVAD != nil
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Text("Silero VAD · речь").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(available ? .white.opacity(0.86) : .white.opacity(0.36))
                Spacer(minLength: 0)
                Text(model.usageVAD.map { String(format: "CPU %.0f%% · %.0f МБ", $0.cpuPercent, $0.rssMB) } ?? "")
                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                Text(!available ? "НЕДОСТУПЕН" : running ? "ДОСТУПЕН" : "ЖДЁТ")
                    .font(.system(size: 7, weight: .semibold, design: .monospaced))
                    .foregroundStyle(running ? .green.opacity(0.9) : .white.opacity(0.38))
                Circle().fill(running ? .green.opacity(0.8) : .white.opacity(0.2)).frame(width: 6, height: 6)
            }
            .padding(.vertical, 2)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(model.vadHistory.enumerated()), id: \.offset) { _, value in
                    Capsule().fill((value >= 0.5 ? Color.green : Color.white).opacity(value >= 0.5 ? 0.8 : 0.25))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(2, CGFloat(value) * 18))
                }
                if model.vadHistory.isEmpty {
                    RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.12)).frame(maxWidth: .infinity).frame(height: 2)
                }
            }
            .frame(height: 20, alignment: .bottom)
            Text(String(format: "сейчас %@ · речь без гейта: %.0f с · гейт без речи: %.0f с", model.vadProbability.map { String(format: "%.0f %%", $0 * 100) } ?? "—", model.vadOnlySeconds, model.energyOnlySeconds))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            Text("работает параллельно с энергетическим гейтом, ничего не решает; показывает, где они расходятся")
                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.45)).lineLimit(2)
        }
        .padding(.leading, 27)
    }

    private func usageSuffix(_ usage: AnalyzerUsage?) -> String {
        guard let usage else { return "" }
        return String(format: " · CPU %.0f%% · %.1f ГБ", usage.cpuPercent, usage.rssMB / 1024)
    }

    private static let tapeHiddenSources: Set<String> = ["Sensors.Microphone", "Sensors.NomoPVAD"]

    private var busContour: some View {
        let visible = model.busMonitor.messages.filter { !Self.tapeHiddenSources.contains($0.source) }
        let hiddenCount = model.busMonitor.messages.count - visible.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("vera-bus · Vera Signal Bus")
                        .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.92))
                    Text("Текущие сообщения шины · в реальном времени")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Text("\(visible.count) сообщений · чанки/скоры скрыты: \(hiddenCount)")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.cyan.opacity(0.85))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if visible.isEmpty {
                        Text("Ожидание сообщений из сенсорного контура")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                    } else {
                        ForEach(visible) { message in busMessageRow(message) }
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color(red: 0.07, green: 0.08, blue: 0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.cyan.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])))
    }

    private func busMessageRow(_ message: SignalMessage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(message.timestamp.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.cyan.opacity(0.78))
                    .frame(width: 88, alignment: .leading)
                Text(message.kind.rawValue.uppercased())
                    .font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.66))
                    .frame(width: 54, alignment: .leading)
                Text("\(message.domain.rawValue) · \(message.type)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1).truncationMode(.middle)
                Text(message.source)
                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            let preview = payloadPreview(message.payload)
            if !preview.isEmpty {
                Text(preview).font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.46))
                    .lineLimit(1).truncationMode(.middle).padding(.leading, 152)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
    }

    private func payloadPreview(_ payload: [String: String]) -> String {
        if let text = payload["text"], !text.isEmpty { return "text: \(text)" }
        return payload.keys.sorted().filter { $0 != "embedding_json" }
            .prefix(3).compactMap { key in payload[key].map { "\(key)=\($0)" } }
            .joined(separator: " · ")
    }

    @ViewBuilder private func moduleContour<Content: View>(name: String, title: String, color: Color,
                                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.93))
                Text(name).font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(0.6).foregroundStyle(color.opacity(0.65))
                Spacer(minLength: 0)
            }
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .background(Color(red: 0.065, green: 0.05, blue: 0.08), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(color.opacity(0.68), style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])))
    }

    private func emptyModule(name: String, title: String, color: Color) -> some View {
        moduleContour(name: name, title: title, color: color) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var storageContour: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive").foregroundStyle(.green)
                Text("Хранилища").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text("ЧТО СОХРАНЯЕТСЯ · ГДЕ")
                    .font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.42))
            }
            HStack(alignment: .top, spacing: 18) {
                storageItem("Образцы голосов", "Копируются в ~/Library/Application Support/VeraSensorPrototype/Users/voice-samples/")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Люди и векторы").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.82))
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill").font(.system(size: 11)).foregroundStyle(.green.opacity(0.9))
                        Text("Людей: \(model.references.count) · голосов: \(model.references.reduce(0) { $0 + $1.templateCount })")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.88))
                    }
                    Text("~/Library/Application Support/VeraSensorPrototype/Users/people.sqlite")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.green.opacity(0.75))
                        .lineLimit(2).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                storageItem("Логи моделей", "~/Library/Application Support/VeraSensorPrototype/Logs/")
                storageItem("Лента звука", "Всё, что слышит микрофон: WAV 16 кГц mono, по файлу на час, бессрочно (~115 МБ/ч) · ~/Library/Application Support/VeraSensorPrototype/Tape/<день>/<час>.wav")
                storageItem("Память Core", "Факты и история задач, JSONL (бессрочно, до 20 МБ на файл) · ~/Library/Application Support/VeraSensorPrototype/Memory/")
                storageItem("Навыки", "Markdown-файлы с описанием в шапке; Core видит список и подгружает текст по read_skill · ~/Library/Application Support/VeraSensorPrototype/Skills/")
                storageItem("Журнал модели", "Каждый запрос и ответ модели, без заголовков авторизации · ~/Library/Application Support/VeraSensorPrototype/Journal/")
                storageItem("Рабочая папка агента", "Единственное место, где Core читает и пишет файлы · ~/Library/Application Support/VeraSensorPrototype/Workspace/")
                storageItem("Запись шины", "Сообщения Sensors, один JSONL на сессию микрофона · ~/Library/Application Support/VeraSensorPrototype/Recordings/")
                storageItem("Ревизии сцены", "Только в памяти процесса; сохраняются лишь как сообщения scene в шине, которые не пишутся.", color: .orange)
            }
        }
        .padding(12)
        .background(Color(red: 0.055, green: 0.075, blue: 0.065), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.green.opacity(0.45), style: StrokeStyle(lineWidth: 1.1, dash: [6, 4])))
    }

    private func storageItem(_ title: String, _ location: String, color: Color = .green) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.82))
            Text(location).font(.system(size: 9, design: .monospaced)).foregroundStyle(color.opacity(0.75))
                .lineLimit(2).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func waveformView(_ samples: [Float]) -> some View {
        Canvas { context, size in
            guard !samples.isEmpty else {
                var idle = Path()
                idle.move(to: CGPoint(x: 0, y: size.height / 2))
                idle.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(idle, with: .color(accent.opacity(0.28)), lineWidth: 1)
                return
            }
            let middle = size.height / 2
            var path = Path()
            let count = max(1, samples.count - 1)
            for (index, sample) in samples.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(count)
                let y = middle - CGFloat(max(-1, min(1, sample))) * (size.height * 0.43)
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(accent), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: middle))
            baseline.addLine(to: CGPoint(x: size.width, y: middle))
            context.stroke(baseline, with: .color(accent.opacity(0.18)), lineWidth: 1)
        }
    }

    private func analyzerActivity(_ name: String, sources: [String], live: Bool) -> some View {
        let events = model.busMonitor.messages.filter { sources.contains($0.source) }
        let latest = events.first
        let history = live ? model.targetSpeakerHistory : []
        let isAvailable = live ? model.runtime.nomoPVADAvailable : false
        let isRunning = live
            ? isAvailable && model.isMicrophoneListening && model.nomoEnrollmentURL != nil && model.liveNomoStatus.hasPrefix("Работает")
            : model.isAnalyzing && latest?.type == "analyzer.started"

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(isRunning ? accent : (latest == nil ? .white.opacity(0.18) : .cyan.opacity(0.75)))
                    .frame(width: 5, height: 5)
                Text(live
                     ? (!isAvailable ? "НЕДОСТУПЕН" : isRunning ? model.liveNomoStatus + usageSuffix(model.usageNomo) : "ДОСТУПЕН · \(model.liveNomoStatus)\(usageSuffix(model.usageNomo))")
                     : "ПАКЕТНЫЙ ВХОД · mic не подключён")
                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.48))
                Spacer(minLength: 4)
                if live, let probability = model.targetSpeakerProbability {
                    Text("\(Int((probability * 100).rounded()))%")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                } else if let latest {
                    Text(activitySummary(latest))
                        .font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text("нет данных").font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.32))
                }
            }
            if live {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(Array(history.enumerated()), id: \.offset) { _, value in
                        Capsule().fill(accent.opacity(0.3 + 0.7 * value))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(2, CGFloat(value) * 18))
                    }
                    if history.isEmpty {
                        RoundedRectangle(cornerRadius: 1).fill(accent.opacity(0.18)).frame(maxWidth: .infinity).frame(height: 2)
                    }
                }
                .frame(height: 20, alignment: .bottom)
                .accessibilityLabel("История вероятности Nomo-PVAD по окнам 160 миллисекунд")
            } else {
                HStack(spacing: 2) {
                    ForEach(Array(events.prefix(18).reversed().enumerated()), id: \.offset) { _, message in
                        Capsule().fill(activityColor(message))
                            .frame(maxWidth: .infinity)
                            .frame(height: message.type.contains("failed") ? 12 : message.type.contains("started") ? 5 : 9)
                    }
                    if events.isEmpty {
                        RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.12)).frame(maxWidth: .infinity).frame(height: 2)
                    }
                }
                .frame(height: 14, alignment: .bottom)
                .accessibilityLabel("Последние события пакетного анализатора \(name)")
            }
            HStack(alignment: .top, spacing: 5) {
                Text("ВХОД").foregroundStyle(.white.opacity(0.35)).frame(width: 33, alignment: .leading)
                Text(analyzerInputSummary(name, live: live))
                    .foregroundStyle(.white.opacity(0.52)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.system(size: 8, design: .monospaced))
            HStack(alignment: .top, spacing: 5) {
                Text("ВЫХОД").foregroundStyle(.white.opacity(0.35)).frame(width: 33, alignment: .leading)
                if live, let message = model.busMonitor.messages.first(where: { $0.source == "Sensors.NomoPVAD" && $0.type == "speaker.target.activity.scored" }) {
                    Text("\(activitySummary(message)) · \(message.timestamp.formatted(.dateTime.hour().minute().second()))")
                        .foregroundStyle(accent.opacity(0.9)).lineLimit(1).truncationMode(.middle)
                } else if let latest {
                    Text("\(activitySummary(latest)) · \(latest.timestamp.formatted(.dateTime.hour().minute().second()))")
                        .foregroundStyle(.white.opacity(0.66)).lineLimit(1).truncationMode(.middle)
                } else {
                    Text(live ? "Ожидание первой оценки" : "Пакетный вход · запуск вне интерфейса")
                        .foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 8, design: .monospaced))
        }
        .padding(.leading, 27)
        .padding(.trailing, 2)
        .padding(.vertical, 1)
    }

    private func analyzerInputSummary(_ name: String, live: Bool) -> String {
        if live {
            let enrollment = model.nomoEnrollmentURL == nil ? "эталон не настроен" : "эталон настроен"
            return "микрофон PCM 16 kHz / 160 ms · \(enrollment)"
        }
        let input = "WAV через внутренний вызов · не подключён к микрофону"
        if name == "CAM++" { return "\(input) · эталонов: \(model.references.count)" }
        return input
    }

    private func activitySummary(_ message: SignalMessage) -> String {
        if let probability = message.payload["probability"] { return "оценка \(probability)" }
        if let similarity = message.payload["cosine_similarity"] { return "cosine \(similarity)" }
        if message.type == "audio.speaker.isolated",
           let bytes = message.payload["output_bytes"],
           let latency = message.payload["inference_ms"] {
            return "дорожка \(bytes) байт · \(latency) мс"
        }
        if let text = message.payload["text"], !text.isEmpty {
            let transcript = String(text.prefix(28))
            let latency = message.payload["elapsed_ms"] ?? message.payload["recognition_ms"]
            return latency.map { "\(transcript) · \($0) ms" } ?? transcript
        }
        if let dimension = message.payload["dimension"] {
            return message.payload["elapsed_ms"].map { "embedding · \(dimension) dim · \($0) ms" } ?? "embedding · \(dimension) dim"
        }
        if let modelTime = message.payload["model_time_ms"] { return "аудио выделено · \(modelTime) ms" }
        if let elapsed = message.payload["elapsed_ms"] { return "готово · \(elapsed) ms" }
        if message.type.contains("failed") { return "ошибка" }
        if message.type.contains("completed") || message.type.contains("isolated") { return "готово" }
        if message.type.contains("started") { return "запуск" }
        return message.type
    }

    private func activityColor(_ message: SignalMessage) -> Color {
        if message.type.contains("failed") { return .red.opacity(0.82) }
        if message.type.contains("started") { return .orange.opacity(0.82) }
        if message.type.contains("completed") || message.type.contains("isolated") || message.type.contains("transcript") || message.type.contains("embedding") {
            return .cyan.opacity(0.85)
        }
        return .white.opacity(0.38)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(accent)
            Text(model.status).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.48)).lineLimit(1)
            Spacer()
            Text("Вход: микрофон · анализаторы запускаются автоматически на поддерживаемых входах")
                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(Color.black.opacity(0.12))
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
    }

    private var separator: some View { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
