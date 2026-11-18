import SwiftUI
import Scene

/// Read-only view of the scene: what it thinks right now, readable at a glance.
/// Every label and state comes from `snapshot.content`; the panel decides nothing itself.
struct ScenePanel: View {
    let snapshot: SceneSnapshot?
    /// The scene model itself: the judge's verdicts and counters live there, outside the snapshot.
    let sceneModel: SceneModel
    /// Resource use of the judge worker; nil while the worker is not running.
    let judgeUsage: AnalyzerUsage?
    /// Whether the judge model is available in this build.
    let judgeAvailable: Bool
    private let accent = Color(red: 0.655, green: 0.545, blue: 0.980)

    private var scene: SceneContent { snapshot?.content ?? SceneContent() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topBar
            GeometryReader { geo in
                // Two 14 pt gutters around a 1 pt divider.
                let usable = max(0, geo.size.width - 29)
                HStack(alignment: .top, spacing: 14) {
                    leftColumn
                        .frame(width: usable * 0.56, alignment: .topLeading)
                    Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
                    analyzersColumn
                        .frame(width: usable * 0.44, alignment: .topLeading)
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
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

    // MARK: - Right column: АНАЛИЗАТОРЫ СЦЕНЫ

    private var okTint: Color { Color(red: 0.42, green: 0.86, blue: 0.56) }
    private var waitTint: Color { Color(red: 1.0, green: 0.74, blue: 0.28) }
    private var noTint: Color { Color(red: 0.98, green: 0.44, blue: 0.44) }
    private var idleTint: Color { Color(white: 0.62) }

    /// Same header and row rhythm as the Sensors tile's "Анализаторы" list, in the Scene accent.
    private var analyzersColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                Text("Анализаторы сцены")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
            }
            .padding(.bottom, 4)
            judgeRow
            rowDivider
            rowDivider
            ownerRow
            rowDivider
            addresseeRow
            rowDivider
            filterRow
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var rowDivider: some View {
        Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
    }

    /// One analyzer per row: name and trailing badge on top, its detail below.
    private func analyzerRow<Trailing: View, Content: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 9) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                trailing()
            }
            content()
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// CPU and memory of a model worker, followed by its status badge.
    private func modelTrailing(_ usage: AnalyzerUsage?, badge: (text: String, tint: Color)) -> some View {
        HStack(spacing: 9) {
            if let usage {
                Text(usageText(usage))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).fixedSize()
            }
            statusBadge(badge.text, tint: badge.tint)
        }
    }

    /// Grey badge for analyzers that are plain rules, not models.
    private var ruleTrailing: some View {
        Text("ПРАВИЛА")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.white.opacity(0.08), in: Capsule())
    }

    private func statusBadge(_ text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint.opacity(0.9))
                .lineLimit(1).fixedSize()
            Circle().fill(tint.opacity(0.8)).frame(width: 6, height: 6)
        }
    }

    private func smallCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.white.opacity(0.46))
            .lineLimit(1).truncationMode(.tail)
    }

    // Row 1: the judge.

    private var judgeRow: some View {
        analyzerRow("Jev-Style-2B · судья", trailing: {
            modelTrailing(judgeUsage, badge: judgeBadge)
        }) {
            judgeDetail
        }
    }

    private var judgeBadge: (text: String, tint: Color) {
        guard judgeAvailable else { return ("НЕТ", noTint) }
        return judgeUsage == nil ? ("ЖДЁТ", idleTint) : ("ДОСТУПЕН", okTint)
    }

    @ViewBuilder private var judgeDetail: some View {
        let verdicts = sceneModel.verdicts
        if sceneModel.judgeName.isEmpty {
            emptyText("судья не подключён")
        } else if let last = verdicts.first {
            HStack(spacing: 8) {
                Text(verdictWord(last.choice))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(verdictTint(last.choice))
                    .lineLimit(1).fixedSize()
                Text(String(format: "%.2f", last.confidence))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                Text("\(last.modelMilliseconds) мс")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).fixedSize()
            }
            Text(last.text.isEmpty ? "…" : last.text)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1).truncationMode(.tail)
            thinBar(last.confidence, tint: verdictTint(last.choice))
        } else {
            emptyText("Судью ещё не спрашивали")
        }
        VStack(alignment: .leading, spacing: 2) {
            verdictStrip
            judgeCounters
        }
    }

    /// Verdicts as capsules, oldest on the left; the newest is at the right edge.
    @ViewBuilder private var verdictStrip: some View {
        if !sceneModel.verdicts.isEmpty {
            HStack(spacing: 3) {
                ForEach(Array(sceneModel.verdicts.prefix(8).reversed())) { verdict in
                    Capsule().fill(verdictTint(verdict.choice))
                        .frame(width: 8, height: 12)
                }
            }
        }
    }

    private var judgeCounters: some View {
        let verdicts = sceneModel.verdicts
        let complete = verdicts.filter { $0.choice == "complete" }.count
        return smallCaption("вызовов \(sceneModel.judgeCalls) · ошибок \(sceneModel.judgeFailures) · закончена \(complete) из \(verdicts.count)")
    }

    private func verdictWord(_ choice: String) -> String {
        choice == "complete" ? "Закончена" : "Продолжение"
    }

    private func verdictTint(_ choice: String) -> Color {
        choice == "complete" ? okTint : waitTint
    }

    private func thinBar(_ value: Double, tint: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(tint.opacity(0.85))
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, value))))
            }
        }
        .frame(height: 4)
    }

    private func usageText(_ usage: AnalyzerUsage) -> String {
        String(format: "CPU %.0f%% · %.1f ГБ", usage.cpuPercent, usage.rssMB / 1024)
    }

    // Row 3: how sure the scene is that the active speaker is the owner.

    private var ownerRow: some View {
        let utterance = scene.active ?? scene.recent.first
        return analyzerRow("Владелец · накопление", trailing: { ruleTrailing }) {
            if let utterance, let odds = utterance.ownerLogOdds {
                HStack(spacing: 8) {
                    Text(String(format: "%+.2f", odds))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ownerTint(odds))
                        .lineLimit(1).fixedSize()
                    Text(ownerCaption(odds))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    smallCaption(speakerBasisText(utterance.speakerBasis))
                }
                ownerBar(odds)
                smallCaption("порог +2.94 · шкала −3…+4 · логарифм шансов")
            } else {
                emptyText("нет данных")
            }
        }
    }

    private func ownerFraction(_ value: Double) -> CGFloat {
        CGFloat((min(4, max(-3, value)) + 3) / 7)
    }

    private func ownerBar(_ value: Double) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let zero = width * ownerFraction(0)
            let point = width * ownerFraction(value)
            let mark = width * ownerFraction(2.94)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(ownerTint(value).opacity(0.85))
                    .frame(width: abs(point - zero))
                    .offset(x: min(zero, point))
                Rectangle().fill(.white.opacity(0.8))
                    .frame(width: 1.5, height: 12)
                    .offset(x: mark - 0.75)
            }
        }
        .frame(height: 12)
    }

    private func ownerTint(_ value: Double) -> Color {
        if value >= 2.94 { return okTint }
        if value <= -2.2 { return noTint }
        return waitTint
    }

    private func ownerCaption(_ value: Double) -> String {
        if value >= 2.94 { return "подтверждён" }
        if value <= -2.2 { return "не он" }
        return "не уверен"
    }

    private func speakerBasisText(_ basis: String?) -> String {
        guard let basis else { return "основа неизвестна" }
        switch basis {
        case "campp": return "по голосу"
        case "nomo": return "по Nomo"
        case "owner_evidence": return "по сумме свидетельств"
        case "no_match": return "не узнан"
        default: return basis
        }
    }

    // Row 4: who the turns are addressed to.

    private var addresseeRow: some View {
        let likely = scene.turns.filter { $0.addressed == .likely }.count
        let possible = scene.turns.filter { $0.addressed == .possible }.count
        let unlikely = scene.turns.filter { $0.addressed == .unlikely }.count
        return analyzerRow("Адресат · правила", trailing: { ruleTrailing }) {
            HStack(spacing: 12) {
                countPair("к Вере", likely, tint: accent)
                countPair("возможно", possible, tint: waitTint)
                countPair("не ко мне", unlikely, tint: idleTint)
            }
            Text("имя Веры в тексте, либо разговор в последние \(Int(SceneTTL().engagedWindow)) с")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.46))
                .lineLimit(2).truncationMode(.tail)
        }
    }

    private func countPair(_ label: String, _ count: Int, tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(tint.opacity(0.85)).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1).fixedSize()
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1).fixedSize()
        }
    }

    // Row 5: what the scene has thrown away.

    private var filterRow: some View {
        let reasons: [(key: String, label: String)] = [
            ("noise", "шум"),
            ("assistant_voice", "голос Веры"),
            ("no_text", "нет текста"),
            ("not_addressed", "не ко мне"),
            ("owner_unconfirmed", "владелец не подтверждён"),
            ("owner_absent", "владелец отсутствует"),
        ]
        let parts: [String] = reasons.compactMap { reason in
            let count = scene.turns.filter { $0.heardReason == reason.key }.count
            return count > 0 ? "\(reason.label) \(count)" : nil
        }
        return analyzerRow("Фильтры", trailing: { ruleTrailing }) {
            Text(parts.isEmpty ? "ничего не отброшено" : parts.joined(separator: " · "))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1).truncationMode(.tail)
        }
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

private extension SceneTurn {
    var readyBasis: String? {
        if case .ready(let basis) = state { return basis }
        return nil
    }

    var heardReason: String? {
        if case .heard(let reason) = state { return reason }
        return nil
    }

    var isReadyTurn: Bool { readyBasis != nil }
    var isHeardTurn: Bool { heardReason != nil }
}
