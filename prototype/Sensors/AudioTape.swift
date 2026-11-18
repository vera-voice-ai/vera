import Foundation

/// Continuous audio tape: everything the microphone hears while Vera is listening is
/// appended to one 16 kHz mono PCM16 WAV file per hour:
/// `<directory>/<yyyy-MM-dd>/<HH>.wav` (about 115 MB per hour).
///
/// Segments, transcripts and bus messages never copy audio; they refer to the tape by
/// file and sample offset (`Position`). Audio is kept indefinitely; there is no
/// automatic deletion. Only time while the microphone is on is recorded, so a sample
/// offset is a position inside the file, not a wall-clock time.
///
/// The WAV header is refreshed every `headerRefreshSeconds` of audio, so a crash or a
/// kill leaves a readable file that is at most that much shorter than what was heard.
public final class AudioTape: @unchecked Sendable {
    public struct Position: Sendable, Equatable {
        /// Path relative to the tape directory, for example `2026-11-18/14.wav`.
        public let file: String
        /// Index of the first sample of the appended block inside the file's data.
        public let sampleOffset: Int
        /// Number of samples appended.
        public let sampleCount: Int
        public var endSampleOffset: Int { sampleOffset + sampleCount }
    }

    public let directory: URL
    private let sampleRate: UInt32 = 16_000
    private let headerRefreshSeconds = 10
    private let lock = NSLock()
    private var handle: FileHandle?
    private var currentKey = ""
    private var dataBytes: UInt32 = 0
    private var bytesSinceHeader = 0

    public init(directory: URL) { self.directory = directory }

    /// Appends little-endian PCM16 mono 16 kHz audio heard at `date`. Returns where it landed.
    @discardableResult
    public func append(pcm16: Data, at date: Date = .now) -> Position? {
        guard !pcm16.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(for: date)
        if key != currentKey {
            closeLocked()
            guard openLocked(key: key) else { return nil }
        }
        guard let handle else { return nil }
        let offset = Int(dataBytes) / 2
        do {
            try handle.write(contentsOf: pcm16)
        } catch {
            NSLog("Vera tape write error: %@", error.localizedDescription)
            return nil
        }
        dataBytes += UInt32(pcm16.count)
        bytesSinceHeader += pcm16.count
        if bytesSinceHeader >= Int(sampleRate) * 2 * headerRefreshSeconds { refreshHeaderLocked() }
        return Position(file: key + ".wav", sampleOffset: offset, sampleCount: pcm16.count / 2)
    }

    /// Writes the final header and closes the current file.
    public func finalize() {
        lock.lock(); defer { lock.unlock() }
        closeLocked()
    }

    private func openLocked(key: String) -> Bool {
        let url = directory.appending(path: key + ".wav")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: Self.header(sampleRate: sampleRate, dataSize: 0),
                                                     attributes: [.posixPermissions: 0o600]) else {
                    return false
                }
            }
            let opened = try FileHandle(forWritingTo: url)
            let end = try opened.seekToEnd()
            handle = opened
            // Resume an existing hour file after a restart: keep appending to its data.
            dataBytes = end > 44 ? UInt32(end - 44) : 0
            currentKey = key
            bytesSinceHeader = 0
            return true
        } catch {
            NSLog("Vera tape open error: %@", error.localizedDescription)
            return false
        }
    }

    private func refreshHeaderLocked() {
        guard let handle else { return }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataSize: dataBytes))
            try handle.seekToEnd()
            bytesSinceHeader = 0
        } catch {
            NSLog("Vera tape header error: %@", error.localizedDescription)
        }
    }

    private func closeLocked() {
        guard handle != nil else { return }
        refreshHeaderLocked()
        try? handle?.close()
        handle = nil
        currentKey = ""
        dataBytes = 0
        bytesSinceHeader = 0
    }

    private static func key(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd/HH"
        return formatter.string(from: date)
    }

    private static func header(sampleRate: UInt32, dataSize: UInt32) -> Data {
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: Array("RIFF".utf8)); append(dataSize &+ 36)
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))
        append(sampleRate); append(sampleRate * 2)
        append(UInt16(2)); append(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); append(dataSize)
        return wav
    }
}
