import SwiftUI

/// Vera 2's palette (`../vera-v2/prototype/App/ContentView.swift`): one place for every colour of Vera — the Mac board
/// and the phone. New colours go here, never into a panel; the kit window (`KitView`) shows them all.
public enum Theme {
    public static let background = Color(red: 0.035, green: 0.025, blue: 0.047)
    public static let contourFill = Color(red: 0.065, green: 0.05, blue: 0.08)
    public static let accent = Color(red: 0.94, green: 0.13, blue: 0.61)
    /// Vera — everything we wrote — is pink, as in Vera 2; Hermes, the connected code, is yellow-orange.
    public static let vera = accent
    public static let hermes = Color(hex: 0xF59E0B)

    // Domains of the Hermes board.
    public static let runtime = Color(hex: 0x38BDF8)     // Hermes itself: install, version, lock
    public static let gateway = Color(hex: 0xE5E7EB)     // the nervous system: gateway socket
    public static let session = Color(hex: 0xA78BFA)     // sessions, like Vera 2's scene
    public static let llm = Color(hex: 0xFACC15)         // the model, like Vera 2's head/core
    public static let tool = Color(hex: 0x4ADE80)        // hands: tool calls
    public static let human = Color(hex: 0xF472B6)       // the agent waits for a person
    public static let subagent = Color(hex: 0x2DD4BF)
    public static let memory = Color(hex: 0x94A3B8)      // storage, compaction
    public static let warn = Color(red: 1.0, green: 0.74, blue: 0.28)
    public static let ok = Color(red: 0.42, green: 0.86, blue: 0.56)
    public static let bad = Color(hex: 0xF87171)
    public static let toolCall = Color(hex: 0xFB923C)   // one tool call on the turn's timeline (orange, apart from the green voice)
    /// A plan's used share: green under 60 %, yellow to 85 %, red above (as Vera 2's header).
    public static func usage(_ percent: Double) -> Color { percent < 60 ? ok : percent < 85 ? warn : bad }

    // Shape of a module (AGENTS.md → «Стиль интерфейса»).
    /// The scheme's border rule: solid — connected code (Hermes, its parts, the provider), dashed — our module.
    public static let ourDash: [CGFloat] = [6, 4]
    public static let contourRadius: CGFloat = 13
    public static let cardRadius: CGFloat = 10
    /// A part's tile on the scheme (`Plate`, `partFrame`).
    public static let partRadius: CGFloat = 14
    /// Text on the dark background: primary, secondary (labels, figures' captions), faint (empty notes, hints).
    public static let textPrimary = Color.white.opacity(0.91)
    public static let textSecondary = Color.white.opacity(0.6)
    public static let textFaint = Color.white.opacity(0.42)

    /// Every named colour, in the order the kit shows them: name, colour, what it means.
    public static let palette: [(name: String, color: Color, meaning: String)] = [
        ("background", background, "фон окна"),
        ("contourFill", contourFill, "заливка модуля"),
        ("vera", vera, "наше: Вера, её части и плагины"),
        ("hermes", hermes, "Hermes и подключённый код"),
        ("runtime", runtime, "установка Hermes, версия, замок"),
        ("gateway", gateway, "шлюз, нервная система"),
        ("session", session, "сессии"),
        ("llm", llm, "модель"),
        ("tool", tool, "руки: вызовы инструментов"),
        ("toolCall", toolCall, "один вызов на линии хода"),
        ("human", human, "агент ждёт человека"),
        ("subagent", subagent, "сабагенты"),
        ("memory", memory, "память, компакция"),
        ("ok", ok, "работает, проверено"),
        ("warn", warn, "внимание, ожидание"),
        ("bad", bad, "ошибка"),
    ]

    /// Whose a block is: Vera's own code, what Hermes does and sends, or our code running inside Hermes.
    public struct Origin: Sendable {
        public let text: String
        public let color: Color
        public init(text: String, color: Color) { self.text = text; self.color = color }
        public static let ours = Origin(text: "НАШЕ", color: Theme.vera)
        /// Our own written code (a dashed border on the scheme); connected code — Hermes, the provider — is solid.
        public var isOurs: Bool { text.hasPrefix("НАШ") }
        public static func hermes(_ what: String = "HERMES") -> Origin { Origin(text: what, color: Theme.hermes) }
        public static func plugin(_ name: String) -> Origin { Origin(text: "НАШ ПЛАГИН В HERMES · \(name)", color: Theme.vera) }
    }

    public static func domainColor(_ domain: String) -> Color {
        switch domain {
        case "session": session
        case "llm": llm
        case "tool": tool
        case "human": human
        case "subagent": subagent
        case "compaction": memory
        default: gateway
        }
    }

    public static func domainTitle(_ domain: String) -> String {
        switch domain {
        case "session": "Сессии"
        case "llm": "Модель"
        case "tool": "Инструменты"
        case "human": "Человек"
        case "subagent": "Сабагенты"
        case "compaction": "Компакция"
        default: domain
        }
    }
}

/// The type scale: a few steps instead of a size per panel. Titles are rounded, data and labels monospaced.
public enum VeraType: String, CaseIterable, Sendable {
    case title       // module title: 16 rounded semibold
    case heading     // header line, sheet titles: 11 rounded bold, tracked
    case body        // running text, messages: 12
    case caption     // captions under figures, empty notes: 10
    case figure      // a big figure: 15 mono semibold
    case data        // values, rows: 9 mono
    case label       // section labels, origin badges: 8 mono bold, tracked

    public var font: Font {
        switch self {
        case .title: .system(size: 16, weight: .semibold, design: .rounded)
        case .heading: .system(size: 11, weight: .bold, design: .rounded)
        case .body: .system(size: 12)
        case .caption: .system(size: 10)
        case .figure: .mono(15, .semibold)
        case .data: .mono(9)
        case .label: .mono(8, .bold)
        }
    }

    public var tracking: CGFloat {
        switch self {
        case .heading: 1.5
        case .label: 1
        default: 0
        }
    }

    public var sample: String {
        switch self {
        case .title: "Уши"
        case .heading: "VERA v0.3"
        case .body: "Ты меня слышишь? — Да, слышу."
        case .caption: "сегодня шагов не было"
        case .figure: "231 мс"
        case .data: "session.transcript · 12 мс"
        case .label: "МИКРОФОН"
        }
    }
}

public extension View {
    /// Text in one step of the scale: `Text("Уши").veraType(.title)`.
    func veraType(_ type: VeraType) -> some View { font(type.font).tracking(type.tracking) }
}

public extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

public extension Font {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
