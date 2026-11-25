import Foundation

/// Judges whether a phrase is finished, from its sound. The ears ask it when the VAD hears silence.
public protocol TurnJudge: AnyObject {
    /// Probability (0…1) that the speaker has finished, or nil when it cannot tell (the phrase still ends then).
    func completion(_ phrase: [Float]) -> Double?
}

/// An async judge: answers later, on any thread. The listener keeps gathering
/// audio while waiting (the `holding` window is the timeout); a late answer is ignored.
public protocol AsyncTurnJudge: AnyObject {
    func judge(_ phrase: [Float], _ reply: @escaping @Sendable (Double?) -> Void)
}

/// Smart Turn v3.2 (Pipecat) in the box: the mouth's Python with onnxruntime runs `smart-turn-worker.py` on the
/// last 8 s of the phrase (~25 ms). Mechanics, not meaning: it hears intonation and pauses, not words.
public final class SmartTurn: TurnJudge, AsyncTurnJudge, @unchecked Sendable {
    private let python: URL, worker: URL, model: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextId = 0
    /// The worker's stdin/stdout are one conversation: every blocking round-trip runs here, never on the ears' queue.
    private let ioQueue = DispatchQueue(label: "vera.smart-turn", qos: .userInitiated)

    /// nil when the mouth's box has no Smart Turn (an older build).
    public init?(mouth: MouthRuntime) {
        python = mouth.python
        worker = mouth.root.appending(path: "smart-turn-worker.py")
        model = mouth.root.appending(path: "models/smart-turn-v3.2-cpu.onnx")
        guard FileManager.default.fileExists(atPath: worker.path), FileManager.default.fileExists(atPath: model.path) else { return nil }
    }
    deinit { process?.terminate() }

    private func start() throws {
        let p = Process()
        p.executableURL = python
        p.arguments = ["-I", worker.path, model.path]
        p.environment = ["HOME": NSTemporaryDirectory(), "PATH": "/usr/bin:/bin", "PYTHONUNBUFFERED": "1",
                         "PYTHONDONTWRITEBYTECODE": "1", "OMP_NUM_THREADS": "2"]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = FileHandle.nullDevice
        try p.run()
        process = p; input = inPipe.fileHandleForWriting; output = outPipe.fileHandleForReading; buffer.removeAll()
        guard (try readLine())["ready"] as? Bool == true else { throw NSError(domain: "Vera", code: 7) }
    }

    private func readLine() throws -> [String: Any] {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { return obj }
                continue
            }
            guard let chunk = output?.availableData, !chunk.isEmpty else { process = nil; throw NSError(domain: "Vera", code: 8) }
            buffer.append(chunk)
        }
    }

    /// Loads the model ahead (on the ears' queue at the start of listening).
    /// Runs on the worker's own queue, like every round-trip: never two threads on one process.
    public func warm() { ioQueue.async { [weak self] in if self?.process?.isRunning != true { try? self?.start() } } }

    /// Async: the blocking round-trip runs on the worker's own queue; the reply lands on an arbitrary thread and
    /// the listener routes it back to its queue (a stale generation is ignored there).
    public func judge(_ phrase: [Float], _ reply: @escaping @Sendable (Double?) -> Void) {
        ioQueue.async { [weak self] in reply(self?.completion(phrase)) }
    }

    public func completion(_ phrase: [Float]) -> Double? {
        do {
            if process?.isRunning != true { try start() }
            nextId += 1
            let tail = phrase.suffix(16_000 * 8)
            let pcm = tail.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
            var line = try JSONSerialization.data(withJSONObject: ["id": nextId, "pcm": pcm])
            line.append(0x0A)
            try input?.write(contentsOf: line)
            return try readLine()["probability"] as? Double
        } catch { return nil }
    }
}
