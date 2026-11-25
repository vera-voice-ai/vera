import SwiftUI

/// The phone's look, brighter than the Mac's board: a dark screen with Vera's pink glowing from the top corner,
/// cards with a gradient rim and a soft glow of their colour (stronger when on).
struct GlowBackground: View {
    var body: some View {
        ZStack {
            Palette.background
            RadialGradient(colors: [Palette.vera.opacity(0.32), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Palette.session.opacity(0.18), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 460)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// A glowing card: a faint fill of `color`, a gradient rim, a glow around it (`on` — brighter).
    func glowCard(_ color: Color, on: Bool = true, radius: CGFloat = 16) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius)
                .fill(LinearGradient(colors: [color.opacity(on ? 0.20 : 0.08), Palette.ink.opacity(0.03)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(LinearGradient(colors: [color.opacity(on ? 0.95 : 0.45), color.opacity(on ? 0.35 : 0.12)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: on ? 1.4 : 1)
        )
        .shadow(color: color.opacity(on ? 0.45 : 0.12), radius: on ? 14 : 6)
    }

    /// Text that glows a little in its own colour.
    func glow(_ color: Color, _ radius: CGFloat = 8) -> some View { shadow(color: color.opacity(0.8), radius: radius) }
}

/// A big round switch with an icon, lit when on.
struct GlowSwitch: View {
    let on: Bool
    let icon: String
    let color: Color
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            Circle().fill(on ? AnyShapeStyle(RadialGradient(colors: [color, color.opacity(0.55)], center: .center, startRadius: 2, endRadius: size / 2))
                             : AnyShapeStyle(Palette.ink.opacity(0.06)))
            Circle().strokeBorder(color.opacity(on ? 1 : 0.5), lineWidth: 1.4)
            Image(systemName: icon).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(on ? .black : color.opacity(0.85))
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(on ? 0.7 : 0), radius: 12)
    }
}

/// One line of text that slowly slides sideways when it does not fit (a long track title): a pause, ~25 pt/s to the
/// end, a pause, back. Fits — stands still, centred.
struct Marquee: View {
    let text: String
    var font: Font = .system(size: 12)
    var speed: Double = 25
    @State private var full: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            let over = full - g.size.width
            TimelineView(.animation(minimumInterval: 1 / 30, paused: over <= 0)) { ctx in
                Text(text).font(font).lineLimit(1).fixedSize()
                    .offset(x: over > 0 ? -Self.shift(over, speed, ctx.date) : (g.size.width - full) / 2)
            }
            .frame(width: g.size.width, alignment: .leading)
            .clipped()
        }
        .frame(height: 18)
        .background(Text(text).font(font).lineLimit(1).fixedSize().hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { full = $0 })
    }

    /// Ping-pong with a 2 s pause at each end.
    static func shift(_ over: CGFloat, _ speed: Double, _ now: Date) -> CGFloat {
        let move = Double(over) / speed, pause = 2.0, cycle = 2 * (move + pause)
        let t = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
        if t < pause { return 0 }
        if t < pause + move { return CGFloat((t - pause) * speed) }
        if t < 2 * pause + move { return over }
        return over - CGFloat((t - 2 * pause - move) * speed)
    }
}
