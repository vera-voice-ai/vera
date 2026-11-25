import SwiftUI
import HermesBridge

/// The adapter on the scheme: the one pipe between Vera and Hermes — the link, the calls it sent (method, time,
/// failed or not), the events that came back by type, the agent's open questions. Our module (dashed).
struct AdapterTile: View {
    let model: BoardModel
    var waiting: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(model.gatewayState == .connected ? (waiting > 0 ? Theme.human : Theme.llm) : Theme.bad).frame(width: 9, height: 9)
                Text("Адаптер").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.95))
                Text("транспорт к шлюзу Hermes").font(.mono(8.5)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text(Theme.Origin.ours.text).font(.mono(7.5, .bold)).tracking(0.8).foregroundStyle(Theme.Origin.ours.color)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(Capsule().stroke(Theme.Origin.ours.color.opacity(0.5), lineWidth: 0.8))
            }
            Text("шлюз: \(model.gatewayState.title)\(model.gatewayURL.map { " · " + $0.replacingOccurrences(of: "ws://", with: "") } ?? "")")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            Text(waiting > 0 ? "агент ждёт ответа: \(waiting) — баннер сверху" : "вопросов агента нет")
                .font(.system(size: 12)).foregroundStyle(waiting > 0 ? Theme.human : .white.opacity(0.6))
            FlowBars(up: model.flows.buckets(.adapterToHermes), down: model.flows.buckets(.hermesToAdapter),
                     upColor: Theme.llm, downColor: Theme.gateway, upLabel: "вызовы", downLabel: "события").frame(height: 50)
            section("вызовы → Hermes")
            VStack(alignment: .leading, spacing: 3) {
                if model.recentCalls.isEmpty { note("ещё не было") }
                ForEach(model.recentCalls.suffix(5).reversed()) { c in
                    HStack(spacing: 6) {
                        Circle().fill(c.failed ? Theme.bad : Theme.llm).frame(width: 5, height: 5)
                        Text(c.method).font(.mono(9)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                        Spacer()
                        if let ms = c.ms { Text(Format.ms(ms)).font(.mono(8.5)).foregroundStyle(.white.opacity(0.5)) }
                        Text(Format.ago(c.at.timeIntervalSince1970, now: Date())).font(.mono(8)).foregroundStyle(.white.opacity(0.35))
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            }
            section("события ← Hermes")
            let events = model.gatewayEvents.sorted { $0.value.count > $1.value.count }.prefix(5)
            VStack(alignment: .leading, spacing: 3) {
                if events.isEmpty { note("ещё не было") }
                let m = Double(max(1, events.first?.value.count ?? 1))
                ForEach(Array(events), id: \.key) { type, stat in
                    HStack(spacing: 6) {
                        Text(type).font(.mono(9)).foregroundStyle(.white.opacity(0.8)).frame(width: 150, alignment: .leading).lineLimit(1)
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 2).fill(Theme.gateway.opacity(0.55))
                                .frame(width: max(2, g.size.width * CGFloat(Double(stat.count) / m)))
                        }.frame(height: 6)
                        Text("\(stat.count)").font(.mono(8.5)).foregroundStyle(.white.opacity(0.55)).frame(width: 36, alignment: .trailing)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .partFrame(Theme.vera)
    }

    private func section(_ t: String) -> some View {
        Text(t).font(.mono(8, .bold)).tracking(1).foregroundStyle(Theme.vera.opacity(0.85)).padding(.top, 4)
    }
    private func note(_ t: String) -> some View { Text(t).font(.mono(8.5)).foregroundStyle(.white.opacity(0.35)) }
}
