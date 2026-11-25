import AppKit
import SwiftUI
import HermesBridge
import VeraEars

/// The right-hand panel: what the clicked part of the board is doing, in detail.
struct PartDetail: View {
    let part: BoardPart
    let model: BoardModel
    var voice: VoiceModel?
    var close: () -> Void = {}
    var scrollable = true

    /// A card of the «Состав» face: the part's title and everything about it, no panel around.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(part.title).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 14) { content }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.contourFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    @ViewBuilder private var content: some View {
        switch part {
        case .windows:
            SessionsPanel(model: model).frame(height: 340)
        case .voice:
            if let v = voice {
                InnerCard(tint: Theme.ok) {
                    KeyValue(key: "сейчас", value: v.phase == .listening ? "слушает" : v.phase == .speaking ? "говорит" : "тихо")
                    KeyValue(key: "уши", value: v.earsRuntime == nil ? "нет в сборке" : "\(v.engine.title) · Silero VAD · sherpa-onnx \(v.earsRuntime?.version ?? "?") · внутри Веры")
                    KeyValue(key: "подавление эха", value: v.echoCancelling.map { $0 ? "включено" : "не удалось включить" } ?? "ещё не включали")
                    if let t = v.lastTiming {
                        KeyValue(key: "последняя фраза", value: "\(String(format: "%.1f", t.seconds)) с · дочитала за \(t.decodeMs) мс")
                    }
                    KeyValue(key: "голос", value: v.voiceName + (v.mouthRuntime.map { " · \($0.modelName) · внутри Веры" } ?? " · системный"))
                    HStack {
                        Text("скорость \(String(format: "%.2f", v.speed))").font(.mono(10)).foregroundStyle(.white.opacity(0.8)).frame(width: 90, alignment: .leading)
                        Slider(value: Binding(get: { v.speed }, set: { v.speed = ($0 * 20).rounded() / 20 }), in: 0.8 ... 1.5)
                    }
                    KeyValue(key: "озвучка ответов", value: v.speakReplies ? "включена" : "выключена")
                }
            }
            if let v = voice {
                InnerCard(tint: Theme.human) {
                    SectionLabel(text: "запись и Вера", color: Theme.human)
                    Toggle("Запись (микрофон открыт, пишет всё)", isOn: Binding(get: { v.background }, set: { _ in Task { await v.toggleBackground() } }))
                        .toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
                    HStack {
                        Text("порог \(OrganismBoard.db(v.thresholdDB)) дБ").font(.mono(10)).foregroundStyle(.white.opacity(0.8)).frame(width: 90, alignment: .leading)
                        Slider(value: Binding(get: { v.thresholdDB }, set: { v.thresholdDB = $0.rounded() }), in: -70 ... -15)
                    }
                    KeyValue(key: "сейчас", value: v.listening ? "\(OrganismBoard.db(Loudness.decibels(v.level))) дБ" : "микрофон закрыт")
                    KeyValue(key: "последняя фраза", value: v.lastLoudness.map { l in
                        "\(OrganismBoard.db(l.db)) дБ" + (l.aboveFloor.map { " · на \(Int($0.rounded())) дБ выше фона" } ?? "")
                    } ?? "—")
                    if let bg = v.lastBackground {
                        KeyValue(key: "в фоне записано (\(v.backgroundCount))", value: "«\(bg.text)» · \(OrganismBoard.db(bg.db)) дБ")
                    }
                    Text("Запись: всё распознанное — в журнал ears/background-*.jsonl, агенту не уходит, музыку не глушит. Вера неактивна — ждёт «Привет, Вера, …» (любой громкости); активна — уходит всё; через 30 с тишины снова ждёт. ⌘L — Вера вкл / выкл.")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                }
                InnerCard(tint: Theme.session) {
                    SectionLabel(text: "движки · фразы за неделю (журнал ушей)", color: Theme.session)
                    ForEach(EarsEngine.allCases, id: \.self) { e in
                        let s = v.comparison[e.rawValue]
                        KeyValue(key: e.title + (v.engine == e ? " · live" : " · тень"), value: s.map {
                            "фраз \($0.phrases) · \(String(format: "%.0f", $0.seconds)) с · первые слова \($0.avgFirstPartialMs.map { "\($0) мс" } ?? "—") · дочитывает \($0.avgDecodeMs) мс"
                        } ?? "ещё не слушала")
                    }
                }
            }
            flowsCard([.micToGate, .micToEars, .gateToEars, .turnJudge, .judgeToEars, .voiceToAdapter, .adapterToVoice])
        case .adapter:
            flowsCard(FlowChannel.allCases)
        case .pulse:
            PulseTimelinePanel(model: model).frame(height: 300)
            FeedPanel(model: model).frame(height: 420)
        case .hermes:
            RuntimePanel(model: model).frame(height: 320)
        case .gateway:
            GatewayPanel(model: model).frame(height: 320)
        case .brain:
            ModelPanel(model: model).frame(height: 300)
            WaitsPanel(model: model).frame(height: 300)
        case .hands:
            ToolsPanel(model: model).frame(height: 320)
            list("Включённые наборы инструментов", model.inventory.enabledToolsets.map { ("\($0.name) · \($0.tools)", $0.description) })
            list("Выключенные", model.inventory.toolsets.filter { !$0.enabled }.map { ("\($0.name) · \($0.tools)", "") }, dim: true)
        case .skills:
            let u = model.skillUsage
            list("Использовались", u.used.map { r in
                (r.name, "раз: \(r.uses)" + (r.lastActive.map { " · " + Format.ago($0, now: Date()) } ?? "") + (r.pinned ? " · закреплён" : ""))
            })
            if !u.madeByAgent.isEmpty {
                list("Создал сам агент", u.madeByAgent.map { ($0.name, "раз: \($0.uses)") })
            }
            ForEach(model.inventory.skills.keys.sorted(), id: \.self) { cat in
                InnerCard(tint: Theme.session) {
                    SectionLabel(text: cat, color: Theme.session)
                    Text((model.inventory.skills[cat] ?? []).joined(separator: " · ")).font(.mono(9)).foregroundStyle(.white.opacity(0.7))
                }
            }
            if model.inventory.skills.isEmpty { EmptyNote(text: "Список навыков придёт от шлюза.") }
        case .memory:
            let u = model.dataUsage
            InnerCard(tint: Theme.memory) {
                SectionLabel(text: "что Hermes Веры хранит", color: Theme.memory)
                KeyValue(key: "всего", value: DataUsage.bytes(u.total))
                KeyValue(key: "разговоры", value: "\(model.sessionCount.map(String.init) ?? "…") · state.db \(DataUsage.bytes(u.conversations))")
                KeyValue(key: "память", value: u.memoryFiles == 0 ? "пока пусто (memories/)" : "записей \(u.memoryFiles) · \(DataUsage.bytes(u.memoryBytes))")
                KeyValue(key: "свои навыки", value: "\(u.skillDirs) (skills/)")
                KeyValue(key: "логи", value: DataUsage.bytes(u.logs))
                KeyValue(key: "журнал пульса", value: DataUsage.bytes(u.pulse))
            }
            StoragePanel(model: model).frame(height: 320)
            Button("Показать данные в Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.runtime.dataRoot]) }
        case .plugins:
            list("Наши — внутри Hermes", model.inventory.ourPlugins.map { ($0.name, Self.pluginLine($0)) })
            list("Стандартные Hermes — включены", model.inventory.otherPlugins.filter(\.enabled).map { ($0.key, Self.pluginLine($0)) })
            list("Стандартные — выключены", model.inventory.otherPlugins.filter { !$0.enabled }.map { ($0.key, Self.pluginLine($0)) }, dim: true)
        case .platforms:
            let seen = Set(model.pulse.stats.sessions.values.compactMap(\.platform))
            list("Откуда уже писали", seen.sorted().map { name in
                (name, "сессий: \(model.pulse.stats.sessions.values.filter { $0.platform == name }.count)")
            })
            list("Платформы Hermes (подключаются в его настройке)", model.inventory.platforms.map {
                ($0.name.replacingOccurrences(of: "-platform", with: ""), $0.enabled ? "модуль загружен" : "выключен")
            }, dim: true)
        case .cron:
            if model.inventory.cronJobs.isEmpty {
                EmptyNote(text: "Задач по расписанию нет. Попроси агента: «каждое утро в 9 присылай сводку» — он заведёт cron сам.")
            } else {
                list("Задачи", model.inventory.cronJobs.map { ($0, "") })
            }
        case .mcp:
            if model.inventory.mcpServers.isEmpty {
                EmptyNote(text: "MCP-серверов нет. Их добавляют в настройке Hermes или просьбой к агенту.")
            } else {
                list("Серверы", model.inventory.mcpServers.map { ($0, "") })
            }
        case .provider:
            flowsCard([.hermesToProvider, .providerToHermes])
        }
    }

    static func pluginLine(_ p: HermesInventory.Plugin) -> String {
        var parts: [String] = [p.enabled ? "включён" : "выключен"]
        if p.tools > 0 { parts.append("инструментов \(p.tools)") }
        if p.hooks > 0 { parts.append("хуков \(p.hooks)") }
        // «not enabled in config» is just the reason it is off, not a fault.
        if let e = p.error, !e.lowercased().contains("not enabled") { parts.append("ошибка: \(e)") }
        return parts.joined(separator: " · ")
    }

    private func flowsCard(_ channels: [FlowChannel]) -> some View {
        InnerCard(tint: Theme.llm) {
            SectionLabel(text: "потоки · за минуту / за 10 минут", color: Theme.llm)
            ForEach(channels, id: \.self) { c in
                HStack {
                    Text(c.title).font(.mono(10)).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text("\(model.flows.perMinute(c)) / \(model.flows.total10m(c))").font(.mono(10)).foregroundStyle(Theme.llm)
                }
            }
        }
    }

    private func list(_ title: String, _ rows: [(String, String)], dim: Bool = false) -> some View {
        InnerCard(tint: dim ? .white : Theme.human) {
            SectionLabel(text: "\(title) · \(rows.count)", color: dim ? .white : Theme.human)
            if rows.isEmpty { EmptyNote(text: "пусто") }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .firstTextBaseline) {
                    Text(r.0).font(.mono(10, .semibold)).foregroundStyle(.white.opacity(dim ? 0.5 : 0.85))
                    Text(r.1).font(.system(size: 10)).foregroundStyle(.white.opacity(dim ? 0.35 : 0.55)).lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
