import SwiftUI
import Scene

/// Runtime process metrics supplied by the app for the concrete scene judge.
public struct SceneAnalyzerUsage: Sendable {
    public let cpuPercent: Double
    public let rssMB: Double

    public init(cpuPercent: Double, rssMB: Double) {
        self.cpuPercent = cpuPercent
        self.rssMB = rssMB
    }
}

/// Read-only diagnostics for the analyzers and rules used by Scene.
/// SceneModel remains the owner of evidence, verdicts, and decisions.
public struct SceneAnalyzersPanel: View {
    public let snapshot: SceneSnapshot?
    public let sceneModel: SceneModel
    public let judgeUsage: SceneAnalyzerUsage?
    public let judgeAvailable: Bool
    private let accent = Color(red: 0.655, green: 0.545, blue: 0.980)

    private var scene: SceneContent { snapshot?.content ?? SceneContent() }

    public init(snapshot: SceneSnapshot?, sceneModel: SceneModel,
                judgeUsage: SceneAnalyzerUsage?, judgeAvailable: Bool) {
        self.snapshot = snapshot
        self.sceneModel = sceneModel
        self.judgeUsage = judgeUsage
        self.judgeAvailable = judgeAvailable
    }

    public var body: some View {
        analyzersColumn
    }


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
    private func modelTrailing(_ usage: SceneAnalyzerUsage?, badge: (text: String, tint: Color)) -> some View {
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

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.5))
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

    private func usageText(_ usage: SceneAnalyzerUsage) -> String {
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
            Text("имя Веры в первых или последних трёх словах; в режимах «Готовность» и «В работе» любая реплика владельца")
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

}
