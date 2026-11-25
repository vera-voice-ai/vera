import SwiftUI
import HermesBridge
import VeraEars

/// What a click on the board selects; the detail panel shows it.
enum BoardPart: String, CaseIterable, Identifiable {
    case windows, voice, adapter, pulse
    case hermes, gateway, brain, hands, skills, memory
    case plugins, platforms, cron, mcp
    case provider
    var id: String { rawValue }

    var title: String {
        switch self {
        case .windows: "Разговор"
        case .voice: "Сенсоры"
        case .adapter: "Адаптер"
        case .pulse: "Пульс"
        case .hermes: "Hermes · версия и замок"
        case .gateway: "Шлюз Hermes"
        case .brain: "Мозг · модель"
        case .hands: "Руки · инструменты"
        case .skills: "Навыки"
        case .memory: "Память · данные"
        case .plugins: "Плагины Hermes"
        case .platforms: "Платформы"
        case .cron: "Расписание (cron)"
        case .mcp: "MCP-серверы"
        case .provider: "Провайдер модели"
        }
    }
}

/// The board as the scheme «Hermes — цельная плитка, вокруг наше»: fixed places, real flows as running dots.
struct OrganismBoard: View {
    let model: BoardModel
    var voice: VoiceModel?
    var phone: PhoneModel? = nil
    @State private var providerSetup = false

    static var size: CGSize { CGSize(width: 2850, height: pulseR.maxY + 30) }

    // Places (the scheme's layout, in board points). The Mac's trackpad and a Sidecar tablet scroll freely: the board
    // takes the room it needs for air between the columns, not more.
    /// «Сенсоры MacBook» — one block: the voice answer on top, the request side (chat input, microphone,
    /// analyzers) under a divider. What the laptop says first, then what it reads and hears.
    static let voiceR = CGRect(x: 30, y: 60, width: 660, height: EarsTile<EmptyView, EmptyView>.height)
    /// «Разговоры»: the channels (MacBook, Telegram, later the phone), each one Hermes session.
    static let conversationsR = CGRect(x: 780, y: 270, width: 440, height: ConversationsTile.height)
    /// The adapter (transport to the gateway). The box's versions sit at their parts: Hermes in Vera-core's badge, the
    /// ears and the voice both in «Сенсоры».
    static let adapter = CGRect(x: 1310, y: 270, width: 420, height: 330)
    static let hermes = CGRect(x: 1820, y: 60, width: 530, height: 980)
    /// Outside the app, to the right of Vera-core: the model's provider and the Telegram bot (Hermes' platform).
    static let provider = CGRect(x: 2440, y: 270, width: 380, height: 170)
    static let telegramR = CGRect(x: 2440, y: 560, width: 380, height: 120)
    /// «Пульс» — observation: the last requests in time and the journal's week, across the whole app.
    /// «iPhone» — the phone itself, above its conversation card (the first in «Разговоры»): what it says goes down into
    /// the card, what comes back goes up; Hermes drives its navigator from the right.
    static let phoneR = CGRect(x: 780, y: 30, width: 440, height: 232)
    static let pulseR = CGRect(x: 30, y: max(voiceR.maxY, conversationsR.maxY, hermes.maxY) + 90, width: 2320, height: 510)

    /// Each channel's path between the places, computed from the places themselves.
    /// Recognition is two stacked cards (GigaAM v3, T-one): the lines split before them and join after;
    /// the recognised phrase leaves for the conversation from the join.
    static func paths(tone: Bool) -> [FlowChannel: [CGPoint]] {
        // The phrase leaves the live engine's card for the join point (the other engine only compares, in the shadow).
        var p = paths
        let s = voiceR
        typealias E = EarsTile<EmptyView, EmptyView>
        let card = E.analyzer(tone ? 3 : 2).offsetBy(dx: s.minX, dy: s.minY)
        let giga = E.analyzer(2).offsetBy(dx: s.minX, dy: s.minY), toneCard = E.analyzer(3).offsetBy(dx: s.minX, dy: s.minY)
        let mergeX = s.minX + E.mergeX, splitY = (giga.midY + toneCard.midY) / 2
        p[.earsMerge] = [pt(card.maxX, card.midY), pt(mergeX, card.midY), pt(mergeX, splitY)]
        return p
    }
    private static func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    /// The recognised phrase goes from the recogniser card into the MacBook conversation.
    private static func phraseToChannel(from a: CGPoint) -> [CGPoint] {
        let mac = conversationsR.minY + ConversationsTile.macCard.minY, inX = conversationsR.minX + ConversationsTile.macCard.minX
        let gapX = (voiceR.maxX + conversationsR.minX) / 2 + 10
        return [a, p(gapX, a.y), p(gapX, mac + 120), p(inX, mac + 120)]
    }

    static var paths: [FlowChannel: [CGPoint]] {
        typealias E = EarsTile<EmptyView, EmptyView>
        typealias C = ConversationsTile
        let s = voiceR, a = adapter, h = hermes, v = voiceR, pr = provider, tg = telegramR, cv = conversationsR
        // The sound's path inside «Сенсоры MacBook»: the bus from the microphone feeds the VAD and both engine
        // cards in parallel; the VAD's silence asks Smart Turn; both tell the recognisers where the phrase begins
        // and ends.
        let busX = s.minX + E.pad + 9, micBottom = s.minY + E.mic.maxY
        let vad = E.analyzer(0).offsetBy(dx: s.minX, dy: s.minY), st = E.analyzer(1).offsetBy(dx: s.minX, dy: s.minY)
        // Recognition is two stacked cards: GigaAM v3 on top, T-one below. One line from the microphone splits
        // right before them and joins back right after; the joined point feeds the conversation.
        let giga = E.analyzer(2).offsetBy(dx: s.minX, dy: s.minY)
        let tone = E.analyzer(3).offsetBy(dx: s.minX, dy: s.minY)
        let splitY = (giga.midY + tone.midY) / 2
        let merge = p(s.minX + E.mergeX, splitY)
        // The tap on the recogniser's entry wire: both verdicts strike here, not the card.
        let valveX = busX + (giga.minX - busX) * 0.55
        let valveGapY = (vad.maxY + giga.minY) / 2
        let gapX = (s.maxX + cv.minX) / 2
        let chatY = s.minY + E.chatCard.midY
        // The answer section sits on top of «Сенсоры»: the conversation's answer lands in its middle.
        let mouthMidY = s.minY + 52 + E.mouthH / 2
        let mac = cv.minY + C.macCard.minY, macL = cv.minX + C.macCard.minX, macR = cv.minX + C.macCard.maxX
        let tgCard = cv.minY + C.telegramCard.midY, tgR = cv.minX + C.telegramCard.maxX
        let phY = cv.minY + C.phoneCard.minY, phR = cv.minX + C.phoneCard.maxX
        let gap2 = (cv.maxX + a.minX) / 2
        // Vera-core's parts, in its own frame: the gateway's left side, the brain's right side, the plugins and platforms.
        let gw = h.minY + 120, gwBack = h.minY + 145, plugins = h.minY + 428, platforms = h.minY + 560
        let pmid = (h.maxX + pr.minX) / 2
        return [
            // The chat's typed line and the recognised phrase go into the MacBook conversation…
            .windowsToAdapter: [p(s.minX + E.chatCard.maxX, chatY), p(gapX - 10, chatY), p(gapX - 10, mac + 90), p(macL, mac + 90)],
            .voiceToAdapter: phraseToChannel(from: merge),
            // …which submits to the adapter and gets the turn's events back; its answer goes up to the answer section.
            .channelToAdapter: [p(macR, mac + 60), p(gap2 - 8, mac + 60), p(gap2 - 8, a.minY + 130), p(a.minX, a.minY + 130)],
            .adapterToChannel: [p(a.minX, a.minY + 170), p(gap2 + 8, a.minY + 170), p(gap2 + 8, mac + 100), p(macR, mac + 100)],
            .adapterToVoice: [p(macL, mac + 30), p(gapX + 28, mac + 30), p(gapX + 28, mouthMidY), p(v.maxX, mouthMidY)],
            // Sound goes down the bus on the left to the VAD and the engine cards (CAM++ is off: no line to it).
            // The VAD's and the judge's verdicts land on the recogniser's wire itself — that point is the phrase
            // tap (the Listener, not a card): silence opens it, the verdict closes it or holds it open.
            .micToGate: [p(busX, micBottom), p(busX, vad.midY), p(vad.minX, vad.midY)],
            .micToEars: [p(busX, micBottom), p(busX, giga.midY), p(giga.minX, giga.midY),
                         p(busX, giga.midY), p(busX, tone.midY), p(tone.minX, tone.midY)],
            .turnJudge: [p(vad.maxX, vad.midY), p(st.minX, st.midY)],
            .gateToEars: [p(vad.midX, vad.maxY), p(vad.midX, valveGapY), p(valveX, valveGapY), p(valveX, giga.midY)],
            .judgeToEars: [p(st.midX, st.maxY), p(st.midX, valveGapY + 9), p(valveX, valveGapY + 9), p(valveX, giga.midY)],
            // The adapter talks to Vera-core's gateway over the WebSocket.
            .adapterToHermes: [p(a.maxX, a.minY + 40), p(h.minX - 46, a.minY + 40), p(h.minX - 46, gw), p(h.minX + 14, gw)],
            .hermesToAdapter: [p(h.minX + 14, gwBack), p(h.minX - 62, gwBack), p(h.minX - 62, a.minY + 66), p(a.maxX, a.minY + 66)],
            // Telegram is Hermes' platform: the bot's messages go straight into Vera-core's «Платформы».
            .telegram: [p(tg.minX, tg.midY), p(pmid, tg.midY), p(pmid, platforms), p(h.maxX - 14, platforms)],
            // The Telegram session's messages come to Vera through the adapter: a pulse line of that session makes it read
            // the new rows from the gateway (`session.transcript`) and pass them to the card in «Разговоры».
            .telegramToChannel: [p(a.minX + 40, a.maxY), p(a.minX + 40, tgCard), p(tgR, tgCard)],
            // The iPhone's session: the phone's message (through Vera's phone door) goes into the adapter, the
            // session's events come back to its card and on to the phone.
            .phoneToAdapter: [p(phR, phY + 50), p(a.minX, phY + 50)],
            .adapterToPhone: [p(a.minX, phY + 84), p(phR, phY + 84)],
            // The phone itself and its conversation card: the phrase goes up, the answer and state come down.
            .phoneToChannel: [p(cv.minX + 150, Self.phoneR.maxY), p(cv.minX + 150, cv.minY + C.phoneCard.minY)],
            .channelToPhone: [p(cv.minX + 300, cv.minY + C.phoneCard.minY), p(cv.minX + 300, Self.phoneR.maxY)],
            // Hermes' phone_route* tool (plugin vera-phone) → Vera → the phone's navigator, and the answer back.
            .hermesToPhone: [p(h.minX, Self.phoneR.minY + 60), p(Self.phoneR.maxX, Self.phoneR.minY + 60)],
            .phoneToHermes: [p(Self.phoneR.maxX, Self.phoneR.minY + 100), p(h.minX, Self.phoneR.minY + 100)],
            .hands: [p(h.minX + 278, h.minY + 190), p(h.minX + 265, h.minY + 202), p(h.minX + 260, h.minY + 230)],
            // Our plugin vera-pulse inside Vera-core writes the journal «Пульс» reads.
            .pluginToPulse: [p(h.minX + 14, plugins), p(h.minX - 12, plugins), p(h.minX - 12, pulseR.minY)],
            // The same line goes live: vera-pulse broadcasts it, the gateway carries it to the adapter, which sends it down.
            .adapterToPulse: [p(a.midX, a.maxY), p(a.midX, pulseR.minY)],
            .hermesToProvider: [p(h.maxX - 14, gw), p(pmid + 9, gw), p(pmid + 9, pr.minY + 65), p(pr.minX, pr.minY + 65)],
            .providerToHermes: [p(pr.minX, pr.minY + 100), p(pmid - 9, pr.minY + 100), p(pmid - 9, gwBack), p(h.maxX - 14, gwBack)],
        ]
    }
    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    var body: some View {
        ZStack(alignment: .topLeading) {

            // «Сенсоры MacBook»: the voice answer on top, the chat, the microphone and its analyzers below —
            // what the laptop says, reads and hears.
            place(Self.voiceR, .voice) {
                if let voice {
                    EarsTile(voice: voice, footer: voiceFooter,
                             versions: [model.boxVersions["sherpa-onnx"].map { "sherpa-onnx \($0)" }, model.boxVersions["модели ушей"]]
                                .compactMap { $0 }.joined(separator: " · "),
                             mouthVersions: [model.boxVersions["голос"], model.boxVersions["torch"].map { "torch \($0)" }]
                                .compactMap { $0 }.joined(separator: " · "),
                             chat: { ChatInputCard(chat: voice.chat, voice: voice) },
                             buttons: { voiceButtons(voice) })
                }
            }
            place(Self.conversationsR, .windows) { ConversationsTile(model: model, voice: voice, phone: phone) }
            place(Self.telegramR, .platforms) { TelegramTile(model: model) }
            if let phone { place(Self.phoneR, .windows) { PhoneDeviceTile(phone: phone) } }
            place(Self.adapter, .adapter) { AdapterTile(model: model, waiting: main?.transcript.pending.count ?? 0) }
            place(Self.pulseR, .pulse) { pulseTile }
            HermesTile(model: model, main: main).frame(width: Self.hermes.width, height: Self.hermes.height).offset(x: Self.hermes.minX, y: Self.hermes.minY)
            place(Self.provider, .provider) { providerTile }
            FlowLayer(model: model, tone: voice?.engine == .tone)
            lineLabels
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    // MARK: Tiles

    private func place<V: View>(_ r: CGRect, _ part: BoardPart, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(width: r.width, height: r.height, alignment: .topLeading)
            .offset(x: r.minX, y: r.minY)
    }

    private var main: ChatModel? { voice?.chat }

    private func ago(_ d: Date) -> String { Format.ago(d.timeIntervalSince1970, now: Date()) }

    private var voiceFooter: String {
        guard let v = voice else { return "" }
        var parts = ["фраз \(v.phrases)"]
        if let t = v.lastTiming { parts.append("последняя \(String(format: "%.1f", t.seconds)) с, дочитала за \(t.decodeMs) мс") }
        if v.interruptions > 0 { parts.append("перебили \(v.interruptions)") }
        if v.backgroundCount > 0 { parts.append("записано \(v.backgroundCount)") }
        if v.wakes > 0 { parts.append("«Привет, Вера» \(v.wakes)") }
        return parts.joined(separator: " · ")
    }

    static func db(_ v: Double) -> String { String(format: "%.0f", v).replacingOccurrences(of: "-", with: "−") }

    /// The voice's own switches, as buttons: talk now (⌘L), speak answers or not, which ears.
    private func voiceButtons(_ v: VoiceModel) -> some View {
        HStack(spacing: 5) {
            Button { Task { await v.toggle() } } label: {
                Label(v.mode == .direct ? "стоп" : "говорить", systemImage: v.mode == .direct ? "stop.fill" : "mic.fill")
                    .font(.mono(8.5, .semibold)).foregroundStyle(v.mode == .direct ? .black : Theme.human)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.human.opacity(v.mode == .direct ? 0.9 : 0.12), in: Capsule())
                    .overlay(Capsule().stroke(Theme.human.opacity(0.7), lineWidth: 1))
                    .fixedSize()
            }
            .buttonStyle(.plain).keyboardShortcut("l", modifiers: .command)
            .help("⌘L — разговор: каждая фраза уходит агенту. Ещё раз — закончить")
            Button { v.engine = v.engine == .gigaam ? .tone : .gigaam } label: {
                Text(v.engine.title).font(.mono(8.5, .semibold)).foregroundStyle(Theme.session)
                    .padding(.horizontal, 7).padding(.vertical, 3).overlay(Capsule().stroke(Theme.session.opacity(0.6), lineWidth: 1))
                    .fixedSize()
            }
            .buttonStyle(.plain).help("Движок распознавания — клик переключает GigaAM ↔ T-one")
        }
    }

    /// «Пульс» — our observation in one tile: the summary from the vera-pulse journal, the turn laid out in time
    /// («Ход») with the last turns, and the journal's raw lanes. It only watches.
    private var pulseTile: some View {
        let st = model.pulse.stats
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(Theme.vera).frame(width: 9, height: 9)
                Text("Пульс").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.95))
                Text("сессий \(st.sessions.count) · модель \(st.llmCalls) · ошибок \(st.llmErrors) · инструментов \(st.tools.values.reduce(0) { $0 + $1.calls }) · токены \(Format.count(st.tokensIn))→\(Format.count(st.tokensOut)) · последнее: \(model.pulse.events.last.map { "\($0.kind) \(Format.ago($0.ts, now: Date()))" } ?? "журнал пуст")")
                    .font(.mono(8.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                Spacer()
                Text(model.pulseLive ? "живьём через адаптер" : "из файла журнала")
                    .font(.mono(8)).foregroundStyle(.white.opacity(0.55))
                Text(Theme.Origin.plugin("vera-pulse").text).font(.mono(7.5, .bold)).tracking(0.8).foregroundStyle(Theme.vera)
                    .padding(.horizontal, 6).padding(.vertical, 2).overlay(Capsule().stroke(Theme.vera.opacity(0.5), lineWidth: 0.8))
            }
            RequestsStrip(model: model, mainSession: main?.sessionId).frame(height: 270)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            HStack(alignment: .top, spacing: 18) {
                TurnStrip(model: model, framed: false).frame(width: 1000)
                Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text("НЕДЕЛЯ · по часам").font(.mono(9, .bold)).tracking(1.2).foregroundStyle(Theme.vera)
                    ActivityHeat(grid: model.activity)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .partFrame(Theme.vera)
    }

    private var providerTile: some View {
        let s = model.pulse.stats
        let current = main?.transcript.model ?? s.models.max { $0.value < $1.value }?.key
        return Plate(title: "Провайдер", color: Theme.memory, origin: .hermes("ВНЕШНИЙ"), lines: [
            "\(current ?? "модель ещё не вызывалась") · запросов \(s.llmCalls) · ошибок \(s.llmErrors)\(s.llmCalls > 0 ? " · в среднем " + Format.ms(s.llmTotalMs / Double(s.llmCalls)) : "")",
        ] + planLine, footer: "", state: s.llmErrors > 0 && s.llmCalls == s.llmErrors ? Theme.bad : nil,
                     visual: AnyView(CallDots(calls: model.modelCalls)), visualHeight: 26,
                     button: ("⚙ настроить", { providerSetup.toggle() }))
            .sheet(isPresented: $providerSetup) { ProviderSetup(board: model, done: { providerSetup = false }) }
    }

    /// The plan's limits as Hermes reads them: «лимиты 5 ч 23% · неделя 8% · месяц 3%».
    private var planLine: [String] {
        guard let u = model.accountUsage else { return [] }
        if u.windows.isEmpty { return ["лимитов у \(u.provider) Hermes не знает"] }
        return ["лимиты " + u.windows.map { w in
            "\(AccountUsage.shortLabel(w.label)) \(w.usedPercent.map { "\(Int($0.rounded()))%" } ?? "—")"
        }.joined(separator: " · ")]
    }

    // MARK: Line labels

    private var lineLabels: some View {
        ZStack(alignment: .topLeading) {
            label("WebSocket", at: CGPoint(x: Self.hermes.minX - 54, y: Self.adapter.minY + 20))
            label("журнал", at: CGPoint(x: Self.hermes.minX - 12, y: Self.pulseR.minY - 22))
            label("бот", at: CGPoint(x: (Self.hermes.maxX + Self.provider.minX) / 2, y: Self.telegramR.midY - 12))
            label("модель", at: CGPoint(x: (Self.hermes.maxX + Self.provider.minX) / 2, y: Self.provider.minY + 30))
        }
    }

    private func label(_ text: String, at p: CGPoint) -> some View {
        Text(text).font(.mono(8)).foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 3).background(Theme.background)
            .fixedSize()
            .position(p)
    }
}

/// Lines of every channel and the dots of the traffic Vera actually saw on them.
struct FlowLayer: View {
    let model: BoardModel
    var tone = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !model.flows.active)) { ctx in
            Canvas { g, _ in
                let paths = OrganismBoard.paths(tone: tone)
                for (channel, pts) in paths {
                    let color = Self.color(channel)
                    var path = Path()
                    path.addLines(pts)
                    g.stroke(path, with: .color(color.opacity(0.35)), style: StrokeStyle(lineWidth: 1.4, dash: [5, 5]))
                    if let last = pts.last, let prev = pts.dropLast().last {
                        g.fill(Self.arrow(from: prev, to: last), with: .color(color.opacity(0.6)))
                    }
                }
                for pulse in model.flows.pulses {
                    guard let pts = paths[pulse.channel] else { continue }
                    let t = ctx.date.timeIntervalSince(pulse.at) / FlowMonitor.flight
                    guard t >= 0, t <= 1 else { continue }
                    let p = Self.point(on: pts, at: t)
                    let color = Self.color(pulse.channel)
                    g.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .color(color.opacity(0.25)))
                    g.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(color))
                }
            }
            .onChange(of: ctx.date) { _, _ in if model.flows.active { model.trimFlows() } }
        }
        .frame(width: OrganismBoard.size.width, height: OrganismBoard.size.height)
        .allowsHitTesting(false)
    }

    static func color(_ c: FlowChannel) -> Color {
        switch c {
        case .windowsToAdapter, .voiceToAdapter: Theme.vera
        case .channelToAdapter, .adapterToChannel, .earsMerge, .telegramToChannel, .phoneToAdapter, .adapterToPhone: Theme.session
        case .adapterToVoice: Theme.ok
        case .micToGate, .micToEars, .turnJudge, .voiceprint: Theme.human
        case .judgeToEars: Theme.human
        case .gateToEars: Theme.llm
        case .adapterToHermes, .hermesToAdapter: Theme.hermes
        case .adapterToPulse, .pluginToPulse: Theme.subagent
        case .telegram: Theme.hermes
        case .hermesToProvider, .providerToHermes: Theme.memory
        case .hands: Theme.tool
        case .phoneToChannel, .channelToPhone: Theme.vera
        case .hermesToPhone, .phoneToHermes: Theme.toolCall
        }
    }

    static func point(on pts: [CGPoint], at t: Double) -> CGPoint {
        let segs = zip(pts, pts.dropFirst()).map { ($0, $1, hypot($1.x - $0.x, $1.y - $0.y)) }
        let total = segs.reduce(0) { $0 + $1.2 }
        var left = total * t
        for (a, b, len) in segs {
            if left <= len, len > 0 {
                let k = left / len
                return CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
            }
            left -= len
        }
        return pts.last ?? .zero
    }

    static func arrow(from a: CGPoint, to b: CGPoint) -> Path {
        let ang = atan2(b.y - a.y, b.x - a.x)
        let l: CGFloat = 9, w: CGFloat = 4.5
        let base = CGPoint(x: b.x - l * cos(ang), y: b.y - l * sin(ang))
        var p = Path()
        p.move(to: b)
        p.addLine(to: CGPoint(x: base.x - w * sin(ang), y: base.y + w * cos(ang)))
        p.addLine(to: CGPoint(x: base.x + w * sin(ang), y: base.y - w * cos(ang)))
        p.closeSubpath()
        return p
    }
}

/// The scheme's legend, in the window's top-right corner over the board (`BoardCorner`), folds away: what a border and each line colour mean. Line colours come from
/// `FlowLayer.color`, so the legend cannot drift from the drawing.
struct BoardLegend: View {
    private static let lines: [(FlowChannel, String)] = [
        (.windowsToAdapter, "чат и фраза → разговор MacBook"),
        (.channelToAdapter, "разговор ↔ адаптер (запрос, события хода)"),
        (.adapterToVoice, "ответ разговора → голос"),
        (.micToGate, "звук микрофона → анализаторы (параллельно)"),
        (.gateToEars, "VAD ⇢ кран фразы: речь началась → открыть"),
        (.judgeToEars, "вердикт ⇢ кран: закрыть / держать до 1,2 с"),
        (.adapterToHermes, "адаптер ↔ шлюз Vera-core · бот Telegram → платформы"),
        (.hands, "вызов инструмента (руки)"),
        (.phoneToChannel, "iPhone ↔ его разговор (фраза вверх, ответ вниз)"),
        (.hermesToPhone, "Hermes ↔ навигатор iPhone (vera-phone)"),
        (.hermesToProvider, "запрос к модели ↔ провайдер"),
        (.adapterToPulse, "адаптер → «Пульс» живьём (vera-pulse через шлюз)"),
        (.pluginToPulse, "журнал на диске → «Пульс» (история, запасной путь)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ЛЕГЕНДА").font(.mono(9, .bold)).tracking(1.4).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4).stroke(Theme.vera.opacity(0.8), style: StrokeStyle(lineWidth: 1.4, dash: Theme.ourDash))
                    .frame(width: 30, height: 14)
                Text("наше — плитка пунктиром").font(.mono(8.5)).foregroundStyle(.white.opacity(0.6))
            }
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4).stroke(Theme.hermes.opacity(0.9), lineWidth: 1.4).frame(width: 30, height: 14)
                Text("подключённое — сплошной: Hermes, провайдер, Telegram").font(.mono(8.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            ForEach(Self.lines, id: \.0) { channel, text in
                HStack(spacing: 8) {
                    Canvas { g, size in
                        var p = Path(); p.move(to: CGPoint(x: 0, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width - 6, y: size.height / 2))
                        let c = FlowLayer.color(channel)
                        g.stroke(p, with: .color(c.opacity(0.6)), style: StrokeStyle(lineWidth: 1.4, dash: [5, 5]))
                        g.fill(FlowLayer.arrow(from: CGPoint(x: 0, y: size.height / 2), to: CGPoint(x: size.width, y: size.height / 2)), with: .color(c.opacity(0.8)))
                    }
                    .frame(width: 30, height: 10)
                    Text(text).font(.mono(8.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Theme.vera.opacity(0.25)).frame(width: 14, height: 14)
                    Circle().fill(Theme.vera).frame(width: 8, height: 8)
                }.frame(width: 30)
                Text("точка — настоящий трафик, бежит по линии").font(.mono(8.5)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.contourFill.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12), lineWidth: 1))
    }
}
