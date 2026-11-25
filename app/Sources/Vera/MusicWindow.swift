import SwiftUI
import VeraMusic

/// «Медиатека Веры» on the Mac — the same sections as the phone's «Музыка»: «Моё любимое», «Исполнители», «Альбомы»,
/// search; a track plays with the list it was picked from as the queue. Opened from the «Музыка» column of the board.
struct MusicWindow: View {
    let music: MacMusic
    @State private var segment = Segment.favorites
    @State private var path: [Drill] = []
    @State private var query = ""

    enum Segment: String, CaseIterable, Identifiable {
        case favorites = "Моё любимое", artists = "Исполнители", albums = "Альбомы"
        var id: String { rawValue }
    }

    enum Drill: Hashable {
        case artist(String)
        case album(name: String, artist: String)
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(Theme.vera).frame(width: 8, height: 8)
                Text("Медиатека Веры").veraType(.title).foregroundStyle(Theme.textPrimary)
                Text("\(music.tracks.count) треков · та же, что на iPhone").veraType(.data).foregroundStyle(Theme.textFaint)
                Spacer()
                CapsuleButton(text: "↻ обновить", color: Theme.vera) { Task { await music.scan() } }
                CapsuleButton(text: "папка", color: Theme.vera) { music.openFolder() }
            }
            now
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textFaint)
                TextField("поиск: название, исполнитель, альбом", text: $query).textFieldStyle(.plain)
            }
            .padding(8).background(Theme.contourFill, in: RoundedRectangle(cornerRadius: 8))
            if let p = music.problem { Text(p).veraType(.caption).foregroundStyle(Theme.warn) }
            content
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 520)
        .background(Theme.background)
        .onChange(of: segment) { _, _ in path = [] }
    }

    @ViewBuilder private var content: some View {
        if music.tracks.isEmpty {
            EmptyNote(text: "музыки ещё нет — Вера качает её в workspace/soulseek; появится здесь и на iPhone")
            Spacer()
        } else if searching {
            trackList(music.library.search(query))
        } else if let top = path.last {
            detail(top)
        } else {
            Picker("Раздел", selection: $segment) {
                ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            switch segment {
            case .favorites: trackList(music.library.playlists.first?.tracks ?? [])
            case .artists:
                List(music.library.artists) { a in
                    row(a.name, "\(a.count) тр.", icon: "person.wave.2") { path.append(.artist(a.name)) }
                }.scrollContentBackground(.hidden)
            case .albums:
                List(music.library.albums) { a in
                    row(a.name, [a.artist, a.year.map(String.init)].compactMap { $0 }.joined(separator: " · ") + " · \(a.count) тр.",
                        icon: "square.stack") { path.append(.album(name: a.name, artist: a.artist)) }
                }.scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder private func detail(_ d: Drill) -> some View {
        Button { path.removeLast() } label: { Label("назад", systemImage: "chevron.left") }
            .buttonStyle(.plain).foregroundStyle(Theme.vera)
        switch d {
        case .artist(let name):
            let tracks = music.library.artist(named: name)?.tracks ?? []
            Text(name).veraType(.title).foregroundStyle(Theme.textPrimary)
            let albums = music.library.albumsOf(artist: name)
            if !albums.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(albums) { a in
                            CapsuleButton(text: a.name, color: Theme.session) { path.append(.album(name: a.name, artist: a.artist)) }
                        }
                    }
                }
            }
            trackList(tracks)
        case .album(let name, let artist):
            Text("\(name) · \(artist)").veraType(.title).foregroundStyle(Theme.textPrimary)
            trackList(music.library.album(name, by: artist)?.tracks ?? [])
        }
    }

    private func trackList(_ list: [LibraryTrack]) -> some View {
        List(list) { t in
            Button { music.play(t, from: list) } label: {
                HStack(spacing: 10) {
                    ArtworkView(url: t.url, size: 34) {
                        RoundedRectangle(cornerRadius: 7).fill(Theme.vera.opacity(0.22))
                            .overlay(Image(systemName: "music.note").foregroundStyle(Theme.textSecondary))
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if music.current == t {
                            Image(systemName: music.playing ? "speaker.wave.2.fill" : "pause.fill").font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white).padding(3).background(Circle().fill(Theme.vera)).offset(x: 4, y: 4)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title).font(.system(size: 13, weight: music.current == t ? .semibold : .regular)).lineLimit(1)
                        Text([t.artist, t.album].filter { !$0.isEmpty }.joined(separator: " · "))
                            .veraType(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    Text(t.format).veraType(.data).foregroundStyle(Theme.textFaint)
                    Text(clock(t.seconds)).veraType(.data).foregroundStyle(Theme.textFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .scrollContentBackground(.hidden)
    }

    private func row(_ title: String, _ sub: String, icon: String, _ open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(Theme.textFaint).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(sub).veraType(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.textFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var now: some View {
        HStack(spacing: 12) {
            Button { music.previous() } label: { Image(systemName: "backward.fill") }.buttonStyle(.plain)
            Button { music.toggle() } label: { Image(systemName: music.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 26)) }
                .buttonStyle(.plain).foregroundStyle(Theme.vera)
            Button { music.next() } label: { Image(systemName: "forward.fill") }.buttonStyle(.plain)
            ArtworkView(url: music.current?.url, size: 40) {
                RoundedRectangle(cornerRadius: 8).fill(Theme.vera.opacity(0.22)).overlay(Image(systemName: "music.note").foregroundStyle(Theme.textSecondary))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(music.current?.title ?? "ничего не играет").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(music.current.map { [$0.artist, $0.format].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "")
                    .veraType(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            Text("громкость \(Int((music.level * 100).rounded()))% — ведёт Вера").veraType(.data).foregroundStyle(Theme.textFaint)
        }
        .padding(10)
        .partFrame(Theme.vera)
    }

    private func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}
