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
            Text("ЗАДАЧИ").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(accent.opacity(0.85))
                .padding(.top, 4)
            if !agent.isEnabled {
                Text(agent.unavailableReason.map { "агент недоступен: \($0)" } ?? "агент выключен (запуск с --agent), работает только в песочнице")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
            }
            if agent.tasks.isEmpty {
                Text("задач ещё не было").font(.system(size: 11)).foregroundStyle(.white.opacity(0.42))
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(agent.tasks.prefix(3)) { task in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Image(systemName: task.state == .running ? "hourglass" : (task.state == .done ? "checkmark.circle.fill" : "xmark.circle.fill"))
                                    .font(.system(size: 10)).foregroundStyle(task.state == .done ? .green : (task.state == .failed ? .red : .orange))
                                Text(task.request).lineLimit(1).truncationMode(.tail).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.88))
                                Spacer(minLength: 6)
                                Text(task.state == .running ? "идёт…" : "\(task.toolCalls.count) инстр. · \(task.steps) запр. · \(Double(task.totalMilliseconds) / 1000, format: .number.precision(.fractionLength(1))) с")
                                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
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
