import SwiftUI
import HermesBridge

/// Small pictures inside the scheme's tiles. All from real counts and timestamps; empty where nothing happened.

/// Flows over the last 10 minutes in 20-second bars: one series up from the middle, an optional second down.
struct FlowBars: View {
    let up: [Int]
    var down: [Int]? = nil
    let upColor: Color
    var downColor: Color = .white
    var upLabel = ""
    var downLabel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Canvas { g, size in
                let n = up.count
                guard n > 0 else { return }
                let m = CGFloat(max(1, (up + (down ?? [])).max() ?? 1))
                let mid = down == nil ? size.height - 1 : size.height / 2
                let half = down == nil ? size.height - 2 : size.height / 2 - 1
                let bw = size.width / CGFloat(n)
                g.fill(Path(CGRect(x: 0, y: mid, width: size.width, height: 0.5)), with: .color(.white.opacity(0.15)))
                for i in 0..<n {
                    if up[i] > 0 {
                        let h = max(2, CGFloat(up[i]) / m * half)
                        g.fill(Path(roundedRect: CGRect(x: CGFloat(i) * bw + 1, y: mid - h, width: bw - 2, height: h), cornerRadius: 1.5),
                               with: .color(upColor.opacity(0.85)))
                    }
                    if let down, down[i] > 0 {
                        let h = max(2, CGFloat(down[i]) / m * half)
                        g.fill(Path(roundedRect: CGRect(x: CGFloat(i) * bw + 1, y: mid + 1, width: bw - 2, height: h), cornerRadius: 1.5),
                               with: .color(downColor.opacity(0.5)))
                    }
                }
            }
            HStack(spacing: 8) {
                Text("10 мин").font(.mono(7.5)).foregroundStyle(.white.opacity(0.35))
                if !upLabel.isEmpty { legend(upColor, upLabel, up.reduce(0, +)) }
                if let down, !downLabel.isEmpty { legend(downColor.opacity(0.6), downLabel, down.reduce(0, +)) }
                Spacer()
                Text("сейчас").font(.mono(7.5)).foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private func legend(_ c: Color, _ text: String, _ n: Int) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 6, height: 6)
            Text("\(text) \(n)").font(.mono(7.5)).foregroundStyle(.white.opacity(0.55))
        }
    }
}

/// The vera-pulse journal as lanes over the last minutes: model calls, tools, turns; failures red.
struct PulseLanes: View {
    let events: [PulseEvent]
    var window: Double = 300

    private static let lanes: [(String, Color, (PulseEvent) -> Bool)] = [
        ("модель", Theme.llm, { $0.kind.hasPrefix("llm.") }),
        ("руки", Theme.toolCall, { $0.kind.hasPrefix("tool.") }),
        ("ходы", Theme.session, { $0.kind.hasPrefix("session.") || $0.kind.hasPrefix("human.") || $0.kind.hasPrefix("subagent.") }),
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { ctx in
            Canvas { g, size in
                let now = ctx.date.timeIntervalSince1970
                let left: CGFloat = 40
                let rowH = (size.height - 10) / CGFloat(Self.lanes.count)
                let recent = events.filter { now - $0.ts <= window }
                for (i, (name, color, match)) in Self.lanes.enumerated() {
                    let y = CGFloat(i) * rowH + rowH / 2
                    g.draw(Text(name).font(.mono(7.5)).foregroundStyle(color.opacity(0.8)), at: CGPoint(x: 0, y: y), anchor: .leading)
                    g.fill(Path(CGRect(x: left, y: y, width: size.width - left, height: 0.5)), with: .color(.white.opacity(0.08)))
                    for e in recent where match(e) {
                        let x = left + CGFloat(1 - (now - e.ts) / window) * (size.width - left - 4)
                        let failed = e.kind == "llm.error" || (e.status != nil && e.status != "ok")
                        let r: CGFloat = e.kind.hasSuffix(".start") || e.kind == "session.open" ? 2 : 3
                        g.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                               with: .color(failed ? Theme.bad : color.opacity(e.kind.hasSuffix(".start") ? 0.5 : 0.95)))
                    }
                }
                g.draw(Text("5 мин").font(.mono(7.5)).foregroundStyle(.white.opacity(0.35)), at: CGPoint(x: left, y: size.height - 3), anchor: .leading)
                g.draw(Text("сейчас").font(.mono(7.5)).foregroundStyle(.white.opacity(0.35)), at: CGPoint(x: size.width, y: size.height - 3), anchor: .trailing)
                if recent.isEmpty {
                    g.draw(Text("за 5 минут журнал молчит").font(.mono(8)).foregroundStyle(.white.opacity(0.35)),
                           at: CGPoint(x: left + (size.width - left) / 2, y: size.height / 2 - 4))
                }
            }
        }
    }
}

/// Today's model calls in a strip: each a dot, higher = slower answer; errors as red ticks.
struct CallDots: View {
    let calls: [LifeHistory.ModelCall]

    var body: some View {
        Canvas { g, size in
            guard let first = calls.first?.ts else {
                g.draw(Text("сегодня вызовов не было").font(.mono(8)).foregroundStyle(.white.opacity(0.35)), at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let to = max(Date().timeIntervalSince1970, first + 60)
            let maxMs = max(1000, calls.map(\.ms).max() ?? 1)
            g.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 0.5)), with: .color(.white.opacity(0.15)))
            for c in calls {
                let x = CGFloat((c.ts - first) / (to - first)) * (size.width - 6) + 3
                if c.failed {
                    g.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(Theme.bad.opacity(0.8)))
                } else {
                    let y = size.height - 3 - CGFloat(c.ms / maxMs) * (size.height - 6)
                    g.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)), with: .color(Theme.human))
                }
            }
        }
    }
}

/// Day × hour: how much happened (model calls, tools, turns), brighter = more.
struct ActivityHeat: View {
    let grid: LifeHistory.Grid
    private static let wd: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "EE d"; return f }()
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Canvas { g, size in
                guard !grid.counts.isEmpty else { return }
                let left: CGFloat = 46, right: CGFloat = 40, bottom: CGFloat = 16
                let cw = (size.width - left - right) / 24, ch = (size.height - bottom) / CGFloat(grid.counts.count)
                let m = Double(max(1, grid.max))
                for (d, row) in grid.counts.enumerated() {
                    g.draw(Text(Self.wd.string(from: grid.days[d])).font(.mono(9)).foregroundStyle(.white.opacity(0.5)),
                           at: CGPoint(x: left - 6, y: CGFloat(d) * ch + ch / 2), anchor: .trailing)
                    for (h, v) in row.enumerated() {
                        let rect = CGRect(x: left + CGFloat(h) * cw + 1.5, y: CGFloat(d) * ch + 1.5, width: cw - 3, height: ch - 3)
                        g.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Theme.subagent.opacity(v == 0 ? 0.05 : 0.18 + 0.8 * Double(v) / m)))
                    }
                    let total = row.reduce(0, +)
                    g.draw(Text(total > 0 ? "\(total)" : "").font(.mono(8.5)).foregroundStyle(Theme.subagent.opacity(0.8)),
                           at: CGPoint(x: size.width - right + 6, y: CGFloat(d) * ch + ch / 2), anchor: .leading)
                }
                for h in [0, 6, 12, 18, 23] {
                    g.draw(Text("\(h)").font(.mono(8)).foregroundStyle(.white.opacity(0.4)),
                           at: CGPoint(x: left + (CGFloat(h) + 0.5) * cw, y: size.height - 6))
                }
            }
            Text(grid.max == 0 ? "журнал пульса за неделю пуст" : "вызовы модели, инструменты и ходы по часам · справа — за день")
                .font(.mono(8.5)).foregroundStyle(.white.opacity(0.45))
        }
    }
}

