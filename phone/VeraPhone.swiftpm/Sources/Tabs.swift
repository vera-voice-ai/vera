import SwiftUI
import UIKit

/// The screens, switched at the bottom: the conversation first, the scheme last.
struct MainTabs: View {
    let link: Link
    let talk: Conversation
    let music: Music
    let nav: Navigator
    let sensors: SensorLog
    let live: LiveVera
    @State private var tab: Tab = .talk
    /// Watches the theme: switching light/dark redraws every tab.
    @ObservedObject private var theme = ThemeStore.shared

    enum Tab: String, CaseIterable {
        case talk = "Vera", map = "Навигация", music = "Музыка", settings = "Настройки", scheme = "Схема"
        var icon: String {
            switch self {
            case .talk: "waveform.circle"
            case .map: "map"
            case .music: "music.note"
            case .settings: "slider.horizontal.3"
            case .scheme: "point.3.connected.trianglepath.dotted"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case .talk: RideScreen(link: link, talk: talk, music: music, nav: nav, openMap: { tab = .map })
                case .map: if Navigator.available { NavigatorScreen(nav: nav) } else { MapScreen() }
                case .music: MusicScreen(music: music)
                case .settings: SettingsScreen(link: link, talk: talk, sensors: sensors)
                case .scheme: SchemeScreen(link: link, talk: talk, nav: nav, music: music, sensors: sensors, live: live)
                }
            }
            .frame(maxHeight: .infinity)
            bar
        }
        // The whole layout reaches the screen's bottom edge (the bar keeps its own room for the home indicator),
        // so the screens end right on the bar, with no empty strip.
        .ignoresSafeArea(.container, edges: .bottom)
        .background(Palette.background)
        .onAppear { talk.musicPlaying = { [weak music] in music?.playing ?? false } }
        .onChange(of: nav.focus) { _, _ in tab = .map }
    }

    private func item(_ t: Tab) -> some View {
        Button { tab = t } label: {
            VStack(spacing: 3) {
                Image(systemName: t.icon).font(.system(size: 19, weight: .semibold))
                Text(t.rawValue).font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(tab == t ? Palette.vera : Palette.ink.opacity(0.4))
            .frame(maxWidth: .infinity).padding(.top, 10)
        }
        .buttonStyle(.plain)
    }

    /// «Вера» in the middle: a glowing pink disc raised over the bar (Vera's own colour), brighter when open.
    private var veraButton: some View {
        let on = tab == .talk
        return Button { tab = .talk } label: {
            ZStack {
                Circle().fill(RadialGradient(colors: [Palette.vera, Palette.vera.opacity(0.7)], center: .topLeading,
                                             startRadius: 4, endRadius: 64))
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.05)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                Image(systemName: "waveform").font(.system(size: 28, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 64, height: 64)
            .shadow(color: Palette.vera.opacity(on ? 0.8 : 0.45), radius: on ? 16 : 9)
            .scaleEffect(on ? 1 : 0.92)
            .animation(.spring(duration: 0.3), value: on)
            .offset(y: -18)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Вера")
    }

    /// «Схема · Музыка» слева, «Вера» в середине, «Навигация · Настройки» справа.
    /// Истории отдельной кнопкой нет: чат открывается с главного экрана.
    private var bar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) { ForEach([Tab.scheme, .music], id: \.self, content: item) }.frame(maxWidth: .infinity)
            veraButton.frame(width: 86)
            HStack(spacing: 0) { ForEach([Tab.map, .settings], id: \.self, content: item) }.frame(maxWidth: .infinity)
        }
        // Lower, into the home-indicator strip: the bar goes to the screen's edge and keeps just enough room under
        // the labels for the indicator.
        .padding(.bottom, 10)
        .background(Palette.ink.opacity(0.06))
        .overlay(alignment: .top) { Rectangle().fill(Palette.ink.opacity(0.08)).frame(height: 1) }
    }
}

struct SettingsScreen: View {
    let link: Link
    let talk: Conversation
    @Bindable var sensors: SensorLog
    @AppStorage("vera.keepAwake") private var keepAwake = false
    @AppStorage("vera.voiceSpeed") private var voiceSpeed = 1.0
    @AppStorage("vera.voiceId") private var voiceId = ""
    @AppStorage("vera.hearing") private var hearing = "обычный"
    @AppStorage("vera.nav.voice") private var navVoice = "vera"
    @State private var mapsKey = ""
    @State private var mapsKeySaved = Keychain.mapsKey?.isEmpty == false

    private var sensorsToday: String {
        let names = ["location": "точек", "visits": "мест", "activity": "активность", "steps": "шаги", "device": "телефон"]
        let parts = names.compactMap { k, v in sensors.today[k].map { "\(v) \($0)" } }.sorted()
        return parts.isEmpty ? "пока пусто" : parts.joined(separator: " · ")
    }

    var body: some View {
        Form {
            Section("Голос") {
                Picker("Голос", selection: $voiceId) {
                    Text(PhoneSilero.present ? "Silero baya — как на Маке" : "лучший из установленных").tag("")
                    ForEach(Mouth.russianVoices, id: \.identifier) { v in Text("\(v.name) · \(Mouth.qualityName(v))").tag(v.identifier) }
                }
                Picker("Скорость", selection: $voiceSpeed) {
                    ForEach([0.9, 1.0, 1.1, 1.15, 1.2, 1.3], id: \.self) { Text("×" + String(format: "%g", $0)).tag($0) }
                }
            }
            Section("Уши") {
                Picker("Слух", selection: $hearing) {
                    Text("обычный").tag("обычный")
                    Text("ветер — строже к шуму").tag("ветер")
                    Text("тихо — слышит шёпот").tag("тихо")
                }
            }
            Section {
                if mapsKeySaved {
                    LabeledContent("Ключ", value: Navigator.available ? "есть · навигатор включён" : "есть · перезапусти приложение")
                    Button("Убрать ключ", role: .destructive) { Keychain.mapsKey = nil; mapsKeySaved = false }
                } else {
                    SecureField("ключ API Google Maps Platform", text: $mapsKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Сохранить") {
                        Keychain.mapsKey = mapsKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        mapsKey = ""; mapsKeySaved = true
                    }
                    .disabled(mapsKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Picker("Подсказки манёвров", selection: $navVoice) {
                    Text("голос Веры").tag("vera")
                    Text("голос Google").tag("google")
                }
            } header: { Text("Карта Google") } footer: {
                Text("Ключ хранится только в связке ключей этого iPhone. Google читает его при запуске — после сохранения закрой и открой приложение.")
            }
            Section {
                Toggle("Записывать", isOn: $sensors.enabled)
                LabeledContent("Сегодня", value: sensorsToday)
                LabeledContent("GPS", value: sensors.navigating ? "раз в секунду — ведёт навигатор"
                               : sensors.moving ? "раз в минуту — в движении" : "стоишь — только места")
            } header: { Text("Журнал активности") } footer: {
                Text("Места, GPS (в движении раз в минуту, в навигации раз в секунду), активность, шаги, заряд и сеть. Хранится на телефоне, дома переносится Вере на Мак. Hermes видит это, только когда спросишь.")
            }
            Section("Экран") {
                Toggle("Экран не гаснет", isOn: $keepAwake)
            }
            Section("Связь с Маком") {
                LabeledContent("Адрес", value: link.url?.host() ?? "—")
                Button("Переподключиться") { link.connect() }
                Button("Отвязать телефон", role: .destructive) { talk.stop(); link.unpair() }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .onChange(of: voiceSpeed) { _, v in talk.voiceSpeed = Float(v) }
        .onChange(of: hearing) { _, v in talk.setHearing(v) }
        .onChange(of: keepAwake) { _, v in UIApplication.shared.isIdleTimerDisabled = v }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = keepAwake }
    }
}
