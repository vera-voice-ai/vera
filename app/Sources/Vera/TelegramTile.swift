import SwiftUI
import HermesBridge

/// Telegram among Vera's senses: Hermes' own platform (connected code — solid border), so the messages go straight
/// into Hermes, not through our adapter. Shows whether a bot is connected (from the gateway's own record), how many
/// conversations came from it, and lets the owner connect the bot: the token is typed here, saved by Hermes' own
/// functions through vera-setup, and never shown or kept by Vera.
struct TelegramTile: View {
    let model: BoardModel
    @State private var setup = false

    var body: some View {
        let st = model.platformStates["telegram"]
        let sessions = model.pulse.stats.sessions.values.filter { $0.platform == "telegram" }
        let state: (String, Color) = {
            if let phase = model.telegramPhase { return (phase, Theme.warn) }
            if let st { return st.state == "connected" ? ("подключён", Theme.ok) : ("\(st.state)\(st.error.map { " · \($0)" } ?? "")", Theme.warn) }
            if model.telegramToken == true { return ("бот задан — шлюз ещё не поднял платформу", Theme.warn) }
            return ("не подключён", .white.opacity(0.5))
        }()
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane.fill").font(.system(size: 12)).foregroundStyle(Theme.hermes)
                Text("Telegram").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.95))
                Text("платформа Hermes").font(.mono(8.5)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button { setup.toggle() } label: {
                    Text(model.telegramToken == true ? "⚙ бот" : "⚙ подключить").font(.mono(8.5, .semibold)).foregroundStyle(Theme.hermes)
                        .padding(.horizontal, 7).padding(.vertical, 3).overlay(Capsule().stroke(Theme.hermes.opacity(0.7), lineWidth: 1))
                }
                .buttonStyle(.plain)
                // A sheet, not a popover: it stays while the owner switches to Telegram or BotFather to copy the token and the id.
                .sheet(isPresented: $setup) { TelegramSetup(model: model, done: { setup = false }) }
            }
            HStack(spacing: 6) {
                Circle().fill(state.1).frame(width: 6, height: 6)
                Text(state.0).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            }
            Text(sessions.isEmpty ? "разговоров из Telegram ещё не было"
                 : "разговоров \(sessions.count) · последний \(Format.ago(sessions.map(\.lastAt).max() ?? 0, now: Date()))"
                   + (model.telegramAllowed > 0 ? " · разрешено людей \(model.telegramAllowed)" : ""))
                .font(.mono(8.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.contourFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hermes.opacity(0.75), lineWidth: 1.6))
    }
}

/// Connecting the bot: the owner pastes the token from @BotFather and, if wanted, the Telegram user ids allowed to
/// write (empty — Hermes approves new people by pairing in a DM). Saved into Hermes, then the gateway restarts.
struct TelegramSetup: View {
    let model: BoardModel
    var done: () -> Void
    @State private var token = ""
    @State private var ids = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Бот Telegram для Hermes Веры").font(.system(size: 14, weight: .semibold))
            Text("Создай бота у @BotFather (/newbot) и вставь его токен. Отдельный бот — не тот, что у твоего рабочего Hermes.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField(model.telegramToken == true ? "токен задан — вставь новый, чтобы заменить" : "токен бота", text: $token)
                .textFieldStyle(.roundedBorder)
            TextField("кому можно писать: id через запятую (пусто — подтверждение в личке)", text: $ids)
                .textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.bad) }
            Text("Токен хранится только в данных Hermes Веры и больше не показывается. После сохранения шлюз перезапустится, Hermes подключится к Telegram секунд за 30 — ход видно на плитке.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Отмена") { done() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Сохраняю…" : "Сохранить и подключить") {
                    busy = true; error = nil
                    Task {
                        error = await model.saveTelegram(token: token.trimmingCharacters(in: .whitespacesAndNewlines),
                                                         allowed: ids.trimmingCharacters(in: .whitespacesAndNewlines))
                        busy = false
                        if error == nil { token = ""; done() }
                    }
                }
                .disabled(busy || (token.isEmpty && ids.isEmpty))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}
