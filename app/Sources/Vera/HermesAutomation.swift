import HermesBridge
import SwiftUI

/// «Наше в Hermes» — the automation Vera has added to Hermes, live from the gateway: our plugins and what each does,
/// the tools they give the agent, our skill, and the schedule. Inside the Hermes tile (our code runs inside Hermes),
/// dashed pink like everything of ours.
struct HermesAutomation: View {
    let inventory: HermesInventory
    let usage: SkillUsage

    /// What each of our plugins is for — our own code, so the words are ours too.
    static let roles: [String: String] = [
        "vera-pulse": "наблюдает: журнал «Пульса»",
        "vera-setup": "настройки: модель, Telegram",
        "vera-ears": "голосовые → текст (GigaAM)",
        "vera-phone": "навигатор и музыка iPhone",
        "vera-context": "каналы: MacBook · iPhone · Telegram",
        "vera-browser": "браузер Веры на Маке",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("НАШЕ В HERMES · АВТОМАТИЗАЦИЯ").font(.mono(8, .bold)).tracking(1).foregroundStyle(Theme.vera.opacity(0.9))
                Spacer()
                Text("из шлюза").font(.mono(7.5)).foregroundStyle(.white.opacity(0.35))
            }
            row("плагины") {
                FlowWrap(spacing: 4) {
                    ForEach(inventory.ourPlugins) { p in
                        chip(p.name, Self.roles[p.name] ?? "наш", Theme.vera, off: !p.enabled)
                    }
                }
            }
            row("инструменты") {
                if inventory.ourTools.isEmpty {
                    Text(inventory.loaded ? "наши плагины инструментов не дают" : "…").font(.mono(8)).foregroundStyle(.white.opacity(0.4))
                } else {
                    FlowWrap(spacing: 3) {
                        ForEach(inventory.ourTools, id: \.self) { t in
                            Text(t).font(.mono(8)).foregroundStyle(Theme.toolCall)
                                .padding(.horizontal, 4).padding(.vertical, 1.5)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.toolCall.opacity(0.5), lineWidth: 0.8))
                        }
                    }
                }
            }
            row("навыки") {
                let veraUses = usage.rows.first { $0.name == "vera" }?.uses ?? 0
                Text("vera — о самой Вере\(veraUses > 0 ? " · вызван \(veraUses)" : "")")
                    .font(.mono(8.5)).foregroundStyle(Theme.session)
                Text(inventory.loaded ? "· всего \(inventory.skillCount), в деле \(usage.used.count)" : "· …")
                    .font(.mono(8)).foregroundStyle(.white.opacity(0.45))
            }
            row("расписание") {
                if inventory.cron.isEmpty {
                    Text(inventory.loaded ? "задач нет" : "…").font(.mono(8)).foregroundStyle(.white.opacity(0.4))
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(inventory.cron) { j in
                            HStack(spacing: 5) {
                                Circle().fill(j.enabled ? Theme.hermes : .white.opacity(0.25)).frame(width: 4, height: 4)
                                Text(j.name).font(.mono(8)).foregroundStyle(.white.opacity(j.enabled ? 0.8 : 0.4)).lineLimit(1)
                                Text(j.schedule).font(.mono(7.5)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.vera.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: Theme.ourDash)))
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.mono(7.5, .semibold)).foregroundStyle(.white.opacity(0.45)).frame(width: 62, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func chip(_ name: String, _ role: String, _ color: Color, off: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.mono(8.5, .semibold)).foregroundStyle(color.opacity(off ? 0.5 : 1))
            Text(off ? "выключен" : role).font(.mono(7)).foregroundStyle(.white.opacity(off ? 0.35 : 0.5)).lineLimit(1)
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(off ? 0.35 : 0.65), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}
