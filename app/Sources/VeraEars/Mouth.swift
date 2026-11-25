import AVFoundation
import Foundation
import SileroVoice

/// Where Vera's mouth lies: `Resources/mouth` in the app (from `scripts/build-mouth.sh`, copied by `bundle.sh`), or the
/// build output `~/.vera03/build/mouth`. Silero TTS in its own Python — not Hermes' Python, not the machine's.
public struct MouthRuntime: Sendable, Equatable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public var python: URL { root.appending(path: "python/bin/python3") }
    public var worker: URL { root.appending(path: "worker.py") }
    public var stamp: URL { root.appending(path: "mouth.stamp.json") }

    public var model: URL? {
        let dir = root.appending(path: "models")
        let name = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.first { $0.hasSuffix(".pt") }
        return name.map { dir.appending(path: $0) }
    }

    public var speaker: String { info["speaker"] as? String ?? "baya" }
    public var sampleRate: Int { info["sample_rate"] as? Int ?? 48_000 }
    public var modelName: String { info["model"] as? String ?? "silero" }

    private var info: [String: Any] {
        guard let data = try? Data(contentsOf: stamp),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    /// The same voice without Python — Silero as ONNX with its Swift text side (SileroVoice, as the phone speaks):
    /// `VERA_VOICE` → the app's `Resources/voice` → the build output `~/.vera03/build/mouth-ios/out`
    /// (scripts/build-mouth-ios.sh). Run on the box's onnxruntime (the ears' library).
    public static func voiceDir(environment: [String: String] = ProcessInfo.processInfo.environment,
                                bundle: Bundle = .main) -> URL? {
        var candidates: [URL] = []
        if let path = environment["VERA_VOICE"], !path.isEmpty { candidates.append(URL(fileURLWithPath: path)) }
        if let res = bundle.resourceURL { candidates.append(res.appending(path: "voice")) }
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".vera03/build/mouth-ios/out"))
        return candidates.first(where: SileroVoice.isComplete)
    }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               bundle: Bundle = .main) -> MouthRuntime? {
        var candidates: [URL] = []
        if let path = environment["VERA_MOUTH"], !path.isEmpty { candidates.append(URL(fileURLWithPath: path)) }
        if let res = bundle.resourceURL { candidates.append(res.appending(path: "mouth")) }
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".vera03/build/mouth"))
        return candidates.map(MouthRuntime.init).first {
            FileManager.default.isExecutableFile(atPath: $0.python.path) && $0.model != nil
        }
    }
}

/// What makes sound from a sentence: the Swift voice (default) or the Python worker (when the ONNX voice is not built).
protocol Synthesizer: Sendable {
    func synthesize(_ text: String) throws -> (pcm: [Float], rate: Double, ms: Int)
    func warm() throws
}

/// Silero in Swift (SileroVoice) on the box's onnxruntime: no process, loads in about a second, a sentence in tens of
/// milliseconds. The same networks and text side as the phone, the same voice as the Python worker.
final class SwiftVoice: Synthesizer, @unchecked Sendable {
    private let dir: URL
    private let library: URL
    private let speaker: String
    private var voice: SileroVoice?
    private let lock = NSLock()

    init(dir: URL, onnxruntime: URL, speaker: String) { self.dir = dir; library = onnxruntime; self.speaker = speaker }

    private func loaded() throws -> SileroVoice {
        if let voice { return voice }
        try OnnxRuntime.load(dylib: library)
        let v = try SileroVoice(dir: dir, threads: 4)
        voice = v
        return v
    }

    func warm() throws { lock.lock(); defer { lock.unlock() }; _ = try loaded() }

    func synthesize(_ text: String) throws -> (pcm: [Float], rate: Double, ms: Int) {
        lock.lock(); defer { lock.unlock() }
        let t0 = Date()
        let pcm = try loaded().synthesize(text, speaker: speaker)
        return (pcm, Double(SileroVoice.sampleRate), Int(Date().timeIntervalSince(t0) * 1000))
    }
}

/// The Silero worker: a long-lived process, one sentence in, PCM out. Started on first use (~5–10 s to load).
final class SileroWorker: Synthesizer, @unchecked Sendable {
    private let runtime: MouthRuntime
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextId = 0
    private let lock = NSLock()

    init(runtime: MouthRuntime) { self.runtime = runtime }
    deinit { process?.terminate() }

    private func start() throws {
        guard let model = runtime.model else { throw NSError(domain: "Vera", code: 3, userInfo: [NSLocalizedDescriptionKey: "нет модели голоса"]) }
        let p = Process()
        p.executableURL = runtime.python
        p.arguments = ["-I", runtime.worker.path, model.path]
        // Nothing inherited: an environment of our own.
        p.environment = ["HOME": NSTemporaryDirectory(), "PATH": "/usr/bin:/bin", "PYTHONUNBUFFERED": "1", "PYTHONDONTWRITEBYTECODE": "1",
                         "OMP_NUM_THREADS": "4", "TMPDIR": NSTemporaryDirectory()]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        input = inPipe.fileHandleForWriting
        output = outPipe.fileHandleForReading
        buffer.removeAll()
        let ready = try readLine()
        guard ready["ready"] as? Bool == true else { throw NSError(domain: "Vera", code: 4, userInfo: [NSLocalizedDescriptionKey: "голос не загрузился"]) }
    }

    private func readLine() throws -> [String: Any] {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { return obj }
                continue
            }
            // `availableData` returns what the pipe has (read(upToCount:) would wait for the whole count).
            guard let chunk = output?.availableData, !chunk.isEmpty else {
                process = nil
                throw NSError(domain: "Vera", code: 5, userInfo: [NSLocalizedDescriptionKey: "процесс голоса закрылся"])
            }
            buffer.append(chunk)
        }
    }

    /// Blocking: call it off the main thread. Returns mono float PCM and its sample rate.
    func synthesize(_ text: String) throws -> (pcm: [Float], rate: Double, ms: Int) {
        lock.lock(); defer { lock.unlock() }
        if process?.isRunning != true { try start() }
        nextId += 1
        let req: [String: Any] = ["id": nextId, "text": text, "speaker": runtime.speaker, "sample_rate": runtime.sampleRate]
        var line = try JSONSerialization.data(withJSONObject: req)
        line.append(0x0A)
        try input?.write(contentsOf: line)
        let res = try readLine()
        if let error = res["error"] as? String { throw NSError(domain: "Vera", code: 6, userInfo: [NSLocalizedDescriptionKey: error]) }
        guard let b64 = res["pcm"] as? String, let data = Data(base64Encoded: b64) else { return ([], Double(runtime.sampleRate), 0) }
        let pcm = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return (pcm, Double(res["sample_rate"] as? Int ?? runtime.sampleRate), res["ms"] as? Int ?? 0)
    }

    func warm() throws {
        lock.lock(); defer { lock.unlock() }
        if process?.isRunning != true { try start() }
    }
}

/// Vera's mouth: sentences in, Silero speaks them in order at `speed` (pitch kept). The next sentence is synthesised
/// while the current one plays. `onSentence` fires when a sentence starts sounding (the text is shown with it).
public final class Mouth: @unchecked Sendable {
    public let runtime: MouthRuntime
    private let worker: Synthesizer
    /// Which voice speaks: «Swift» (ONNX, no Python) or «Python».
    public let voiceEngine: String
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    /// Synthesis runs here, one sentence at a time.
    private let synthQueue = DispatchQueue(label: "vera.mouth.synth")
    /// Playback state; guarded by `lock` (callbacks come from the audio thread, `stop` from the main one).
    private let lock = NSLock()
    private var generation = 0
    private var pending = 0
    private var revealQueue: [Sentence] = []
    private let format: AVAudioFormat

    /// A sentence starts sounding: its text and the tag it was given.
    public var onSentence: (@Sendable (Sentence) -> Void)?
    /// A sentence as it starts sounding: its text, tag, outline (peaks per 20 ms of audio) and length at `speed`.
    public struct Sentence: Sendable {
        public let text: String
        public let tag: Int
        public let peaks: [Float]
        public let seconds: Double
    }
    public var onIdle: (@Sendable () -> Void)?
    public var onError: (@Sendable (String) -> Void)?

    public var speed: Float = 1.05 { didSet { pitch.rate = speed } }

    public init(runtime: MouthRuntime) {
        self.runtime = runtime
        if let dir = MouthRuntime.voiceDir(), let ears = EarsRuntime.resolve(),
           FileManager.default.fileExists(atPath: ears.onnxruntime.path) {
            worker = SwiftVoice(dir: dir, onnxruntime: ears.onnxruntime, speaker: runtime.speaker); voiceEngine = "Swift"
        } else {
            worker = SileroWorker(runtime: runtime); voiceEngine = "Python"
        }
        format = AVAudioFormat(standardFormatWithSampleRate: Double(runtime.sampleRate), channels: 1)!
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        pitch.rate = speed
    }

    /// Loads the model in the background so the first answer is not late.
    public func warm() { synthQueue.async { [worker] in try? worker.warm() } }

    /// `text` is what the screen shows; `voice` (if given) is what Silero reads — numbers, signs and Latin as words.
    public func say(_ text: String, voice: String? = nil, tag: Int = 0) {
        lock.lock(); let gen = generation; pending += 1; lock.unlock()
        synthQueue.async { [self] in
            do {
                let spoken = (voice ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !spoken.isEmpty else { lock.lock(); finishLocked(played: false); lock.unlock(); return }
                let out = try worker.synthesize(spoken)
                lock.lock(); defer { lock.unlock() }
                guard gen == generation else { return }
                guard !out.pcm.isEmpty, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(out.pcm.count)) else {
                    finishLocked(played: false); return
                }
                buf.frameLength = AVAudioFrameCount(out.pcm.count)
                out.pcm.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: out.pcm.count) }
                if !engine.isRunning { try engine.start() }
                player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    guard let self else { return }
                    self.lock.lock(); defer { self.lock.unlock() }
                    if gen == self.generation { self.finishLocked(played: true) }
                }
                // The text appears when its sound starts: now if nothing plays, else when the one before ends.
                let per = max(1, Int(format.sampleRate / 50))
                let peaks = stride(from: 0, to: out.pcm.count, by: per).map { i in
                    out.pcm[i..<min(i + per, out.pcm.count)].reduce(Float(0)) { max($0, abs($1)) }
                }
                let sentence = Sentence(text: text, tag: tag, peaks: peaks,
                                        seconds: Double(out.pcm.count) / format.sampleRate / Double(max(0.1, speed)))
                revealQueue.append(sentence)
                if revealQueue.count == 1 { onSentence?(sentence) }
                if !player.isPlaying { player.play() }
            } catch {
                lock.lock(); defer { lock.unlock() }
                guard gen == generation else { return }
                onError?(error.localizedDescription)
                finishLocked(played: false)
            }
        }
    }

    private func finishLocked(played: Bool) {
        pending = max(0, pending - 1)
        if played, !revealQueue.isEmpty {
            revealQueue.removeFirst()
            if let next = revealQueue.first { onSentence?(next) }
        }
        if pending == 0 { onIdle?() }
    }

    /// Silence now: the queue is dropped and the sound stops at once.
    public func stop() {
        lock.lock()
        generation += 1
        pending = 0
        revealQueue.removeAll()
        lock.unlock()
        player.stop()
        onIdle?()
    }
}
