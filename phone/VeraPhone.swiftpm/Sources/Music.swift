import AVFoundation
import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers
import VeraMusic

/// The music player: the owner's own files on the phone (Documents/Music — from the Files app, Finder or
/// scripts/phone-music.sh). With the microphone off it plays on its own, as it is: the session asks the output for the
/// file's sample rate, so a wired DAC gets 24/96 as 24/96 where it can. With the microphone open (Vera waits for
/// «Вера» or talks) it plays on the conversation's engine (`AudioRig`): the echo canceller subtracts it from the
/// microphone and Vera leads its loudness — 100% while she waits, 15% while she listens, 10% while she speaks. The
/// track moves between the two at the same place when the microphone opens or closes.
/// A library.json next to the files (the Mac puts one into Documents/Music/Vera/, in any subfolder) gives the exact
/// artist, title, album and year of the files in its own folder; its `file` names are relative to that folder.
/// The library itself — tracks, «Моё любимое», artists, albums, search, the queue — is VeraMusic, the same on the Mac.
@MainActor @Observable
final class Music {
    typealias Track = VeraMusic.LibraryTrack
    typealias Artist = VeraMusic.LibraryArtist
    typealias Album = VeraMusic.LibraryAlbum
    typealias Playlist = VeraMusic.LibraryPlaylist

    private(set) var library = MusicLibrary([])
    var tracks: [Track] { library.tracks }
    private(set) var current: Track?
    /// The list the current track was started from: next and previous walk it.
    @ObservationIgnored private var queue = MusicQueue()
    private(set) var playing = false
    /// Shuffle (remembered): the queue plays in random order.
    private(set) var shuffling = UserDefaults.standard.bool(forKey: "vera.music.shuffle")
    private(set) var output = ""          // "USB Audio · 96 кГц"
    private(set) var problem: String?
    var position: Double { onRig ? talk.rig.musicPosition : (player?.currentTime ?? pausedAt) }
    /// The loudness Vera asks for now (1 — she waits or the microphone is off).
    private(set) var level: Float = 1
    static let levels = (waiting: Float(1.0), listening: Float(0.15), speaking: Float(0.10))

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let ender = Ender()
    @ObservationIgnored private let talk: Conversation
    /// Playing on the conversation's engine (the microphone is open), not on its own.
    @ObservationIgnored private var onRig = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pausedAt: Double = 0

    static var folder: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Music")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static let favoritesName = MusicLibrary.favoritesName

    init(talk: Conversation) {
        self.talk = talk
        ender.done = { [weak self] in MainActor.assumeIsolated { self?.next() } }
        // The headset button belongs to the music while a track is loaded and the conversation is off.
        talk.mediaButton = { [weak self] in
            guard let self, self.current != nil, !talk.on || self.playing else { return false }
            self.toggle(); return true
        }
        talk.didStart = { [weak self] in self?.microphoneOpened() }
        talk.willStop = { [weak self] in self?.microphoneClosing() }
        talk.onVera = { [weak self] active, speaking in self?.follow(active: active, speaking: speaking) }
        let rc = MPRemoteCommandCenter.shared()
        rc.nextTrackCommand.isEnabled = true
        rc.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.next() }; return .success }
        rc.previousTrackCommand.isEnabled = true
        rc.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.previous() }; return .success }
        rc.changePlaybackPositionCommand.isEnabled = true
        rc.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(e.positionTime) }
            return .success
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            // Headphones pulled out: stop rather than play into the street.
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                if reason == .oldDeviceUnavailable, self?.playing == true { self?.pause() }
                self?.describeOutput()
            }
        }
        queue.setShuffle(shuffling, current: nil)
        Task { await scan(); restoreLast() }
        // While playing, the place is remembered every 5 s (a crash or iOS closing the app loses at most that).
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                if self.playing { self.saveLast() }
            }
        }
    }

    // MARK: Library

    func scan() async {
        Self.pruneMirror()
        let found = await MusicSources.folder(Self.folder)
        if let p = found.problem { problem = p }
        library = MusicLibrary(found.tracks)
        // The playing track and its queue move to the fresh metadata; files that are gone drop out of the queue.
        queue.refresh(library)
        if let c = current { current = library.tracks.first { $0.url == c.url } ?? c }
    }

    /// The Mac's mirror (Music/Vera) keeps only what its library.json lists: the Mac copies new tracks in, and a track
    /// it dropped is deleted here (the copy from the Mac cannot remove files without wiping the whole app's data).
    static func pruneMirror() {
        let dir = folder.appending(path: "Vera")
        struct Entry: Decodable { let file: String }
        guard let data = try? Data(contentsOf: dir.appending(path: "library.json")),
              let list = try? JSONDecoder().decode([Entry].self, from: data), !list.isEmpty else { return }
        let keep = Set(list.map(\.file.precomposedStringWithCanonicalMapping))
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { MusicLibrary.kinds.contains($0.pathExtension.lowercased()) }
        let gone = files.filter { !keep.contains($0.lastPathComponent.precomposedStringWithCanonicalMapping) }
        // A list that matches less than half of the files is not trusted (a broken or foreign library.json).
        guard gone.count * 2 <= files.count else { return }
        for f in gone { try? FileManager.default.removeItem(at: f) }
    }

    /// Files picked in the Files app are copied in (the originals may live in iCloud and vanish).
    func add(_ urls: [URL]) async {
        for u in urls {
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            let to = Self.folder.appending(path: u.lastPathComponent)
            try? FileManager.default.removeItem(at: to)
            do { try FileManager.default.copyItem(at: u, to: to) } catch { problem = "не скопировал \(u.lastPathComponent): \(error.localizedDescription)" }
        }
        await scan()
    }

    func remove(_ t: Track) {
        // The Mac owns its folder and writes it again: those files stay.
        guard !t.mirrored else { problem = "\(t.title) пришла с Мака — удалить её здесь нельзя"; return }
        if current == t { stopPlayer() }
        try? FileManager.default.removeItem(at: t.url)
        library = MusicLibrary(library.tracks.filter { $0 != t })
        queue.refresh(library)
    }

    // MARK: Groups and playlists (VeraMusic, the same on the Mac)

    var playlists: [Playlist] { library.playlists }
    var artists: [Artist] { library.artists }
    var albums: [Album] { library.albums }
    func artist(named name: String) -> Artist? { library.artist(named: name) }
    func album(_ name: String, by artist: String) -> Album? { library.album(name, by: artist) }
    func albumsOf(artist name: String) -> [Album] { library.albumsOf(artist: name) }
    func search(_ text: String) -> [Track] { library.search(text) }

    // MARK: Playback

    /// Starts a track. `list` is the queue it was picked from (an album, an artist, the search result);
    /// without it the queue stays as it is, or becomes the whole library when the track is not in it.
    func play(_ t: Track, from list: [Track]? = nil) {
        problem = nil
        queue.start(t, from: list, library: library)
        start(t, at: 0)
    }

    /// Starts `t` at `seconds` on the rig (the microphone is open) or on its own.
    private func start(_ t: Track, at seconds: Double) {
        generation += 1
        let gen = generation
        current = t
        do {
            // On the rig only from the speaker (its echo canceller takes the music out of the microphone); into
            // headphones the microphone does not hear it, and the music keeps its own player — no move, no gap.
            if talk.on, !AudioRig.headphonesOut() {
                player?.stop(); player = nil
                let f = try AVAudioFile(forReading: t.url)
                talk.rig.playMusic(f, from: AVAudioFramePosition(seconds * f.processingFormat.sampleRate), volume: level) { [weak self] in
                    Task { @MainActor in self?.finished(gen) }
                }
                onRig = true
            } else {
                talk.rig.stopMusic(); onRig = false
                let p = try AVAudioPlayer(contentsOf: t.url)
                // With the microphone open the session is the rig's; otherwise the music's own.
                if !talk.on { try Self.ownSession(rate: p.format.sampleRate) }
                p.volume = level
                p.delegate = ender
                p.prepareToPlay()
                p.currentTime = seconds
                p.play()
                player = p
            }
            playing = true
            saveLast()
            // After `playing`: the session policy reads it (music on the rig keeps stereo in background listening).
            if onRig { talk.refreshSession() }
            describeOutput()
            nowPlaying()
        } catch {
            problem = "не играет: \(error.localizedDescription)"
            playing = false
        }
    }

    /// The rig played the track to its end (a stop or a newer start does not count).
    private func finished(_ gen: Int) {
        guard gen == generation, playing else { return }
        next()
    }

    func toggleShuffle() {
        shuffling.toggle()
        UserDefaults.standard.set(shuffling, forKey: "vera.music.shuffle")
        queue.setShuffle(shuffling, current: current)
    }

    // MARK: The last track

    /// The track and the place, remembered by the path under Music (it survives a rescan and a new build).
    private static let lastKey = "vera.music.last"
    private func saveLast() {
        guard let c = current else { return }
        let rel = c.url.standardizedFileURL.path.replacingOccurrences(of: Self.folder.standardizedFileURL.path + "/", with: "")
        UserDefaults.standard.set(["path": rel, "at": position], forKey: Self.lastKey)
    }

    /// At launch: the last track comes back paused at its place (play continues from there).
    private func restoreLast() {
        guard current == nil, let saved = UserDefaults.standard.dictionary(forKey: Self.lastKey),
              let rel = saved["path"] as? String else { return }
        let url = Self.folder.appending(path: rel).standardizedFileURL
        guard let t = library.tracks.first(where: { $0.url.standardizedFileURL == url }) else { return }
        queue.start(t, from: nil, library: library)
        current = t
        pausedAt = min(max(0, saved["at"] as? Double ?? 0), max(0, t.seconds - 1))
        nowPlaying()
    }

    func toggle() {
        guard let c = current else {
            let all = library.playlists.first?.tracks ?? tracks
            if let t = shuffling ? all.randomElement() : all.first { play(t, from: all) }
            return
        }
        if playing { pause(); return }
        if onRig, talk.on { talk.rig.resumeMusic(); playing = true; talk.refreshSession(); nowPlaying(); return }
        if !onRig, let player {
            if !talk.on { try? Self.ownSession(rate: player.format.sampleRate) }
            player.play(); playing = true; nowPlaying(); return
        }
        start(c, at: pausedAt)
    }

    func pause() {
        pausedAt = position
        if onRig { talk.rig.pauseMusic() } else { player?.pause() }
        playing = false; nowPlaying()
        saveLast()
        talk.refreshSession()
    }

    /// The music alone: into headphones — the same session as background listening (so the microphone can open
    /// without a gap); from the speaker — plain playback at the file's rate.
    static func ownSession(rate: Double) throws {
        if AudioRig.headphonesOut() { AudioRig.musicSession(); return }
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playback, mode: .default, options: [])
        try? s.setPreferredSampleRate(rate)
        try s.setActive(true)
    }

    /// The microphone opened: from the speaker a track playing on its own moves onto the rig at the same place (for
    /// the echo canceller); into headphones it stays where it is.
    private func microphoneOpened() {
        talk.refreshSession()
        guard let c = current, !onRig, !AudioRig.headphonesOut() else { return }
        if playing { start(c, at: player?.currentTime ?? 0) } else { pausedAt = player?.currentTime ?? pausedAt; player = nil }
    }

    /// The microphone is about to close (the rig stops and releases the session): the track goes on on its own, at
    /// the same place, right after.
    private func microphoneClosing() {
        if !onRig { level = Self.levels.waiting; player?.setVolume(level, fadeDuration: 0.5); return }
        guard let c = current else { return }
        let at = talk.rig.musicPosition, wasPlaying = playing
        generation += 1
        talk.rig.stopMusic(); onRig = false
        level = Self.levels.waiting
        pausedAt = at
        if wasPlaying { DispatchQueue.main.async { [weak self] in self?.start(c, at: at) } }
    }

    /// Vera's state → the music's loudness on the rig.
    private func follow(active: Bool, speaking: Bool) {
        level = speaking ? Self.levels.speaking : active ? Self.levels.listening : Self.levels.waiting
        if onRig { talk.rig.musicVolume(level) } else { player?.setVolume(level, fadeDuration: level < (player?.volume ?? 1) ? 0.25 : 0.8) }
    }

    func next() {
        guard let c = current else { return }
        if let t = queue.after(c) { start(t, at: 0) } else { stopPlayer() }
    }

    func previous() {
        guard let c = current else { return }
        if let t = queue.before(c, position: position) { start(t, at: 0) } else { seek(0) }
    }

    func seek(_ t: Double) {
        if onRig, let c = current { if playing { start(c, at: t) } else { pausedAt = t } } else { player?.currentTime = t }
        nowPlaying()
    }

    private func stopPlayer() {
        generation += 1
        player?.stop(); player = nil; talk.rig.stopMusic(); onRig = false
        playing = false; current = nil; pausedAt = 0
        talk.refreshSession()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func describeOutput() {
        let s = AVAudioSession.sharedInstance()
        let port = s.currentRoute.outputs.first
        let name: String = switch port?.portType {
        case .usbAudio: "USB · \(port?.portName ?? "")"
        case .headphones: "провод · \(port?.portName ?? "")"
        case .bluetoothA2DP, .bluetoothLE: "Bluetooth · \(port?.portName ?? "")"
        case .builtInSpeaker: "динамик"
        default: port?.portName ?? "—"
        }
        output = "\(name) · \(MusicSources.khz(s.sampleRate)) кГц"
    }

    private func nowPlaying() {
        guard let c = current else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: c.title,
            MPMediaItemPropertyArtist: c.artist,
            MPMediaItemPropertyAlbumTitle: c.album,
            MPMediaItemPropertyPlaybackDuration: c.seconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
    }
}

/// AVAudioPlayer's end-of-track callback, outside the main actor.
private final class Ender: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var done: (@Sendable () -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let d = done
        DispatchQueue.main.async { d?() }
    }
}

struct MusicScreen: View {
    let music: Music
    @State private var segment = Segment.all
    /// Pages opened from the lists, last one on top: an artist, then one of its albums.
    @State private var path: [Drill] = []
    @State private var query = ""
    /// While the finger drags the progress slider (seek on release).
    @State private var scrub: Double?

    /// The segments of the library: every track first, then the favourites, artists, albums.
    enum Segment: String, CaseIterable, Identifiable {
        case all = "Все треки", favorites = "Любимое", artists = "Исполнители", albums = "Альбомы"
        var id: String { rawValue }
    }

    enum Drill: Hashable {
        case artist(String)
        case album(name: String, artist: String)
    }

    /// «трек», «трека», «треков» by the number.
    static func tracksWord(_ n: Int) -> String {
        let d = n % 10, h = n % 100
        if d == 1 && h != 11 { return "трек" }
        if (2...4).contains(d) && !(12...14).contains(h) { return "трека" }
        return "треков"
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Музыка").font(.system(size: 28, weight: .bold, design: .rounded))
                Spacer()
                // How many tracks there are in all (the Mac's mirror and the owner's own).
                Text("\(music.tracks.count) \(Self.tracksWord(music.tracks.count))")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.6))
            }
            .padding(.horizontal, 18).padding(.top, 8)
            if let p = music.problem {
                Text(p).font(.system(size: 12)).foregroundStyle(.orange).padding(.horizontal, 18).padding(.top, 6)
            }
            if music.tracks.isEmpty {
                Spacer()
                Text("Пока пусто.\nВера на Маке зальёт музыку по Wi-Fi.")
                    .font(.system(size: 13)).foregroundStyle(Palette.ink.opacity(0.6)).multilineTextAlignment(.center).padding(30)
                Spacer()
            } else {
                search
                content
            }
            // The player at the bottom, under the thumb.
            nowCard.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
        }
        .background(GlowBackground())
        .refreshable { await music.scan() }
        .onChange(of: segment) { _, _ in path = [] }
    }

    // MARK: Library body

    @ViewBuilder private var content: some View {
        if searching {
            trackList(music.search(query))
        } else if let top = path.last {
            detail(top)
        } else {
            segments
            switch segment {
            case .all:
                trackList(music.tracks)
            case .favorites:
                if let p = music.playlists.first { trackList(p.tracks) }
            case .artists:
                artistList
            case .albums:
                albumList
            }
        }
    }

    /// The three sections as glowing pills.
    private var segments: some View {
        HStack(spacing: 4) {
            ForEach(Segment.allCases) { sg in
                let on = segment == sg
                Button { segment = sg } label: {
                    Text(sg.rawValue).font(.system(size: 13, weight: on ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(on ? .white : Palette.ink.opacity(0.7))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(Capsule().fill(on ? Palette.vera.opacity(0.35) : .clear))
                        .overlay(Capsule().strokeBorder(on ? Palette.vera.opacity(0.9) : .clear, lineWidth: 1))
                        .shadow(color: on ? Palette.vera.opacity(0.5) : .clear, radius: 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Palette.ink.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Palette.ink.opacity(0.14), lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 10)
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.ink.opacity(0.45))
            TextField("поиск: название, исполнитель, альбом", text: $query)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if searching {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 20))
                        .foregroundStyle(Palette.ink.opacity(0.4)).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.ink.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.ink.opacity(0.16), lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 10)
    }

    private var artistList: some View {
        List {
            ForEach(music.artists) { a in
                Button { path.append(.artist(a.name)) } label: { artistRow(a) }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var albumList: some View {
        List {
            ForEach(music.albums) { a in
                Button { path.append(.album(name: a.name, artist: a.artist)) } label: { albumRow(a) }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private func detail(_ d: Drill) -> some View {
        switch d {
        case .artist(let name):
            let albums = music.albumsOf(artist: name)
            let tracks = music.artist(named: name)?.tracks ?? []
            VStack(spacing: 0) {
                back(name, "\(tracks.count) треков")
                List {
                    if !albums.isEmpty {
                        Section("альбомы") {
                            ForEach(albums) { a in
                                Button { path.append(.album(name: a.name, artist: a.artist)) } label: { albumRow(a) }
                                    .buttonStyle(.plain)
                                    .listRowBackground(Color.clear)
                            }
                        }
                    }
                    Section("треки") {
                        ForEach(tracks) { t in trackRow(t, in: tracks) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        case .album(let name, let artist):
            let tracks = music.album(name, by: artist)?.tracks ?? []
            VStack(spacing: 0) {
                back(name, "\(artist) · \(tracks.count) треков")
                trackList(tracks)
            }
        }
    }

    /// The bar on an opened page: back goes one step up the path.
    private func back(_ title: String, _ sub: String) -> some View {
        HStack(spacing: 10) {
            Button { path.removeLast() } label: {
                Label("назад", systemImage: "chevron.left")
                    .font(.system(size: 14, weight: .semibold)).frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.vera)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(sub).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.5)).lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.top, 10)
    }

    private func trackList(_ list: [Music.Track]) -> some View {
        Group {
            if list.isEmpty {
                Spacer()
                Text("ничего нет").font(.system(size: 13)).foregroundStyle(Palette.ink.opacity(0.45))
                Spacer()
            } else {
                List {
                    ForEach(list) { t in trackRow(t, in: list) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: Now playing

    private var nowCard: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                if let c = music.current {
                    HStack(spacing: 10) {
                        cover(c, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                            Text([c.artist, c.album].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 12))
                                .foregroundStyle(Palette.ink.opacity(0.7)).lineLimit(1)
                        }
                    }
                    Slider(value: Binding(get: { scrub ?? min(music.position, c.seconds) }, set: { scrub = $0 }),
                           in: 0...max(c.seconds, 1), step: 1,
                           onEditingChanged: { editing in if !editing, let s = scrub { music.seek(s); scrub = nil } })
                        .tint(Palette.vera)
                    HStack {
                        Text("\(clock(music.position)) / \(clock(c.seconds))")
                        Spacer()
                        Text("\(c.format) → \(music.output)")
                    }
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.65)).lineLimit(1)
                } else {
                    Text("ничего не играет").font(.system(size: 14)).foregroundStyle(Palette.ink.opacity(0.6))
                }
                // Big touch zones (52 pt and up): the music is used on a bike.
                HStack(spacing: 34) {
                    Spacer()
                    Button { music.previous() } label: {
                        Image(systemName: "backward.fill").font(.system(size: 24)).frame(width: 56, height: 52).contentShape(Rectangle())
                    }
                    Button { music.toggle() } label: {
                        ZStack {
                            Circle().fill(RadialGradient(colors: [Palette.vera, Palette.vera.opacity(0.6)], center: .center, startRadius: 2, endRadius: 32))
                            Image(systemName: music.playing ? "pause.fill" : "play.fill").font(.system(size: 24, weight: .bold)).foregroundStyle(.black)
                        }
                        .frame(width: 62, height: 62)
                        .shadow(color: Palette.vera.opacity(0.75), radius: 16)
                    }
                    Button { music.next() } label: {
                        Image(systemName: "forward.fill").font(.system(size: 24)).frame(width: 56, height: 52).contentShape(Rectangle())
                    }
                    Spacer()
                }
                // Shuffle at the left edge, over the row: play stays centred and the row keeps its width.
                .overlay(alignment: .leading) {
                    Button { music.toggleShuffle() } label: {
                        Image(systemName: "shuffle").font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(music.shuffling ? Palette.vera : Palette.ink.opacity(0.35))
                            .frame(width: 44, height: 52).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(music.shuffling ? "Перемешивание включено" : "Перемешать")
                }
                .foregroundStyle(Palette.vera).buttonStyle(.plain)
                .shadow(color: Palette.vera.opacity(0.6), radius: 6)
                .disabled(music.tracks.isEmpty)
            }
            .padding(14)
            .glowCard(Palette.vera, on: music.playing, radius: 20)
        }
    }

    /// The track's cover from its file (VeraMusic), Vera's note on a glowing tile while there is none.
    private func cover(_ t: Music.Track, size: CGFloat) -> some View {
        ArtworkView(url: t.url, size: size) { artwork(size: size) }
            .shadow(color: Palette.vera.opacity(0.3), radius: 5)
    }

    /// The tile without a cover.
    private func artwork(size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.24)
            .fill(LinearGradient(colors: [Palette.vera.opacity(0.45), Palette.session.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24).strokeBorder(Palette.vera.opacity(0.6), lineWidth: 1))
            .overlay(Image(systemName: "music.note").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(Palette.ink.opacity(0.9)))
            .frame(width: size, height: size)
            .shadow(color: Palette.vera.opacity(0.35), radius: 6)
    }

    // MARK: Rows

    private func trackRow(_ t: Music.Track, in list: [Music.Track]) -> some View {
        Button { music.play(t, from: list) } label: {
            HStack(spacing: 10) {
                ZStack {
                    cover(t, size: 36)
                    if music.current == t {
                        Image(systemName: music.playing ? "speaker.wave.2.fill" : "pause.fill").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white).padding(4).background(Circle().fill(Palette.vera)).offset(x: 14, y: 14)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.system(size: 14, weight: music.current == t ? .semibold : .regular)).lineLimit(1)
                    let sub = [t.artist, t.album].filter { !$0.isEmpty }.joined(separator: " · ")
                    Text(sub).font(.system(size: 11)).foregroundStyle(Palette.ink.opacity(0.65)).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(t.format).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.7))
                    Text(clock(t.seconds)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.55))
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
        .swipeActions(edge: .trailing) {
            // Files the Mac writes (Vera/) are not deleted from here.
            if !t.mirrored {
                Button(role: .destructive) { music.remove(t) } label: { Label("удалить", systemImage: "trash") }
            }
        }
    }

    private func artistRow(_ a: Music.Artist) -> some View {
        HStack(spacing: 10) {
            if let first = a.tracks.first { cover(first, size: 44) } else { artwork(size: 44) }
            Text(a.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 6)
            Text("\(a.count) тр.").font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.5))
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.3))
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    private func albumRow(_ a: Music.Album) -> some View {
        HStack(spacing: 10) {
            if let first = a.tracks.first { cover(first, size: 44) } else { artwork(size: 44) }
            VStack(alignment: .leading, spacing: 2) {
                Text(a.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                let sub = [a.artist, a.year.map { String($0) }].compactMap { $0 }.joined(separator: " · ")
                Text(sub).font(.system(size: 11)).foregroundStyle(Palette.ink.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text("\(a.count) тр.").font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.ink.opacity(0.5))
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Palette.ink.opacity(0.3))
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    private func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}
