import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SmartAnalyzerApp: App {
    var body: some Scene {
        WindowGroup("Умный анализатор") {
            AnalyzerView()
                .frame(minWidth: 660, minHeight: 580)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate()
                }
        }
        .defaultSize(width: 780, height: 720)
    }
}

@MainActor
final class AnalyzerModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var provider: Provider = .deepseek
    @Published var modelOverride = ""
    @Published var prompt = ""
    @Published var context = ""
    @Published var speak = true
    @Published private(set) var reply = ""
    @Published private(set) var status = "Готов"
    @Published private(set) var firstText: Int?
    @Published private(set) var firstVoice: Int?
    @Published private(set) var finished: Int?
    @Published private(set) var running = false
    private(set) var failed = false

    private let client = ProviderClient()
    private let voice = AVSpeechSynthesisVoice(language: "ru-RU")
    private let speaker = AVSpeechSynthesizer()
    var speaking: Bool { speaker.isSpeaking }
    private let clock = ContinuousClock()
    private var started: ContinuousClock.Instant?
    private var firstUtterance: ObjectIdentifier?
    private var speechBuffer = ""
    private var job: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var runID = UUID()

    override init() {
        super.init()
        speaker.delegate = self
    }

    func send(ping: Bool = false) {
        let input = ping ? "Ответь одним словом: понг." : prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        stop()
        let id = UUID()
        runID = id
        let selected = provider
        let model = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let suppliedContext = ping ? "" : context
        let shouldSpeak = speak
        reply = ""
        firstText = nil
        firstVoice = nil
        finished = nil
        running = true
        failed = false
        status = "Запрос к \(selected.rawValue)…"
        started = clock.now

        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, let self, self.runID == id, self.running else { return }
            self.stop()
            self.failed = true
            self.status = "Время запроса истекло."
        }
        job = Task {
            defer {
                if runID == id {
                    timeout?.cancel()
                    timeout = nil
                    running = false
                    job = nil
                }
            }
            do {
                try await client.request(selected, model: model, prompt: input, context: suppliedContext,
                                         maxTokens: ping && selected != .opencode ? 64 : 512) { [weak self] fragment in
                    guard let self, self.runID == id, !fragment.isEmpty else { return }
                    self.reply += fragment
                    if self.firstText == nil, !self.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.firstText = self.elapsed()
                        self.status = "Получаю ответ…"
                    }
                    if shouldSpeak {
                        self.speechBuffer += fragment
                        self.flushSpeech()
                    }
                }
                guard runID == id else { return }
                finished = elapsed()
                if shouldSpeak { flushSpeech(final: true) }
                status = firstText == nil ? "Пустой ответ." : "Ответ получен"
                failed = firstText == nil
            } catch {
                guard runID == id else { return }
                if shouldSpeak { flushSpeech(final: true) }
                status = error.localizedDescription
                failed = true
                finished = elapsed()
            }
        }
    }

    func stop() {
        let wasRunning = running || speaker.isSpeaking
        runID = UUID()
        job?.cancel()
        timeout?.cancel()
        job = nil
        timeout = nil
        running = false
        speechBuffer = ""
        firstUtterance = nil
        speaker.stopSpeaking(at: .immediate)
        if wasRunning { status = "Остановлено" }
    }

    func loadContext(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= 8_000_000 else {
                throw ProviderError("Выбери текстовый файл до 8 МБ.")
            }
            context = try String(contentsOf: url, encoding: .utf8)
            status = "Контекст загружен"
        } catch {
            status = error.localizedDescription
        }
    }

    private func elapsed() -> Int? {
        guard let started else { return nil }
        let duration = started.duration(to: clock.now).components
        return Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
    }

    private func flushSpeech(final: Bool = false) {
        while !speechBuffer.isEmpty {
            let boundary: String.Index
            if let end = speechBuffer.firstIndex(where: { ".!?…\n".contains($0) }),
               speechBuffer.distance(from: speechBuffer.startIndex, to: end) >= 6 {
                boundary = speechBuffer.index(after: end)
            } else if final {
                boundary = speechBuffer.endIndex
            } else if speechBuffer.count >= (firstUtterance == nil ? 55 : 120),
                      let space = speechBuffer.lastIndex(where: \.isWhitespace) {
                boundary = speechBuffer.index(after: space)
            } else {
                break
            }
            let phrase = speechBuffer[..<boundary].trimmingCharacters(in: .whitespacesAndNewlines)
            speechBuffer.removeSubrange(..<boundary)
            guard !phrase.isEmpty else { continue }
            let utterance = AVSpeechUtterance(string: phrase)
            utterance.voice = voice
            if firstUtterance == nil { firstUtterance = ObjectIdentifier(utterance) }
            speaker.speak(utterance)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            if firstUtterance == id, firstVoice == nil { firstVoice = elapsed() }
        }
    }
}

struct AnalyzerView: View {
    @StateObject private var state = AnalyzerModel()
    @State private var importing = false
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Умный анализатор", systemImage: "waveform")
                    .font(.title2.weight(.semibold))
                Spacer()
                Toggle("Озвучка", isOn: $state.speak)
            }

            Picker("Провайдер", selection: $state.provider) {
                ForEach(Provider.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(state.running)
            .onChange(of: state.provider) { _, _ in state.modelOverride = "" }

            HStack {
                Text(state.provider.caption).foregroundStyle(.secondary)
                if !state.provider.keyNames.isEmpty, state.provider.key == nil {
                    Text("Ключ вне окружения запуска").foregroundStyle(.orange)
                }
                Spacer()
                TextField(state.provider.model.isEmpty ? "Модель Codex по умолчанию" : state.provider.model,
                          text: $state.modelOverride)
                    .frame(width: 240)
                    .disabled(state.running)
                    .accessibilityLabel("Модель")
            }
            .font(.callout)

            HStack {
                TextField("Запрос", text: $state.prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($promptFocused)
                Button("Пинг") { state.send(ping: true) }.disabled(state.running)
                Button("Отправить") { state.send() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(state.running || state.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Стоп") { state.stop() }
            }

            HStack {
                Text("Контекст").font(.headline)
                Text("\(state.context.utf8.count.formatted()) байт").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Загрузить файл…") { importing = true }.disabled(state.running)
            }
            TextEditor(text: $state.context)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 72, maxHeight: 150)
                .padding(5)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Контекст запроса")

            HStack(spacing: 24) {
                metric("Первый текст", state.firstText)
                metric("Начало озвучки", state.firstVoice)
                metric("Весь ответ", state.finished)
                Spacer()
                if state.running { ProgressView().controlSize(.small) }
            }
            .padding(10)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

            ScrollView {
                Text(state.reply.isEmpty ? "Здесь появится ответ" : state.reply)
                    .foregroundStyle(state.reply.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 110)
            Text(state.status).font(.callout).foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear { promptFocused = true }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .json]) { result in
            if case let .success(url) = result { state.loadContext(url) }
        }
    }

    private func metric(_ label: String, _ milliseconds: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(milliseconds.map { "\($0) мс" } ?? "—")
                .font(.system(.headline, design: .monospaced))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
