import PhoneWire
import SwiftUI

/// The phone's scheme, cut down on purpose (the riding screen is the main one): the ears, the link and what Hermes does
/// in the phone's session, with real flows along the lines. Ours is pink and dashed, Hermes (connected code) solid.
struct Tile<Content: View>: View {
    let title: String
    let tag: String
    let color: Color
    var ours = true
    var state: (String, Color)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(tag).font(.system(size: 8, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.45)).lineLimit(1)
                Spacer(minLength: 0)
                if let state {
                    Text(state.0).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(state.1).lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 2).overlay(Capsule().stroke(state.1.opacity(0.6), lineWidth: 1))
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13)
            .stroke(color.opacity(0.68), style: StrokeStyle(lineWidth: 1.3, dash: ours ? [6, 4] : [])))
    }
}

/// A line between two tiles; a dot runs down (or up) for 0.9 s after something really went that way.
struct Connector: View {
    let label: String
    var down: Date? = nil
    var up: Date? = nil
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            Canvas { g, size in
                let x = size.width / 2
                var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                g.stroke(line, with: .color(color.opacity(0.45)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                for (at, goingDown) in [(down, true), (up, false)] {
                    guard let at else { continue }
                    let t = ctx.date.timeIntervalSince(at) / 0.9
                    guard t >= 0, t <= 1 else { continue }
                    let y = size.height * (goingDown ? t : 1 - t)
                    g.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(color))
                }
            }
        }
        .frame(height: 30)
        .overlay(alignment: .leading) {
            Text(label).font(.system(size: 8, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.45))
                .padding(.leading, 8)
        }
    }
}

struct Card: View {
    let title: String
    let value: String
    let color: Color
    let foot: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 8.5, weight: .bold, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.55))
            Text(value).font(.system(size: 13)).foregroundStyle(color).lineLimit(2)
            Text(foot).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.45)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Palette.ink.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: Composer and the full chat

struct Composer: View {
    let link: Link
    let talk: Conversation
    @Binding var draft: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("написать Hermes", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
            if link.state.running {
                Button { link.send(.interrupt) } label: {
                    Image(systemName: "stop.fill").font(.system(size: 18)).frame(width: 46, height: 46)
                        .background(Palette.hermes.opacity(0.25), in: Circle())
                }
            }
            if !draft.isEmpty {
                Button { link.say(draft); draft = "" } label: {
                    Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold)).frame(width: 46, height: 46)
                        .background(Palette.vera, in: Circle()).foregroundStyle(.white)
                }
            } else {
                Button { talk.toggle() } label: {
                    Image(systemName: talk.on ? "waveform.circle.fill" : "mic.fill")
                        .font(.system(size: talk.on ? 26 : 20, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(talk.on ? Palette.vera : Palette.vera.opacity(0.35), in: Circle())
                        .overlay(Circle().stroke(Palette.vera, lineWidth: 2).scaleEffect(1 + CGFloat(min(talk.micLevel, 0.6))).opacity(talk.on ? 0.9 : 0))
                }
                .accessibilityLabel(talk.on ? "Выключить разговор" : "Включить разговор")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct ChatSheet: View {
    let link: Link
    let talk: Conversation
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("История").font(.system(size: 22, weight: .semibold, design: .rounded))
                Spacer()
                Text("сессия «iPhone»").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.5))
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(link.items) { Bubble(item: $0).id($0.id) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(14)
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: link.items) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            Composer(link: link, talk: talk, draft: $draft)
        }
        .background(Palette.background)
        .preferredColorScheme(ThemeStore.shared.mode.scheme)
    }
}

/// «12 с назад», «3 мин назад».
func ago(_ d: Date, now: Date = Date()) -> String {
    let s = Int(now.timeIntervalSince(d))
    if s < 60 { return "\(max(0, s)) с назад" }
    if s < 3600 { return "\(s / 60) мин назад" }
    return "\(s / 3600) ч назад"
}

extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
