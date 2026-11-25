import PhoneWire
import SwiftUI
import UIKit
import struct VeraKit.ParticleSphere

/// The first screen, «Вера»: on top two halves — the microphone (left: a button with the microphone on or crossed out,
/// the stage, rays from what it hears; a tap pauses) and Vera's voice (right: her particle sphere, as on the Mac). Under them the
/// last exchange, then the navigation and the player (compact cards). How the models work is shown on «Схема», not here. The rest of the screen is left free for what is
/// useful on the phone. History, settings and the scheme are the other screens (the bar at the bottom).
struct RideScreen: View {
    let link: Link
    let talk: Conversation
    let music: Music
    let nav: Navigator
    /// Switch to the map tab (the navigation card's tap).
    var openMap: () -> Void = {}
    /// Чат — кнопкой на главном экране, а не вкладкой внизу.
    @State private var chatOpen = false

    var body: some View {
        VStack(spacing: 0) {
            top
            HStack(alignment: .center, spacing: 14) {
                VStack(spacing: 6) {
                    VoiceSphere(talk: talk).frame(width: 150, height: 150)
                    // The line keeps its place when the microphone is off (empty), so nothing on the screen jumps.
                    Text(talk.on ? stageWord : " ").font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(stageColor).glow(stageColor, 6)
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 10) { micSwitch; veraSwitch }
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16).padding(.top, 14)
            Spectrogram(columns: talk.columns).frame(height: 34).clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(talk.on ? 1 : 0.3)
                .padding(4)
                .glowCard(Palette.human, on: talk.vadOn, radius: 12)
                .padding(.horizontal, 16).padding(.top, 12)
            exchange.padding(.top, 12)
            // Upright cards side by side: the navigator — three quarters of the width, the player — a quarter.
            GeometryReader { g in
                HStack(spacing: 10) {
                    NavCard(nav: nav, open: openMap).frame(width: (g.size.width - 10) * 0.75, height: g.size.height)
                    PlayerCard(music: music).frame(height: g.size.height)
                }
            }
            // The cards take all the space left down to the tab bar.
            .frame(minHeight: 250, maxHeight: .infinity)
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlowBackground())
        .task {
            // The microphone opens by itself only when «Слушаю фон» is on (as on the Mac: recording owns it);
            // otherwise it waits for the owner's switch.
            if !talk.autostarted, link.paired, talk.recording { talk.autostarted = true; await talk.start() }
        }
    }

    private var top: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform").font(.system(size: 20, weight: .bold)).foregroundStyle(Palette.vera).glow(Palette.vera)
            Text("Vera").font(.system(size: 28, weight: .bold, design: .rounded))
            Spacer()
            Label(linkShort, systemImage: "desktopcomputer").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(linkColor)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Palette.ink.opacity(0.06)))
                .overlay(Capsule().strokeBorder(Palette.ink.opacity(0.18), lineWidth: 1))
                .accessibilityLabel(linkText)
            Button { chatOpen = true } label: {
                Label("Чат", systemImage: "text.bubble").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Palette.ink.opacity(0.06)))
                    .overlay(Capsule().strokeBorder(Palette.ink.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $chatOpen) { ChatSheet(link: link, talk: talk) }
            Button { ThemeMode.current = ThemeMode.current.next } label: {
                Image(systemName: ThemeMode.current.icon).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Palette.ink.opacity(0.06)))
                    .overlay(Capsule().strokeBorder(Palette.ink.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Переключить тему")
        }
        .padding(.horizontal, 18).padding(.top, 8)
    }

    /// The Mac link in one short pill: «Мак · 42 мс», «нет связи», details in the accessibility label.
    private var linkShort: String {
        switch link.phase {
        case .online: link.state.connected ? "Мак\(link.rttMs.map { " · \($0) мс" } ?? "")" : "Hermes?"
        case .connecting: "…"
        case .offline: "нет связи"
        case .unpaired: "не сопряжён"
        }
    }

    private var linkColor: Color {
        switch link.phase {
        case .online: link.state.connected ? Palette.ok : .orange
        case .connecting: .yellow
        default: .gray
        }
    }

    private var linkText: String {
        switch link.phase {
        case .online: link.state.connected ? "Мак · туннель\(link.rttMs.map { " · \($0) мс" } ?? "")" : "Hermes не подключён"
        case .connecting: "подключаюсь…"
        case .offline: "нет связи с Маком"
        case .unpaired: "не сопряжён"
        }
    }

    /// The last exchange: what was heard (live while speaking) and what Vera says or said.
    private var exchange: some View {
        VStack(alignment: .leading, spacing: 8) {
            let you = talk.partial.isEmpty ? talk.last?.text : talk.partial
            // A problem (the microphone, the link to the Mac) takes the place of what was heard.
            if let p = talk.problem ?? link.problem {
                line("ошибка", p, .orange, live: false)
            } else if let you, !you.isEmpty {
                line("ты", you, Palette.human, live: !talk.partial.isEmpty)
            }
            let vera = talk.saying.isEmpty ? talk.lastAnswer : talk.saying
            if let vera, !vera.isEmpty {
                line("Вера", vera, Palette.ok, live: !talk.saying.isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .animation(.easeOut(duration: 0.2), value: talk.partial)
    }

    private func line(_ who: String, _ text: String, _ c: Color, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(who).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(c).glow(c, 4)
            Text(text).font(.system(size: 16, weight: live ? .semibold : .medium)).foregroundStyle(Palette.ink.opacity(live ? 1 : 0.92))
                .lineLimit(3)
        }
    }

    /// Background listening (Mac's «Запись»): owns the microphone — on opens it by itself
    /// (Vera asleep, waits for «Привет, Вера»), off with inactive Vera closes everything.
    /// Neither toggle touches the music.
    private var micSwitch: some View {
        Button { talk.toggleRecording() } label: {
            HStack(spacing: 10) {
                GlowSwitch(on: talk.recording, icon: talk.recording ? "record.circle.fill" : "record.circle", color: Palette.human, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Слушаю фон").font(.system(size: 15, weight: .semibold))
                    Text(talk.recording ? "вкл · в журнал · \(talk.backgroundCount)" : "выкл").font(.system(size: 10, design: .monospaced)).lineLimit(2, reservesSpace: true)
                        .foregroundStyle(Palette.ink.opacity(0.7))
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glowCard(Palette.human, on: talk.recording)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(talk.recording ? "Выключить прослушивание фона" : "Включить прослушивание фона")
    }

    /// Vera's switch (Mac semantics): active — every phrase goes to Hermes; off — back to recording
    /// (the mic stays open), and if recording is off too — everything closes.
    private var veraSwitch: some View {
        Button {
            if talk.active { talk.setActive(false); if !talk.recording { talk.stop() } }
            else if talk.on { talk.setActive(true) }
            else { Task { await talk.start(); talk.setActive(true) } }
        } label: {
            HStack(spacing: 10) {
                GlowSwitch(on: talk.active, icon: "sparkles", color: Palette.vera, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Вера").font(.system(size: 15, weight: .semibold))
                    Text(!talk.on ? "микрофон выкл" : talk.active ? "активна · слушает" : "ждёт\n«Привет, Вера»").lineLimit(2, reservesSpace: true)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glowCard(Palette.vera, on: talk.active)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(talk.active ? "Вера: ждать «Привет, Вера»" : "Вера: слушать")
    }

    /// Under the sphere: what Vera is doing.
    private var stageWord: String {
        guard talk.on else { return "микрофон выкл" }
        switch talk.stage {
        case .speaking: return "говорю"
        case .thinking: return "думаю"
        case .hearing: return talk.active ? "слышу" : "слышу фон"
        default: return talk.active ? "слушаю" : "жду «Привет, Вера»"
        }
    }

    private var stageColor: Color {
        guard talk.on else { return Palette.ink.opacity(0.4) }
        switch talk.stage {
        case .speaking: return Palette.vera
        case .thinking: return Palette.hermes
        case .hearing: return Palette.human
        default: return talk.active ? Palette.ok : Palette.vera.opacity(0.8)
        }
    }

}

/// Vera's voice: the particle sphere from the UI kit, as on the Mac's «Ответ» tile — it rests, and while she speaks it
/// follows the loudness of her real voice now (the peaks of the Silero sentence sounding).
struct VoiceSphere: View {
    let talk: Conversation

    var body: some View {
        let speaking = talk.stage == .speaking
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !speaking)) { ctx in
            let now = ctx.date
            let energy = talk.voiceTrace.lazy.compactMap { clip -> Float? in
                let t = now.timeIntervalSince(clip.start)
                guard t >= 0, t <= clip.seconds, !clip.peaks.isEmpty else { return nil }
                return clip.peaks[min(clip.peaks.count - 1, Int(t / clip.seconds * Double(clip.peaks.count)))]
            }.first ?? 0
            ParticleSphere(speaking: speaking, voiceEnergy: Double(min(1, energy * 1.6)), particles: 830, glow: 1.7, dotScale: 9, warp: 0.2)
                .shadow(color: Palette.vera.opacity(0.55), radius: 24)
        }
    }
}
