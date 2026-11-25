import AVFoundation
import Foundation

/// Where the tracks come from, and how one file is read (tags, format, length). Exact names from Vera's catalog win
/// over the files' own tags; without either the file name «Artist - Title» is used.
public enum MusicSources {
    /// What a catalog (`каталог.json` on the Mac, `library.json` on the phone) knows about one file.
    public struct Entry: Decodable, Sendable {
        public let file: String
        public let artist: String?
        public let title: String?
        public let album: String?
        public let year: Int?
        public let duration: String?
        public init(file: String, artist: String?, title: String?, album: String?, year: Int?, duration: String?) {
            self.file = file; self.artist = artist; self.title = title; self.album = album; self.year = year; self.duration = duration
        }
    }

    /// The phone: every audio file under `root` (any depth); every `library.json` gives its folder's exact names.
    /// Files under `root/Vera/` are the Mac's mirror. Returns the tracks and a problem to show, if a library is broken.
    public static func folder(_ root: URL) async -> (tracks: [LibraryTrack], problem: String?) {
        let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        var entries: [String: Entry] = [:]
        var problem: String?
        for url in all where url.lastPathComponent == "library.json" {
            do {
                let list = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
                let dir = url.deletingLastPathComponent()
                for e in list { entries[dir.appending(path: e.file).standardizedFileURL.path] = e }
            } catch {
                problem = "\(url.deletingLastPathComponent().lastPathComponent)/library.json не прочитан: \(error.localizedDescription)"
            }
        }
        let mirror = root.appending(path: "Vera").standardizedFileURL.path + "/"
        var tracks: [LibraryTrack] = []
        for u in all where MusicLibrary.kinds.contains(u.pathExtension.lowercased()) {
            let added = (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            tracks.append(await read(u, entry: entries[u.standardizedFileURL.path], added: added,
                                     mirrored: u.standardizedFileURL.path.hasPrefix(mirror)))
        }
        return (tracks, problem)
    }

    /// The Mac: what Hermes downloaded — `workspace/soulseek/каталог.json`, tracks «скачано», files in
    /// `soulseek/музыка/` (the catalog's Windows-style path, last part). The same music the phone gets as a mirror.
    public static func soulseek(workspace: URL) async -> [LibraryTrack] {
        // Hermes writes the catalog by hand-made scripts: a field may be a number or a string («year»), or of another
        // type in one line — each value is read on its own, and a line that cannot be read is skipped, not the catalog.
        struct Catalog: Decodable {
            struct Item: Decodable {
                var status: String?, file: String?, artist: String?, title: String?, album: String?, year: Int?
                var duration: String?, added: String?
                enum K: String, CodingKey { case status, file, artist, title, album, year, duration, added }
                init(from d: Decoder) throws {
                    let c = try d.container(keyedBy: K.self)
                    func text(_ k: K) -> String? {
                        (try? c.decodeIfPresent(String.self, forKey: k)) ?? (try? c.decodeIfPresent(Int.self, forKey: k)).flatMap { $0.map(String.init) }
                    }
                    status = text(.status); file = text(.file); artist = text(.artist); title = text(.title)
                    album = text(.album); duration = text(.duration); added = text(.added)
                    year = (try? c.decodeIfPresent(Int.self, forKey: .year)) ?? text(.year).flatMap { Int($0.prefix(4)) }
                }
            }
            let tracks: [Item?]
            enum K: String, CodingKey { case tracks }
            init(from d: Decoder) throws {
                var list = try d.container(keyedBy: K.self).nestedUnkeyedContainer(forKey: .tracks)
                var out: [Item?] = []
                while !list.isAtEnd { out.append(try? list.decode(Item.self)); if out.last! == nil { _ = try? list.decode(Skip.self) } }
                tracks = out
            }
            /// Takes any one value (an object, a number, null) so the list moves past a line that could not be read.
            struct Skip: Decodable { init(from decoder: Decoder) {} }
        }
        let root = workspace.appending(path: "soulseek")
        guard let data = try? Data(contentsOf: root.appending(path: "каталог.json")),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return [] }
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        var seen = Set<String>(), tracks: [LibraryTrack] = []
        for case let t? in catalog.tracks where t.status == "скачано" {
            guard let file = t.file?.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init)
            else { continue }
            let url = root.appending(path: "музыка").appending(path: file)
            guard FileManager.default.fileExists(atPath: url.path), seen.insert(url.path).inserted else { continue }
            let entry = Entry(file: file, artist: t.artist, title: t.title, album: t.album, year: t.year, duration: t.duration)
            let added = t.added.flatMap { day.date(from: $0) } ?? .distantPast
            tracks.append(await read(url, entry: entry, added: added, mirrored: false))
        }
        return tracks
    }

    /// One file: its tags, then the catalog's names over them, then the file name if nothing else; format and length.
    public static func read(_ url: URL, entry: Entry?, added: Date, mirrored: Bool) async -> LibraryTrack {
        let asset = AVURLAsset(url: url)
        var artist = "", album = "", tagTitle = "", year: Int?
        if let meta = try? await asset.load(.commonMetadata) {
            for item in meta {
                guard let key = item.commonKey, let v = try? await item.load(.stringValue), !v.isEmpty else { continue }
                switch key {
                case .commonKeyTitle: tagTitle = v
                case .commonKeyArtist: artist = v
                case .commonKeyAlbumName: album = v
                case .commonKeyCreationDate: year = Int(v.prefix(4))
                default: break
                }
            }
        }
        var title = tagTitle
        if let l = entry {
            if let v = l.title, !v.isEmpty { title = v }
            if let v = l.artist, !v.isEmpty { artist = v }
            if let v = l.album, !v.isEmpty { album = v }
            if let v = l.year { year = v }
        }
        if title.isEmpty {
            let name = url.deletingPathExtension().lastPathComponent
            if let r = name.range(of: " - ") {
                if artist.isEmpty { artist = String(name[..<r.lowerBound]) }
                title = String(name[r.upperBound...])
            } else {
                title = name
            }
        }
        var format = url.pathExtension.uppercased(), seconds = 0.0
        if let f = try? AVAudioFile(forReading: url) {
            let d = f.fileFormat.streamDescription.pointee
            seconds = Double(f.length) / f.fileFormat.sampleRate
            format = "\(codec(d.mFormatID, ext: url.pathExtension)) \(bits(d))\(khz(f.fileFormat.sampleRate))"
        }
        if seconds == 0 { seconds = durationSeconds(entry?.duration) }
        return LibraryTrack(url: url, title: title, artist: artist, album: album, format: format, seconds: seconds,
                          year: year, artists: MusicLibrary.splitArtists(artist), added: added, mirrored: mirrored)
    }

    /// "3:41" or "1:02:03" to seconds.
    static func durationSeconds(_ s: String?) -> Double {
        guard let s else { return 0 }
        return s.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
    }

    static func codec(_ id: AudioFormatID, ext: String) -> String {
        switch id {
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatAppleLossless: "ALAC"
        case kAudioFormatMPEG4AAC: "AAC"
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatLinearPCM: ext.lowercased().hasPrefix("aif") ? "AIFF" : "WAV"
        default: ext.uppercased()
        }
    }

    /// Bit depth: PCM says it outright, lossless codecs keep it in the flags.
    static func bits(_ d: AudioStreamBasicDescription) -> String {
        if d.mBitsPerChannel > 0 { return "\(d.mBitsPerChannel)/" }
        guard d.mFormatID == kAudioFormatFLAC || d.mFormatID == kAudioFormatAppleLossless else { return "" }
        switch d.mFormatFlags {
        case kAppleLosslessFormatFlag_16BitSourceData: return "16/"
        case kAppleLosslessFormatFlag_20BitSourceData: return "20/"
        case kAppleLosslessFormatFlag_24BitSourceData: return "24/"
        case kAppleLosslessFormatFlag_32BitSourceData: return "32/"
        default: return ""
        }
    }

    public static func khz(_ rate: Double) -> String { String(format: "%g", rate / 1000) }
}
