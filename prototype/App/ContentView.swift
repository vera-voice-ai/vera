import SwiftUI
import Scene
import Sensors
import SignalBus
import SceneAnalyzers
import Core

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
                    GeometryReader { geometry in
                        let unit = (geometry.size.width - 24) / 5
                        HStack(alignment: .top, spacing: 12) {
                            moduleContour(name: "vera-sensors", title: "Sensors", color: Color(hex: 0x38BDF8)) {
                                sensorsBody
                            }
                            .frame(width: unit * 1.5, height: 440)

                            moduleContour(name: "sensors/analyzers", title: "Анализаторы", color: Color(hex: 0x38BDF8)) {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 10) {
                                        analyzersContent
                                        separator
                                        SceneAnalyzersPanel(
                                            snapshot: model.scene.snapshot,
                                            sceneModel: model.scene,
                                            judgeUsage: model.usageJev.map {
                                                SceneAnalyzerUsage(cpuPercent: $0.cpuPercent, rssMB: $0.rssMB)
                                            },
                                            judgeAvailable: model.runtime.jevAvailable
                                        )
                                    }
                                }
                                    .scrollIndicators(.automatic)
                            }
                            .frame(width: unit * 2, height: 440)

                            moduleContour(name: "vera-response", title: "Response", color: Color(hex: 0x4ADE80)) {
                                ResponsePanel(speaker: model.speaker, available: model.speechAvailable)
                            }
                            .frame(width: unit * 1.5, height: 440)
                        }
                    }
                    .frame(height: 440)

                    HStack(alignment: .top, spacing: 12) {
                        moduleContour(name: "vera-scene", title: "Scene", color: Color(hex: 0xA78BFA)) {
                            ScenePanel(snapshot: model.scene.snapshot, sceneModel: model.scene)
                        }
                        .frame(maxWidth: .infinity).frame(height: 500)

                        moduleContour(name: "vera-core", title: "Core", color: Color(hex: 0xFACC15)) {
                            CorePanel(inbox: model.core, agent: model.agent)
                        }
                        .frame(maxWidth: .infinity).frame(height: 500)
                    }

                    GeometryReader { geometry in
                        let unit = (geometry.size.width - 12) / 3
                        HStack(alignment: .top, spacing: 12) {
                            BusActivityPanel(monitor: model.busMonitor)
                                .frame(width: unit * 2, height: 370)

                            storageContour
                                .frame(width: unit, height: 370)
                        }
                    }
                    .frame(height: 370)
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

    private var deepSeekText: (text: String, help: String) {
        switch model.deepSeekState {
        case .unknown: return ("DeepSeek —", "баланс ещё не запрошен")
        case .balance(let balance): return ("DeepSeek \(balance.display)", "баланс по данным DeepSeek API")
        case .failed(let reason): return ("DeepSeek —", reason)
        }
    }

    private var openCodeText: (text: String, help: String) {
        switch model.openCodeState {
        case .unknown: return ("OpenCode —", "расход ещё не запрошен")
        case .usage(let usage):
            return ("OpenCode \(usage.display)", "расход подписки OpenCode Go: 5 часов / неделя / месяц. Сброс окон: \(usage.rolling.resetsAt) · \(usage.weekly.resetsAt) · \(usage.monthly.resetsAt)")
        case .failed(let reason): return ("OpenCode —", reason)
        }
    }

    private var codexText: (text: String, help: String) {
        switch model.codexState {
        case .unknown: return ("Codex —", "лимиты ещё не запрошены")
        case .limits(let limits):
            func reset(_ window: CodexUsage.Window) -> String {
                window.resetsAt.map { $0.formatted(.dateTime.day().month().hour().minute()) } ?? "неизвестно"
            }
            let plan = limits.planType.map { ", план \($0)" } ?? ""
            return ("Codex \(limits.display)", "лимиты подписки Codex: 5 часов / неделя. Сброс: \(reset(limits.primary)) · \(reset(limits.secondary))\(plan)")
        case .failed(let reason): return ("Codex —", reason)
        }
    }

    private func usageLabel(_ text: String, help: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(0.8)
            .foregroundStyle(.white.opacity(0.6))
            .help(help)
    }

    /// The thin divider between header items, in the same muted tone as the labels.
    private var usageDivider: some View {
        Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 12)
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
            }
            Spacer()
            HStack(spacing: 10) {
                usageLabel(openCodeText.text, help: openCodeText.help)
                usageDivider
                usageLabel(deepSeekText.text, help: deepSeekText.help)
                usageDivider
                usageLabel(codexText.text, help: codexText.help)
                usageDivider
                usageLabel(model.resources.headerText, help: model.resources.helpText)
            }
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
                            Text("\(model.microphoneDBFS, format: .number.precision(.fractionLength(1))) dBFS · RMS \(model.microphoneRMS, format: .number.precision(.fractionLength(3))) · пик \(model.microphonePeak, format: .number.precision(.fractionLength(2)))")
                        }
                    }
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.52))
                    if !model.telegramStatus.isEmpty {
                        Text(model.telegramStatus).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.52)).textSelection(.enabled)
                    }
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
                }
                Spacer(minLength: 0)
            }
            micContent
            spectrumView
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0x38BDF8).opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }

    private var spectrumView: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("СПЕКТРОГРАММА")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.58))
            }
            HStack(spacing: 5) {
                VStack(alignment: .trailing) {
                    Text("8к")
                    Spacer()
                    Text("4к")
                    Spacer()
                    Text("0")
                }
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
                .frame(width: 20, height: 112)

                spectrumCanvas(model.microphoneSpectrum)
                    .frame(height: 112)
                    .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.06), lineWidth: 1))
                    .accessibilityLabel("Спектрограмма микрофона: частоты от 0 до 8 килогерц за последние пять секунд")
            }
        }
    }

    private func spectrumCanvas(_ frames: [LiveSpectrumFrame]) -> some View {
        Canvas { context, size in
            let grid = Color.white.opacity(0.08)
            for fraction in [CGFloat(0.25), 0.5, 0.75] {
                var vertical = Path()
                let x = size.width * fraction
                vertical.move(to: CGPoint(x: x, y: 0))
                vertical.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(vertical, with: .color(grid), lineWidth: 1)
            }
            for fraction in [CGFloat(0.5)] {
                var horizontal = Path()
                let y = size.height * fraction
                horizontal.move(to: CGPoint(x: 0, y: y))
                horizontal.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(horizontal, with: .color(grid), lineWidth: 1)
            }

            let now = Date()
            let columnWidth = max(1, size.width * 0.16 / 5)
            let bandHeight = size.height / CGFloat(LiveSpectrumAnalyzer.bandCount)
            for frame in frames {
                let age = now.timeIntervalSince(frame.timestamp)
                guard (0...5).contains(age), frame.bandsDBFS.count == LiveSpectrumAnalyzer.bandCount else { continue }
                let x = size.width * CGFloat(1 - age / 5)
                for (band, dbfs) in frame.bandsDBFS.enumerated() {
                    // Brighter than before: a narrower dB window and a gamma below one lift quiet speech out of the dark.
                    let linear = CGFloat(max(0, min(1, (dbfs + 80) / 62)))
                    let strength = pow(linear, 0.7)
                    guard strength > 0 else { continue }
                    let color = Color(red: 0.42 + 0.58 * strength,
                                      green: 0.06 + 0.30 * strength,
                                      blue: 0.40 + 0.60 * strength,
                                      opacity: 0.22 + 0.78 * strength)
                    let rect = CGRect(x: x - columnWidth, y: size.height - CGFloat(band + 1) * bandHeight,
                                      width: columnWidth + 1, height: bandHeight + 0.4)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
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
                        Circle().fill(nomoAvailable ? .green.opacity(0.8) : .white.opacity(0.2)).frame(width: 6, height: 6)
                    }
                    .padding(.vertical, 2)
                    analyzerActivity("Nomo-PVAD", sources: ["Sensors.NomoPVAD"], live: true)
                    separator
                    smartTurnRow
                    separator
                    vadRow
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
                // Eight fixed slots, the newest on the right: a short history leaves faint empty slots instead of a few stray pills.
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<8, id: \.self) { slot in
                        let offset = slot - (8 - model.smartTurnHistory.count)
                        if offset >= 0 {
                            let value = model.smartTurnHistory[offset]
                            Capsule().fill((value >= 0.9 ? Color.green : (value >= 0.5 ? Color.orange : Color.red)).opacity(0.8))
                                .frame(maxWidth: .infinity)
                                .frame(height: 2 + 12 * CGFloat(min(1, max(0, value))))
                        } else {
                            Capsule().fill(.white.opacity(0.08)).frame(maxWidth: .infinity).frame(height: 2)
                        }
                    }
                }
                .frame(height: 16, alignment: .bottom)
            } else {
                Text("оценок ещё нет").font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
            }
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
        }
        .padding(.leading, 27)
    }

    private func usageSuffix(_ usage: AnalyzerUsage?) -> String {
        guard let usage else { return "" }
        return String(format: " · CPU %.0f%% · %.1f ГБ", usage.cpuPercent, usage.rssMB / 1024)
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
            freeSpaceLine
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    storageItem("Образцы голосов", "Копируются в ~/Library/Application Support/VeraSensorPrototype/Users/voice-samples/", area: .users)
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
                    storageItem("Логи моделей", "~/Library/Application Support/VeraSensorPrototype/Logs/", area: .logs)
                    storageItem("Лента звука", "Всё, что слышит микрофон: WAV 16 кГц mono, по файлу на час, бессрочно (~115 МБ/ч) · ~/Library/Application Support/VeraSensorPrototype/Tape/<день>/<час>.wav", area: .tape)
                    storageItem("Память Core", "Факты и история задач, JSONL (бессрочно, до 20 МБ на файл) · ~/Library/Application Support/VeraSensorPrototype/Memory/", area: .memory)
                    storageItem("Навыки", "Markdown-файлы с описанием в шапке; Core видит список и подгружает текст по read_skill · ~/Library/Application Support/VeraSensorPrototype/Skills/", area: .skills)
                    storageItem("Журнал модели", "Каждый запрос и ответ модели, без заголовков авторизации · ~/Library/Application Support/VeraSensorPrototype/Journal/", area: .journal)
                    storageItem("Рабочая папка агента", "Единственное место, где Core читает и пишет файлы · ~/Library/Application Support/VeraSensorPrototype/Workspace/", area: .workspace)
                    storageItem("Запись шины", "Сообщения Sensors, один JSONL на сессию микрофона · ~/Library/Application Support/VeraSensorPrototype/Recordings/", area: .recordings)
                    storageItem("Ревизии сцены", "Только в памяти процесса; сохраняются лишь как сообщения scene в шине, которые не пишутся.", color: .orange)
                }
                .padding(.trailing, 4)
            }
            .scrollIndicators(.automatic)
        }
        .padding(12)
        .background(Color(red: 0.055, green: 0.075, blue: 0.065), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.green.opacity(0.45), style: StrokeStyle(lineWidth: 1.1, dash: [6, 4])))
    }

    /// Free and total space of the volume, amber under 20 GB free and red under 5 GB.
    private var freeSpaceLine: some View {
        let snapshot = model.storageUsage.snapshot
        let text: String
        let color: Color
        if let free = snapshot?.freeBytes {
            let total = snapshot?.totalBytes.map(StorageUsageModel.bytesText) ?? "—"
            text = "Свободно на диске: \(StorageUsageModel.bytesText(free)) из \(total)"
            color = free < 5_000_000_000 ? .red : free < 20_000_000_000 ? .orange : .green.opacity(0.85)
        } else {
            text = "Свободно на диске: —"
            color = .white.opacity(0.5)
        }
        return Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(color)
            .padding(.bottom, 2)
    }

    private func storageItem(_ title: String, _ location: String, color: Color = .green, area: StorageUsage.Area? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.82))
                if let area, let size = model.storageUsage.sizeText(area) {
                    Text(size).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
                }
            }
            Text(location).font(.system(size: 9, design: .monospaced)).foregroundStyle(color.opacity(0.75))
                .lineLimit(2).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            if !live {
                HStack(alignment: .top, spacing: 5) {
                    Text("ВХОД").foregroundStyle(.white.opacity(0.35)).frame(width: 33, alignment: .leading)
                    Text(analyzerInputSummary(name, live: live))
                        .foregroundStyle(.white.opacity(0.52)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 8, design: .monospaced))
            }
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
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(Color.black.opacity(0.12))
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
    }

    private var separator: some View { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
