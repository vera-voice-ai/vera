import PhoneWire
import SwiftUI

/// The scheme on the phone, live — the same idea as the Mac's board, with what the phone has: two devices. The iPhone
/// (ours, pink dashed): its senses (microphone, Silero VAD, GigaAM), its voice, the map, the music, the activity log
/// for self-analysis and its link. The Mac — a separate
/// device, reachable or not — where Vera and her core Hermes run. Real flows run along the lines.
struct SchemeScreen: View {
    let link: Link
    let talk: Conversation
    let nav: Navigator
    let music: Music
    let sensors: SensorLog
    let live: LiveVera

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Device(title: "iPhone", icon: "iphone", status: ("этот телефон", Palette.ok)) {
                    HStack(alignment: .top, spacing: 10) {
                        PhoneSensors(talk: talk).frame(maxWidth: .infinity)
                        PhoneVoice(talk: talk).frame(maxWidth: .infinity)
                    }
                    HStack(spacing: 10) {
                        Connector(label: "фраза", down: talk.phraseAt, color: Palette.human)
                        Connector(label: "ответ", up: talk.sentenceAt, color: Palette.ok)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        PhoneMapPart(nav: nav).frame(maxWidth: .infinity)
                        PhoneMusicPart(music: music).frame(maxWidth: .infinity)
                    }
                    PhoneActivityLog(sensors: sensors)
                    PhoneIsland(live: live)
                    PhoneLink(link: link)
                }
                Connector(label: "туннель · \(link.url?.host() ?? "—")", down: link.sentAt, up: link.receivedAt, color: Palette.vera)
                Device(title: "Mac", icon: "laptopcomputer", status: macStatus) {
                    MacVera(link: link)
                    Connector(label: "WebSocket · шлюз", down: link.sentAt, up: link.receivedAt, color: Palette.hermes)
                    MacHermes(link: link)
                }
                .opacity(link.phase == .online ? 1 : 0.55)
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 20)
        }
        .background(Palette.background)
    }

    private var macStatus: (String, Color) {
        switch link.phase {
        case .online: ("доступен\(link.rttMs.map { " · \($0) мс" } ?? "")", Palette.ok)
        case .connecting: ("подключаюсь", .yellow)
        case .offline: ("недоступен", .orange)
        case .unpaired: ("не сопряжён", .gray)
        }
    }
}

/// A device on the scheme: a solid neutral frame (hardware), its name, an icon and whether it is there.
struct Device<Content: View>: View {
    let title: String
    let icon: String
    let status: (String, Color)
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink.opacity(0.8))
                Text(title).font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Circle().fill(status.1).frame(width: 7, height: 7)
                Text(status.0).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(status.1)
            }
            content
        }
        .padding(10)
        .background(Palette.ink.opacity(0.025), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.ink.opacity(0.22), lineWidth: 1.2))
    }
}

/// A part inside a device: ours dashed in its colour, connected code (Hermes) solid.
struct Part<Content: View>: View {
    let title: String
    let tag: String
    let color: Color
    var ours = true
    var state: (String, Color)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1).fixedSize().layoutPriority(2)
                Text(tag).font(.system(size: 7.5, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.4)).lineLimit(1)
                Spacer(minLength: 0)
                if let state {
                    Text(state.0).font(.system(size: 8.5, weight: .semibold, design: .monospaced)).foregroundStyle(state.1).lineLimit(1)
                }
            }
            content
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(color.opacity(0.68), style: StrokeStyle(lineWidth: 1.2, dash: ours ? [6, 4] : [])))
    }
}

struct Mini: View {
    let title: String
    let value: String
    let color: Color
    var foot: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 7.5, weight: .bold, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.5))
            Text(value).font(.system(size: 11)).foregroundStyle(color).lineLimit(2)
            if !foot.isEmpty { Text(foot).font(.system(size: 7.5, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.42)).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(Palette.ink.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct PhoneSensors: View {
    let talk: Conversation

    var body: some View {
        Part(title: "Сенсоры", tag: "iphone/ears", color: Palette.vera, state: state) {
            Spectrogram(columns: talk.columns).frame(height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
            Mini(title: "VAD · Silero", value: talk.vadOn ? "речь" : (talk.on ? (talk.paused ? "тишина · жду «Привет, Вера»" : "тишина") : "—"),
                 color: talk.vadOn ? Palette.human : Palette.ink.opacity(0.45), foot: "фраз \(talk.phrases)")
            Mini(title: "GigaAM v3", value: talk.partial.isEmpty ? (talk.last?.text ?? "—") : talk.partial,
                 color: talk.partial.isEmpty ? Palette.ink.opacity(0.85) : Palette.human,
                 foot: talk.partialMs.map { "читает · \($0) мс" } ?? talk.last.map { String(format: "%.1f с → %d мс", $0.seconds, $0.ms) } ?? "на телефоне")
        }
    }

    private var state: (String, Color)? {
        guard talk.on else { return ("выкл", Palette.ink.opacity(0.4)) }
        if talk.paused { return ("жду «Привет, Вера»", Palette.vera.opacity(0.6)) }
        return talk.vadOn ? ("слышу", Palette.human) : ("слушаю", Palette.vera)
    }
}

/// Vera's voice on the phone, drawn as on the Mac: a ring of 72 rays — what sounded in the last 1.4 s — around a circle
/// that says whether she speaks.
struct PhoneVoice: View {
    let talk: Conversation

    var body: some View {
        Part(title: "Голос", tag: "iphone/voice", color: Palette.vera, state: talk.stage == .speaking ? ("говорю", Palette.vera) : nil) {
            VoiceRingMac(trace: talk.voiceTrace, speaking: talk.stage == .speaking)
                .frame(maxWidth: .infinity).frame(height: 118)
            Text(talk.saying.isEmpty ? (talk.lastAnswer ?? "—") : talk.saying)
                .font(.system(size: 10.5)).foregroundStyle(Palette.ink.opacity(talk.saying.isEmpty ? 0.5 : 0.9)).lineLimit(2)
            Text("\(Mouth.voiceName) · ×\(String(format: "%g", talk.voiceSpeed))\(talk.tts.map { String(format: " · %d мс до звука · %.1f с", $0.latencyMs, $0.seconds) } ?? "")").font(.system(size: 7.5, design: .monospaced))
                .foregroundStyle(Palette.ink.opacity(0.42)).lineLimit(1)
        }
    }
}

struct VoiceRingMac: View {
    let trace: [VoiceClip]
    let speaking: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !speaking)) { ctx in
            Canvas { g, size in
                let now = ctx.date.timeIntervalSince1970
                let side = min(size.width, size.height)
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let inner = side * 0.30, outerMax = side * 0.49
                g.stroke(Path(ellipseIn: CGRect(x: c.x - outerMax, y: c.y - outerMax, width: outerMax * 2, height: outerMax * 2)),
                         with: .color(Palette.vera.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                let bars = 72, window = 1.4
                for k in 0..<bars {
                    let t = now - window * Double(k) / Double(bars)
                    var v: Float = 0
                    for clip in trace {
                        let s = clip.start.timeIntervalSince1970
                        guard t >= s, t <= s + clip.seconds, !clip.peaks.isEmpty else { continue }
                        let idx = Int((t - s) / clip.seconds * Double(clip.peaks.count))
                        if idx >= 0 && idx < clip.peaks.count { v = clip.peaks[idx] }
                    }
                    let a = -Double.pi / 2 + Double(k) / Double(bars) * 2 * .pi
                    let len = 3 + CGFloat(min(1, v * 1.6)) * (outerMax - inner - 4)
                    var p = Path()
                    p.move(to: CGPoint(x: c.x + inner * cos(a), y: c.y + inner * sin(a)))
                    p.addLine(to: CGPoint(x: c.x + (inner + len) * cos(a), y: c.y + (inner + len) * sin(a)))
                    g.stroke(p, with: .color(Palette.vera.opacity(v > 0 ? 0.95 : 0.25)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                let r = inner - 4
                g.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(Palette.background))
                g.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                         with: .color(Palette.vera.opacity(speaking ? 0.9 : 0.4)), lineWidth: 1.4)
                g.draw(Text(speaking ? "говорю" : "молчу").font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(speaking ? Palette.vera : Palette.ink.opacity(0.55)), at: c)
            }
        }
    }
}

struct PhoneLink: View {
    let link: Link

    var body: some View {
        Part(title: "Связь", tag: "iphone/link", color: Palette.vera, state: state) {
            Text(foot).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.55)).lineLimit(1)
        }
    }

    private var state: (String, Color) {
        switch link.phase {
        case .online: (link.rttMs.map { "\($0) мс" } ?? "на связи", Palette.ok)
        case .connecting: ("подключаюсь", .yellow)
        case .offline: ("нет связи", .orange)
        case .unpaired: ("не сопряжён", .gray)
        }
    }

    private var foot: String {
        var p = ["WebSocket · токен в Keychain"]
        if let s = link.sentAt { p.append("↑ \(ago(s))") }
        if let r = link.receivedAt { p.append("↓ \(ago(r))") }
        return p.joined(separator: " · ")
    }
}

/// Vera on the Mac, as the phone sees her: the door for phones and the phone's own Hermes session.
struct MacVera: View {
    let link: Link

    var body: some View {
        Part(title: "Вера", tag: "дверь 127.0.0.1:8765", color: Palette.vera,
             state: link.phase == .online ? ("принимает", Palette.ok) : ("не отвечает", .orange)) {
            Text("сессия «iPhone» · \(link.items.filter { $0.role == .user }.count) реплик в ленте")
                .font(.system(size: 8.5, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.55)).lineLimit(1)
        }
    }
}

/// Hermes — one block (connected code, solid): the model, what it does now, the last steps of the phone's session.
struct MacHermes: View {
    let link: Link

    var body: some View {
        let h = link.hermes
        Part(title: "Hermes", tag: "ядро · на Маке", color: Palette.hermes, ours: false, state: state) {
            Text([h?.model, h?.provider].compactMap { $0 }.joined(separator: " · ").ifEmpty("модель — после первого хода"))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.8)).lineLimit(1)
            Text("ходов сегодня \(h?.turns ?? 0) · модель \(h?.llmCalls ?? 0) · руки \(h?.toolCalls ?? 0)")
                .font(.system(size: 8.5, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.5))
            ForEach(Array((h?.steps ?? []).suffix(3).enumerated()), id: \.offset) { _, s in
                HStack(spacing: 5) {
                    Image(systemName: s.kind == "llm" ? "brain" : "hammer").font(.system(size: 8))
                        .foregroundStyle(s.ok ? (s.kind == "llm" ? Palette.llm : Palette.tool) : .red).frame(width: 10)
                    Text(s.name).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.75)).lineLimit(1)
                    Spacer()
                    Text(s.ms.map { $0 >= 1000 ? String(format: "%.1f с", $0 / 1000) : "\(Int($0)) мс" } ?? "")
                        .font(.system(size: 8.5, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.45))
                }
            }
        }
    }

    private var state: (String, Color) {
        guard link.phase == .online else { return ("нет данных", .gray) }
        if !link.state.connected { return ("шлюз не подключён", .orange) }
        var seen = Set<String>()
        if let now = link.hermes?.now.filter({ seen.insert($0).inserted }), !now.isEmpty {
            return (now.joined(separator: ", "), now.contains("думает") ? Palette.llm : Palette.tool)
        }
        return (link.state.running ? "думает" : "ждёт", link.state.running ? Palette.llm : Palette.ink.opacity(0.55))
    }
}

/// The navigator inside the phone: Google's guidance, driven from the map tab or by Hermes (plugin vera-phone).
struct PhoneMapPart: View {
    let nav: Navigator

    var body: some View {
        Part(title: "Карта", tag: "iphone/nav", color: Palette.tool, state: state) {
            Mini(title: Navigator.available ? "Google Navigation" : "без ключа — Apple",
                 value: nav.destination.map { "«\($0)»" } ?? "без маршрута",
                 color: nav.phase == .guiding ? Palette.ok : Palette.ink.opacity(0.8),
                 foot: left.isEmpty ? places : left)
        }
    }

    private var state: (String, Color)? {
        switch nav.phase {
        case .idle: nil
        case .routing: ("строю", Palette.llm)
        case .ready: ("готов", Palette.ink.opacity(0.7))
        case .guiding: ("веду", Palette.ok)
        case .arrived: ("приехали", Palette.ok)
        case .failed: ("ошибка", .orange)
        }
    }

    /// What the navigator knows of the owner's places, and how the last search went.
    private var places: String {
        let b = nav.places
        var parts = [b.home != nil ? "дом ✓" : "дом —", b.work != nil ? "работа ✓" : "работа —"]
        if !b.favorites.isEmpty { parts.append("★ \(b.favorites.count)") }
        if !nav.searchSource.isEmpty { parts.append("поиск \(nav.searchSource)") }
        return parts.joined(separator: " · ")
    }

    private var left: String {
        guard let s = nav.remainingSeconds, s > 0 else { return "" }
        let m = Int((s / 60).rounded())
        return "\(m) мин\(nav.remainingMeters.map { String(format: " · %.1f км", $0 / 1000) } ?? "")"
    }
}

/// The player inside the phone: the owner's own files, played at the file's rate.
struct PhoneMusicPart: View {
    let music: Music

    var body: some View {
        Part(title: "Музыка", tag: "iphone/music", color: Palette.session, state: music.playing ? ("играет", Palette.session) : nil) {
            Mini(title: "моё любимое · \(music.tracks.count)", value: music.current?.title ?? "тишина",
                 color: music.playing ? Palette.ink.opacity(0.9) : Palette.ink.opacity(0.5),
                 foot: music.current.map { "\($0.format) → \(music.output)" }
                    ?? "исполнителей \(music.artists.count) · альбомов \(music.albums.count)")
        }
    }
}

/// The activity log for self-analysis — a micro-module, not a part of its own: one line of what it writes and the
/// latest values it holds (GPS mode, what the phone thinks you do, steps, charge, network, places and points today).
struct PhoneActivityLog: View {
    let sensors: SensorLog

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(sensors.enabled ? Palette.human : Palette.ink.opacity(0.3)).frame(width: 5, height: 5)
                Text("журнал активности").font(.system(size: 8.5, weight: .bold, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.7))
                Text("iphone/sensors · хранится у тебя").font(.system(size: 7.5, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.35))
                Spacer(minLength: 0)
                Text(sensors.enabled ? "пишет" : "выкл").font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(sensors.enabled ? Palette.human : Palette.ink.opacity(0.4))
            }
            HStack(spacing: 4) {
                chip("GPS", sensors.navigating ? "1/с" : sensors.moving ? "1/мин" : "места", hot: sensors.navigating || sensors.moving)
                chip("сейчас", Self.activity(sensors.activityNow), hot: sensors.moving)
                if let v = sensors.speedKmh, sensors.moving || sensors.navigating { chip("скор.", "\(Int(v)) км/ч", hot: true) }
                chip("шаги", sensors.stepsToday.map(String.init) ?? "—")
            }
            HStack(spacing: 4) {
                chip("мест", "\(sensors.today["visits"] ?? 0)")
                chip("точек", "\(sensors.today["location"] ?? 0)")
                if let b = sensors.battery { chip("заряд", "\(Int(b.level * 100))%\(b.power == "заряжается" ? " ⚡" : "")") }
                if let n = sensors.networkNow { chip("сеть", n) }
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.human.opacity(0.45), style: StrokeStyle(lineWidth: 0.9, dash: [4, 3])))
    }

    private func chip(_ k: String, _ v: String, hot: Bool = false) -> some View {
        HStack(spacing: 3) {
            Text(k).font(.system(size: 7.5, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.4))
            Text(v).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(hot ? Palette.human : Palette.ink.opacity(0.8))
        }
        .lineLimit(1)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Palette.ink.opacity(0.04), in: Capsule())
    }

    static func activity(_ k: String?) -> String {
        switch k {
        case "automotive": "еду"
        case "cycling": "велосипед"
        case "running": "бегу"
        case "walking": "иду"
        case "stationary": "стою"
        default: "—"
        }
    }
}

/// Vera in the Dynamic Island and on the lock screen (Live Activity, extension VeraWidgets) — a micro-module: whether
/// it shows now and what.
struct PhoneIsland: View {
    let live: LiveVera

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(live.showing ? Palette.vera : Palette.ink.opacity(0.3)).frame(width: 5, height: 5)
            Text("dynamic island").font(.system(size: 8.5, weight: .bold, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.7))
            Text(detail).font(.system(size: 9, design: .monospaced)).foregroundStyle(live.showing ? Palette.vera : Palette.ink.opacity(0.45))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.vera.opacity(0.4), style: StrokeStyle(lineWidth: 0.9, dash: [4, 3])))
    }

    private var detail: String {
        guard live.allowed else { return "выключено в настройках iOS" }
        if let p = live.problem, !live.showing { return p }
        guard live.showing, let s = live.shown else { return "пусто — всё тихо" }
        return [s.stageWord, s.trip, s.track.map { "♪ \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }
}
