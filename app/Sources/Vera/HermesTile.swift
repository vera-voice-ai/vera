import SwiftUI
import HermesBridge

/// Hermes on the scheme — one whole tile with everything it is made of, live. Its parts are standard code (solid
/// borders); our plugins inside it are dashed. Nothing here is clickable as a tile: hovering shows names, the «▸»
/// buttons open a part's full details next to it.
struct HermesTile: View {
    let model: BoardModel
    var main: ChatModel?

    var body: some View {
        let inv = model.inventory
        VStack(alignment: .leading, spacing: 10) {
            header
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    HermesCell(part: .gateway, title: "Шлюз", color: Theme.gateway, model: model,
                               value: model.gatewayState == .connected ? "онлайн" : "нет связи",
                               sub: "событий за минуту \(model.flows.perMinute(.hermesToAdapter))", glow: glow(.hermesToAdapter, 60)) {
                        VStack(spacing: 4) {
                            FlowBars(up: model.flows.buckets(.hermesToAdapter), upColor: Theme.gateway)
                            HStack {
                                Spacer()
                                Button { Task { await model.restartGateway() } } label: {
                                    Text("↻ перезапустить").font(.mono(8, .semibold)).foregroundStyle(Theme.gateway)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .overlay(Capsule().stroke(Theme.gateway.opacity(0.6), lineWidth: 1))
                                }.buttonStyle(.plain).help("Перезапустить шлюз Hermes внутри Веры")
                            }
                        }
                    }
                    HermesCell(part: .brain, title: "Мозг", color: Theme.llm, model: model,
                               value: brainValue, sub: brainSub, glow: glow(.hermesToProvider, 6)) {
                        CallDots(calls: model.modelCalls)
                    }
                }
                GridRow {
                    HermesCell(part: .hands, title: "Руки", color: Theme.tool, model: model,
                               value: inv.loaded ? "наборов \(inv.enabledToolsets.count) из \(inv.toolsets.count)" : "…",
                               sub: handsSub, glow: glow(.hands, 6)) {
                        ToolBars(tools: model.pulse.stats.tools)
                    }
                    HermesCell(part: .skills, title: "Навыки", color: Theme.session, model: model,
                               value: inv.loaded ? "\(inv.skillCount) · использовались \(model.skillUsage.used.count)" : "…",
                               sub: model.skillUsage.lastUsed.map { "последний: \($0.name)" } ?? "наведи на точку — имя") {
                        SkillDots(inventory: inv, usage: model.skillUsage)
                    }
                }
                GridRow {
                    HermesCell(part: .plugins, title: "Плагины", color: Theme.hermes, model: model,
                               value: inv.loaded ? "включено \(inv.plugins.filter(\.enabled).count) из \(inv.plugins.count)" : "…",
                               sub: "наши — пунктиром, стандартные — сплошные") {
                        PluginChips(inventory: inv)
                    }
                    HermesCell(part: .memory, title: "Память", color: Theme.memory, model: model,
                               value: model.dataUsage.measured ? "\(DataUsage.bytes(model.dataUsage.total)) · записей \(model.dataUsage.memoryFiles)" : "…",
                               sub: model.dataUsage.measured ? "разговоры \(DataUsage.bytes(model.dataUsage.conversations)) · навыки \(model.dataUsage.skillDirs)" : nil) {
                        GrowthLine(points: model.usageHistory)
                    }
                }
                GridRow {
                    HermesCell(part: .platforms, title: "Платформы", color: Theme.hermes, model: model,
                               value: inv.loaded ? "доступно \(inv.platforms.count)" : "…", sub: activePlatforms) {
                        PlatformChips(inventory: inv, active: Set(model.pulse.stats.sessions.values.compactMap(\.platform)))
                    }
                    VStack(spacing: 10) {
                        HermesCell(part: .cron, title: "Cron", color: Theme.hermes, model: model,
                                   value: inv.loaded ? "задач \(inv.cronJobs.count)" : "…",
                                   sub: inv.cronJobs.first ?? "задач по расписанию нет") { EmptyView() }
                        HermesCell(part: .mcp, title: "MCP", color: Theme.hermes, model: model,
                                   value: inv.loaded ? "серверов \(inv.mcpServers.count)" : "…",
                                   sub: inv.mcpServers.first ?? "серверов нет") { EmptyView() }
                    }
                }
            }
            // What Vera added to Hermes: plugins, tools, skill, schedule.
            HermesAutomation(inventory: inv, usage: model.skillUsage)
            // What happens inside, seen by our plugin vera-pulse from within: model calls, tools, turns — 5 minutes.
            VStack(alignment: .leading, spacing: 4) {
                Text("ВНУТРИ · ЖУРНАЛ vera-pulse · 5 МИН").font(.mono(8, .bold)).tracking(1).foregroundStyle(Theme.vera.opacity(0.85))
                PulseLanes(events: model.pulse.events).frame(height: 86)
            }
            .padding(8)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.vera.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: Theme.ourDash)))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.085, green: 0.062, blue: 0.04), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hermes, lineWidth: 2))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Circle().fill(Theme.hermes).frame(width: 9, height: 9)
                Text("Vera-core").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                Text("коробка Hermes-agent с плагинами для Vera").font(.mono(8.5)).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).truncationMode(.tail)
                Spacer()
                Pill(text: "\(model.lock?.tag ?? "?") · \(lockWord)\(upstreamShort.map { " · " + $0 } ?? "")",
                     color: newer ? Theme.hermes : lockColor, strong: false)
                    .fixedSize().layoutPriority(1)
                    .help(versionHelp)
                InfoButton(part: .hermes, model: model, color: Theme.hermes)
            }
            Text(now).font(.mono(9)).foregroundStyle(model.pulse.stats.running.isEmpty ? .white.opacity(0.45) : Theme.llm).lineLimit(1)
        }
    }

    /// What Hermes is doing this second (from the pulse journal).
    private var now: String {
        let t = Date().timeIntervalSince1970
        let running = model.pulse.stats.running.values.sorted { $0.since < $1.since }
        guard !running.isEmpty else { return "сейчас: ждёт" }
        return "сейчас: " + running.prefix(3).map { r in
            let what = switch r.kind { case "llm": "думает"; case "tool": r.name; case "subagent": "сабагент \(r.name)"; case "human": "ждёт человека"; default: r.name }
            return "\(what) \(Format.sec(t - r.since))"
        }.joined(separator: " · ")
    }

    private var brainValue: String {
        main?.transcript.model ?? model.pulse.stats.models.max { $0.value < $1.value }?.key ?? "модель ещё не вызывалась"
    }

    private var brainSub: String {
        let c = model.modelCalls
        guard !c.isEmpty else { return "сегодня вызовов не было" }
        let ok = c.filter { !$0.failed }
        let avg = ok.isEmpty ? 0 : ok.map(\.ms).reduce(0, +) / Double(ok.count)
        return "сегодня \(c.count) · в среднем \(Format.ms(avg)) · ошибок \(c.count - ok.count)"
    }

    private var handsSub: String {
        let calls = model.pulse.stats.tools.values.reduce(0) { $0 + $1.calls }
        let errors = model.pulse.stats.tools.values.reduce(0) { $0 + $1.errors }
        return "вызовов \(calls)" + (errors > 0 ? " · ошибок \(errors)" : "")
    }

    private var activePlatforms: String {
        let seen = Set(model.pulse.stats.sessions.values.compactMap(\.platform))
        return seen.isEmpty ? "пока никто не писал" : "писали: " + seen.sorted().joined(separator: ", ")
    }

    private func glow(_ c: FlowChannel, _ per: Double) -> Double { min(1, Double(model.flows.perMinute(c)) / per) }

    /// The newest stable Hermes upstream (checked at most every 6 h, never installed by itself).
    private var newer: Bool { model.latestHermes.map { UpdateCheck.isNewer($0, than: model.lock?.tag ?? "?") } ?? false }
    private var upstreamShort: String? {
        guard let latest = model.latestHermes else { return nil }
        return newer ? "есть \(latest) ↗" : "новее нет"
    }
    private var versionHelp: String {
        var lines = ["Hermes внутри Веры: \(model.lock?.tag ?? "?"), проверка по замку hermes.lock.json — \(lockWord)"]
        if let latest = model.latestHermes {
            let when = model.latestCheckedAt.map { ", проверено " + Format.ago($0.timeIntervalSince1970, now: Date()) } ?? ""
            lines.append(newer ? "На GitHub есть stable \(latest)\(when). Вера сама не обновляет: scripts/build-hermes.sh \(latest) → проверки → bundle.sh (docs/hermes-updates.md)"
                               : "\(latest) — последний stable\(when)")
        } else {
            lines.append(model.latestCheckedAt == nil ? "Новый stable ещё не проверяли" : "Новый stable проверить не удалось (сеть)")
        }
        return lines.joined(separator: "\n")
    }

    private var lockWord: String {
        switch model.lockStatus { case .verified: "замок ✓"; case .unverified: "НЕ ПРОВЕРЕН"; case .unknown: "…" }
    }
    private var lockColor: Color {
        switch model.lockStatus { case .verified: Theme.ok; case .unverified: Theme.warn; case .unknown: .white.opacity(0.5) }
    }
}

/// One part of Hermes: title, value, a line, a small picture; «▸» opens all its details beside it. Solid border —
/// it is Hermes' own code.
struct HermesCell<Content: View>: View {
    let part: BoardPart
    let title: String
    let color: Color
    let model: BoardModel
    let value: String
    var sub: String? = nil
    var glow: Double = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 4)
                InfoButton(part: part, model: model, color: color)
            }
            Text(value).font(.mono(9.5)).foregroundStyle(color).lineLimit(1)
            if let sub { Text(sub).font(.mono(8)).foregroundStyle(.white.opacity(0.45)).lineLimit(1) }
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(0.05 + 0.25 * glow), in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: color.opacity(0.5 * glow), radius: 8 * glow)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.45), lineWidth: 1))
    }
}

/// «▸»: the part's full details in a popover next to it (what the «Состав» face shows, for this part only).
struct InfoButton: View {
    let part: BoardPart
    let model: BoardModel
    var voice: VoiceModel? = nil
    let color: Color
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "chevron.right.circle").font(.system(size: 11)).foregroundStyle(color.opacity(0.85))
        }
        .buttonStyle(.plain)
        .help("Подробнее: \(part.title)")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            ScrollView { PartDetail(part: part, model: model, voice: voice).padding(4) }
                .frame(width: 480, height: 560)
                .background(Theme.background)
        }
    }
}

/// The tools called most today: a bar each, errors in red.
private struct ToolBars: View {
    let tools: [String: PulseStats.ToolStat]
    var body: some View {
        let top = tools.sorted { $0.value.calls > $1.value.calls }.prefix(4)
        let m = Double(max(1, top.first?.value.calls ?? 1))
        VStack(alignment: .leading, spacing: 3) {
            if top.isEmpty { Text("сегодня руками не работал").font(.mono(8)).foregroundStyle(.white.opacity(0.35)) }
            ForEach(Array(top), id: \.key) { name, s in
                HStack(spacing: 5) {
                    Text(name).font(.mono(8)).foregroundStyle(.white.opacity(0.75)).frame(width: 82, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        HStack(spacing: 0) {
                            Rectangle().fill(Theme.tool.opacity(0.8)).frame(width: g.size.width * CGFloat(Double(s.calls - s.errors) / m))
                            Rectangle().fill(Theme.bad.opacity(0.8)).frame(width: g.size.width * CGFloat(Double(s.errors) / m))
                        }
                    }.frame(height: 6)
                    Text("\(s.calls)").font(.mono(7.5)).foregroundStyle(.white.opacity(0.5)).frame(width: 18, alignment: .trailing)
                }
            }
        }
    }
}

/// Every skill a dot; used ones lit and larger. Hover a dot — its name and how many times it was used.
private struct SkillDots: View {
    let inventory: HermesInventory
    let usage: SkillUsage
    @State private var hover: CGPoint?

    var body: some View {
        let names = inventory.skills.keys.sorted().flatMap { inventory.skills[$0] ?? [] }
        let used = Dictionary(usage.rows.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        GeometryReader { g in
            let cols = 15, rows = max(1, Int((Double(names.count) / 15).rounded(.up)))
            let cw = g.size.width / CGFloat(cols), ch = g.size.height / CGFloat(rows)
            let pts = names.enumerated().map { i, n in (n, CGPoint(x: (CGFloat(i % cols) + 0.5) * cw, y: (CGFloat(i / cols) + 0.5) * ch)) }
            let near = hover.flatMap { h in pts.min { hypot($0.1.x - h.x, $0.1.y - h.y) < hypot($1.1.x - h.x, $1.1.y - h.y) } }
            ZStack(alignment: .topLeading) {
                Canvas { c, _ in
                    for (n, p) in pts {
                        let uses = used[n]?.uses ?? 0
                        let byAgent = used[n]?.createdBy == "agent" || used[n]?.createdBy == "learn"
                        let r: CGFloat = uses > 0 ? min(6, 3 + CGFloat(uses).squareRoot()) : 2.2
                        let color = byAgent ? Theme.subagent : Theme.session
                        c.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                               with: .color(color.opacity(uses > 0 ? 0.95 : (near?.0 == n ? 0.9 : 0.28))))
                    }
                }
                if let near {
                    Text("\(near.0)\(used[near.0].map { " · \($0.uses)" } ?? "")")
                        .font(.mono(8.5)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize()
                        .position(x: min(g.size.width - 50, max(50, near.1.x)), y: max(8, near.1.y - 12))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hover = p } else { hover = nil }
            }
        }
    }
}

/// Our plugins dashed (our code inside Hermes), the standard ones solid; hover — the names.
private struct PluginChips: View {
    let inventory: HermesInventory
    var body: some View {
        let ours = inventory.ourPlugins
        let standard = inventory.otherPlugins.filter(\.enabled)
        VStack(alignment: .leading, spacing: 5) {
            // Every vera-* plugin Hermes has loaded — what they do is in «Наше в Hermes» below.
            FlowWrap(spacing: 4) {
                ForEach(ours) { p in
                    chip(p.name.replacingOccurrences(of: "vera-", with: ""), p.enabled ? "включён" : "выкл", Theme.vera, dashed: true, dim: !p.enabled)
                }
            }
            chip("\(standard.count) стандартных", "включены", Theme.hermes, dashed: false)
                .help(standard.map(\.key).joined(separator: "\n"))
        }
    }

    private func chip(_ name: String, _ state: String, _ color: Color, dashed: Bool, dim: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.mono(9, .semibold)).foregroundStyle(color.opacity(dim ? 0.6 : 1))
            Text(state).font(.mono(7.5)).foregroundStyle(.white.opacity(dim ? 0.35 : 0.5))
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(dim ? 0.4 : 0.7), style: StrokeStyle(lineWidth: 1.2, dash: dashed ? [4, 3] : [])))
    }
}

/// Every platform Hermes can talk on, tiny; the ones that wrote lit. Hover — the name.
private struct PlatformChips: View {
    let inventory: HermesInventory
    let active: Set<String>
    var body: some View {
        let names = inventory.platforms.map { $0.name.replacingOccurrences(of: "-platform", with: "") }.sorted()
        let shown = names.sorted { (active.contains($0) ? 0 : 1, $0) < (active.contains($1) ? 0 : 1, $1) }
        FlowWrap(spacing: 3) {
            ForEach(shown, id: \.self) { n in
                let on = active.contains(n)
                Text(n).font(.mono(7.5)).foregroundStyle(on ? Theme.hermes : .white.opacity(0.4))
                    .padding(.horizontal, 4).padding(.vertical, 1.5)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hermes.opacity(on ? 0.8 : 0.2), lineWidth: 0.8))
            }
        }
    }
}

/// How the data grows: a point per record (Vera writes one an hour or when the memory changes), on a scale from zero —
/// so a small growth looks small. Until there are two points, an honest note.
private struct GrowthLine: View {
    let points: [LifeHistory.UsagePoint]
    var body: some View {
        Canvas { g, size in
            guard points.count >= 2, let lo = points.first?.ts, let hi = points.last?.ts, hi > lo else {
                g.draw(Text("рост пишется с сегодняшнего дня").font(.mono(8)).foregroundStyle(.white.opacity(0.35)),
                       at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let maxV = Double(points.map(\.total).max() ?? 1)
            let base = size.height - 10
            func pt(_ p: LifeHistory.UsagePoint) -> CGPoint {
                CGPoint(x: 4 + CGFloat((p.ts - lo) / (hi - lo)) * (size.width - 8), y: base - CGFloat(Double(p.total) / maxV) * (base - 6))
            }
            var area = Path(), line = Path()
            area.move(to: CGPoint(x: pt(points[0]).x, y: base))
            for (i, p) in points.enumerated() {
                area.addLine(to: pt(p))
                if i == 0 { line.move(to: pt(p)) } else { line.addLine(to: pt(p)) }
            }
            area.addLine(to: CGPoint(x: pt(points.last!).x, y: base)); area.closeSubpath()
            g.fill(area, with: .color(Theme.memory.opacity(0.14)))
            g.stroke(line, with: .color(Theme.memory.opacity(0.9)), lineWidth: 1.2)
            for p in points { let c = pt(p); g.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(Theme.memory)) }
            let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMM"
            let grew = points.last!.total - points.first!.total
            g.draw(Text("с \(f.string(from: Date(timeIntervalSince1970: lo))) · \(grew >= 0 ? "+" : "")\(DataUsage.bytes(grew)) · замеров \(points.count)")
                .font(.mono(7.5)).foregroundStyle(.white.opacity(0.45)), at: CGPoint(x: 4, y: size.height - 3), anchor: .leading)
        }
    }
}

/// Lays chips out in lines, wrapping at the width.
struct FlowWrap: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > w, x > 0 { x = 0; y += line + spacing; line = 0 }
            x += sz.width + spacing; line = max(line, sz.height)
        }
        return CGSize(width: w, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; line = max(line, sz.height)
        }
    }
}
