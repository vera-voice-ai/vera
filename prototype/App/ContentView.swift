import SwiftUI
import Scene
import Sensors
import SignalBus

struct ContentView: View {
    @Bindable var model: PrototypeModel
    private let background = Color(red: 0.035, green: 0.025, blue: 0.047)
    private let panel = Color(red: 0.085, green: 0.068, blue: 0.102)
    private let accent = Color(red: 0.94, green: 0.13, blue: 0.61)

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        moduleContour(name: "vera-sensors", title: "Sensors", color: Color(hex: 0x38BDF8)) {
                            VStack(spacing: 10) {
                                sensorSnapshot
                                sensorsColumn
                            }
                        }
                        .frame(maxWidth: .infinity).frame(height: 420)

                        emptyModule(name: "vera-scene", title: "Scene", color: Color(hex: 0xA78BFA))
                            .frame(maxWidth: .infinity).frame(height: 420)
                    }

                    GeometryReader { geometry in
                        busContour
                            .frame(width: geometry.size.width * 0.7)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 165)

                    HStack(alignment: .top, spacing: 12) {
                        emptyModule(name: "vera-core", title: "Core", color: Color(hex: 0xFACC15))
                            .frame(maxWidth: .infinity).frame(height: 95)

                        emptyModule(name: "vera-response", title: "Response", color: Color(hex: 0x4ADE80))
                            .frame(maxWidth: .infinity).frame(height: 95)
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

    private var sensorsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                card("Поток с микрофона", symbol: "mic") {
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
                        Text(model.microphoneAECActive == true ? "AEC / Voice Processing активен" :
                             model.microphoneAECActive == false ? "AEC не активен" : "AEC выключен")
                        Spacer()
                        if model.isMicrophoneListening {
                            Text("RMS \(model.microphoneRMS, format: .number.precision(.fractionLength(3))) · пик \(model.microphonePeak, format: .number.precision(.fractionLength(2)))")
                        }
                    }
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.52))
                    Text(model.microphoneStatus).font(.system(size: 9)).foregroundStyle(.white.opacity(0.48)).lineLimit(2)
                    if let probability = model.targetSpeakerProbability {
                        HStack {
                            Text("Оценка целевого голоса · последнее окно 160 мс")
                            Spacer()
                            Text("\(Int((probability * 100).rounded()))%")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.cyan)
                        }
                        Text("20% — выходная оценка модели для окна, не доля голоса в аудио.")
                            .font(.system(size: 8)).foregroundStyle(.white.opacity(0.43))
                    }
                }

                card("Анализаторы", symbol: "waveform.path.ecg") {
                    analyzerRow("GigaAM v3", subtitle: "Локальное распознавание русской речи · потоковые гипотезы",
                                available: model.runtime.gigaAMAvailable)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.liveGigaAMText.isEmpty
                             ? "Слышит: \(model.liveGigaAMStatus)"
                             : "Слышит: \(model.liveGigaAMText)")
                            .font(.system(size: 11, weight: model.liveGigaAMText.isEmpty ? .regular : .medium))
                            .foregroundStyle(model.liveGigaAMText.isEmpty ? .white.opacity(0.52) : .white.opacity(0.92))
                            .lineLimit(3).truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.liveGigaAMLastLatencyMilliseconds != nil {
                            Text("Текущая гипотеза обновляется по перекрывающимся окнам; финальная реплика публикуется отдельно.")
                                .font(.system(size: 8)).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .padding(.leading, 27).padding(.vertical, 3)
                    analyzerRealtimeActivity("GigaAM", sources: ["Sensors.GigaAM.Live"],
                                             input: "Общий микрофон PCM 16 kHz · rolling WAV до 8 с",
                                             status: model.liveGigaAMStatus)
                    separator
                    analyzerRow("CAM++", subtitle: "Сравнение живого окна со всеми локальными профилями",
                                available: model.runtime.speakerModelAvailable)
                    VStack(alignment: .leading, spacing: 3) {
                        if let first = model.liveCAMMatches.first {
                            Text("Наиболее похожий профиль: \(first.label) · cosine \(String(format: "%.3f", first.similarity))")
                                .foregroundStyle(.white.opacity(0.86))
                            if model.liveCAMMatches.count > 1, let second = model.liveCAMMatches.dropFirst().first {
                                let margin = first.similarity - second.similarity
                                Text("Следующий: \(second.label) · cosine \(String(format: "%.3f", second.similarity)) · разница \(String(format: "%.3f", margin))")
                                    .foregroundStyle(.white.opacity(0.57))
                            }
                            Text("Сходство профиля с окном; это не подтверждение личности.")
                                .foregroundStyle(.white.opacity(0.42))
                        } else {
                            Text(model.liveCAMStatus).foregroundStyle(.white.opacity(0.48))
                        }
                    }
                    .font(.system(size: 9, design: .monospaced)).lineLimit(2)
                    .padding(.leading, 27)
                    analyzerRealtimeActivity("CAM++", sources: ["Sensors.CAM++"],
                                             input: "Общий микрофон · последние 1,6 с · все активные SQLite профили",
                                             status: model.liveCAMStatus)
                    separator
                    analyzerRow("VoxLock", subtitle: "Выделить целевой голос, сравнить ASR до и после",
                                available: model.runtime.voxLockAvailable)
                    analyzerRealtimeActivity("VoxLock", sources: ["Sensors.VoxLock", "Sensors.GigaAM.VoxLock"],
                                             input: "Общий сегмент после 2 с тишины · эталон Алексея",
                                             status: model.liveVoxLockStatus)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("После VoxLock")
                            .font(.system(size: 8, weight: .semibold)).foregroundStyle(.white.opacity(0.52))
                        Text(model.voxLockGigaAMText.isEmpty ? model.liveVoxLockStatus : model.voxLockGigaAMText)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(model.voxLockGigaAMText.isEmpty ? .white.opacity(0.45) : .cyan.opacity(0.9))
                            .lineLimit(2).truncationMode(.tail)
                        if let elapsed = model.voxLockGigaAMLastLatencyMilliseconds {
                            Text("\(elapsed) мс").font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.42))
                        }
                    }
                    .padding(.leading, 27)
                    separator
                    analyzerRow("Nomo-PVAD", subtitle: "Оценка целевого голоса · последнее окно 160 мс",
                                available: model.runtime.nomoPVADAvailable)
                    analyzerActivity("Nomo-PVAD", sources: ["Sensors.NomoPVAD"], live: true)
                    Text("Процент — выходная оценка модели, не доля целевого голоса в смеси; порог не применяется.")
                        .font(.system(size: 8)).foregroundStyle(.white.opacity(0.43)).padding(.leading, 27)
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").foregroundStyle(.cyan.opacity(0.85))
                        Text("Распознавание и голосовой анализ работают параллельно. Groq/облачная отправка не включены.")
                            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.top, 3)
                }

                card("Голосовые эталоны", symbol: "person.wave.2") {
                    if model.references.isEmpty {
                        Text("Сходство с голосами будет видно после создания эталонов из выбранных фрагментов.")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    } else {
                        ForEach(model.references) { reference in
                            HStack(spacing: 8) {
                                Text(reference.label).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.82))
                                Spacer()
                                Button { model.removeReference(reference) } label: {
                                    Image(systemName: "trash").font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    HStack(spacing: 7) {
                        TextField("Имя эталона", text: $model.speakerLabel)
                            .textFieldStyle(.roundedBorder).font(.system(size: 10))
                        Button("Сохранить текущий отпечаток", action: model.addSpeakerReference)
                            .buttonStyle(.bordered).tint(.cyan)
                            .disabled(model.scene.latestEmbedding == nil || model.speakerLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("В файл сохраняется только embedding после явного нажатия. Похожесть — численная метрика, не вероятность личности.")
                        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.42))
                }
            }
            .padding(.bottom, 4)
        }
        .scrollIndicators(.automatic)
    }

    private var sensorSnapshot: some View {
        HStack(spacing: 8) {
            snapshotValue("МИКРОФОН", model.isMicrophoneListening ? "Поток активен" : "Выключен", icon: "mic")
            snapshotValue("СЕНСОРЫ", model.isMicrophoneListening ? "LIVE" : "Ожидание", icon: "waveform")
        }
        .frame(height: 63)
    }

    private func snapshotValue(_ title: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.system(size: 8, weight: .semibold, design: .rounded)).tracking(0.5)
                .foregroundStyle(Color(hex: 0x38BDF8).opacity(0.82))
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82)).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(.black.opacity(0.17), in: RoundedRectangle(cornerRadius: 8))
    }

    private var busContour: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                Text("\(model.busMonitor.messages.count) сообщений")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.cyan.opacity(0.85))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if model.busMonitor.messages.isEmpty {
                        Text("Ожидание сообщений из сенсорного контура")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                    } else {
                        ForEach(model.busMonitor.messages) { message in busMessageRow(message) }
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
                storageItem("Люди и векторы", "~/Library/Application Support/VeraSensorPrototype/Users/people.sqlite")
                storageItem("Логи моделей", "~/Library/Application Support/VeraSensorPrototype/Logs/")
                storageItem("События и транскрипты", "Пока только в памяти процесса; постоянный журнал не подключён.")
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

    private func analyzerRow(_ title: String, subtitle: String, available: Bool) -> some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(available ? .white.opacity(0.86) : .white.opacity(0.36))
                Text(subtitle).font(.system(size: 9)).foregroundStyle(.white.opacity(available ? 0.46 : 0.3))
            }
            Spacer(minLength: 0)
            Text(available ? "ДОСТУПЕН" : "НЕДОСТУПЕН")
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundStyle(available ? .green.opacity(0.9) : .white.opacity(0.38))
            Circle().fill(available ? .green.opacity(0.8) : .white.opacity(0.2)).frame(width: 6, height: 6)
        }
        .padding(.vertical, 2)
    }

    private func analyzerRealtimeActivity(_ name: String, sources: [String], input: String, status: String) -> some View {
        let events = model.busMonitor.messages.filter { sources.contains($0.source) }
        let latest = events.first
        let analyzerReady: Bool
        switch name {
        case "GigaAM": analyzerReady = model.runtime.gigaAMAvailable
        case "CAM++": analyzerReady = model.runtime.speakerModelAvailable && model.references.contains(where: { $0.label.contains("Алексей") })
        case "VoxLock": analyzerReady = status.hasPrefix("Выделяю")
        default: analyzerReady = false
        }
        let isActive = model.isMicrophoneListening && analyzerReady
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(isActive ? accent : (latest == nil ? .white.opacity(0.18) : .cyan.opacity(0.75)))
                    .frame(width: 5, height: 5)
                Text(status)
                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.54))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if name == "CAM++", let similarity = model.liveCAMSimilarity {
                    Text(String(format: "cosine %.3f", similarity))
                        .font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(.cyan)
                } else if name == "GigaAM", let elapsed = model.liveGigaAMLastLatencyMilliseconds {
                    Text("\(elapsed) ms")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(accent)
                } else if name == "VoxLock", let elapsed = model.voxLockGigaAMLastLatencyMilliseconds {
                    Text("ASR \(elapsed) ms")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(.cyan)
                }
            }
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
            .accessibilityLabel("Реальные последние выходные события анализатора \(name)")
            HStack(alignment: .top, spacing: 5) {
                Text("ВХОД").foregroundStyle(.white.opacity(0.35)).frame(width: 33, alignment: .leading)
                Text(input).foregroundStyle(.white.opacity(0.52)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 5) {
                Text("ВЫХОД").foregroundStyle(.white.opacity(0.35)).frame(width: 33, alignment: .leading)
                if let latest {
                    Text("\(activitySummary(latest)) · \(latest.timestamp.formatted(.dateTime.hour().minute().second()))")
                        .foregroundStyle(.white.opacity(0.66)).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Ожидание результата").foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 8, design: .monospaced))
        }
        .font(.system(size: 8, design: .monospaced))
        .padding(.leading, 27).padding(.trailing, 2).padding(.vertical, 1)
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
                     ? (!isAvailable ? "НЕДОСТУПЕН" : isRunning ? model.liveNomoStatus : "ДОСТУПЕН · \(model.liveNomoStatus)")
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

    @ViewBuilder private func card<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.88))
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(12)
        .background(panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.16), lineWidth: 1))
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
