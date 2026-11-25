import AppKit
import SwiftUI
import HermesBridge

/// «Ввод» in «Сенсоры MacBook» — the laptop's second input, next to the microphone: a line for a request (completions of
/// /commands pop up above it), paste from the clipboard, pick a /command. Only input: what was said and answered is in
/// the MacBook card of «Разговоры» («открыть весь чат ↗»).
struct ChatInputCard: View {
    @Bindable var chat: ChatModel
    let voice: VoiceModel

    var body: some View {
        let t = chat.transcript
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.vera)
                Text("Ввод").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
                Text("запрос в разговор MacBook").font(.mono(8.5)).foregroundStyle(.white.opacity(0.45))
                Spacer()
            }
            ComposerLine(chat: chat)
            HStack(spacing: 6) {
                chip("⌘V вставить", help: "Вставить из буфера обмена в строку") {
                    if let text = NSPasteboard.general.string(forType: .string) { chat.draft += text; chat.updateCompletions() }
                }
                chip("/ команда ▾", help: "Команды Hermes, как в его TUI: начни с / — появятся подсказки") {
                    if !chat.draft.hasPrefix("/") { chat.draft = "/" + chat.draft }
                    chat.updateCompletions()
                }
                Spacer()
            }
            if let tail = t.items.last, case .error(let e) = tail.kind {
                Text(e).font(.mono(8.5)).foregroundStyle(Theme.bad).lineLimit(1)
            } else if let p = chat.problem ?? voice.problem {
                Text(p).font(.mono(8.5)).foregroundStyle(Theme.warn).lineLimit(1)
            } else {
                Text("только ввод — переписка в «Разговорах»").font(.mono(8)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.vera.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: Theme.ourDash)))
    }

    private func chip(_ title: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.mono(8.5, .semibold)).foregroundStyle(Theme.session)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.session.opacity(0.1), in: Capsule())
                .overlay(Capsule().stroke(Theme.session.opacity(0.6), lineWidth: 1)).fixedSize()
        }.buttonStyle(.plain).help(help)
    }
}

/// The MacBook's conversation in «Разговоры» — the main Hermes session, one forever: its state, the last exchange (Vera's
/// line appears as she speaks it; Hermes' own notes as notes), the session in one line, the agent's open questions and
/// the score of the last 10 minutes.
struct MacBookChannelCard: View {
    @Bindable var chat: ChatModel
    let voice: VoiceModel
    let model: BoardModel
    @State private var history = false

    var body: some View {
        let t = chat.transcript
        let lines = rows
        let state: (String, Color) = {
            if t.running { return (t.thinking ?? "думает", Theme.llm) }
            if !chat.connected { return ("шлюз не подключён", Theme.warn) }
            if chat.sessionId == nil { return ("открывается", .white.opacity(0.55)) }
            return ("на связи · MacBook", Theme.ok)
        }()
        VStack(alignment: .leading, spacing: 5) {
            ChannelHeader(icon: "laptopcomputer", title: "MacBook", tag: "основная сессия · через адаптер", color: Theme.vera,
                          state: state.0, stateColor: state.1)
            if lines.isEmpty {
                Text("переписки ещё нет — скажи «Привет, Вера» или напиши в «Вводе»").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45))
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                line(l.who == "бот" ? "Вера" : l.who, l.who == "ты" ? l.text.replacingOccurrences(of: "🎙 ", with: "") : l.text, l.color)
            }
            Text(sessionLine).font(.mono(8)).foregroundStyle(.white.opacity(0.42)).lineLimit(1)
            if !t.pending.isEmpty {
                Text("Hermes спрашивает: \(t.pending.count) — ответь на баннере или голосом «да / нет»")
                    .font(.mono(8.5, .semibold)).foregroundStyle(Theme.human).lineLimit(1)
            }
            Button { history.toggle() } label: {
                Text("открыть весь чат ↗").font(.mono(9, .semibold)).foregroundStyle(Theme.session)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Theme.session.opacity(0.1), in: Capsule())
                    .overlay(Capsule().stroke(Theme.session.opacity(0.7), lineWidth: 1))
            }
            .buttonStyle(.plain).help("Вся переписка разговора MacBook: реплики, инструменты, вывод команд")
            .popover(isPresented: $history, arrowEdge: .trailing) {
                ConversationPanel(chat: chat).padding(14).frame(width: 560, height: 640).background(Theme.background)
            }
            Spacer(minLength: 0)
            ConversationScore(turns: model.pulse.turns).frame(height: 44)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.vera.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: Theme.ourDash)))
    }

    /// The same rows as the iPhone and Telegram cards (the last exchanges, tools folded); Vera's line as she speaks it.
    private var rows: [(who: String, text: String, color: Color)] {
        let t = chat.transcript
        var lines = TelegramChannelCard.lines(t)
        if let item = t.items.last(where: { if case .assistant = $0.kind { return true }; return false }),
           let spoken = voice.revealed[item.id], let i = lines.lastIndex(where: { $0.who == "бот" }) {
            lines[i].text = spoken.isEmpty ? "…" : spoken.replacingOccurrences(of: "\n", with: " ")
        }
        return lines
    }

    private var sessionLine: String {
        let t = chat.transcript
        let said = t.items.filter { if case .user = $0.kind { return true }; return false }.count
        var parts = ["реплик \(said)"]
        if t.tokensIn + t.tokensOut > 0 { parts.append("токены \(Format.count(t.tokensIn))→\(Format.count(t.tokensOut))") }
        if let m = t.model { parts.append(m) }
        if let last = model.pulse.turns.recent.last { parts.append("последний ход \(Format.sec(last.total))") }
        return parts.joined(separator: " · ")
    }

    private func line(_ who: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(who).font(.mono(9, .semibold)).foregroundStyle(color).frame(width: 44, alignment: .leading)
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
        }
    }
}

/// A channel card's first line: icon, name, what it is, and its state as a chip on the right.
struct ChannelHeader: View {
    let icon: String
    let title: String
    let tag: String
    let color: Color
    let state: String
    var stateColor: Color = .white.opacity(0.55)

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            Text(title).font(.system(size: 13.5, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.95))
            Text(tag).font(.mono(8.5)).foregroundStyle(color.opacity(0.8)).lineLimit(1)
            Spacer()
            Text(state).font(.mono(8.5, .semibold)).foregroundStyle(stateColor).lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .overlay(Capsule().stroke(stateColor.opacity(0.6), lineWidth: 1))
        }
    }
}

/// One line to type a message or a /command; completions pop up above it.
struct ComposerLine: View {
    @Bindable var chat: ChatModel

    var body: some View {
        HStack(spacing: 6) {
            TextField(chat.connected ? "написать или /команда" : "шлюз не подключён", text: $chat.draft)
                .textFieldStyle(.plain).font(.system(size: 11.5))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .onSubmit { Task { await chat.send() } }
                .onChange(of: chat.draft) { _, _ in chat.updateCompletions() }
            if chat.transcript.running {
                Button { Task { await chat.interrupt() } } label: { Image(systemName: "stop.fill").font(.system(size: 9)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.bad).help("Остановить ход агента")
            }
        }
        .overlay(alignment: .bottomLeading) {
            if !chat.completions.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(chat.completions.prefix(6)) { c in
                        Button { chat.pick(c) } label: {
                            HStack(spacing: 8) {
                                Text(c.display).font(.mono(10, .semibold)).foregroundStyle(Theme.accent)
                                Text(c.meta).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 8).padding(.vertical, 3).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                .padding(4)
                .frame(width: 360, alignment: .leading)
                .background(Color(red: 0.08, green: 0.06, blue: 0.1), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.4), lineWidth: 1))
                .offset(y: -34)
                .fixedSize(horizontal: false, vertical: true)
                .alignmentGuide(.bottom) { $0[.bottom] }
            }
        }
    }
}

/// The agent's open questions (approvals, clarifications) as a banner over the board: Vera also says them aloud,
/// a short «да / нет» by voice answers an approval.
struct RequestBanner: View {
    let chat: ChatModel
    var body: some View {
        if !chat.transcript.pending.isEmpty {
            VStack(spacing: 8) {
                ForEach(chat.transcript.pending) { r in RequestCard(chat: chat, request: r) }
            }
            .padding(12)
            .frame(width: 600)
            .background(Color(red: 0.08, green: 0.05, blue: 0.09), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.human, lineWidth: 2))
            .shadow(color: Theme.human.opacity(0.35), radius: 18)
        }
    }
}

/// The conversation as a score over the last 10 minutes: you speaking, Vera thinking (model and text), her hands,
/// her voice — each turn's real steps from the turn recorder, side by side in time. Interruptions are red ticks.
struct ConversationScore: View {
    let turns: TurnRecorder
    var window: Double = 600

    private static let lanes: [(String, Color, (TurnTrace.Step) -> Bool)] = [
        ("ты", Theme.human, { $0.lane == .phrase && $0.name == "фраза" }),
        ("думает", Theme.llm, { $0.lane == .model || $0.lane == .text }),
        ("руки", Theme.toolCall, { $0.lane == .tool }),
        ("голос", Theme.vera, { $0.lane == .voice }),
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Canvas { g, size in
                let now = ctx.date.timeIntervalSince1970
                let left: CGFloat = 38
                let rowH = (size.height - 8) / CGFloat(Self.lanes.count)
                func x(_ t: Double) -> CGFloat { left + CGFloat(1 - (now - t) / window) * (size.width - left) }
                let all = turns.recent + (turns.current.map { [$0] } ?? [])
                for (i, (name, color, match)) in Self.lanes.enumerated() {
                    let y = CGFloat(i) * rowH
                    g.draw(Text(name).font(.mono(7)).foregroundStyle(color.opacity(0.8)), at: CGPoint(x: 0, y: y + rowH / 2), anchor: .leading)
                    g.fill(Path(CGRect(x: left, y: y + rowH / 2, width: size.width - left, height: 0.5)), with: .color(.white.opacity(0.06)))
                    for t in all {
                        for s in t.steps where match(s) {
                            let a = max(s.start, now - window), b = s.end ?? now
                            guard b > now - window else { continue }
                            let r = CGRect(x: x(a), y: y + 1.5, width: max(2, x(b) - x(a)), height: rowH - 3)
                            g.fill(Path(roundedRect: r, cornerRadius: 2), with: .color((s.failed ? Theme.bad : color).opacity(0.85)))
                        }
                    }
                }
                g.draw(Text("10 мин").font(.mono(7)).foregroundStyle(.white.opacity(0.3)), at: CGPoint(x: left, y: size.height - 2), anchor: .leading)
                g.draw(Text("сейчас").font(.mono(7)).foregroundStyle(.white.opacity(0.3)), at: CGPoint(x: size.width, y: size.height - 2), anchor: .trailing)
            }
        }
    }
}

