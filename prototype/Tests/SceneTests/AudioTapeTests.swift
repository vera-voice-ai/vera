import Foundation
import Testing
import Sensors

private func samples(_ count: Int, value: Int16 = 1000) -> Data {
    var data = Data()
    for _ in 0..<count { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    return data
}

private func le32(_ data: Data, at offset: Int) -> UInt32 {
    data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
}

private func date(_ hour: Int, _ minute: Int) -> Date {
    var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 18; c.hour = hour; c.minute = minute
    return Calendar(identifier: .gregorian).date(from: c)!
}

@Test func tapeAppendsPerHourAndReportsOffsets() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vera-tape-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let tape = AudioTape(directory: dir)

    let a = try #require(tape.append(pcm16: samples(2_560), at: date(14, 5)))
    let b = try #require(tape.append(pcm16: samples(2_560), at: date(14, 6)))
    let c = try #require(tape.append(pcm16: samples(100), at: date(15, 0)))
    #expect(a.file == "2026-11-18/14.wav" && a.sampleOffset == 0)
    #expect(b.file == a.file && b.sampleOffset == 2_560 && b.endSampleOffset == 5_120)
    #expect(c.file == "2026-11-18/15.wav" && c.sampleOffset == 0)
    tape.finalize()

    let hour14 = try Data(contentsOf: dir.appending(path: a.file))
    #expect(hour14.count == 44 + 5_120 * 2)
    #expect(le32(hour14, at: 40) == UInt32(5_120 * 2))   // data size
    #expect(le32(hour14, at: 24) == 16_000)              // sample rate
    let attributes = try FileManager.default.attributesOfItem(atPath: dir.appending(path: a.file).path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func tapeHeaderStaysValidWithoutFinalizeAndResumesAfterRestart() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vera-tape-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    var tape: AudioTape? = AudioTape(directory: dir)
    // 11 s of audio crosses the 10 s header refresh; no finalize() afterwards (simulated kill).
    for _ in 0..<69 { tape?.append(pcm16: samples(2_560), at: date(9, 0)) }
    let file = dir.appending(path: "2026-11-18/09.wav")
    let killed = try Data(contentsOf: file)
    #expect(le32(killed, at: 40) > 0)                    // refreshed, not left at zero
    tape = nil

    let restarted = AudioTape(directory: dir)
    let next = try #require(restarted.append(pcm16: samples(2_560), at: date(9, 30)))
    #expect(next.sampleOffset == 69 * 2_560)             // continues after the existing data
    restarted.finalize()
    let final = try Data(contentsOf: file)
    #expect(le32(final, at: 40) == UInt32(70 * 2_560 * 2))
}
