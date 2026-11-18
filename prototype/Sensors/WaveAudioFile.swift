import Foundation

public struct WaveAudioFile: Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public let sampleRate: Int
    public let channels: Int
    public let bitsPerSample: Int
    public let dataOffset: UInt64
    public let dataBytes: UInt64

    public var duration: Double {
        Double(dataBytes) / Double(sampleRate * channels * bitsPerSample / 8)
    }

    public var displayName: String { url.lastPathComponent }

    public static func open(_ url: URL) throws -> WaveAudioFile {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 12) ?? Data()
        guard header.count == 12,
              String(decoding: header[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: header[8..<12], as: UTF8.self) == "WAVE" else {
            throw WaveFileError.notWave
        }

        var format: (code: Int, channels: Int, rate: Int, bits: Int)?
        var dataRange: (offset: UInt64, count: UInt64)?
        while let chunkHeader = try handle.read(upToCount: 8), chunkHeader.count == 8 {
            let name = String(decoding: chunkHeader[0..<4], as: UTF8.self)
            let length = UInt64(readUInt32(chunkHeader, at: 4))
            let chunkStart = try handle.offset()
            if name == "fmt ", length >= 16 {
                let data = try handle.read(upToCount: Int(min(length, 64))) ?? Data()
                if data.count >= 16 {
                    format = (Int(readUInt16(data, at: 0)), Int(readUInt16(data, at: 2)),
                              Int(readUInt32(data, at: 4)), Int(readUInt16(data, at: 14)))
                }
            } else if name == "data" {
                dataRange = (chunkStart, length)
            }
            try handle.seek(toOffset: chunkStart + length + (length & 1))
        }
        guard let format, let dataRange else { throw WaveFileError.missingChunks }
        guard format.code == 1, format.bits == 16 else { throw WaveFileError.pcm16Only }
        guard format.channels > 0, format.rate > 0 else { throw WaveFileError.invalidFormat }
        let blockAlign = format.channels * format.bits / 8
        guard dataRange.count >= UInt64(blockAlign) else { throw WaveFileError.empty }
        return WaveAudioFile(id: UUID(), url: url, sampleRate: format.rate, channels: format.channels,
                             bitsPerSample: format.bits, dataOffset: dataRange.offset,
                             dataBytes: dataRange.count)
    }

    public func readSegment(start: Double, end: Double) throws -> AudioSegment {
        let lower = min(max(0, start), duration)
        let upper = min(max(lower, end), duration)
        guard upper - lower > 0 else { throw WaveFileError.emptySelection }
        let bytesPerFrame = channels * bitsPerSample / 8
        let firstFrame = UInt64(lower * Double(sampleRate))
        let lastFrame = UInt64(upper * Double(sampleRate))
        let frameCount = max(1, lastFrame - firstFrame)
        let byteCount = min(frameCount * UInt64(bytesPerFrame), dataBytes - firstFrame * UInt64(bytesPerFrame))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: dataOffset + firstFrame * UInt64(bytesPerFrame))
        guard let pcm = try handle.read(upToCount: Int(byteCount)), !pcm.isEmpty else { throw WaveFileError.emptySelection }
        return AudioSegment(sourceURL: url, start: lower, end: upper,
                            sampleRate: sampleRate, channels: channels, pcm16: pcm)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}

public struct AudioSegment: Sendable {
    public let sourceURL: URL
    public let start: Double
    public let end: Double
    public let sampleRate: Int
    public let channels: Int
    public let pcm16: Data

    public var duration: Double { end - start }

    public var wav: Data {
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(UInt32(pcm16.count + 36), to: &data)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(UInt16(channels), to: &data)
        appendUInt32(UInt32(sampleRate), to: &data)
        appendUInt32(UInt32(sampleRate * channels * 2), to: &data)
        appendUInt16(UInt16(channels * 2), to: &data)
        appendUInt16(16, to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(UInt32(pcm16.count), to: &data)
        data.append(pcm16)
        return data
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        data.append(Data(bytes: &little, count: 2))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        data.append(Data(bytes: &little, count: 4))
    }
}

public enum WaveFileError: LocalizedError {
    case notWave, missingChunks, pcm16Only, invalidFormat, empty, emptySelection
    public var errorDescription: String? {
        switch self {
        case .notWave: "Выбери WAV-файл."
        case .missingChunks: "В WAV не найдены параметры PCM или аудиоданные."
        case .pcm16Only: "Для прототипа нужен WAV PCM 16-bit."
        case .invalidFormat: "Некорректные параметры WAV."
        case .empty: "В аудиофайле нет данных."
        case .emptySelection: "Выбран пустой аудиоотрезок."
        }
    }
}
