import SwiftUI
import VeraMusic

/// The player on the main screen, upright (a quarter of the width next to the navigator): the cover, the title,
/// the progress line and the buttons one under another — big targets for gloves.
struct PlayerCard: View {
    let music: Music

    var body: some View {
        VStack(spacing: 8) {
            if let t = music.current { playing(t) } else { empty }
        }
        .padding(.horizontal, 8).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glowCard(Palette.vera, on: music.playing)
    }

    private func playing(_ t: Music.Track) -> some View {
        VStack(spacing: 4) {
            ArtworkView(url: t.url, size: 52) {
                RoundedRectangle(cornerRadius: 13).fill(Palette.vera.opacity(0.3))
                    .overlay(Image(systemName: "music.note").font(.system(size: 22)).foregroundStyle(Palette.ink.opacity(0.85)))
            }
            Marquee(text: t.title, font: .system(size: 12, weight: .semibold))
            progress(t)
            // The buttons share all the height left, split by thin lines: big targets for a thumb (or a glove).
            VStack(spacing: 0) {
                line
                button("backward.fill", size: 24) { music.previous() }
                line
                button(music.playing ? "pause.fill" : "play.fill", size: 32) { music.toggle() }
                line
                button("forward.fill", size: 24) { music.next() }
            }
            .padding(.top, 4)
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note").font(.system(size: 24)).foregroundStyle(Palette.vera)
            Text("музыка").font(.system(size: 12, weight: .semibold))
            caption(music.tracks.isEmpty ? "нет файлов" : "\(music.tracks.count)")
            line.padding(.top, 4)
            if !music.tracks.isEmpty { button("play.fill", size: 32) { music.toggle() } }
        }
    }

    private func progress(_ t: Music.Track) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let f = t.seconds > 0 ? min(1, max(0, music.position / t.seconds)) : 0
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.ink.opacity(0.12))
                    Capsule().fill(Palette.vera).frame(width: g.size.width * f)
                }
            }
            .frame(height: 3)
        }
        // Paused: the line does not move, so no need to tick.
        .transaction { if !music.playing { $0.animation = nil } }
    }

    private var line: some View { Rectangle().fill(Palette.vera.opacity(0.35)).frame(height: 1).padding(.horizontal, 4) }

    private func caption(_ s: String) -> some View {
        Text(s).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.55)).lineLimit(1)
    }

    private func button(_ name: String, size: CGFloat = 19, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: size)).foregroundStyle(Palette.ink.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
