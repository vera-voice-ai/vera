import SwiftUI
import Core

/// The Core tile for now: what has reached Core from the scene, and the round trip of asking the scene for its picture.
/// It decides nothing.
struct CorePanel: View {
    let inbox: CoreInbox
    let agent: CoreAgent
    private let accent = Color(red: 0.98, green: 0.80, blue: 0.08)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(inbox.isSubscribed ? .green : .gray).frame(width: 7, height: 7)
                Text(inbox.isSubscribed ? "Слушает события сцены" : "Не подписано")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.88))
                Spacer()
                Text("получено к действию: \(inbox.readyCount) · контекст: \(inbox.heardCount)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
            }
            modeRow
            if let reply = inbox.lastReply {
                HStack(spacing: 6) {
                    Text("СНИМОК СЦЕНЫ").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(accent.opacity(0.85))
                    Text("ревизия \(reply.revision) · \(statusText(reply.status)) · ходов \(reply.turns) · \(reply.participants.isEmpty ? "никого" : reply.participants)")
                        .lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Text("запрос → ответ \(reply.roundTripMilliseconds) мс")
                }
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
            }
            Text("ПОЛУЧЕНО ОТ СЦЕНЫ").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(accent.opacity(0.85))
            if inbox.received.isEmpty {
                Text("Пока ничего не пришло").font(.system(size: 11)).foregroundStyle(.white.opacity(0.42))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(inbox.received.prefix(5)) { event in
                        HStack(spacing: 8) {
                            Image(systemName: event.isReady ? "arrow.right.circle.fill" : "ear")
                                .font(.system(size: 10)).foregroundStyle(event.isReady ? .green : .white.opacity(0.4))
                            Text(event.at, format: .dateTime.hour().minute().second())
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                            Text(event.isReady ? "ready" : "heard")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(event.isReady ? .green.opacity(0.9) : .white.opacity(0.45))
                            Text(event.text).lineLimit(1).truncationMode(.tail)
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(event.isReady ? 0.88 : 0.5))
                            Spacer(minLength: 6)
                            Text("\(event.speaker.isEmpty ? "—" : event.speaker) · \(whyText(event))")
                                .lineLimit(1).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Text("ЗАДАЧИ").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(accent.opacity(0.85))
                Spacer()
                // A safety switch: while it is off, nothing Vera hears becomes an action.
                Button(agent.isEnabled ? "агент включён · выключить" : "агент выключен · включить") { agent.setEnabled(!agent.isEnabled) }
                    .buttonStyle(.plain).font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(agent.isEnabled ? .green.opacity(0.9) : .white.opacity(0.55))
                    .disabled(agent.unavailableReason != nil)
            }
            .padding(.top, 4)
            if !agent.isEnabled {
                Text(agent.unavailableReason.map { "агент недоступен: \($0)" } ?? "агент выключен (запуск с --agent), работает только в песочнице")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
            }
            memoryRow
            if agent.tasks.isEmpty {
                Text("задач ещё не было").font(.system(size: 11)).foregroundStyle(.white.opacity(0.42))
            } else {
                Text(Self.load(agent.tasks, voice: agent.voiceTaskID)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(agent.tasks.prefix(6)) { task in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Image(systemName: Self.icon(task.state)).font(.system(size: 10)).foregroundStyle(Self.tint(task.state))
                                Text(task.request).lineLimit(1).truncationMode(.tail).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.88))
                                Spacer(minLength: 6)
                                Text(Self.trailing(task))
                                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                            }
                            if task.state == .done || task.state == .failed || task.speechStartMilliseconds != nil {
                                Text(stagesText(task)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.42)).padding(.leading, 16)
                            }
                            if !task.answer.isEmpty || task.error != nil {
                                Text(task.answer.isEmpty ? (task.error ?? "") : task.answer).lineLimit(2).truncationMode(.tail)
                                    .font(.system(size: 10)).foregroundStyle(task.state == .failed ? .red.opacity(0.8) : .white.opacity(0.6))
                                    .padding(.leading, 16)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// What Core keeps between tasks: remembered facts, task history and the skills it can load.
    private var memoryRow: some View {
        let counts = agent.memory?.counts
        let skills = agent.skills?.all().map(\.name) ?? []
        return VStack(alignment: .leading, spacing: 2) {
            Text("ПАМЯТЬ И НАВЫКИ").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(accent.opacity(0.85))
            Text("фактов: \(counts?.facts ?? 0) · задач в истории: \(counts?.tasks ?? 0) · навыки: \(skills.isEmpty ? "нет" : skills.joined(separator: ", "))")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
            Text("команды: «Вера, режим тишины» · «Вера, засыпай» · «стоп» отменяет задачу и речь")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
            Text("инструменты: read_file, list_dir, write_file, replace_in_file, remember, search_memory, read_skill · голосом «стоп» отменяет задачу и речь")
                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.42)).lineLimit(2)
        }
        .padding(.top, 4)
    }

    /// The mode she is in and how long Ready or Working still lasts if the owner says nothing.
    private var modeRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 8) {
                Circle().fill(Self.modeTint(agent.mode)).frame(width: 8, height: 8)
                Text("РЕЖИМ · \(agent.mode.title.uppercased())").font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Self.modeTint(agent.mode))
                Text(modeHint).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    private var modeHint: String {
        let left = agent.modeDeadline.map { max(0, Int($0.timeIntervalSinceNow)) }.map { String(format: "ещё %d:%02d", $0 / 60, $0 % 60) } ?? ""
        switch agent.mode {
        case .ready: return "отвечает без имени · \(left) · потом Тишина"
        case .working: return "отвечает без имени · \(left) после последней реплики"
        case .silent: return "не говорит, задачи доделывает · проснётся по «Вера»"
        case .sleep: return "не слушает · проснётся, когда включишь микрофон"
        }
    }

    private static func modeTint(_ mode: VeraMode) -> Color {
        switch mode {
        case .ready: return .green
        case .working: return .yellow
        case .silent: return .orange
        case .sleep: return .gray
        }
    }

    private static func icon(_ state: CoreAgent.Task.State) -> String {
        switch state {
        case .queued: return "clock"
        case .running: return "hourglass"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle"
        }
    }

    private static func tint(_ state: CoreAgent.Task.State) -> Color {
        switch state {
        case .queued: return .gray
        case .running: return .orange
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .white.opacity(0.5)
        }
    }

    private static func trailing(_ task: CoreAgent.Task) -> String {
        switch task.state {
        case .queued: return "в очереди"
        case .running: return task.speechStartMilliseconds == nil ? "идёт…" : "говорит"
        case .cancelled: return "отменено"
        case .done, .failed:
            return "\(task.toolCalls.count) инстр. · \(task.steps) запр. · \(String(format: "%.1f", Double(task.totalMilliseconds) / 1000)) с"
        }
    }

    private static func load(_ tasks: [CoreAgent.Task], voice: String?) -> String {
        let running = tasks.filter { $0.state == .running }.count
        let queued = tasks.filter { $0.state == .queued }.count
        let holder = voice.map { "голос у \($0)" } ?? "голос свободен"
        return "идут: \(running) · в очереди: \(queued) (не больше \(CoreAgent.maxParallelTasks)) · \(holder)"
    }

    /// Where the time went, in the order it is spent: queue, scene question, first token, the rest of the model and tools, speech.
    private func stagesText(_ task: CoreAgent.Task) -> String {
        func sec(_ ms: Int) -> String { String(format: "%.1f", Double(ms) / 1000) }
        var parts = ["очередь \(sec(task.queueMilliseconds))", "сцена \(sec(task.contextMilliseconds))"]
        if let first = task.firstTokenMilliseconds { parts.append("1-й токен \(sec(first))") }
        parts.append("модель+инстр. \(sec(task.totalMilliseconds))")
        if let speech = task.speechStartMilliseconds { parts.append("до голоса \(sec(speech)) с от передачи") }
        return "этапы, с: " + parts.joined(separator: " · ")
    }

    private func statusText(_ raw: String) -> String {
        switch raw {
        case "idle": return "тишина"
        case "listening": return "слушает"
        case "forming": return "формирует"
        case "handedOver": return "передано"
        case "background": return "фон"
        default: return raw
        }
    }

    private func whyText(_ event: CoreInbox.Received) -> String {
        switch event.why {
        case "jev": return "по Jev"
        case "no_verdict": return "без Jev"
        case "hold_expired": return "после ожидания"
        case "smart_turn": return "по звуку"
        case "not_addressed": return "не ко мне"
        case "noise": return "шум"
        case "assistant_voice": return "голос Веры"
        case "no_text": return "нет текста"
        case "owner_absent": return "владельца нет"
        case "owner_unconfirmed": return "владелец не подтверждён"
        default: return event.why
        }
    }
}
