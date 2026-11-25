import SwiftUI
import HermesBridge
import VeraEars

/// The microphone's spectrogram over the last seconds (0–8 kHz, low at the bottom), brighter where louder — as in
/// Vera 2. Under it a thin line where the VAD heard speech. Only what the microphone really delivered.
struct MicSpectrogram: View {
    let voice: VoiceModel
    var window: Double = 5

    var body: some View {
        let _ = voice.liveTick
        HStack(spacing: 4) {
            VStack(alignment: .trailing) {
                Text("8к"); Spacer(); Text("4к"); Spacer(); Text("0")
            }
            .font(.mono(7)).foregroundStyle(.white.opacity(0.4)).frame(width: 14).padding(.bottom, 4)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !voice.listening)) { ctx in
                Canvas { g, size in
                    let now = ctx.date.timeIntervalSince1970
                    let h = size.height - 4
                    for f in [0.25, 0.5, 0.75] {
                        g.fill(Path(CGRect(x: size.width * f, y: 0, width: 0.6, height: h)), with: .color(.white.opacity(0.06)))
                    }
                    g.fill(Path(CGRect(x: 0, y: h / 2, width: size.width, height: 0.6)), with: .color(.white.opacity(0.06)))
                    let colW = max(1, size.width * 0.02 / window) + 0.6
                    let bandH = h / CGFloat(Spectrum.bands)
                    for c in voice.specTrace where now - c.t <= window && c.bands.count == Spectrum.bands {
                        let x = size.width * CGFloat(1 - (now - c.t) / window)
                        for (b, db) in c.bands.enumerated() {
                            // A narrow dB window and a gamma below one lift quiet speech out of the dark.
                            let strength = pow(CGFloat(max(0, min(1, (db + 80) / 62))), 0.7)
                            guard strength > 0.04 else { continue }
                            g.fill(Path(CGRect(x: x - colW, y: h - CGFloat(b + 1) * bandH, width: colW, height: bandH + 0.4)),
                                   with: .color(Color(red: 0.55 + 0.45 * strength, green: 0.06 + 0.27 * strength,
                                                      blue: 0.35 + 0.30 * strength, opacity: 0.25 + 0.75 * strength)))
                        }
                    }
                    for p in voice.micTrace where p.speech && now - p.t <= window {
                        let x = size.width * CGFloat(1 - (now - p.t) / window)
                        g.fill(Path(CGRect(x: x - colW, y: size.height - 2.5, width: colW, height: 2.5)), with: .color(Theme.human.opacity(0.85)))
                    }
                    if !voice.listening && voice.specTrace.isEmpty {
                        g.draw(Text("микрофон выключен").font(.mono(8)).foregroundStyle(.white.opacity(0.35)),
                               at: CGPoint(x: size.width / 2, y: h / 2))
                    }
                }
            }
            .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.06), lineWidth: 1))
        }
        .help("Спектрограмма микрофона: 0–8 кГц за последние 5 с; розовая черта снизу — VAD слышит речь")
    }
}

/// «Ход»: one turn of the main session as lanes in time — phrase, gateway, model, tools, text, voice — and the last
/// turns as small bars to pick from. Everything is from `TurnRecorder`, i.e. real timestamps.
struct TurnStrip: View {
    let model: BoardModel
    /// Inside «Пульс»: no frame of its own.
    var framed = true
    @State private var picked: UUID?

    private static let lanes: [(TurnTrace.Lane, String, Color)] = [
        (.phrase, "фраза", Theme.human), (.gateway, "шлюз", Theme.gateway), (.model, "модель", Theme.llm),
        (.tool, "руки", Theme.toolCall), (.text, "текст", Theme.session), (.voice, "голос", Theme.ok),
    ]

    var body: some View {
        let turns = model.pulse.turns
        let trace = turns.recent.first { $0.id == picked } ?? turns.latest
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("ХОД").font(.mono(9, .bold)).tracking(1.2).foregroundStyle(Theme.llm)
                Text("куда уходит время").font(.mono(9)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                if let trace { Text(summary(trace)).font(.mono(9)).foregroundStyle(Theme.llm.opacity(0.9)).lineLimit(1) }
            }
            HStack(alignment: .top, spacing: 14) {
                TimelineView(.animation(minimumInterval: 1 / 20, paused: turns.current == nil)) { ctx in
                    Canvas { g, size in draw(trace, in: g, size: size, now: ctx.date.timeIntervalSince1970) }
                }
                history(turns.recent)
                    .frame(width: 150)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func summary(_ t: TurnTrace) -> String {
        var parts = [t.spoken ? "голосом" : "текстом", Format.sec(t.total)]
        if let f = t.toFirstWord { parts.append("до первого слова \(Format.sec(f))") }
        let models = t.steps.filter { $0.lane == .model }
        if !models.isEmpty { parts.append("модель \(models.count) × \(Format.sec(models.compactMap(\.seconds).reduce(0, +) / Double(models.count)))") }
        let tools = t.steps.filter { $0.lane == .tool }.count
        if tools > 0 { parts.append("инструментов \(tools)") }
        if !t.done { parts.append("идёт") }
        return parts.joined(separator: " · ")
    }

    private func draw(_ trace: TurnTrace?, in g: GraphicsContext, size: CGSize, now: Double) {
        let labelW: CGFloat = 46
        let rowH = (size.height - 14) / CGFloat(Self.lanes.count)
        for (i, (_, name, color)) in Self.lanes.enumerated() {
            g.draw(Text(name).font(.mono(8.5)).foregroundStyle(color.opacity(0.85)),
                   at: CGPoint(x: 2, y: CGFloat(i) * rowH + rowH / 2), anchor: .leading)
        }
        guard let t = trace, !t.steps.isEmpty else {
            g.draw(Text("ходов ещё не было: скажи или напиши что-нибудь в разговоре").font(.mono(9)).foregroundStyle(.white.opacity(0.4)),
                   at: CGPoint(x: labelW + (size.width - labelW) / 2, y: size.height / 2))
            return
        }
        let start = t.start
        let end = t.done ? t.end : max(t.end, now)
        let span = max(2, end - start)
        let w = size.width - labelW - 34
        // second ticks
        let tick = span > 20 ? 5.0 : (span > 8 ? 2.0 : 1.0)
        var s = 0.0
        while s <= span {
            let x = labelW + CGFloat(s / span) * w
            g.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height - 12)), with: .color(.white.opacity(0.07)))
            g.draw(Text("\(Int(s)) с").font(.mono(7.5)).foregroundStyle(.white.opacity(0.35)), at: CGPoint(x: x, y: size.height - 5))
            s += tick
        }
        for step in t.steps {
            guard let row = Self.lanes.firstIndex(where: { $0.0 == step.lane }) else { continue }
            let color = step.failed ? Theme.bad : Self.lanes[row].2
            let a = step.start - start, b = (step.end ?? now) - start
            let x = labelW + CGFloat(a / span) * w
            let bw = max(2, CGFloat((b - a) / span) * w)
            let y = CGFloat(row) * rowH + 2
            let rect = CGRect(x: x, y: y, width: bw, height: rowH - 4)
            g.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(color.opacity(step.end == nil ? 0.45 : 0.85)))
            let label = step.lane == .tool ? "\(step.name) \(Format.sec(b - a))" : Format.sec(b - a)
            let text = Text(label).font(.mono(7.5)).foregroundStyle(.white.opacity(0.85))
            if bw > CGFloat(label.count) * 5 + 6 {
                g.draw(text.foregroundStyle(.black.opacity(0.8)), at: CGPoint(x: x + 4, y: y + (rowH - 4) / 2), anchor: .leading)
            } else {
                g.draw(text, at: CGPoint(x: x + bw + 3, y: y + (rowH - 4) / 2), anchor: .leading)
            }
        }
    }

    /// The last turns: a bar each (its length is the turn's total), the picked one bright.
    private func history(_ recent: [TurnTrace]) -> some View {
        let maxT = max(1, recent.map(\.total).max() ?? 1)
        return VStack(alignment: .leading, spacing: 3) {
            Text("последние ходы").font(.mono(8)).foregroundStyle(.white.opacity(0.45))
            ForEach(recent.suffix(7).reversed()) { t in
                Button { picked = picked == t.id ? nil : t.id } label: {
                    HStack(spacing: 5) {
                        Circle().fill(t.spoken ? Theme.human : Theme.session).frame(width: 5, height: 5)
                        RoundedRectangle(cornerRadius: 2).fill(Theme.llm.opacity(picked == t.id ? 0.95 : 0.45))
                            .frame(width: max(3, 80 * t.total / maxT), height: 7)
                        Text(Format.sec(t.total)).font(.mono(7.5)).foregroundStyle(.white.opacity(0.55))
                    }
                }.buttonStyle(.plain)
            }
            if recent.isEmpty { Text("—").font(.mono(8)).foregroundStyle(.white.opacity(0.3)) }
        }
    }
}

/// «Запросы» — the last 10 requests to Hermes from every channel, one row each on one time axis, so overlapping turns
/// show as overlapping bars: the first one's answer arriving while the next one still runs. Each row: the channel, when,
/// its model (yellow) and tool (orange) calls from the vera-pulse journal, for the MacBook also the phrase (pink) and
/// the spoken answer (green) from the turn recorder, and how it ended. Only real data; no row — no request yet.
struct RequestsStrip: View {
    let model: BoardModel
    var mainSession: String?

    var body: some View {
        let reqs = model.pulse.requests.requests
        let running = reqs.contains(where: \.running)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("ЗАПРОСЫ").font(.mono(9, .bold)).tracking(1.2).foregroundStyle(Theme.llm)
                Text("последние \(RequestLog.keep) · все каналы · полосы на одной оси времени — видно, что идёт одновременно")
                    .font(.mono(9)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                legendDot("фраза", Theme.human); legendDot("модель", Theme.llm); legendDot("руки", Theme.toolCall); legendDot("голос", Theme.ok)
            }
            if reqs.isEmpty {
                Text("запросов ещё не было: скажи или напиши что-нибудь — или напиши боту в Telegram")
                    .font(.mono(9)).foregroundStyle(.white.opacity(0.4)).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TimelineView(.periodic(from: .now, by: running ? 0.5 : 30)) { ctx in
                    Canvas { g, size in draw(Array(reqs.reversed()), in: g, size: size, now: ctx.date.timeIntervalSince1970) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func legendDot(_ s: String, _ c: Color) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 6); Text(s).font(.mono(8)).foregroundStyle(.white.opacity(0.5)) }
    }

    private func channel(_ r: RequestLog.Request) -> (String, Color) {
        if let m = mainSession, r.session == m { return ("MacBook", Theme.vera) }
        switch r.platform {
        case "telegram": return ("Telegram", Theme.hermes)
        case "cron": return ("cron", Theme.memory)
        case let p?: return (p, .white.opacity(0.6))
        default: return ("сессия", .white.opacity(0.6))
        }
    }

    private func outcome(_ r: RequestLog.Request, now: Double) -> (String, Color) {
        if r.running { return ("идёт · \(Format.sec(now - r.start))", Theme.llm) }
        let d = Format.sec((r.end ?? r.lastAt) - r.start)
        switch r.status {
        case "interrupted": return ("прерван · \(d)", Theme.warn)
        case "failed": return ("ошибка · \(d)", Theme.bad)
        case "cut": return ("оборван · конца в журнале нет", .white.opacity(0.5))
        default: return ("ответ ✓ · \(d)", Theme.ok)
        }
    }

    /// Newest on top. Left: channel and time; middle: the bars on a shared axis; right: how it ended.
    private func draw(_ reqs: [RequestLog.Request], in g: GraphicsContext, size: CGSize, now: Double) {
        let left: CGFloat = 150, right: CGFloat = 170
        let rowH = min(26, (size.height - 16) / CGFloat(RequestLog.keep))
        let traces = model.pulse.turns.recent + (model.pulse.turns.current.map { [$0] } ?? [])
        let t0 = reqs.map(\.start).min() ?? now
        let t1 = max(reqs.map { $0.running ? now : $0.lastAt }.max() ?? now,
                     traces.filter { $0.end >= t0 }.map(\.end).max() ?? 0)
        let pad = max(1, (t1 - t0) * 0.03)
        let a = t0 - pad, b = t1 + pad
        let w = size.width - left - right
        func x(_ t: Double) -> CGFloat { left + CGFloat((t - a) / (b - a)) * w }
        // time ticks
        let span = b - a
        let step = [1.0, 2, 5, 10, 30, 60, 120, 300, 600, 1800, 3600, 7200].first { span / $0 <= 8 } ?? 7200
        var tk = (a / step).rounded(.up) * step
        while tk <= b {
            g.fill(Path(CGRect(x: x(tk), y: 0, width: 0.5, height: CGFloat(reqs.count) * rowH)), with: .color(.white.opacity(0.06)))
            g.draw(Text(Date(timeIntervalSince1970: tk).formatted(.dateTime.hour().minute().second())).font(.mono(7)).foregroundStyle(.white.opacity(0.3)),
                   at: CGPoint(x: x(tk), y: CGFloat(reqs.count) * rowH + 7))
            tk += step
        }
        for (i, r) in reqs.enumerated() {
            let y = CGFloat(i) * rowH
            let (name, color) = channel(r)
            g.fill(Path(roundedRect: CGRect(x: 0, y: y + rowH / 2 - 3, width: 6, height: 6), cornerRadius: 3), with: .color(color))
            g.draw(Text(name).font(.mono(9, .semibold)).foregroundStyle(color), at: CGPoint(x: 12, y: y + rowH / 2), anchor: .leading)
            g.draw(Text(Date(timeIntervalSince1970: r.start).formatted(.dateTime.hour().minute().second())).font(.mono(8)).foregroundStyle(.white.opacity(0.45)),
                   at: CGPoint(x: left - 10, y: y + rowH / 2), anchor: .trailing)
            let endT = r.running ? now : r.lastAt
            // the whole turn, faint
            g.fill(Path(roundedRect: CGRect(x: x(r.start), y: y + 4, width: max(2, x(endT) - x(r.start)), height: rowH - 8), cornerRadius: 3),
                   with: .color(color.opacity(0.12)))
            // the MacBook's own steps around it: the phrase before, the spoken answer after
            if let m = mainSession, r.session == m,
               let tr = traces.first(where: { $0.start <= endT + 1 && $0.end >= r.start - 15 }) {
                for s in tr.steps where s.lane == .phrase || s.lane == .voice {
                    let e = s.end ?? now
                    g.fill(Path(roundedRect: CGRect(x: x(s.start), y: y + rowH / 2 - 3, width: max(2, x(e) - x(s.start)), height: 6), cornerRadius: 2),
                           with: .color((s.lane == .phrase ? Theme.human : Theme.ok).opacity(0.85)))
                }
            }
            for s in r.steps {
                let e = s.end ?? now
                let c = s.failed ? Theme.bad : (s.kind == .model ? Theme.llm : Theme.toolCall)
                g.fill(Path(roundedRect: CGRect(x: x(s.start), y: y + (s.kind == .model ? 6 : rowH / 2 + 1), width: max(2, x(e) - x(s.start)),
                                                height: s.kind == .model ? rowH / 2 - 7 : rowH / 2 - 7), cornerRadius: 2), with: .color(c.opacity(0.9)))
            }
            let models = r.steps.filter { $0.kind == .model }.count
            let tools = r.steps.filter { $0.kind == .tool }.map(\.name)
            let (out, oc) = outcome(r, now: now)
            g.draw(Text(out).font(.mono(9, .semibold)).foregroundStyle(oc), at: CGPoint(x: size.width - right + 10, y: y + rowH / 2 - 5), anchor: .leading)
            g.draw(Text("модель ×\(models)\(tools.isEmpty ? "" : " · " + Set(tools).sorted().prefix(2).joined(separator: ", "))")
                    .font(.mono(7.5)).foregroundStyle(.white.opacity(0.45)),
                   at: CGPoint(x: size.width - right + 10, y: y + rowH / 2 + 6), anchor: .leading)
        }
    }
}
