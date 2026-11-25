import SwiftUI
import HermesBridge

// MARK: - Hermes runtime

struct RuntimePanel: View {
    let model: BoardModel
    var body: some View {
        ModuleContour(name: "hermes/runtime", title: "Hermes · рантайм", color: Theme.runtime, origin: .hermes("ПАКЕТ HERMES + НАШ ЗАМОК")) {
            VStack(alignment: .leading, spacing: 10) {
                InnerCard(tint: Theme.runtime) {
                    SectionLabel(text: "установка", color: Theme.runtime)
                    if let i = model.install {
                        KeyValue(key: "версия", value: i.versionLine ?? "—")
                        KeyValue(key: "тег", value: i.stableTag ?? "не stable-тег")
                        KeyValue(key: "commit", value: i.shortCommit)
                        KeyValue(key: "пакет", value: i.runtime.payloadDescription)
                    } else {
                        EmptyNote(text: model.muted ? "без подключения (--mute)" : "нет пакета Hermes — scripts/build-hermes.sh")
                    }
                }
                InnerCard(tint: lockColor) {
                    SectionLabel(text: "замок hermes.lock.json", color: lockColor)
                    if let lock = model.lock {
                        KeyValue(key: "проверен с", value: "\(lock.tag) · \(lock.commit.prefix(12))")
                        KeyValue(key: "протокол", value: "\(lock.gatewayProtocol) · runtime \(lock.runtimeProtocol)")
                        KeyValue(key: "хуков", value: "\(lock.hooksUsed.count) · путей-контрактов \(lock.contractPaths.count)")
                    } else {
                        EmptyNote(text: "замок не найден")
                    }
                    lockVerdict
                }
            }
        }
    }

    private var lockColor: Color {
        switch model.lockStatus {
        case .verified: Theme.ok
        case .unverified: Theme.warn
        case .unknown: .white
        }
    }

    @ViewBuilder private var lockVerdict: some View {
        switch model.lockStatus {
        case .verified:
            Text("✓ работает проверенная версия").font(.mono(9, .semibold)).foregroundStyle(Theme.ok)
        case .unverified(let reasons):
            ForEach(reasons, id: \.self) { Text("! \($0)").font(.mono(9)).foregroundStyle(Theme.warn) }
        case .unknown:
            Text("сверка после подключения").font(.mono(9)).foregroundStyle(.white.opacity(0.4))
        }
    }
}

// MARK: - Gateway

struct GatewayPanel: View {
    let model: BoardModel
    var body: some View {
        ModuleContour(name: "hermes/gateway", title: "Нервная система · Gateway", color: Theme.gateway,
                      trailing: model.endpoint?.supervisor, origin: .hermes("ШЛЮЗ HERMES")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Stat(value: stateWord, label: "соединение", color: stateColor)
                    Stat(value: "\(model.gatewayEvents.values.reduce(0) { $0 + $1.count })", label: "событий шлюза")
                    Stat(value: model.endpoint?.authorityEpoch.map { "\($0)" } ?? "—", label: "эпоха владельца")
                }
                .padding(10)
                .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                InnerCard {
                    KeyValue(key: "адрес", value: model.gatewayURL ?? "—")
                    KeyValue(key: "протокол", value: model.gatewayProtocol ?? "—")
                    KeyValue(key: "код шлюза", value: model.endpoint?.codeSha.map { String($0.prefix(12)) } ?? "—")
                    KeyValue(key: "профиль", value: model.endpoint?.profileId ?? "—")
                    KeyValue(key: "возможности", value: capabilities)
                }
                SectionLabel(text: "события шлюза")
                if model.gatewayEvents.isEmpty {
                    EmptyNote(text: stateNote)
                } else {
                    ForEach(model.gatewayEvents.sorted { $0.value.lastAt > $1.value.lastAt }.prefix(4), id: \.key) { type, stat in
                        HStack {
                            Text(type).font(.mono(9)).foregroundStyle(.white.opacity(0.7))
                            Spacer()
                            Text("×\(stat.count)").font(.mono(9)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
            }
        }
    }

    private var capabilities: String {
        let caps = model.describeCapabilities.isEmpty ? (model.endpoint?.capabilities ?? []) : model.describeCapabilities
        return caps.isEmpty ? "—" : caps.joined(separator: ", ")
    }

    private var stateWord: String {
        switch model.gatewayState {
        case .connected: "онлайн"
        case .attaching: "…"
        case .failed: "нет"
        case .muted: "выкл"
        case .idle: "—"
        }
    }

    private var stateColor: Color {
        switch model.gatewayState {
        case .connected: Theme.ok
        case .failed: Theme.bad
        default: .white.opacity(0.6)
        }
    }

    private var stateNote: String {
        switch model.gatewayState {
        case .failed(let r): "нет связи со шлюзом: \(r)"
        case .muted: "Вера запущена с --mute: к Hermes не подключается"
        default: "ждём gateway.ready"
        }
    }
}

// MARK: - Pulse timeline

struct PulseTimelinePanel: View {
    let model: BoardModel
    static let lanes = ["session", "llm", "tool", "subagent", "human", "compaction"]

    var body: some View {
        ModuleContour(name: "vera-pulse", title: "Пульс · последние 60 с", color: Theme.accent, origin: .plugin("vera-pulse")) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let data = model.timeline(now: context.date)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Self.lanes, id: \.self) { lane in
                        HStack(spacing: 10) {
                            HStack(spacing: 6) {
                                Circle().fill(Theme.domainColor(lane)).frame(width: 6, height: 6)
                                Text(Theme.domainTitle(lane)).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                            }
                            .frame(width: 104, alignment: .leading)
                            Bars(values: data[lane] ?? [], color: Theme.domainColor(lane))
                        }
                        .frame(height: 22)
                    }
                    HStack {
                        Text("−60 с").font(.mono(9))
                        Spacer()
                        Text("−30 с").font(.mono(9))
                        Spacer()
                        Text("сейчас").font(.mono(9))
                    }
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.leading, 114)
                }
            }
        }
    }

    struct Bars: View {
        let values: [Int]
        let color: Color
        var body: some View {
            Canvas { ctx, size in
                let n = 60
                let w = size.width / CGFloat(n)
                let peak = max(1, values.max() ?? 1)
                ctx.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(.white.opacity(0.08)))
                for (i, v) in values.enumerated() where v > 0 {
                    let h = max(3, size.height * CGFloat(v) / CGFloat(peak))
                    let rect = CGRect(x: CGFloat(i) * w + 1, y: size.height - h, width: max(1, w - 2), height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color.opacity(0.85)))
                }
            }
            .background(.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 3))
        }
    }
}

// MARK: - Sessions

struct SessionsPanel: View {
    let model: BoardModel
    var body: some View {
        ModuleContour(name: "hermes/sessions", title: "Сессии", color: Theme.session,
                      trailing: "\(model.pulse.stats.sessions.count)", origin: .plugin("vera-pulse")) {
            let sessions = model.pulse.stats.sessions.values.sorted { $0.lastAt > $1.lastAt }.prefix(6)
            if sessions.isEmpty {
                EmptyNote(text: "Пока нет сессий в пульсе. Сессии появятся, когда Hermes начнёт работу (CLI, TUI, Telegram…).")
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(sessions), id: \.id) { s in
                        InnerCard(tint: Theme.session) {
                            HStack {
                                Text(s.platform ?? "?").font(.mono(9, .semibold)).foregroundStyle(Theme.session)
                                Text(String(s.id.suffix(10))).font(.mono(9)).foregroundStyle(.white.opacity(0.5))
                                Spacer()
                                Text(Format.ago(s.lastAt, now: Date())).font(.mono(8)).foregroundStyle(.white.opacity(0.4))
                            }
                            Text("ходов \(s.turns) · модель \(s.llmCalls) · инстр. \(s.toolCalls)\(s.lastOutcome.map { " · \($0)" } ?? "")")
                                .font(.mono(9)).foregroundStyle(.white.opacity(0.65))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Model

struct ModelPanel: View {
    let model: BoardModel
    var body: some View {
        let s = model.pulse.stats
        ModuleContour(name: "hermes/llm", title: "Модель · LLM", color: Theme.llm, origin: .plugin("vera-pulse")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Stat(value: "\(s.llmCalls)", label: "запросов", color: Theme.llm)
                    Stat(value: "\(s.llmErrors)", label: "ошибок", color: s.llmErrors > 0 ? Theme.bad : Theme.llm)
                    Stat(value: s.llmCalls > 0 ? Format.ms(s.llmTotalMs / Double(s.llmCalls)) : "—", label: "в среднем", color: Theme.llm)
                }
                HStack {
                    Stat(value: Format.count(s.tokensIn), label: "токенов на вход", color: Theme.llm)
                    Stat(value: Format.count(s.tokensOut), label: "на выход", color: Theme.llm)
                }
                SectionLabel(text: "модели", color: Theme.llm)
                if s.models.isEmpty {
                    EmptyNote(text: "запросов к модели ещё не было")
                } else {
                    ForEach(s.models.sorted { $0.value > $1.value }.prefix(5), id: \.key) { name, n in
                        HStack {
                            Text(name).font(.mono(9)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                            Spacer()
                            Text("×\(n)").font(.mono(9)).foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Tools

struct ToolsPanel: View {
    let model: BoardModel
    var body: some View {
        let tools = model.pulse.stats.tools.sorted { $0.value.lastAt > $1.value.lastAt }
        ModuleContour(name: "hermes/tools", title: "Руки · инструменты", color: Theme.tool,
                      trailing: "\(tools.count) видов", origin: .plugin("vera-pulse")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("инструмент").frame(maxWidth: .infinity, alignment: .leading)
                    Text("вызовы").frame(width: 50, alignment: .trailing)
                    Text("ошибки").frame(width: 50, alignment: .trailing)
                    Text("среднее").frame(width: 62, alignment: .trailing)
                }
                .font(.mono(8, .bold)).foregroundStyle(Theme.tool.opacity(0.7))
                if tools.isEmpty {
                    EmptyNote(text: "Агент ещё не вызывал инструменты.")
                }
                ForEach(tools.prefix(12), id: \.key) { name, t in
                    HStack {
                        HStack(spacing: 5) {
                            if model.pulse.stats.running.values.contains(where: { $0.kind == "tool" && $0.name == name }) {
                                Circle().fill(.orange).frame(width: 5, height: 5)
                            }
                            Text(name).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(t.calls)").frame(width: 50, alignment: .trailing)
                        Text("\(t.errors)").foregroundStyle(t.errors > 0 ? Theme.bad : .white.opacity(0.4)).frame(width: 50, alignment: .trailing)
                        Text(Format.ms(t.averageMs)).frame(width: 62, alignment: .trailing)
                    }
                    .font(.mono(9)).foregroundStyle(.white.opacity(0.75))
                }
            }
        }
    }
}

// MARK: - Waits and subagents

struct WaitsPanel: View {
    let model: BoardModel
    var body: some View {
        let running = model.pulse.stats.running.values.sorted { $0.since < $1.since }
        ModuleContour(name: "hermes/now", title: "Сейчас", color: Theme.human, origin: .plugin("vera-pulse")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Stat(value: "\(model.pulse.stats.humanWaits)", label: "ждал человека", color: Theme.human)
                    Stat(value: "\(model.pulse.stats.subagents)", label: "сабагентов", color: Theme.subagent)
                }
                HStack {
                    Stat(value: "\(model.pulse.stats.compactions)", label: "компакций", color: Theme.memory)
                }
                SectionLabel(text: "в работе", color: Theme.human)
                if running.isEmpty {
                    EmptyNote(text: "ничего не выполняется")
                }
                ForEach(Array(running.prefix(8).enumerated()), id: \.offset) { _, r in
                    HStack(spacing: 6) {
                        Circle().fill(Theme.domainColor(r.kind)).frame(width: 6, height: 6)
                        Text(r.name).font(.mono(9)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                        Spacer()
                        Text(Format.ago(r.since, now: Date())).font(.mono(8)).foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
        }
    }
}

// MARK: - Feed

struct FeedPanel: View {
    let model: BoardModel
    var body: some View {
        ModuleContour(name: "vera-pulse/feed", title: "Лента событий", color: Theme.accent,
                      trailing: "\(model.pulse.events.count) в памяти", origin: .plugin("vera-pulse")) {
            if model.pulse.events.isEmpty {
                EmptyNote(text: "Журнал пуст. Плагин vera-pulse подключается сам; события пойдут, когда агент начнёт работать — для этого нужен ключ модели (кнопка «НАСТРОЙКА»).")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.pulse.events.suffix(16).reversed()) { e in
                        HStack(spacing: 10) {
                            Text(Format.time(e.ts)).foregroundStyle(.white.opacity(0.4)).frame(width: 60, alignment: .leading)
                            Circle().fill(Theme.domainColor(e.domain)).frame(width: 6, height: 6)
                            Text(e.kind).foregroundStyle(Theme.domainColor(e.domain)).frame(width: 110, alignment: .leading)
                            Text(e.name ?? e.model ?? "").foregroundStyle(.white.opacity(0.8)).frame(width: 200, alignment: .leading).lineLimit(1)
                            Text(details(e)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.mono(9))
                    }
                }
            }
        }
    }

    private func details(_ e: PulseEvent) -> String {
        var parts: [String] = []
        if let d = e.durationMs { parts.append(Format.ms(d)) }
        if let s = e.status { parts.append(s) }
        if let i = e.tokensIn, let o = e.tokensOut { parts.append("\(i)→\(o) ток.") }
        if let p = e.platform { parts.append(p) }
        if let d = e.detail { parts.append(d) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Storage

struct StoragePanel: View {
    let model: BoardModel
    var body: some View {
        ModuleContour(name: "storage", title: "Хранилище", color: Theme.memory, origin: .ours) {
            VStack(alignment: .leading, spacing: 8) {
                row("Журнал пульса", "пишет плагин vera-pulse, по файлу на день", model.pulseDirectory.path(percentEncoded: false) + "/<дата>.jsonl", real: true)
                row("Hermes внутри Веры", "код, Python, зависимости — только чтение", model.runtime.payloadDescription, real: true)
                row("Данные Hermes Веры", "конфиг, ключи (.env), сессии, память, логи", model.runtime.hermesHome.path(percentEncoded: false), real: true)
                row("Замок версии", "с какой версией Hermes Вера проверена", "hermes.lock.json", real: true)
                row("Своя домашняя папка Hermes", "HOME процессов Hermes: чужие папки он не видит", model.runtime.home.path(percentEncoded: false), real: true)
            }
        }
    }

    private func row(_ title: String, _ note: String, _ path: String, real: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(real ? Theme.ok : .white.opacity(0.25)).frame(width: 5, height: 5)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(real ? 0.85 : 0.45))
                Text(note).font(.system(size: 9)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            Text(path).font(.mono(9)).foregroundStyle(Theme.memory.opacity(real ? 0.8 : 0.4)).lineLimit(1).truncationMode(.middle)
                .padding(.leading, 11)
        }
    }
}
