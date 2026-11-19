import SwiftUI
import Scene

/// Read-only view of the scene: what it thinks right now, readable at a glance.
/// Every label and state comes from `snapshot.content`; the panel decides nothing itself.
struct ScenePanel: View {
    let snapshot: SceneSnapshot?
    /// The scene model itself: the judge's verdicts and counters live there, outside the snapshot.
    let sceneModel: SceneModel
    private let accent = Color(red: 0.655, green: 0.545, blue: 0.980)

    private var scene: SceneContent { snapshot?.content ?? SceneContent() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topBar
            leftColumn
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            statusChip
            Text(statusSentence)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text("в Core: \(readyCount) · фон: \(heardCount)")
                Text(sensorLine)
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
            .fixedSize()
        }
    }

    private var statusChip: some View {
        let style = statusStyle
        return Text(style.title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(style.tint)
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(style.tint.opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(style.tint.opacity(0.35), lineWidth: 1))
            .fixedSize()
    }

    private var statusStyle: (title: String, tint: Color) {
        switch scene.status {
        case .idle: return ("Тишина", Color(white: 0.62))
        case .listening: return ("Слушаю", Color(red: 0.42, green: 0.68, blue: 1.0))
        case .forming: return ("Формирую реплику", Color(red: 1.0, green: 0.74, blue: 0.28))
        case .handedOver: return ("Передано в Core", Color(red: 0.42, green: 0.86, blue: 0.56))
        case .background: return ("Фон · не ко мне", Color(red: 0.62, green: 0.58, blue: 0.74))
        }
    }

    private var statusSentence: String {
        switch scene.status {
        case .idle:
            return "Сейчас никто не говорит"
        case .listening:
            return "\(name(of: scene.active?.speakerID) ?? "кто-то") говорит…"
        case .forming:
            guard let turn = scene.turns.first(where: { $0.isAwaiting }) else {
                return "реплика формируется"
            }
            guard turn.needsVerdict else { return "жду продолжения" }
            return "\(turn.speakerLabel ?? "кто-то") договорил(а) · жду, закончена ли мысль"
        case .handedOver:
            let turn = scene.turns.first(where: { $0.isReadyTurn })
            return "\(turn?.speakerLabel ?? "кто-то") · реплика передана в Core"
        case .background:
            let turn = scene.turns.first(where: { $0.isHeardTurn })
            return "\(turn?.speakerLabel ?? "кто-то") · речь не к Вере"
        }
    }

    private var readyCount: Int { scene.turns.filter { $0.isReadyTurn }.count }
    private var heardCount: Int { scene.turns.filter { $0.isHeardTurn }.count }

    private var sensorLine: String {
        let mic = scene.microphoneOn ? "" : "микрофон выключен · "
        return "\(mic)звук: \(soundText) · владелец: \(ownerText)"
    }

    private var soundText: String {
        switch snapshot?.content.sound {
        case .silence: return "тишина"
        case .sound: return "звук"
        case nil: return "нет сигнала"
        }
    }

    private var ownerText: String {
        guard snapshot != nil else { return "неизвестно" }
        let label: String
        switch scene.owner {
        case .unknown: label = "неизвестно"
        case .absent: label = "нет"
        case .possible: label = "возможно"
        case .likely: label = "вероятно"
        }
        guard let mean = scene.ownerMean else { return label }
        return "\(label) · \(String(format: "%.1f", mean))"
    }

    // MARK: - Left column: РАЗГОВОР and КТО РЯДОМ

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            conversation
            people
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private struct Item: Identifiable {
        enum Kind { case turn(SceneTurn), draft(SceneUtterance) }
        let id: String
        let kind: Kind
    }

    /// Last 8 turns, oldest first, then the utterance in progress.
    private var items: [Item] {
        var result: [Item] = Array(scene.turns.prefix(8).reversed()).map { Item(id: $0.id, kind: .turn($0)) }
        if let active = scene.active {
            result.append(Item(id: "draft", kind: .draft(active)))
        }
        return result
    }

    private var conversation: some View {
        section("РАЗГОВОР") {
            if items.isEmpty {
                emptyText("Разговора ещё не было")
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(items) { item in
                                switch item.kind {
                                case .turn(let turn): turnRow(turn)
                                case .draft(let utterance): draftRow(utterance)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 6)
                    }
                    .onAppear { scrollToEnd(proxy) }
                    .onChange(of: snapshot?.revision) { _, _ in scrollToEnd(proxy) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = items.last?.id else { return }
        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
    }

    private func turnRow(_ turn: SceneTurn) -> some View {
        let speaker = participant(for: turn.speakerID)
        return HStack(alignment: .top, spacing: 8) {
            avatar(role: speaker?.role)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(turn.speakerLabel ?? speaker?.label ?? "кто-то")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1).truncationMode(.tail)
                    if let text = addressedText(turn.addressed) {
                        chip(text, tint: accent)
                    }
                    statePill(turn)
                    if let verdict = turn.verdict {
                        Text(verdictText(verdict))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    if let probability = turn.turnEndProbability {
                        Text("звук \(String(format: "%.2f", probability))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1).fixedSize()
                    }
                }
                Text(turn.text.isEmpty ? "…" : turn.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2).truncationMode(.tail)
            }
        }
        .opacity(turn.isHeardTurn ? 0.45 : 1)
    }

    private func draftRow(_ utterance: SceneUtterance) -> some View {
        let speaker = participant(for: utterance.speakerID)
        return HStack(alignment: .top, spacing: 8) {
            avatar(role: speaker?.role)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(accent)
                        .symbolEffect(.pulse, options: .repeating)
                    Text(speaker?.label ?? "кто-то")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                    chip("идёт", tint: accent)
                }
                Text(utterance.text.isEmpty ? "…" : utterance.text)
                    .font(.system(size: 11)).italic()
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2).truncationMode(.tail)
            }
        }
    }

    @ViewBuilder
    private func statePill(_ turn: SceneTurn) -> some View {
        if let basis = turn.readyBasis {
            chip("в Core · \(readyBasisText(basis))", tint: Color(red: 0.42, green: 0.86, blue: 0.56))
        } else if let reason = turn.heardReason {
            chip(heardReasonText(reason), tint: Color(white: 0.62))
        } else {
            chip("ждём", tint: Color(red: 1.0, green: 0.74, blue: 0.28))
        }
    }

    private func addressedText(_ addressed: Addressed) -> String? {
        switch addressed {
        case .likely: return "к Вере"
        case .possible: return "возможно к Вере"
        case .unlikely: return nil
        }
    }

    private func verdictText(_ verdict: SceneTurn.Verdict) -> String {
        let label = verdict.choice == "complete" ? "закончено" : "продолжение"
        return "Jev: \(label) \(String(format: "%.2f", verdict.confidence))"
    }

    private func readyBasisText(_ basis: String) -> String {
        switch basis {
        case "jev": return "по Jev"
        case "no_verdict": return "без Jev"
        case "hold_expired": return "после ожидания"
        case "smart_turn": return "по звуку"
        default: return basis
        }
    }

    private func heardReasonText(_ reason: String) -> String {
        switch reason {
        case "not_addressed": return "фон"
        case "noise": return "шум"
        case "assistant_voice": return "голос Веры"
        case "no_text": return "нет текста"
        default: return reason
        }
    }

    private var people: some View {
        section("КТО РЯДОМ") {
            if scene.participants.isEmpty {
                emptyText("Пока никого не слышно")
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(scene.participants.prefix(5)) { participant in
                            participantRow(participant, now: context.date)
                        }
                    }
                }
            }
            Text("в сцене \(Int(SceneTTL().participantPresence / 60)) мин после последней реплики")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func participantRow(_ participant: SceneParticipant, now: Date) -> some View {
        HStack(spacing: 6) {
            avatar(role: participant.role)
            Text(participant.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1).truncationMode(.tail)
            chip(roleText(participant.role), tint: .white)
            Text("реплик \(participant.utteranceCount)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            Text(heardText(since: participant.lastHeard, now: now))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1).fixedSize()
        }
    }

    private func roleText(_ role: SceneParticipant.Role) -> String {
        switch role {
        case .owner: return "владелец"
        case .human: return "человек"
        case .assistant: return "Вера"
        case .unknown: return "неизвестный"
        }
    }

    private func heardText(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 10 { return "только что" }
        if seconds < 60 { return "\(seconds) с" }
        return "\(seconds / 60) мин"
    }

    // MARK: - Helpers

    private func participant(for id: String?) -> SceneParticipant? {
        guard let id else { return nil }
        return scene.participants.first { $0.id == id }
    }

    private func name(of speakerID: String?) -> String? {
        participant(for: speakerID)?.label
    }

    private func avatar(role: SceneParticipant.Role?) -> some View {
        Image(systemName: symbolName(role))
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.6))
            .frame(width: 16, height: 16)
    }

    private func symbolName(_ role: SceneParticipant.Role?) -> String {
        switch role {
        case .owner: return "person.fill"
        case .human: return "person"
        case .assistant: return "waveform"
        case .unknown, nil: return "questionmark.circle"
        }
    }

    private func section<Body: View>(_ title: String, @ViewBuilder _ builder: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(0.8)
                .foregroundStyle(accent.opacity(0.85))
            builder()
        }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1).truncationMode(.tail)
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint.opacity(0.9))
            .lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}
