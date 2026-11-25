import SwiftUI
import HermesBridge

/// «Разговоры» — between the senses and the adapter: one card per channel, and a channel is one Hermes session for good.
/// MacBook — the main session (Vera's chat and voice go through the adapter); Telegram — Hermes' own platform: the
/// bot's messages go straight into Hermes, and the card shows that session as the adapter reads it (`session.transcript`
/// on each pulse line of it); iPhone — the phone sensor's own pinned session (`PhoneModel`). No «new chat» anywhere: Hermes compacts a session itself, the pin follows the id.
struct ConversationsTile: View {
    let model: BoardModel
    let voice: VoiceModel?
    var phone: PhoneModel? = nil

    static let pad: CGFloat = 18
    static let width: CGFloat = 440
    /// The iPhone first: its phone sits right above «Разговоры» on the scheme.
    static var phoneCard: CGRect { CGRect(x: pad, y: 40, width: width - 2 * pad, height: 132) }
    static var macCard: CGRect { CGRect(x: pad, y: phoneCard.maxY + 16, width: width - 2 * pad, height: 258) }
    static var telegramCard: CGRect { CGRect(x: pad, y: macCard.maxY + 16, width: width - 2 * pad, height: 206) }
    static var height: CGFloat { telegramCard.maxY + pad }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 8) {
                Circle().fill(Theme.session).frame(width: 9, height: 9)
                Text("Разговоры").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.95))
                Text("канал = сессия Hermes · новых не создаём").font(.mono(8.5)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text(Theme.Origin.ours.text).font(.mono(7.5, .bold)).tracking(0.8).foregroundStyle(Theme.Origin.ours.color)
                    .padding(.horizontal, 6).padding(.vertical, 2).overlay(Capsule().stroke(Theme.Origin.ours.color.opacity(0.5), lineWidth: 0.8))
            }
            .frame(width: Self.width - 2 * Self.pad).offset(x: Self.pad, y: 12)
            if let voice {
                MacBookChannelCard(chat: voice.chat, voice: voice, model: model).frame(width: Self.macCard.width, height: Self.macCard.height)
                    .offset(x: Self.macCard.minX, y: Self.macCard.minY)
            }
            TelegramChannelCard(model: model).frame(width: Self.telegramCard.width, height: Self.telegramCard.height)
                .offset(x: Self.telegramCard.minX, y: Self.telegramCard.minY)
            if let phone {
                PhoneChannelCard(phone: phone).frame(width: Self.phoneCard.width, height: Self.phoneCard.height)
                    .offset(x: Self.phoneCard.minX, y: Self.phoneCard.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .partFrame(Theme.session, opacity: 0.7)
    }
}

/// The Telegram channel, our card (dashed, pink) over Hermes' own session: the bot answers by itself inside Hermes; Vera
/// shows the conversation as the adapter reads it (`BoardModel.telegramChat`, `session.transcript` right after a pulse
/// line of that session), its state from the pulse (thinking, waiting for you) and whether the bot is up.
struct TelegramChannelCard: View {
    let model: BoardModel
    static let shownLines = 6

    var body: some View {
        let reqs = model.pulse.requests.requests.filter { $0.platform == "telegram" }
        let last = reqs.last
        let up = model.platformStates["telegram"]?.state == "connected"
        let tgSessions = Set(model.conversations.filter { $0.source == "telegram" }.map(\.id) + reqs.map(\.session)
                             + [model.telegramSessionId].compactMap { $0 })
        let asking = model.pulse.stats.running.values.first { $0.kind == "human" && $0.session.map(tgSessions.contains) == true }
        let state: (String, Color) = asking.map { ("ждёт тебя в Telegram · \($0.name)", Theme.human) }
            ?? (last?.running == true ? ("думает", Theme.llm) : (up ? "ждёт" : "бот не подключён", up ? .white.opacity(0.55) : Theme.warn))
        let lines = Self.lines(model.telegramChat)
        VStack(alignment: .leading, spacing: 5) {
            ChannelHeader(icon: "paperplane.fill", title: "Telegram", tag: "сессия Hermes · через адаптер", color: Theme.vera,
                          state: state.0, stateColor: state.1)
            if let home = model.homeChannels["telegram"] {
                HStack(spacing: 6) {
                    Image(systemName: "house.fill").font(.system(size: 9, weight: .semibold))
                    Text("домашний канал Hermes\(home.isEmpty ? "" : " · \(home)")").font(.mono(8.5, .semibold))
                }
                .foregroundStyle(Theme.ok)
                .help("Hermes доставляет сюда итоги задач по расписанию и сообщения между платформами (/sethome в боте)")
            } else if up {
                Text("домашнего канала нет — /sethome в боте сделает его этой личкой").font(.mono(8.5)).foregroundStyle(Theme.warn)
            }
            if lines.isEmpty {
                Text(model.telegramSessionId == nil ? "переписки ещё нет — напиши боту" : "в сессии пока нет реплик")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in line(l.who, l.text, l.color) }
            Spacer(minLength: 0)
            Text(footer(last)).font(.mono(8)).foregroundStyle(.white.opacity(0.42)).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.vera.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: Theme.ourDash)))
    }

    /// The last replies: you, the bot's answers, Hermes' own notes; tool rows only as their name.
    static func lines(_ chat: ChatTranscript) -> [(who: String, text: String, color: Color)] {
        let all: [(String, String, Color)] = chat.items.compactMap { item in
            switch item.kind {
            case .user(let s): ("ты", s, Theme.human)
            case .assistant(let s, _): ("бот", s, Theme.ok)
            case .notice(let s, _): ("Hermes", s, Theme.hermes)
            case .tool(_, let name, _, _, _, _): ("руки", name, Theme.tool)
            case .output, .error: nil
            }
        }
        // Consecutive tool rows fold into one line.
        var folded: [(who: String, text: String, color: Color)] = []
        for l in all {
            if l.0 == "руки", let prev = folded.last, prev.who == "руки" {
                folded[folded.count - 1].text = prev.text + ", " + l.1
            } else { folded.append((l.0, l.1.replacingOccurrences(of: "\n", with: " "), l.2)) }
        }
        return Array(folded.suffix(shownLines))
    }

    private func footer(_ last: RequestLog.Request?) -> String {
        var parts: [String] = []
        if let s = model.conversations.first(where: { $0.id == model.telegramSessionId }) {
            parts.append("\(s.title.isEmpty ? "личка с ботом" : s.title) · сообщений \(s.messages)")
        }
        if let last {
            let how: String = last.running ? "идёт \(Format.sec(Date().timeIntervalSince1970 - last.start))"
                : last.status == "ok" ? "ответ за \(Format.sec((last.end ?? last.lastAt) - last.start))"
                : last.status == "cut" ? "оборван" : (last.status ?? "")
            parts.append("запрос \(Format.ago(last.start, now: Date())) · \(how)")
        }
        if let at = model.telegramReadAt { parts.append("прочитано \(Format.ago(at.timeIntervalSince1970, now: Date()))") }
        return parts.isEmpty ? "адаптер читает сессию по событиям пульса" : parts.joined(separator: " · ")
    }

    private func line(_ who: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(who).font(.mono(9, .semibold)).foregroundStyle(color).frame(width: 44, alignment: .leading)
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
        }
    }
}
