import Foundation

/// Writes the bus message stream to a JSON Lines file, one message per line, so a live
/// session can later be replayed into Scene (and other consumers) without microphone or
/// models. It records messages only: raw audio never goes through the bus.
///
/// Recorded: everything in `domain == .sensors` (the input) and `scene.turn.verdict` (the judge model's answers, which
/// a replay cannot recompute without the model). Other scene output is derived and regenerated on replay.
public actor BusRecorder {
    public private(set) var url: URL?
    public private(set) var recordedCount = 0

    private var task: Task<Void, Never>?
    private var handle: FileHandle?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public init() {}

    public var isRecording: Bool { task != nil }

    /// Subscribes before returning, so messages published after `start` returns are captured.
    @discardableResult
    public func start(bus: SignalBus, directory: URL, name: String) async throws -> URL {
        await stop(after: 0)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let stamp = Self.fileStamp(Date())
        let file = directory.appending(path: "\(stamp)-\(name).jsonl")
        guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: file)
        url = file
        recordedCount = 0
        let stream = await bus.subscribe()
        task = Task { [weak self] in
            for await message in stream {
                if Task.isCancelled { break }
                await self?.write(message)
            }
        }
        return file
    }

    /// Waits briefly so messages published just before the call (for example
    /// `audio.microphone.stopped`) still reach the file, then closes it.
    public func stop(after delay: TimeInterval = 0.3) async {
        guard task != nil else { return }
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        task?.cancel()
        task = nil
        try? handle?.close()
        handle = nil
    }

    private func write(_ message: SignalMessage) {
        // Sensors are the input; the judge's verdicts are also model output that a replay must be able to repeat.
        guard message.domain == .sensors || message.type == "scene.turn.verdict" || message.type.hasPrefix("output.speech."), let handle,
              var line = try? encoder.encode(message) else { return }
        line.append(0x0A)
        do {
            try handle.write(contentsOf: line)
            recordedCount += 1
        } catch {
            // A failed write must not take down the live pipeline; the count stops growing.
        }
    }

    private static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.string(from: date)
    }
}
