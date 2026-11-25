import AVFoundation
import Foundation

/// Vera's music library, the same on the Mac and the phone: the tracks, and what is built from them — «Моё любимое»,
/// artists, albums, search, the queue a track was started from. Players differ (the phone's AVAudioPlayer with its
/// audio session, the Mac's engine whose loudness Vera leads); the library does not. New features of the music go
/// here, for both.
///
/// Where the tracks come from: the files Hermes downloads (`workspace/soulseek`, its catalog `каталог.json`) — read in
/// place on the Mac (`MusicSources.soulseek`), mirrored to the phone with a `library.json` (`MusicSources.folder`).

public struct LibraryTrack: Identifiable, Hashable, Sendable {
    public let url: URL
    public var id: URL { url }
    public var title: String
    public var artist: String
    public var album: String
    public var format: String     // "FLAC 24/96"
    public var seconds: Double
    public var year: Int?
    /// The artists in the artist tag, split: "A, B" and "A feat. B" are two; "Miyagi & Эндшпиль" stays one.
    public var artists: [String]
    /// When it came in (the phone: the file's creation; the Mac: the catalog's date).
    public var added: Date
    /// Kept by the Mac on the phone (Documents/Music/Vera/): written again from there, so not deleted on the phone.
    public var mirrored: Bool

    public init(url: URL, title: String, artist: String, album: String, format: String, seconds: Double, year: Int?,
                artists: [String], added: Date, mirrored: Bool) {
        self.url = url; self.title = title; self.artist = artist; self.album = album; self.format = format
        self.seconds = seconds; self.year = year; self.artists = artists; self.added = added; self.mirrored = mirrored
    }

    // A track is its file: equal by URL, so a rescan keeps the same track.
    public static func == (a: LibraryTrack, b: LibraryTrack) -> Bool { a.url == b.url }
    public func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// Everything by one artist. Built from the tracks, never stored.
public struct LibraryArtist: Identifiable, Sendable {
    public let name: String
    public let tracks: [LibraryTrack]
    public var id: String { name }
    public var count: Int { tracks.count }
}

/// One album: the tracks with this album name and album artist string.
public struct LibraryAlbum: Identifiable, Sendable {
    public let name: String
    public let artist: String
    public let tracks: [LibraryTrack]      // in file-name order: numbered files play in album order
    public var id: String { artist + "|" + name }
    public var count: Int { tracks.count }
    public var year: Int? { tracks.compactMap(\.year).min() }
}

/// A named list of tracks. «Моё любимое» is built in; more lists go into `playlists`.
public struct LibraryPlaylist: Identifiable, Sendable {
    public let name: String
    public let tracks: [LibraryTrack]
    public var id: String { name }
}

public struct MusicLibrary: Sendable {
    public static let favoritesName = "Моё любимое"
    public static let kinds: Set<String> = ["flac", "m4a", "alac", "mp3", "wav", "aif", "aiff", "caf", "aac"]

    /// By artist, album, file name.
    public let tracks: [LibraryTrack]

    public init(_ tracks: [LibraryTrack]) {
        self.tracks = tracks.sorted { a, b in
            if a.artist != b.artist { return Self.before(a.artist, b.artist) }
            if a.album != b.album { return Self.before(a.album, b.album) }
            return Self.before(a.url.lastPathComponent, b.url.lastPathComponent)
        }
    }

    /// Built-in playlist: the whole library, newest first, then by artist. More playlists go here later.
    public var playlists: [LibraryPlaylist] {
        let byDate = tracks.sorted { a, b in
            if a.added != b.added { return a.added > b.added }
            return Self.before(a.artist, b.artist)
        }
        return [LibraryPlaylist(name: Self.favoritesName, tracks: byDate)]
    }

    /// Every artist of every track (a track can have several), by name.
    public var artists: [LibraryArtist] {
        Set(tracks.flatMap(\.artists))
            .map { name in LibraryArtist(name: name, tracks: tracks.filter { $0.artists.contains(name) }) }
            .sorted { Self.before($0.name, $1.name) }
    }

    /// Albums: tracks grouped by album name and album artist string, by artist then name.
    public var albums: [LibraryAlbum] {
        Dictionary(grouping: tracks.filter { !$0.album.isEmpty }) { AlbumKey(name: $0.album, artist: $0.artist) }
            .map { key, ts in
                LibraryAlbum(name: key.name, artist: key.artist,
                           tracks: ts.sorted { Self.before($0.url.lastPathComponent, $1.url.lastPathComponent) })
            }
            .sorted { a, b in a.artist == b.artist ? Self.before(a.name, b.name) : Self.before(a.artist, b.artist) }
    }

    public func artist(named name: String) -> LibraryArtist? { artists.first { $0.name == name } }
    public func album(_ name: String, by artist: String) -> LibraryAlbum? { albums.first { $0.name == name && $0.artist == artist } }
    /// The albums where the artist plays at least one track.
    public func albumsOf(artist name: String) -> [LibraryAlbum] {
        albums.filter { $0.tracks.contains { $0.artists.contains(name) } }
    }

    /// Title, artist and album, case-insensitive. An empty query is the whole library.
    public func search(_ text: String) -> [LibraryTrack] {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return tracks }
        return tracks.filter { t in [t.title, t.artist, t.album].contains { $0.localizedCaseInsensitiveContains(q) } }
    }

    /// "Artist A, Artist B", "A feat. B", "A x B" are several artists. A plain "A & B" is one (a duo's name),
    /// unless the string already has a separator — then its "&" parts are artists too.
    public static func splitArtists(_ s: String) -> [String] {
        let whole = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.isEmpty else { return [] }
        var norm = whole
        var split = false
        for sep in [" feat. ", " ft. ", " x "] {
            if norm.range(of: sep, options: .caseInsensitive) != nil { split = true }
            norm = norm.replacingOccurrences(of: sep, with: ",", options: .caseInsensitive)
        }
        if norm.contains(",") { split = true }
        let names = split ? norm.components(separatedBy: ",").flatMap { $0.components(separatedBy: " & ") } : [norm]
        var out: [String] = []
        for n in names.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !n.isEmpty && !out.contains(n) {
            out.append(n)
        }
        return out
    }

    public static func before(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }
}

private struct AlbumKey: Hashable {
    let name: String
    let artist: String
}

/// The queue: the list a track was started from (an album, an artist, the search result, «Моё любимое»); next and
/// previous walk it. Without a list the queue stays, or becomes the whole library when the track is not in it.
public struct MusicQueue: Sendable {
    public private(set) var tracks: [LibraryTrack] = []
    /// Shuffle: the queue in random order, the playing track first; off — back to the list's own order.
    public private(set) var shuffled = false
    private var ordered: [LibraryTrack] = []
    public init() {}

    public mutating func start(_ t: LibraryTrack, from list: [LibraryTrack]?, library: MusicLibrary) {
        if let list { set(list, first: t) } else if !tracks.contains(t) { set(library.tracks, first: t) }
    }

    public mutating func setShuffle(_ on: Bool, current: LibraryTrack?) {
        guard on != shuffled else { return }
        let list = shuffled ? ordered : tracks
        shuffled = on
        set(list, first: current)
    }

    private mutating func set(_ list: [LibraryTrack], first: LibraryTrack?) {
        guard shuffled else { tracks = list; ordered = []; return }
        ordered = list
        var mixed = list.filter { $0 != first }.shuffled()
        if let first, list.contains(first) { mixed.insert(first, at: 0) }
        tracks = mixed
    }

    /// The track after `current`; nil at the end.
    public func after(_ current: LibraryTrack) -> LibraryTrack? {
        guard let i = tracks.firstIndex(of: current), i + 1 < tracks.count else { return nil }
        return tracks[i + 1]
    }

    /// Previous: back to the start of the same track after 3 s or on the first one (nil), else the one before.
    public func before(_ current: LibraryTrack, position: Double) -> LibraryTrack? {
        guard let i = tracks.firstIndex(of: current), position <= 3, i > 0 else { return nil }
        return tracks[i - 1]
    }

    /// A rescan: tracks move to their fresh metadata; files that are gone drop out.
    public mutating func refresh(_ library: MusicLibrary) {
        let fresh = Dictionary(library.tracks.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        tracks = tracks.compactMap { fresh[$0.url] }
        ordered = ordered.compactMap { fresh[$0.url] }
    }
}
