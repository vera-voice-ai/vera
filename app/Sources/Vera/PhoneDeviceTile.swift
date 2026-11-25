import HermesBridge
import PhoneWire
import SwiftUI

/// «iPhone» — the phone itself on the scheme (ours: the app Vera on the owner's iPhone, a sensor like «Сенсоры
/// MacBook»). What it does now (from the phone: listening, hearing, thinking, speaking), the last thing it sent into
/// its conversation, and its navigator driven by Hermes (plugin vera-phone). The ears, the voice, the map and the music
/// run on the phone; only the conversation goes through Vera to Hermes. Everything shown came from the phone.
struct PhoneDeviceTile: View {
    let phone: PhoneModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let peers = phone.server.peers
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Circle().fill(Theme.vera).frame(width: 8, height: 8)
                    Text("iPhone").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.95))
                    Text("приложение Vera · сенсор").font(.mono(8.5)).foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    pill(peers.isEmpty ? "не на связи" : "на связи · \(peers.map(\.device).joined(separator: ", "))",
                         peers.isEmpty ? .white.opacity(0.5) : Theme.ok)
                    Text("НАШЕ").font(.mono(7.5, .bold)).foregroundStyle(Theme.vera)
                        .padding(.horizontal, 5).padding(.vertical, 2).overlay(Capsule().stroke(Theme.vera.opacity(0.6), lineWidth: 0.8))
                }
                row("сейчас") { talk(ctx.date, online: !peers.isEmpty) }
                row("сказал") {
                    if let l = phone.lastFromPhone {
                        Text("\(l.voice ? "🎙" : "⌨") \(l.text)").font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                        Text(Format.ago(l.at.timeIntervalSince1970, now: ctx.date)).font(.mono(8.5)).foregroundStyle(.white.opacity(0.45))
                    } else {
                        Text("с телефона ещё ничего не приходило").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
                    }
                }
                row("карта") { navigator(ctx.date) }
                row("журнал") { diary(ctx.date) }
                row("музыка") {
                    let m = phone.musicMirror
                    if m.tracks > 0 {
                        Text("\(m.tracks) треков Веры → телефон").font(.system(size: 11.5)).foregroundStyle(Theme.session).lineLimit(1)
                        Text(m.synced.map { "перенесено \(Format.ago($0.timeIntervalSince1970, now: ctx.date))" } ?? "ещё не переносилось")
                            .font(.mono(8.5)).foregroundStyle(.white.opacity(0.45))
                    } else {
                        Text("скачанной музыки пока нет").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
                    }
                }
                if let l = phone.nav.last {
                    row("Hermes") {
                        Text(l.what).font(.system(size: 11.5)).foregroundStyle(Theme.tool).lineLimit(1)
                        Text(l.answer.map { "→ \($0)" } ?? "→ ждёт телефон").font(.system(size: 11)).lineLimit(1)
                            .foregroundStyle(l.ok == false ? Theme.warn : .white.opacity(0.6))
                    }
                }
                Spacer(minLength: 0)
                Text("уши GigaAM v3 и голос iOS, карта Google и музыка — на телефоне · через Мак только разговор с Hermes")
                    .font(.mono(8)).foregroundStyle(.white.opacity(0.42)).lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .partFrame(Theme.vera)
        }
    }

    @ViewBuilder private func talk(_ now: Date, online: Bool) -> some View {
        if let t = phone.phoneTalk, online {
            let (word, color) = Self.stage(t.stage, paused: t.paused)
            Circle().fill(color).frame(width: 7, height: 7)
            Text(word).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(color)
            Text(Format.ago(t.at.timeIntervalSince1970, now: now)).font(.mono(8.5)).foregroundStyle(.white.opacity(0.45))
        } else {
            Text(online ? "телефон ещё не сказал, что делает" : "—").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
        }
    }

    @ViewBuilder private func navigator(_ now: Date) -> some View {
        if let n = phone.nav.lastState {
            Text(Self.phase(n.phase)).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(n.phase == "guiding" ? Theme.ok : n.phase == "failed" ? Theme.warn : .white.opacity(0.8))
            if let d = n.destination { Text("«\(d)»").font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(1) }
            if let s = n.remainingSeconds, s > 0, ["ready", "guiding"].contains(n.phase) {
                Text("\(Int((s / 60).rounded())) мин\(n.remainingMeters.map { String(format: " · %.1f км", $0 / 1000) } ?? "")")
                    .font(.mono(9)).foregroundStyle(.white.opacity(0.6))
            }
        } else {
            Text("навигатор ещё ничего не присылал").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
        }
    }

    /// The activity log (self-analysis) as Vera has it on the Mac (the phone's files, copied at home).
    @ViewBuilder private func diary(_ now: Date) -> some View {
        let d = phone.diary
        if let at = d.updated {
            let names = ["location": "точек", "visits": "мест", "activity": "активн.", "steps": "шаги", "device": "тел."]
            Text((d.last + names.compactMap { k, v in d.today[k].map { "\(v) \($0)" } }.sorted()).joined(separator: " · "))
                .font(.system(size: 11.5)).foregroundStyle(Theme.human).lineLimit(1)
            Text("дней \(d.days) · пришёл \(Format.ago(at.timeIntervalSince1970, now: now))").font(.mono(8.5)).foregroundStyle(.white.opacity(0.45))
        } else {
            Text("ещё не переносился с телефона").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(label).font(.mono(8.5, .semibold)).foregroundStyle(.white.opacity(0.5)).frame(width: 50, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text).font(.mono(8.5, .semibold)).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2).overlay(Capsule().stroke(color.opacity(0.7), lineWidth: 1))
    }

    static func stage(_ s: String, paused: Bool) -> (String, Color) {
        if paused, s != "off", s != "speaking" { return ("ждёт «Привет, Вера»", Theme.vera.opacity(0.6)) }
        switch s {
        case "listening": return ("слушает", Theme.vera)
        case "hearing": return ("слышит речь", Theme.human)
        case "thinking": return ("ждёт Hermes", Theme.llm)
        case "speaking": return ("говорит", Theme.ok)
        case "starting": return ("включается", .white.opacity(0.6))
        default: return ("разговор выключен", .white.opacity(0.5))
        }
    }

    static func phase(_ p: String) -> String {
        switch p {
        case "idle": "без маршрута"
        case "routing": "строит маршрут"
        case "ready": "маршрут готов"
        case "guiding": "ведёт"
        case "arrived": "приехали"
        case "failed": "ошибка"
        case "unavailable": "нет ключа Google"
        default: p
        }
    }
}
