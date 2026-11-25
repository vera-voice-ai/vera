import Foundation
import SwiftUI

/// ScrollView, or its plain content: ImageRenderer cannot draw a ScrollView, and the off-screen snapshot needs the content.
public struct MaybeScroll<Content: View>: View {
    let scrollable: Bool
    var axes: Axis.Set = .vertical
    @ViewBuilder let content: () -> Content
    public init(scrollable: Bool, axes: Axis.Set = .vertical, @ViewBuilder content: @escaping () -> Content) {
        self.scrollable = scrollable; self.axes = axes; self.content = content
    }
    public var body: some View {
        if scrollable { ScrollView(axes) { content() } } else { content() }
    }
}

/// A module on the board: dashed contour in its domain colour, dot, title and a monospaced name (Vera 2's `moduleContour`).
public struct ModuleContour<Content: View>: View {
    let name: String
    let title: String
    let color: Color
    var trailing: String? = nil
    var origin: Theme.Origin? = nil
    @ViewBuilder let content: () -> Content

    public init(name: String, title: String, color: Color, trailing: String? = nil, origin: Theme.Origin? = nil,
                @ViewBuilder content: @escaping () -> Content) {
        self.name = name; self.title = title; self.color = color; self.trailing = trailing; self.origin = origin; self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(title).veraType(.title).foregroundStyle(.white.opacity(0.93))
                        .lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 0)
                    if let trailing {
                        Text(trailing).font(.mono(9)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    }
                }
                // Whose this block is, on its own line: the title never has to make room for it.
                if let origin {
                    HStack(spacing: 7) {
                        OriginBadge(origin: origin)
                    }
                    .padding(.leading, 17)
                }
            }
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .background(Theme.contourFill, in: RoundedRectangle(cornerRadius: Theme.contourRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.contourRadius).stroke(color.opacity(0.68), style: StrokeStyle(lineWidth: 1.2, dash: Theme.ourDash)))
    }
}

/// An inner card inside a module.
public struct InnerCard<Content: View>: View {
    var tint: Color = .white
    @ViewBuilder let content: () -> Content
    public init(tint: Color = .white, @ViewBuilder content: @escaping () -> Content) { self.tint = tint; self.content = content }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(tint.opacity(0.16), lineWidth: 1))
    }
}

/// The frame of a part on the scheme: contour fill, radius 14, a 1.6 border in the part's colour — dashed for our
/// own module, solid for connected code (Hermes, the provider). AGENTS.md → «Границы на схеме».
public extension View {
    func partFrame(_ color: Color, dashed: Bool = true, opacity: Double = 0.8) -> some View {
        background(Theme.contourFill, in: RoundedRectangle(cornerRadius: Theme.partRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.partRadius)
                .stroke(color.opacity(opacity), style: StrokeStyle(lineWidth: 1.6, dash: dashed ? Theme.ourDash : [])))
    }
}

/// The only clickable thing on a tile: an explicit outlined capsule button («⚙ настроить», «↻ перезапустить»).
public struct CapsuleButton: View {
    let text: String
    var color: Color = Theme.vera
    let action: () -> Void
    public init(text: String, color: Color = Theme.vera, action: @escaping () -> Void) { self.text = text; self.color = color; self.action = action }
    public var body: some View {
        Button(action: action) {
            Text(text).font(.mono(8.5, .semibold)).foregroundStyle(color)
                .padding(.horizontal, 7).padding(.vertical, 3).overlay(Capsule().stroke(color.opacity(0.7), lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

/// Whose a block is, as a small outlined badge: «НАШЕ», «HERMES», «НАШ ПЛАГИН В HERMES · vera-pulse».
public struct OriginBadge: View {
    let origin: Theme.Origin
    public init(origin: Theme.Origin) { self.origin = origin }
    public var body: some View {
        Text(origin.text).font(.mono(7.5, .bold)).tracking(0.8).foregroundStyle(origin.color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Capsule().stroke(origin.color.opacity(0.5), lineWidth: 0.8))
            .lineLimit(1)
    }
}

/// Header capsule: «РЕШЕНИЯ», «HERMES v0.23.2 · ПРОВЕРЕН».
public struct Pill: View {
    let text: String
    var color: Color = Theme.accent
    var strong = true
    public init(text: String, color: Color = Theme.accent, strong: Bool = true) { self.text = text; self.color = color; self.strong = strong }
    public var body: some View {
        Text(text).font(.mono(9, .semibold)).tracking(1)
            .foregroundStyle(color.opacity(strong ? 1 : 0.85))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .overlay(Capsule().stroke(color.opacity(strong ? 0.55 : 0.35), lineWidth: 1))
    }
}

/// Big monospaced figure with a caption, as on the Signal Bus panel.
public struct Stat: View {
    let value: String
    let label: String
    var color: Color = Theme.runtime
    public init(value: String, label: String, color: Color = Theme.runtime) { self.value = value; self.label = label; self.color = color }
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).veraType(.figure).foregroundStyle(color).lineLimit(1)
            Text(label).veraType(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `key · value` row in small mono.
public struct KeyValue: View {
    let key: String
    let value: String
    var valueColor: Color = .white.opacity(0.75)
    public init(key: String, value: String, valueColor: Color = .white.opacity(0.75)) { self.key = key; self.value = value; self.valueColor = valueColor }
    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key).font(.mono(9)).foregroundStyle(.white.opacity(0.42)).frame(width: 96, alignment: .leading)
            Text(value).font(.mono(9)).foregroundStyle(valueColor).lineLimit(1).truncationMode(.middle)
        }
    }
}

public struct SectionLabel: View {
    let text: String
    var color: Color = .white
    public init(text: String, color: Color = .white) { self.text = text; self.color = color }
    public var body: some View {
        Text(text.uppercased()).veraType(.label).foregroundStyle(color.opacity(0.7))
    }
}

public struct EmptyNote: View {
    let text: String
    public init(text: String) { self.text = text }
    public var body: some View {
        Text(text).veraType(.caption).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
    }
}

public enum Format {
    /// Seconds, short: 40 мс, 1.6 с.
    public static func sec(_ s: Double) -> String { ms(s * 1000) }

    public static func ms(_ v: Double) -> String {
        v >= 10_000 ? String(format: "%.0f с", v / 1000) : v >= 1000 ? String(format: "%.1f с", v / 1000) : String(format: "%.0f мс", v)
    }

    public static func count(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 10_000 ? String(format: "%.0fK", Double(n) / 1e3) : "\(n)"
    }

    public static func ago(_ ts: Double, now: Date) -> String {
        let s = max(0, now.timeIntervalSince1970 - ts)
        if s < 60 { return String(format: "%.0f с назад", s) }
        if s < 3600 { return String(format: "%.0f мин назад", s / 60) }
        return String(format: "%.0f ч назад", s / 3600)
    }

    public static func time(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}

/// Text with its URLs clickable (Hermes' notices carry the provider's own fix links).
public func linkified(_ text: String) -> AttributedString {
    var out = AttributedString(text)
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return out }
    let ns = text as NSString
    for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        guard let url = match.url, let range = Range(match.range, in: text),
              let lower = AttributedString.Index(range.lowerBound, within: out),
              let upper = AttributedString.Index(range.upperBound, within: out) else { continue }
        out[lower..<upper].link = url
        out[lower..<upper].underlineStyle = .single
    }
    return out
}

/// A plain tile of the scheme.
public struct Plate: View {
    let title: String
    let color: Color
    let origin: Theme.Origin?
    let lines: [String]
    let footer: String
    var state: Color? = nil
    var dim = false
    /// A small picture under the lines (bars, lanes, dots) — from real data only.
    var visual: AnyView? = nil
    var visualHeight: CGFloat = 60
    /// An explicit button in the tile's header (the tile itself is not clickable).
    var button: (String, () -> Void)? = nil

    public init(title: String, color: Color, origin: Theme.Origin?, lines: [String], footer: String, state: Color? = nil,
                dim: Bool = false, visual: AnyView? = nil, visualHeight: CGFloat = 60, button: (String, () -> Void)? = nil) {
        self.title = title; self.color = color; self.origin = origin; self.lines = lines; self.footer = footer; self.state = state
        self.dim = dim; self.visual = visual; self.visualHeight = visualHeight; self.button = button
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle().fill(state ?? color).frame(width: 9, height: 9)
                Text(title).veraType(.title).foregroundStyle(.white.opacity(dim ? 0.5 : 0.95))
                Spacer()
                if let button {
                    CapsuleButton(text: button.0, color: color, action: button.1)
                }
                if let origin {
                    OriginBadge(origin: origin)
                }
            }
            ForEach(lines, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(.white.opacity(dim ? 0.4 : 0.8)).lineLimit(1) }
            Spacer(minLength: 0)
            if let visual { visual.frame(height: visualHeight) }
            if !footer.isEmpty {
                Text(footer).font(.mono(9)).foregroundStyle(color.opacity(dim ? 0.4 : 0.85)).lineLimit(1)
            }
        }
        .padding(14)
        .partFrame(origin?.isOurs == true ? Theme.vera : color, dashed: origin?.isOurs == true, opacity: dim ? 0.3 : 0.75)
    }
}

