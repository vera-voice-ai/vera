import SwiftUI
import SignalBus

/// Telegram as its own sensor: the bot link, what came in and went out today, and the last message (local only).
@MainActor
@Observable
final class TelegramSensorModel {
    enum Link: Equatable {
        case noToken
        /// This instance does not poll the bot (no `--agent`, or `--no-telegram`).
        case notPolling
        case starting
        case pairing(code: String)
        case paired
    }

    static let previewLength = 60

    private(set) var botName = ""
    private(set) var lastText = ""
    private(set) var lastMessageAt: Date?
    private var polls = false
    private var hasToken = false
    /// What the channel last reported with `sensors.telegram.status`.
    private var reported: Link?
    private var counter: DayCounter
    private let clock: @Sendable () -> Date

    init(clock: @escaping @Sendable () -> Date = { .now }, calendar: Calendar = .current) {
        self.clock = clock
        self.counter = DayCounter(now: clock(), calendar: calendar)
    }

    var link: Link {
        guard polls else { return .notPolling }
        guard hasToken else { return .noToken }
        return reported ?? .starting
    }

    var incomingToday: Int { counter.count("in", now: clock()) }
    var answersToday: Int { counter.count("out", now: clock()) }

    /// Set once at launch: whether this instance polls the bot, and whether a token is in the Keychain.
    func configure(polls: Bool, hasToken: Bool) {
        self.polls = polls
        self.hasToken = hasToken
    }

    func consume(_ bus: SignalBus) async {
        for await message in await bus.subscribe() {
            handle(message)
        }
    }

    func handle(_ message: SignalMessage) {
        switch message.type {
        case "sensors.telegram.status":
            let payload = message.payload
            if let bot = payload["bot"], !bot.isEmpty { botName = bot }
            reported = payload["state"] == "paired" ? .paired : .pairing(code: payload["code"] ?? "")
        case "sensors.text.received":
            guard message.payload["channel"] == "telegram" else { return }
            counter.increment("in", now: clock())
            lastText = Self.preview(message.payload["text"] ?? "")
            lastMessageAt = message.timestamp
        case "core.task.finished":
            guard message.domain == .core, message.subjectID?.hasPrefix("task/tg-") == true else { return }
            // The same rule as the channel: a failure is always sent, an answer is not sent when empty or silent.
            let payload = message.payload
            let ok = payload["success"] == "true"
            let answer = (payload["answer"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let sent = !ok || !(answer.isEmpty || answer.contains("[молчу]"))
            if sent { counter.increment("out", now: clock()) }
        default:
            break
        }
    }

    /// "2 мин назад" and the like; nil before the first message.
    func agoText(now: Date) -> String? {
        guard let lastMessageAt else { return nil }
        let seconds = Int(now.timeIntervalSince(lastMessageAt))
        if seconds < 60 { return "только что" }
        if seconds < 3_600 { return "\(seconds / 60) мин назад" }
        if seconds < 86_400 { return "\(seconds / 3_600) ч назад" }
        return "\(seconds / 86_400) дн назад"
    }

    /// One line, at most `previewLength` characters of the text.
    static func preview(_ text: String) -> String {
        let flat = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > previewLength ? String(flat.prefix(previewLength)) + "…" : flat
    }
}

struct TelegramSensorPanel: View {
    let model: TelegramSensorModel
    /// Telegram's blue (#2AABEE), spelled out so that this file compiles in the test target, which has no `Color(hex:)`.
    private let color = Color(red: 0x2A / 255, green: 0xAB / 255, blue: 0xEE / 255)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "paperplane.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                    Text("Telegram").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.88))
                    if !model.botName.isEmpty {
                        Text("@\(model.botName)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer(minLength: 0)
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                }
                Text(linkText)
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.6)).textSelection(.enabled)
                Text("сегодня · получено \(model.incomingToday) · отправлено \(model.answersToday)")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.52))
                Text("последнее: \(model.agoText(now: context.date) ?? "нет сообщений")")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.52))
                if !model.lastText.isEmpty {
                    Text(model.lastText).font(.system(size: 10)).foregroundStyle(.white.opacity(0.78)).lineLimit(1).truncationMode(.tail)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
    }

    private var linkText: String {
        switch model.link {
        case .noToken: return "нет токена"
        case .notPolling: return "не опрашивается в этом экземпляре"
        case .starting: return "запускается…"
        case .pairing(let code): return "ждёт привязки · отправь боту код \(code)"
        case .paired: return "подключён"
        }
    }

    private var dotColor: Color {
        switch model.link {
        case .paired: return .green
        case .pairing: return .orange
        case .noToken, .notPolling, .starting: return .gray
        }
    }
}
