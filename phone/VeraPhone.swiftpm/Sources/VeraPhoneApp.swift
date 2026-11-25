import PhoneWire
import SwiftUI
import UIKit
import VisionKit

@main
struct VeraPhoneApp: App {
    /// The chosen theme (light, dark, as the system): the whole app follows it.
    @ObservedObject private var theme = ThemeStore.shared
    @State private var link: Link
    @State private var talk: Conversation
    @State private var music: Music
    @State private var nav: Navigator
    @State private var sensors: SensorLog
    @State private var live: LiveVera

    init() {
        // Settings first: after a new build is installed they come back from Documents (see SettingsVault).
        SettingsVault.start()
        // The app speaks Russian whatever the phone's language: Google's navigation (its panel, alerts, road text)
        // follows the app's language. Read at launch — the very first launch after this may still be in the old one.
        if (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first?.hasPrefix("ru") != true {
            UserDefaults.standard.set(["ru-RU"], forKey: "AppleLanguages")
        }
        let l = Link(device: UIDevice.current.name)
        _link = State(initialValue: l)
        let t = Conversation(link: l)
        _talk = State(initialValue: t)
        let m = Music(talk: t)
        _music = State(initialValue: m)
        let n = Navigator()
        _nav = State(initialValue: n)
        n.voice.speak = { [weak t] text in if let t { t.announce(text) } else { NavSpeaker.shared.say(text) } }
        // Hermes' phone_route* tools reach the navigator through Vera; its state goes back the same way.
        l.onNavigate = { [weak l, weak n] c in
            Task { @MainActor in
                guard let n else { return }
                let (ok, text) = await n.command(c)
                l?.send(.navResult(id: c.id, ok: ok, text: text))
            }
        }
        // The activity log (self-analysis): started with the app (iOS also relaunches it for visits and long moves).
        let sl = SensorLog()
        _sensors = State(initialValue: sl)
        sl.start()
        // Vera in the Dynamic Island and on the lock screen while something goes on.
        let lv = LiveVera()
        _live = State(initialValue: lv)
        lv.run(talk: t, nav: n, music: m, link: l)
        // Hermes' phone_music* tools reach the player the same way.
        l.onMusic = { [weak l, weak m] c in
            guard let m else { return }
            let (ok, text) = m.command(c)
            l?.send(.navResult(id: c.id, ok: ok, text: text))
        }
        n.onState = { [weak l, weak sl] state in
            l?.send(.nav(state))
            sl?.setNavigating(state.phase == "guiding")
        }
        // The board on the Mac shows what the phone's conversation is doing.
        t.onStage = { [weak l] stage, paused in l?.send(.talk(stage: stage, paused: paused)) }
        l.onWelcome = { [weak t, weak n] in t?.reportStage(); n?.report() }
        EarsFileCheck.runIfAsked(); VoiceCheck.runIfAsked(); EarsBench.runIfAsked()
    }
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if link.paired || link.phase == .connecting { MainTabs(link: link, talk: talk, music: music, nav: nav, sensors: sensors, live: live) } else { PairScreen(link: link) }
            }
            .preferredColorScheme(theme.mode.scheme)
            .tint(Palette.vera)
            .onOpenURL { url in _ = link.pair(link: url) }
            .onChange(of: phase) { _, p in
                // Riding: the conversation goes on with the screen off (background audio); the orange dot shows the mic.
                if p == .active { link.wake() }
                talk.setVisible(p == .active)
            }
        }
    }
}

/// Light or dark, by hand or by the system.
enum ThemeMode: String, CaseIterable {
    case system, light, dark
    var scheme: ColorScheme? { self == .system ? nil : (self == .light ? .light : .dark) }
    var icon: String { self == .light ? "sun.max.fill" : self == .dark ? "moon.fill" : "circle.lefthalf.striped.horizontal" }
    /// Cycles system → light → dark.
    var next: ThemeMode { self == .system ? .light : self == .light ? .dark : .system }
    /// Reads straight from UserDefaults (safe from anywhere); writing tells the store, which redraws the app.
    /// (The setter used to assign itself in a Task — an endless loop on every switch.)
    static var current: ThemeMode {
        get { ThemeMode(rawValue: UserDefaults.standard.string(forKey: "vera.theme") ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "vera.theme")
            Task { @MainActor in ThemeStore.shared.mode = newValue }
        }
    }
}

/// The theme switch every screen watches: changing `mode` redraws the app.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    @Published var mode: ThemeMode = ThemeMode(rawValue: UserDefaults.standard.string(forKey: "vera.theme") ?? "") ?? .system
    func cycle() { ThemeMode.current = mode.next }
}

/// Vera's colours — the same as the Mac board's Theme.
/// Vera's colours. Surfaces (`background`, `card`), `ink` and the accents that would fade on paper are *dynamic*: each
/// is resolved by the screen's actual appearance — the chosen theme, or the system's when the choice is «как в системе»
/// — so no screen has to know the theme. On accent fills (pink buttons) text stays `.white`.
enum Palette {
    private static func dynamic(dark: UIColor, light: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .light ? light : dark })
    }
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }

    static let background = dynamic(dark: rgb(0.035, 0.025, 0.047), light: rgb(0.88, 0.88, 0.91))
    static let card = dynamic(dark: rgb(0.065, 0.05, 0.08), light: .white)
    /// Plain text and icons on surfaces: pure black on paper, white on dark.
    static let ink = dynamic(dark: .white, light: .black)
    static let vera = Color(red: 0.94, green: 0.13, blue: 0.61)
    static let hermes = dynamic(dark: rgb(0.961, 0.620, 0.043), light: rgb(0.80, 0.45, 0.0))   // 0xF59E0B; deeper on paper
    static let session = Color(red: 0.655, green: 0.545, blue: 0.980)  // 0xA78BFA
    static let llm = dynamic(dark: rgb(0.980, 0.800, 0.082), light: rgb(0.72, 0.55, 0.0))      // 0xFACC15; yellow is unreadable on white
    static let tool = dynamic(dark: rgb(0.290, 0.871, 0.502), light: rgb(0.10, 0.60, 0.30))     // 0x4ADE80
    static let human = Color(red: 0.957, green: 0.447, blue: 0.714)    // 0xF472B6
    static let ok = dynamic(dark: rgb(0.42, 0.86, 0.56), light: rgb(0.12, 0.58, 0.32))
    /// A recessed well under live graphics (the spectrogram): darker than the card at night, a faint tint by day.
    static let well = Color(UIColor { $0.userInterfaceStyle == .light ? UIColor(white: 0, alpha: 0.05) : UIColor(white: 0, alpha: 0.35) })
}

// MARK: Pairing

struct PairScreen: View {
    let link: Link
    @ObservedObject private var theme = ThemeStore.shared
    @State private var scanning = false
    @State private var code = ""

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "waveform.path").font(.system(size: 44, weight: .semibold)).foregroundStyle(Palette.vera)
            Text("Вера").font(.system(size: 30, weight: .semibold, design: .rounded))
            Text("Телефон — сенсор Веры на Маке: пишешь и говоришь здесь, думает Hermes там.")
                .font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
            if let p = link.problem { Text(p).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center).padding(.horizontal, 30) }
            Button { scanning = true } label: {
                Label("Сопрячь по QR", systemImage: "qrcode.viewfinder").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).padding(.horizontal, 40)
            .disabled(!DataScannerViewController.isSupported)
            VStack(spacing: 8) {
                Text("или код с карточки «iPhone»").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    TextField("ABCD2345", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .font(.system(size: 20, design: .monospaced)).multilineTextAlignment(.center)
                        .padding(10).background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
                    Button("OK") { link.pair(code: code); code = "" }.disabled(code.count < 6 || link.url == nil)
                }
                .padding(.horizontal, 40)
            }
            Spacer()
            Text(link.url?.host() ?? "адрес Веры придёт с QR").font(.caption.monospaced()).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .sheet(isPresented: $scanning) {
            QRScanner { text in
                if let url = URL(string: text), link.pair(link: url) { scanning = false }
            }
            .ignoresSafeArea()
        }
    }
}

/// The camera looking for Vera's pairing QR.
struct QRScanner: UIViewControllerRepresentable {
    var found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }
    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        init(found: @escaping (String) -> Void) { self.found = found }
        func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let b) in items { if let v = b.payloadStringValue { found(v) } }
        }
    }
}

// MARK: Pieces shared by the board and the chat

struct Spectrogram: View {
    let columns: [[Float]]

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.well))
            let n = Conversation.shownColumns
            let w = size.width / CGFloat(n)
            for (i, col) in columns.enumerated() {
                let x = size.width - CGFloat(columns.count - i) * w
                let h = size.height / CGFloat(max(col.count, 1))
                for (b, v) in col.enumerated() where v > 0.08 {
                    let y = size.height - CGFloat(b + 1) * h
                    ctx.fill(Path(CGRect(x: x, y: y, width: w + 0.5, height: h + 0.5)),
                             with: .color(Palette.vera.opacity(Double(v))))
                }
            }
        }
    }
}

struct VoiceRing: View {
    let level: Float
    let on: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Palette.ok.opacity(on ? 0.35 : 0.15), lineWidth: 2)
            Circle().fill(Palette.ok.opacity(on ? 0.8 : 0.2)).scaleEffect(0.35 + CGFloat(on ? min(level, 1) : 0) * 0.6)
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

struct Bubble: View {
    let item: PhoneItem

    var body: some View {
        switch item.role {
        case .user:
            HStack { Spacer(minLength: 50); text.padding(10).background(Palette.vera.opacity(0.28), in: RoundedRectangle(cornerRadius: 14)) }
        case .assistant:
            HStack { text.padding(10).background(Palette.card, in: RoundedRectangle(cornerRadius: 14)); Spacer(minLength: 30) }
        case .tool:
            Label(item.text, systemImage: item.done ? "hammer" : "hammer.fill")
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
        case .notice, .output:
            Text(item.text).font(.caption).foregroundStyle(Palette.hermes.opacity(0.85))
        case .error:
            Text(item.text).font(.caption).foregroundStyle(.red)
        }
    }

    private var text: some View {
        Text(LocalizedStringKey(item.text)).font(.system(size: 16)).textSelection(.enabled)
    }
}
