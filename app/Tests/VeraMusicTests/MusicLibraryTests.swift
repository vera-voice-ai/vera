import Foundation
import Testing
@testable import VeraMusic

@Suite struct MusicLibraryTests {
    func track(_ name: String, _ artist: String, album: String = "", day: Double = 0) -> LibraryTrack {
        LibraryTrack(url: URL(fileURLWithPath: "/m/\(name).mp3"), title: name, artist: artist, album: album, format: "MP3",
                   seconds: 180, year: nil, artists: MusicLibrary.splitArtists(artist), added: Date(timeIntervalSince1970: day),
                   mirrored: false)
    }

    @Test func artistsAreSplitAsBefore() {
        #expect(MusicLibrary.splitArtists("A feat. B") == ["A", "B"])
        #expect(MusicLibrary.splitArtists("Miyagi & Эндшпиль") == ["Miyagi & Эндшпиль"])
        #expect(MusicLibrary.splitArtists("A, B & C") == ["A", "B", "C"])
        #expect(MusicLibrary.splitArtists("  ") == [])
    }

    @Test func groupsAndFavorites() {
        let lib = MusicLibrary([track("02", "A", album: "X", day: 1), track("01", "A", album: "X", day: 2),
                                track("s", "A feat. B", day: 3)])
        #expect(lib.artists.map(\.name) == ["A", "B"])
        #expect(lib.artist(named: "A")?.count == 3)
        #expect(lib.albums.map(\.name) == ["X"])
        #expect(lib.album("X", by: "A")?.tracks.map(\.title) == ["01", "02"])
        #expect(lib.playlists.first?.name == MusicLibrary.favoritesName)
        #expect(lib.playlists.first?.tracks.map(\.title) == ["s", "01", "02"])
        #expect(lib.search("feat").map(\.title) == ["s"])
    }

    @Test func queueWalksTheListItWasStartedFrom() {
        let a = track("a", "A"), b = track("b", "A"), c = track("c", "A")
        let lib = MusicLibrary([a, b, c])
        var q = MusicQueue()
        q.start(b, from: [a, b], library: lib)
        #expect(q.after(b) == nil)
        #expect(q.before(b, position: 1) == a)
        #expect(q.before(b, position: 10) == nil)
        q.start(c, from: nil, library: lib)
        #expect(q.tracks == lib.tracks)
    }
}

@Suite struct MusicArtworkTests {
    /// A FLAC header with one PICTURE block (front cover) — the block is found and its data returned.
    @Test func readsFlacFrontCover() throws {
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        let image: [UInt8] = [0xFF, 0xD8, 0xFF, 0xD9]
        let mime = Array("image/jpeg".utf8)
        var pic = be(3) + be(UInt32(mime.count)) + mime + be(0) + be(1) + be(1) + be(24) + be(0) + be(UInt32(image.count)) + image
        let streamInfo = [UInt8](repeating: 0, count: 34)
        var file = Array("fLaC".utf8)
        file += [0x00, 0, 0, 34] + streamInfo
        file += [0x86, UInt8(pic.count >> 16), UInt8(pic.count >> 8 & 0xFF), UInt8(pic.count & 0xFF)]
        file += pic; pic.removeAll()
        let url = FileManager.default.temporaryDirectory.appending(path: "art-\(UUID().uuidString).flac")
        try Data(file).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(MusicArtwork.flacPicture(url) == Data(image))
    }
}
