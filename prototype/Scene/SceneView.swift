import SwiftUI
import SignalBus

public struct SceneView: View {
    @Bindable private var scene: SceneModel
    @State private var showPayload = false

    public init(scene: SceneModel) { self.scene = scene }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scene · входящий поток")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Сейчас показывает сообщения Sensors; Scene State и интерпретатор пока не подключены")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.47))
                }
                Spacer()
                Text("\(scene.messages.count) сигналов")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.48))
            }

            HStack(spacing: 10) {
                metric(title: "ПОСЛЕДНЯЯ РАСШИФРОВКА", value: scene.latestTranscript?.payload["text"] ?? "Пока нет результата",
                       detail: scene.latestTranscript?.payload["elapsed_ms"].map { "GigaAM · \($0) мс" } ?? "Здесь отображается только выход модели")
                metric(title: "ГОЛОСОВЫЕ ОТПЕЧАТКИ", value: scene.latestEmbedding.map { "\($0.count) измерений" } ?? "Пока нет результата",
                       detail: "Вектор приходит отдельным событием sensors")
            }
            .frame(height: 94)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("СООБЩЕНИЯ ШИНЫ").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(1.1)
                            .foregroundStyle(.white.opacity(0.48))
                        Spacer()
                        Text("LIVE / REPLAY").font(.system(size: 9, design: .monospaced)).foregroundStyle(Color.pink.opacity(0.8))
                    }
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            if scene.messages.isEmpty {
                                ContentUnavailableView("Нет событий Sensors", systemImage: "point.3.connected.trianglepath.dotted",
                                                       description: Text("Добавь WAV-фрагмент и запусти анализаторы в панели Sensors."))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .frame(maxWidth: .infinity, minHeight: 230)
                            }
                            ForEach(scene.messages) { message in
                                Button { scene.selectedMessageID = message.id } label: { messageRow(message) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(minWidth: 250, maxWidth: 360)

                Rectangle().fill(.white.opacity(0.08)).frame(width: 1)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("СООБЩЕНИЕ").font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(1.1)
                            .foregroundStyle(.white.opacity(0.48))
                        Spacer()
                        Button(showPayload ? "Скрыть JSON" : "Показать JSON") { showPayload.toggle() }
                            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.pink.opacity(0.85))
                    }
                    if let message = scene.selectedMessage {
                        messageDetail(message)
                    } else {
                        ContentUnavailableView("Выбери сигнал", systemImage: "text.alignleft")
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(16)
        .background(Color(red: 0.045, green: 0.032, blue: 0.068), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.pink.opacity(0.2), lineWidth: 1))
    }

    private func metric(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(0.9).foregroundStyle(.white.opacity(0.45))
            Text(value).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
            Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.46)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.055), lineWidth: 1))
    }

    private func messageRow(_ message: SignalMessage) -> some View {
        let color = domainColor(message.domain)
        return HStack(alignment: .top, spacing: 9) {
            Circle().fill(color).frame(width: 7, height: 7).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(message.type).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Text(message.timestamp.formatted(.dateTime.hour().minute().second()))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                }
                Text("\(message.kind.rawValue) · \(message.domain.rawValue) · \(message.source)")
                    .font(.system(size: 9)).foregroundStyle(color.opacity(0.85)).lineLimit(1)
                if let text = message.payload["text"], !text.isEmpty {
                    Text(text).font(.system(size: 10)).foregroundStyle(.white.opacity(0.72)).lineLimit(2)
                } else if let error = message.payload["error"] {
                    Text(error).font(.system(size: 10)).foregroundStyle(.orange.opacity(0.9)).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(scene.selectedMessageID == message.id ? color.opacity(0.12) : .white.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(scene.selectedMessageID == message.id ? color.opacity(0.35) : .white.opacity(0.04), lineWidth: 1))
    }

    @ViewBuilder private func messageDetail(_ message: SignalMessage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(message.type).font(.system(size: 16, weight: .semibold, design: .monospaced)).foregroundStyle(domainColor(message.domain))
                detailLine("Kind", message.kind.rawValue)
                detailLine("Domain", message.domain.rawValue)
                detailLine("Source", message.source)
                if let target = message.target { detailLine("Target", target) }
                detailLine("Time", message.timestamp.formatted(.dateTime.year().month().day().hour().minute().second().secondFraction(.fractional(3))))
                detailLine("ID", message.id.uuidString.lowercased())

                if message.type == "speaker.reference.similarity.computed" {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.badge.mic").foregroundStyle(.cyan)
                        Text("Similarity: \(message.payload["cosine_similarity"] ?? "—")")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        Text("не вероятность").font(.system(size: 10)).foregroundStyle(.white.opacity(0.46))
                    }
                    .padding(10).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                }

                Text(showPayload ? "PAYLOAD JSON" : "ПОЛЯ PAYLOAD")
                    .font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(1).foregroundStyle(.white.opacity(0.46))
                if showPayload {
                    Text(payloadJSON(message.payload))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.78))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(.black.opacity(0.23), in: RoundedRectangle(cornerRadius: 7))
                } else {
                    ForEach(displayPayloadKeys(message.payload), id: \.self) { key in
                        detailLine(key, message.payload[key] ?? "")
                    }
                    if !showPayload, message.payload["embedding_json"] != nil {
                        Text("Embedding скрыт в таблице. Открой JSON, чтобы увидеть полный вектор.")
                            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.42))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func detailLine(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key).frame(width: 105, alignment: .trailing).foregroundStyle(.white.opacity(0.43))
            Text(value).foregroundStyle(.white.opacity(0.83)).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, design: .monospaced))
    }

    private func payloadJSON(_ payload: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func displayPayloadKeys(_ payload: [String: String]) -> [String] {
        let keys = payload.keys.sorted()
        return showPayload ? keys : keys.filter { $0 != "embedding_json" }
    }

    private func domainColor(_ domain: SignalDomain) -> Color {
        switch domain {
        case .sensors: Color(red: 0.22, green: 0.74, blue: 0.97)
        case .scene: Color(red: 0.65, green: 0.54, blue: 0.98)
        case .core: Color(red: 0.98, green: 0.79, blue: 0.13)
        case .response: Color(red: 0.29, green: 0.87, blue: 0.51)
        }
    }
}
