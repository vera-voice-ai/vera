import SwiftUI
import HermesBridge

/// One conversation: the live transcript, the agent's questions as cards, slash-command completions and the composer.
/// Used by «Чат» (any session) and «Разговор» (the pinned main session, with the voice controls as `accessory`).
struct ConversationPanel<Accessory: View>: View {
    @Bindable var chat: ChatModel
    var scrollable = true
    /// An answer being spoken: only what has been said so far is shown (item id → text).
    var revealed: [Int: String] = [:]
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MaybeScroll(scrollable: scrollable) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if chat.transcript.items.isEmpty {
                        EmptyNote(text: "Пусто. Напиши, скажи (⌘L) или начни с /")
                    }
                    ForEach(chat.transcript.items) { item in itemView(item).id(item.id) }
                    if let thinking = chat.transcript.thinking {
                        Text(thinking).font(.mono(9)).foregroundStyle(Theme.llm.opacity(0.7))
                    }
                    ForEach(chat.transcript.pending) { request in requestCard(request) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            if let problem = chat.problem {
                Text(problem).font(.mono(9)).foregroundStyle(Theme.bad).textSelection(.enabled)
            }
            completions
            composer
        }
    }

    @ViewBuilder private func itemView(_ item: ChatTranscript.Item) -> some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 80)
                Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.92)).textSelection(.enabled)
                    .padding(10).background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
            }
        case .assistant(let full, let done):
            let speaking = revealed[item.id]
            let text = speaking ?? full
            HStack {
                Text(linkified(text.isEmpty && (!done || speaking != nil) ? "…" : text)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.88))
                    .textSelection(.enabled)
                    .padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.llm.opacity(done ? 0.12 : 0.35), lineWidth: 1))
                Spacer(minLength: 80)
            }
        case .tool(_, let name, let preview, let duration, let summary, let done):
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(done ? Theme.tool : .orange).frame(width: 6, height: 6)
                    Text(name).font(.mono(10, .semibold)).foregroundStyle(Theme.tool)
                    if let preview, !preview.isEmpty {
                        Text(preview).font(.mono(9)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if let duration { Text(Format.ms(duration * 1000)).font(.mono(9)).foregroundStyle(.white.opacity(0.45)) }
                }
                if let summary, !summary.isEmpty {
                    Text(summary).font(.mono(9)).foregroundStyle(.white.opacity(0.5)).lineLimit(3).padding(.leading, 12)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.tool.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        case .notice(let text, let warning):
            Text(linkified(text)).font(.mono(9)).foregroundStyle(warning ? Theme.warn : .white.opacity(0.45)).textSelection(.enabled)
                .tint(warning ? Theme.warn : Theme.accent)
        case .output(let text):
            Text(linkified(text)).font(.mono(10)).foregroundStyle(.white.opacity(0.78)).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.accent.opacity(0.2), lineWidth: 1))
        case .error(let text):
            Text(linkified(text)).font(.mono(10)).foregroundStyle(Theme.bad).textSelection(.enabled).tint(Theme.bad)
        }
    }

    // MARK: The agent's questions

    private func requestCard(_ r: ChatTranscript.PendingRequest) -> some View { RequestCard(chat: chat, request: r) }

    static func choiceTitle(_ c: String) -> String {
        switch c {
        case "once": "Разрешить один раз"
        case "session": "На эту сессию"
        case "always": "Всегда"
        case "deny": "Запретить"
        default: c
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            accessory()
            TextField(chat.connected ? "Сообщение или /команда  (⌘↩ — отправить)" : "шлюз не подключён", text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(1...8)
                .padding(9).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .onSubmit { Task { await chat.send() } }
                .onChange(of: chat.draft) { _, _ in chat.updateCompletions() }
            if chat.transcript.running {
                Button("Стоп") { Task { await chat.interrupt() } }.tint(Theme.bad)
            }
            Button("Отправить") { Task { await chat.send() } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!chat.connected || chat.busy || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: Slash commands

    @ViewBuilder private var completions: some View {
        if !chat.completions.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(chat.completions.prefix(8)) { c in
                    Button { chat.pick(c) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(c.display).font(.mono(10, .semibold)).foregroundStyle(Theme.accent)
                            Text(c.meta).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

extension ConversationPanel where Accessory == EmptyView {
    init(chat: ChatModel, scrollable: Bool = true) {
        self.init(chat: chat, scrollable: scrollable, accessory: { EmptyView() })
    }
}

/// The clarify tool: 1–5 questions, each with choices or free text.
struct ClarifyCard: View {
    let request: ChatTranscript.PendingRequest
    let submit: ([String: JSONValue]) -> Void
    let skip: () -> Void
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "агент уточняет", color: Theme.human)
            ForEach(request.questions, id: \.qid) { q in
                VStack(alignment: .leading, spacing: 4) {
                    Text(q.question).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                    if q.choices.isEmpty {
                        TextField("ответ", text: binding(q.qid)).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    } else {
                        Picker("", selection: binding(q.qid)) {
                            Text("—").tag("")
                            ForEach(q.choices, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                    }
                }
            }
            HStack {
                Button("Ответить") { submit(answers.mapValues { .string($0) }) }
                Button("Пропустить", action: skip)
            }
        }
    }

    private func binding(_ qid: String) -> Binding<String> {
        Binding(get: { answers[qid] ?? "" }, set: { answers[qid] = $0 })
    }
}

/// One open question of the agent: an approval (its choices as buttons) or a clarification.
struct RequestCard: View {
    let chat: ChatModel
    let request: ChatTranscript.PendingRequest
    var body: some View {
        let r = request
        InnerCard(tint: Theme.human) {
            if r.method == "approval" {
                SectionLabel(text: "агент просит разрешения", color: Theme.human)
                if let d = r.description { Text(d).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)) }
                if let c = r.command {
                    Text(c).font(.mono(10)).foregroundStyle(.white.opacity(0.8)).textSelection(.enabled)
                        .padding(7).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    ForEach(r.choices, id: \.self) { choice in
                        Button(ConversationPanel<EmptyView>.choiceTitle(choice)) {
                            Task { await chat.answer(r, result: .object(["choice": .string(choice)])) }
                        }
                        .tint(choice == "deny" ? Theme.bad : nil)
                    }
                }
            } else {
                ClarifyCard(request: r) { answers in
                    Task { await chat.answer(r, result: .object(["answers": .object(answers), "outcome": .string("submitted")])) }
                } skip: {
                    Task { await chat.answer(r, result: .object(["outcome": .string("cancelled")])) }
                }
            }
        }
    }
}
