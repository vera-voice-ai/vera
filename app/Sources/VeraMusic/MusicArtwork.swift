import AVFoundation
import Foundation
import ImageIO
import SwiftUI

/// The cover of a track, from the file itself: FLAC's PICTURE block (read here — AVFoundation does not read it), the
/// artwork tag of MP3 / M4A (AVFoundation). Shrunk to a thumbnail once and kept in memory; the same on the Mac and the
/// phone.
public actor MusicArtwork {
    public static let shared = MusicArtwork()

    /// A decoded thumbnail; CGImage is immutable, so it is safe to hand around.
    public struct Picture: @unchecked Sendable { public let image: CGImage }

    private var cache: [URL: Picture?] = [:]
    private var running: [URL: Task<Picture?, Never>] = [:]

    /// The cover of `url`, at most `pixels` on its long side; nil when the file has none.
    public func picture(for url: URL, pixels: Int = 256) async -> Picture? {
        if let hit = cache[url] { return hit }
        if let task = running[url] { return await task.value }
        let task = Task.detached(priority: .utility) { () -> Picture? in
            guard let data = await Self.embedded(url) else { return nil }
            return Self.thumbnail(data, pixels: pixels).map(Picture.init)
        }
        running[url] = task
        let p = await task.value
        running[url] = nil
        cache[url] = p
        return p
    }

    /// The picture's bytes as stored in the file.
    static func embedded(_ url: URL) async -> Data? {
        if url.pathExtension.lowercased() == "flac" { return flacPicture(url) }
        guard let meta = try? await AVURLAsset(url: url).load(.commonMetadata) else { return nil }
        for item in meta where item.commonKey == .commonKeyArtwork {
            if let d = try? await item.load(.dataValue), !d.isEmpty { return d }
        }
        return nil
    }

    /// FLAC metadata: "fLaC", then blocks (1 byte: last flag + type, 3 bytes: length). PICTURE is type 6: picture type,
    /// MIME, description, width, height, depth, colours, then the data — all lengths big-endian 32-bit. The front
    /// cover (picture type 3) wins over any other picture.
    static func flacPicture(_ url: URL) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard (try? h.read(upToCount: 4)) == Data("fLaC".utf8) else { return nil }
        var any: Data?
        while let head = try? h.read(upToCount: 4), head.count == 4 {
            let last = head[0] & 0x80 != 0, type = head[0] & 0x7F
            let length = Int(head[1]) << 16 | Int(head[2]) << 8 | Int(head[3])
            if type == 6, let block = try? h.read(upToCount: length), block.count == length {
                if let (kind, data) = parsePicture(block) {
                    if kind == 3 { return data }
                    if any == nil { any = data }
                }
            } else {
                guard (try? h.seek(toOffset: h.offsetInFile + UInt64(length))) != nil else { break }
            }
            if last { break }
        }
        return any
    }

    static func parsePicture(_ b: Data) -> (kind: UInt32, data: Data)? {
        var i = b.startIndex
        func u32() -> UInt32? {
            guard i + 4 <= b.endIndex else { return nil }
            defer { i += 4 }
            return b[i..<i + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        guard let kind = u32(), let mime = u32() else { return nil }
        i += Int(mime)
        guard let desc = u32() else { return nil }
        i += Int(desc)
        guard u32() != nil, u32() != nil, u32() != nil, u32() != nil, let size = u32(),
              i + Int(size) <= b.endIndex else { return nil }
        return (kind, b[i..<i + Int(size)])
    }

    static func thumbnail(_ data: Data, pixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: pixels,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// A track's cover in a rounded tile; `placeholder` until (or unless) the file has one.
public struct ArtworkView<Placeholder: View>: View {
    let url: URL?
    let size: CGFloat
    let placeholder: () -> Placeholder
    @State private var picture: MusicArtwork.Picture?

    public init(url: URL?, size: CGFloat, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url; self.size = size; self.placeholder = placeholder
    }

    public var body: some View {
        Group {
            if let picture {
                Image(decorative: picture.image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            } else {
                placeholder()
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            picture = nil
            guard let url else { return }
            picture = await MusicArtwork.shared.picture(for: url, pixels: Int(size * 3))
        }
    }
}
