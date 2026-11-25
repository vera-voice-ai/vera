import SwiftUI
import HermesBridge
import VeraEars
import VeraMusic

/// «Голос» — Vera speaking: Silero in the box. On the left Vera's particle sphere (VeraKit, as in Vera Sphere Lab),
/// small: it rests, and while she speaks it follows her real voice; under it her state. On the right what she said, answers on/off and the speed.
struct MouthTile: View {
    @Bindable var voice: VoiceModel
    /// What speaks, from the box's lock: the voice model and torch.
    var versions = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AnswerSphere(voice: voice).frame(width: 96, height: 112)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(voice.speaking ? Theme.vera : Theme.vera.opacity(0.5)).frame(width: 9, height: 9)
                    Text("Ответ").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.95))
                        .fixedSize()
                    Spacer(minLength: 0)
                }
                Text("\(voice.voiceName)\(voice.interruptions > 0 ? " · перебили \(voice.interruptions)" : "")")
                    .font(.mono(8)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                if !versions.isEmpty {
                    Text("в коробке: \(versions)").font(.mono(7.5)).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                }
                answer
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Button { voice.speakReplies.toggle() } label: {
                        Label(voice.speakReplies ? "озвучка" : "без звука", systemImage: voice.speakReplies ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.mono(8.5, .semibold)).foregroundStyle(voice.speakReplies ? Theme.ok : .white.opacity(0.45))
                            .padding(.horizontal, 7).padding(.vertical, 2).overlay(Capsule().stroke(Theme.ok.opacity(0.6), lineWidth: 1))
                            .fixedSize()
                    }.buttonStyle(.plain).help("Озвучивать ответы агента")
                    Text("×\(String(format: "%.2f", voice.speed))").font(.mono(8.5)).foregroundStyle(.white.opacity(0.7)).fixedSize()
                    Slider(value: Binding(get: { voice.speed }, set: { voice.speed = ($0 * 20).rounded() / 20 }), in: 0.8 ... 1.5).controlSize(.mini)
                    if voice.speaking {
                        Button { voice.stopSpeaking() } label: {
                            Label("замолчать", systemImage: "stop.fill").font(.mono(8.5, .semibold)).foregroundStyle(Theme.vera)
                                .padding(.horizontal, 7).padding(.vertical, 2).overlay(Capsule().stroke(Theme.vera.opacity(0.7), lineWidth: 1))
                                .fixedSize()
                        }.buttonStyle(.plain).help("Замолчать: остановить озвучку ответа")
                    }
                }
            }
            Rectangle().fill(Theme.vera.opacity(0.85)).frame(width: 1.5).frame(maxHeight: .infinity)
            MusicPanel(music: voice.music).frame(width: 128)
            Rectangle().fill(Theme.vera.opacity(0.85)).frame(width: 1.5).frame(maxHeight: .infinity)
            BrowserPanel(browser: voice.browser).frame(width: 128)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.contourFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.vera.opacity(0.8), style: StrokeStyle(lineWidth: 1.6, dash: Theme.ourDash)))
    }

    /// The MacBook conversation's last answer, here where it is heard: what it answers, and the text as it is spoken —
    /// the said part bright, the rest dim (the text goes with the voice).
    @ViewBuilder private var answer: some View {
        let items = voice.chat.transcript.items
        let asked: String? = items.last(where: { if case .user = $0.kind { return true }; return false }).flatMap {
            if case .user(let s) = $0.kind { return s.replacingOccurrences(of: "🎙 ", with: "") }; return nil
        }
        let last = items.last(where: { if case .assistant = $0.kind { return true }; return false })
        if let last, case .assistant(let full, _) = last.kind {
            let said = voice.revealed[last.id]
            let bright = said ?? full
            let rest = (said != nil && full.hasPrefix(bright)) ? String(full.dropFirst(bright.count)) : ""
            if let asked { Text("на «\(asked)»").font(.mono(8.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1) }
            (Text(bright.replacingOccurrences(of: "\n", with: " ")).foregroundStyle(.white.opacity(0.92))
             + Text(rest.replacingOccurrences(of: "\n", with: " ")).foregroundStyle(.white.opacity(0.3)))
                .font(.system(size: 12.5)).lineLimit(2)
        } else {
            Text("ответов ещё не было").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
        }
    }
}

/// Vera's own music, right of the answer: the track and its format, previous / play / next, the loudness Vera sets
/// now, and the library window (the same library as the phone).
struct MusicPanel: View {
    let music: MacMusic
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "music.note").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.vera)
                Text("Музыка").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.95))
                    .fixedSize()
                Spacer(minLength: 0)
                Button { openWindow(id: "music") } label: {
                    Text("все").font(.mono(8, .semibold)).foregroundStyle(Theme.vera)
                        .padding(.horizontal, 6).padding(.vertical, 1).overlay(Capsule().stroke(Theme.vera.opacity(0.5), lineWidth: 0.8)).fixedSize()
                }.buttonStyle(.plain).help("Медиатека Веры: «Моё любимое», исполнители, альбомы — та же, что на iPhone")
            }
            if let c = music.current {
                ArtworkView(url: c.url, size: 52) { EmptyView() }
            }
            Text(music.current.map { "\($0.title)\($0.artist.isEmpty ? "" : " · \($0.artist)")" }
                 ?? (music.tracks.isEmpty ? "музыки ещё нет — Вера качает" : "\(music.tracks.count) треков · «Моё любимое»"))
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(music.current == nil ? 0.45 : 0.9)).lineLimit(2)
            if let f = music.current?.format { Text(f).font(.mono(7.5)).foregroundStyle(.white.opacity(0.42)).lineLimit(1) }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                button("backward.fill", "предыдущий") { music.previous() }
                button(music.playing ? "pause.fill" : "play.fill", music.playing ? "пауза" : "играть", big: true) { music.toggle() }
                button("forward.fill", "следующий") { music.next() }
            }
            .frame(maxWidth: .infinity)
            Text(music.playing ? "громкость \(Int((music.level * 100).rounded()))% — ведёт Вера" : "ждёт «Привет, Вера» 100% · слушает 15% · говорит 10%")
                .font(.mono(7.5)).foregroundStyle(.white.opacity(0.42)).lineLimit(2)
        }
        .help(music.problem ?? "Музыка Веры — та же медиатека, что на iPhone; громкость ведёт сама Вера")
    }

    private func button(_ icon: String, _ help: String, big: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: big ? 16 : 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                .frame(width: big ? 30 : 22, height: 24)
        }.buttonStyle(.plain).help(help)
    }
}

/// Vera's browser, right of the music: open or closed, its tabs, and the three buttons — open (bring forward),
/// hide, close. Hermes works in this window; the owner finishes what is his (CAPTCHA, «Откликнуться»).
struct BrowserPanel: View {
    let browser: MacBrowser
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "globe").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.vera)
                Text("Браузер").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.95))
                Spacer(minLength: 0)
                Circle().fill(browser.running ? Theme.ok : .white.opacity(0.25)).frame(width: 6, height: 6)
            }
            Text(browser.running ? "открыт · вкладок \(pages.count)" : "закрыт · вход на сайты сохранён")
                .font(.mono(8)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            if browser.running {
                ForEach(pages.prefix(3)) { t in
                    Text(t.title.isEmpty ? t.url : t.title).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }
            } else {
                Text("Вера заполняет здесь формы, капчу и последнюю кнопку жмёшь ты").font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45)).lineLimit(3)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                button(browser.running ? "macwindow.on.rectangle" : "play.fill", browser.running ? "показать" : "открыть", big: true) { "show" }
                button("minus", "свернуть") { "hide" }.disabled(!browser.running)
                button("xmark", "закрыть") { "close" }.disabled(!browser.running)
            }
            .frame(maxWidth: .infinity)
            Text("Вере: «открой / спрячь / закрой браузер»").font(.mono(7.5)).foregroundStyle(.white.opacity(0.42)).lineLimit(2)
        }
        .help("Браузер Веры: свой профиль (вход сохраняется), цвета Веры; Hermes работает в нём через порт 9333 только на этом Маке")
    }

    private var pages: [MacBrowser.Tab] { browser.tabs.filter { !$0.url.hasPrefix("devtools") } }

    private func button(_ icon: String, _ help: String, big: Bool = false, _ action: @escaping () -> String) -> some View {
        Button { let a = action(); Task { _ = await browser.act(a) } } label: {
            Image(systemName: icon).font(.system(size: big ? 15 : 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                .frame(width: big ? 30 : 22, height: 24)
        }.buttonStyle(.plain).help(help)
    }
}

/// The sphere of the «Ответ» tile (VeraKit), small: it rests, and while Vera speaks it follows the loudness of her real
/// voice now (the peaks of the Silero sentence sounding, as the ring reads them). Her state is written under it.
struct AnswerSphere: View {
    let voice: VoiceModel
    var body: some View {
        let _ = voice.liveTick
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !voice.speaking)) { ctx in
            let now = ctx.date.timeIntervalSince1970
            let energy = voice.mouthTrace.lazy.compactMap { clip -> Float? in
                guard now >= clip.start, now <= clip.start + clip.seconds, !clip.peaks.isEmpty else { return nil }
                return clip.peaks[min(clip.peaks.count - 1, Int((now - clip.start) / clip.seconds * Double(clip.peaks.count)))]
            }.first ?? 0
            VStack(spacing: 0) {
                ParticleSphere(speaking: voice.speaking, voiceEnergy: Double(min(1, energy * 1.6)), particles: 830, dotScale: 3)
                Text(!voice.speakReplies ? "без звука" : voice.speaking ? "говорю" : voice.chat.busy ? "думаю" : voice.listening ? "слушаю" : "молчу")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(voice.speaking ? Theme.vera : .white.opacity(0.55))
            }
        }
    }
}

/// The ring: 72 bars around a circle — the last 1.4 s of Vera's real voice outline, newest at the top, going round.
/// Silent when she is silent; the centre says «говорю», «молчу» or «без звука».
struct VoiceRing: View {
    let voice: VoiceModel
    var body: some View {
        let _ = voice.liveTick
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !voice.speaking)) { ctx in
            Canvas { g, size in
                let now = ctx.date.timeIntervalSince1970
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let inner = size.width * 0.30, outerMax = size.width * 0.49
                g.stroke(Path(ellipseIn: CGRect(x: c.x - outerMax, y: c.y - outerMax, width: outerMax * 2, height: outerMax * 2)),
                         with: .color(Theme.vera.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                let bars = 72, window = 1.4
                for k in 0..<bars {
                    let t = now - window * Double(k) / Double(bars)
                    var v: Float = 0
                    for clip in voice.mouthTrace where t >= clip.start && t <= clip.start + clip.seconds {
                        let idx = Int((t - clip.start) / clip.seconds * Double(clip.peaks.count))
                        if idx >= 0 && idx < clip.peaks.count { v = clip.peaks[idx] }
                    }
                    let a = -Double.pi / 2 + Double(k) / Double(bars) * 2 * .pi
                    let len = 3 + CGFloat(min(1, v * 1.6)) * (outerMax - inner - 4)
                    var p = Path()
                    p.move(to: CGPoint(x: c.x + inner * cos(a), y: c.y + inner * sin(a)))
                    p.addLine(to: CGPoint(x: c.x + (inner + len) * cos(a), y: c.y + (inner + len) * sin(a)))
                    g.stroke(p, with: .color(Theme.vera.opacity(v > 0 ? 0.95 : 0.25)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                }
                g.fill(Path(ellipseIn: CGRect(x: c.x - inner + 4, y: c.y - inner + 4, width: (inner - 4) * 2, height: (inner - 4) * 2)),
                       with: .color(Theme.background))
                g.stroke(Path(ellipseIn: CGRect(x: c.x - inner + 4, y: c.y - inner + 4, width: (inner - 4) * 2, height: (inner - 4) * 2)),
                         with: .color(Theme.vera.opacity(voice.speaking ? 0.9 : 0.4)), lineWidth: 1.6)
                let label = !voice.speakReplies ? "без звука" : (voice.speaking ? "говорю" : "молчу")
                g.draw(Text(label).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(voice.speaking ? Theme.vera : .white.opacity(0.55)), at: c)
            }
        }
    }
}

/// «Сенсоры MacBook» — everything the laptop hears and reads, as Vera 2's «Органы чувств»: on top the voice answer
/// (what Vera says — the ring and the text as it is spoken), under a divider the request side: the chat (typing goes
/// into the main conversation), then the microphone (a round button for background listening, echo cancellation,
/// level against the threshold, the live spectrogram), then the analyzers as cards in a column — Silero VAD
/// (the fast path), Smart Turn (asks in the background), recognition as two stacked cards (GigaAM v3 on top, T-one
/// below; click a card to make it live — both read the same audio, only live's phrase goes to the adapter),
/// CAM++ (off) — each with its latest output and numbers. Sound reaches them in parallel along the bus on the left
/// (the scheme's lines). Positions are fixed: the scheme's lines run to these cards.
struct EarsTile<Chat: View, Buttons: View>: View {
    let voice: VoiceModel
    let footer: String
    /// What hears, from the box's lock: sherpa-onnx and the models.
    var versions = ""
    /// What speaks, from the box's lock: the voice model and torch. Shown in the top «ответ» section.
    var mouthVersions = ""
    @ViewBuilder var chat: () -> Chat
    @ViewBuilder var buttons: () -> Buttons

    /// Card frames inside the tile (the scheme adds the tile's origin for its lines). The top «ответ» section holds
    /// the voice answer; under the divider the request side: two inputs on top — the
    /// microphone and the input line. Under them the analyzers in the order the sound goes through them: the VAD and,
    /// on its silence, Smart Turn side by side; recognition as two stacked engine cards (GigaAM v3 on top, T-one
    /// below) with a shared strip between them (what is heard now + the shadow-compare toggle), fed by the
    /// microphone in parallel and told by both where the phrase begins and ends; CAM++ (off, no line).
    static var pad: CGFloat { 22 }
    static var width: CGFloat { 660 }
    static var inner: CGFloat { width - 2 * pad }
    /// The top «ответ» section (the voice answer) and the divider under it; the request side starts at micTop.
    static var mouthH: CGFloat { 190 }
    static var micTop: CGFloat { 52 + mouthH + 18 }
    static var dividerY: CGFloat { 52 + mouthH + 8 }
    static var mic: CGRect { CGRect(x: pad, y: micTop, width: (inner - 16) / 2, height: 176) }
    static var chatCard: CGRect { CGRect(x: mic.maxX + 16, y: micTop, width: (inner - 16) / 2, height: 176) }
    static var analyzerX: CGFloat { pad + 18 }
    static var analyzerW: CGFloat { inner - 18 }
    /// Every analyzer card shares one right edge; the gutter to its right carries the engines' join line.
    static var cardW: CGFloat { analyzerW - 30 }
    static var mergeX: CGFloat { analyzerX + cardW + 15 }
    static var engineH: CGFloat { 44 }
    static var stripH: CGFloat { 40 }
    static var stripGap: CGFloat { 6 }
    /// 0 — VAD, 1 — Smart Turn, 2 — GigaAM v3, 3 — T-one, 4 — CAM++.
    /// The shared strip (heard now + compare toggle) sits between the engine cards: see strip().
    static func analyzer(_ i: Int) -> CGRect {
        let y0 = mic.maxY + 40
        let half = (cardW - 14) / 2
        switch i {
        case 0: return CGRect(x: analyzerX, y: y0, width: half, height: 54)
        case 1: return CGRect(x: analyzerX + half + 14, y: y0, width: half, height: 54)
        // The gap above the engines carries the VAD's and Smart Turn's verdict lines to the phrase tap.
        case 2: return CGRect(x: analyzerX, y: y0 + 54 + 30, width: cardW, height: engineH)
        case 3: return CGRect(x: analyzerX, y: strip().maxY + stripGap, width: cardW, height: engineH)
        default: return CGRect(x: analyzerX, y: analyzer(3).maxY + 14, width: cardW, height: 50)
        }
    }
    /// The shared strip between the engine cards: what is heard right now + the shadow-compare toggle.
    static func strip() -> CGRect {
        let top = analyzer(2)
        return CGRect(x: top.minX, y: top.maxY + stripGap, width: top.width, height: stripH)
    }
    /// The tile's height: the last analyzer, the versions line and the bottom padding.
    static var height: CGFloat { analyzer(4).maxY + 18 + pad }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 8) {
                Circle().fill(voice.listening ? Theme.vera : Theme.vera.opacity(0.5)).frame(width: 9, height: 9)
                Text("Сенсоры MacBook").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.95))
                Text("что ноутбук слышит и читает").font(.mono(8.5)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                buttons()
                Text(Theme.Origin.ours.text).font(.mono(7.5, .bold)).tracking(0.8).foregroundStyle(Theme.Origin.ours.color)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(Capsule().stroke(Theme.Origin.ours.color.opacity(0.5), lineWidth: 0.8))
            }
            .frame(width: Self.inner).offset(x: Self.pad, y: 16)
            MouthTile(voice: voice, versions: mouthVersions)
                .frame(width: Self.inner, height: Self.mouthH, alignment: .topLeading)
                .offset(x: Self.pad, y: 52)
            Rectangle().fill(.white.opacity(0.35)).frame(width: Self.inner, height: 1)
                .offset(x: Self.pad, y: Self.dividerY)
            micCard.frame(width: Self.mic.width, height: Self.mic.height).offset(x: Self.mic.minX, y: Self.mic.minY)
            chat().frame(width: Self.chatCard.width, height: Self.chatCard.height).offset(x: Self.chatCard.minX, y: Self.chatCard.minY)
            Text("АНАЛИЗАТОРЫ · по пути звука").font(.mono(8, .bold)).tracking(1.2).foregroundStyle(Theme.session.opacity(0.85))
                .offset(x: Self.analyzerX, y: Self.analyzer(0).minY - 20)
            card(0, "Silero VAD", "речь / тишина", active: voice.listening,
                 main: voice.hearing ? "речь" : (voice.listening ? "тишина" : "микрофон выключен"),
                 numbers: "фраз \(voice.phrases) · тишина \(voice.smartTurn ? "0,3" : "0,5") с → конец?", color: Theme.llm)
            card(1, "Smart Turn", "фраза закончена?", active: voice.listening && voice.smartTurn,
                 main: !voice.smartTurn ? "нет в сборке — конец по тишине 0,5 с"
                     : voice.holding ? "ждёт продолжения…"
                     : voice.lastTurn.map { $0.finished ? "закончена · \(String(format: "%.2f", $0.probability))" : "не закончена · \(String(format: "%.2f", $0.probability))" } ?? "ждёт тишину",
                 numbers: "спрашивается на тишине · ждёт до 1,2 с", color: Theme.human)
            engineCard(.gigaam, 2)
            engineStrip
            engineCard(.tone, 3)
            // CAM++ is in the box but off: no sound reaches it (no line on the scheme), Hermes gets no speaker notes.
            card(4, "CAM++", "определитель твоего голоса", active: false,
                 main: EarsSession.identifiesSpeakers ? speakerLine : "выключен — включим позже",
                 numbers: voice.speakersReady ? "модель в коробке · 3D-Speaker · линии нет — звук к нему не идёт" : "нет в сборке",
                 color: Theme.vera, dim: !EarsSession.identifiesSpeakers)
            if !versions.isEmpty {
                Text("в коробке: \(versions)").font(.mono(7.5)).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                    .frame(width: Self.inner, alignment: .leading)
                    .offset(x: Self.pad, y: Self.analyzer(4).maxY + 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.contourFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.vera.opacity(0.8), style: StrokeStyle(lineWidth: 1.6, dash: Theme.ourDash)))
    }

    /// One engine as its own card: GigaAM v3 on top, T-one below. Clicking a card makes it the live engine;
    /// both read the same sound, only the live one's phrase goes to the adapter.
    private func engineCard(_ e: EarsEngine, _ i: Int) -> some View {
        let r = Self.analyzer(i)
        let on = voice.engine == e
        let s = voice.comparison[e.rawValue]
        return Button { voice.engine = e } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text((on ? "● " : "○ ") + e.title).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(on ? 0.95 : 0.55))
                    Text(e == .gigaam ? "с пунктуацией · перечитывает фразу" : "потоковый · без пунктуации")
                        .font(.mono(7.5)).foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    Circle().fill(voice.listening && on ? Theme.ok : .white.opacity(0.25)).frame(width: 6, height: 6)
                }
                Text(s.map { "фраз \($0.phrases) · первые слова \($0.avgFirstPartialMs.map { "\($0) мс" } ?? "—") · дочитывает \($0.avgDecodeMs) мс" } ?? "\(e.title): ещё не слушала")
                    .font(.mono(7.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(width: r.width, height: r.height, alignment: .topLeading)
            .background(.white.opacity(on ? 0.05 : 0.025), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.session.opacity(on ? 0.9 : 0.35), lineWidth: on ? 1.6 : 1))
        }
        .buttonStyle(.plain)
        .help((e == .gigaam ? "GigaAM v3" : "T-one") + " — клик: слушать этим движком")
        .offset(x: r.minX, y: r.minY)
    }

    /// What is heard right now and the shadow-compare toggle, shared by both engine cards.
    private var engineStrip: some View {
        let r = Self.strip()
        let other: EarsEngine = voice.engine == .gigaam ? .tone : .gigaam
        let os = voice.comparison[other.rawValue]
        return VStack(alignment: .leading, spacing: 3) {
            Text(voice.partial.isEmpty ? (voice.lastHeard.map { "«\($0)»" } ?? (voice.listening ? "ждёт речь" : "микрофон выключен")) : "«\(voice.partial)»")
                .font(.system(size: 12)).foregroundStyle(voice.listening ? Theme.session : .white.opacity(0.45)).lineLimit(1)
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { voice.compareEngines }, set: { voice.compareEngines = $0 })) {
                    Text("сравнивать с \(other.title) в тени").font(.system(size: 10, weight: .medium))
                }
                .toggleStyle(.checkbox).controlSize(.small)
                Text(voice.compareEngines
                    ? (os.map { "\(other.title): фраз \($0.phrases) · дочитывает \($0.avgDecodeMs) мс — только журнал" } ?? "тот же звук, только счётчики в журнал")
                    : "выкл — работает один движок")
                    .font(.mono(7.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(width: r.width, height: r.height, alignment: .topLeading)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.session.opacity(0.22), lineWidth: 1))
        .offset(x: r.minX, y: r.minY)
    }

    /// The microphone: two lanes on one stream — «Запись» (always-open, writes everything, never sends) and «Вера»
    /// (inactive: waits for «Привет, Вера»; active: every phrase goes to the agent), each with its own switch.
    private var micCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("Микрофон").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
                Circle().fill(voice.echoCancelling == true ? Theme.ok : Theme.warn).frame(width: 6, height: 6)
                Text(!voice.listening ? "" : voice.speaking ? "не слушаю — Вера говорит" : "обычный вход · звук не трогает").font(.mono(7.5))
                    .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                Spacer(minLength: 4)
                Text(state).font(.mono(7.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            lane(on: voice.background, icon: "record.circle", color: Theme.human, title: "Запись",
                 line: !voice.background ? "выключена" : voice.listening ? "пишет всё · записано \(voice.backgroundCount)" : "включена · микрофон ещё закрыт",
                 detail: voice.lastBackground.map { "«\($0.text)»" } ?? (voice.background ? "агенту не уходит" : "микрофон открыт только в разговоре"),
                 help: "Запись: микрофон открыт всегда, всё распознанное — в журнал фона, агенту не уходит. Вкл / выкл") {
                Task { await voice.toggleBackground() }
            }
            lane(on: voice.active, icon: "sparkles", color: Theme.vera, title: "Вера",
                 line: voice.active ? (voice.woke ? "активна по «Привет, Вера» · уходит всё" : "активна · уходит всё")
                     : (voice.listening ? "ждёт «Привет, Вера»" : "микрофон закрыт"),
                 detail: "«Привет, Вера» \(voice.wakes) · через \(Int(VoiceModel.wakeIdle)) с тишины — ждёт снова",
                 help: "Вера: активна — каждая фраза уходит агенту; неактивна — ждёт «Привет, Вера, …». ⌘L") {
                Task { await voice.toggle() }
            }
            MicSpectrogram(voice: voice).frame(maxHeight: .infinity)
            ThresholdLine(voice: voice)
        }
        .padding(10)
        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.human.opacity(0.5), lineWidth: 1))
    }

    private func lane(on: Bool, icon: String, color: Color, title: String, line: String, detail: String, help: String,
                      action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: action) {
                ZStack {
                    Circle().fill(on ? color.opacity(0.85) : .white.opacity(0.06)).frame(width: 26, height: 26)
                    Circle().stroke(color.opacity(0.7), lineWidth: 1).frame(width: 26, height: 26)
                    Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? .black : .white.opacity(0.55))
                }
            }.buttonStyle(.plain).help(help)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(on ? color : .white.opacity(0.7))
                    Text(line).font(.mono(8.5)).foregroundStyle(.white.opacity(on ? 0.8 : 0.5)).lineLimit(1)
                }
                Text(detail).font(.mono(7.5)).foregroundStyle(.white.opacity(0.42)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.white.opacity(on ? 0.04 : 0.015), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(on ? 0.5 : 0.2), style: StrokeStyle(lineWidth: 1, dash: Theme.ourDash)))
    }

    private var speakerLine: String {
        guard let s = voice.lastSpeaker else { return voice.voiceBook.people.isEmpty ? "твой голос ещё не записан" : "ждёт фразу" }
        return "\(s.name.map { $0 == "владелец" ? "ты" : $0 } ?? "голос не узнан") · \(String(format: "%.2f", s.cosine))"
    }

    private var state: String {
        voice.listening ? "открыт · \(OrganismBoard.db(Loudness.decibels(voice.level))) дБ" : "закрыт"
    }

    private func card(_ i: Int, _ name: String, _ kind: String, active: Bool, main: String, numbers: String, color: Color, dim: Bool = false) -> some View {
        let r = Self.analyzer(i)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(dim ? 0.5 : 0.92))
                Text(kind).font(.mono(7.5)).foregroundStyle(.white.opacity(0.4))
                Spacer()
                Circle().fill(active ? Theme.ok : .white.opacity(0.25)).frame(width: 6, height: 6)
            }
            Text(main).font(.system(size: 11)).foregroundStyle(dim ? .white.opacity(0.4) : color).lineLimit(1)
            Text(numbers).font(.mono(7.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(width: r.width, height: r.height, alignment: .topLeading)
        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(color.opacity(dim ? 0.25 : 0.6), lineWidth: 1))
        .offset(x: r.minX, y: r.minY)
    }
}

/// The threshold of background listening as one line: level now (pink), the threshold (white), the last phrase
/// (green), and the slider to move the threshold.
struct ThresholdLine: View {
    @Bindable var voice: VoiceModel
    private static let range: ClosedRange<Double> = -70 ... -15
    var body: some View {
        HStack(spacing: 6) {
            Text("порог").font(.mono(8)).foregroundStyle(.white.opacity(0.5))
            ZStack {
                Canvas { g, size in
                    func x(_ db: Double) -> CGFloat {
                        CGFloat((min(max(db, Self.range.lowerBound), Self.range.upperBound) - Self.range.lowerBound)
                                / (Self.range.upperBound - Self.range.lowerBound)) * size.width
                    }
                    let y = size.height / 2 - 2
                    g.fill(Path(roundedRect: CGRect(x: 0, y: y, width: size.width, height: 4), cornerRadius: 2), with: .color(.white.opacity(0.08)))
                    if voice.listening {
                        let lv = Loudness.decibels(voice.level)
                        g.fill(Path(roundedRect: CGRect(x: 0, y: y, width: x(lv), height: 4), cornerRadius: 2),
                               with: .color(lv >= voice.thresholdDB ? Theme.human : Theme.human.opacity(0.4)))
                    }
                    if let l = voice.lastLoudness { g.fill(Path(CGRect(x: x(l.db) - 1, y: y - 4, width: 2, height: 12)), with: .color(Theme.ok)) }
                }
                Slider(value: Binding(get: { voice.thresholdDB }, set: { voice.thresholdDB = $0.rounded() }), in: Self.range)
                    .controlSize(.mini).opacity(0.9)
            }
            Text("\(OrganismBoard.db(voice.thresholdDB)) дБ").font(.mono(8)).foregroundStyle(.white.opacity(0.7)).frame(width: 42, alignment: .trailing)
        }
        .frame(height: 18)
        .help("Порог перебивания: громче него голос перебивает Веру, пока она говорит в режиме ожидания. Розовое — уровень сейчас, зелёная черта — громкость последней фразы, ползунок — порог")
    }
}
