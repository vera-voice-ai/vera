import Foundation

/// Silero TTS (Russian, 48 kHz) through Vera 1's local worker: JSON in, base64 WAV out. The voice is chosen per call.
public final class SileroSpeech: Sendable {
    private let worker: JSONLineWorker
    public let voice: String

    public static func isAvailable(_ runtime: ModelRuntime) -> Bool {
        FileManager.default.isExecutableFile(atPath: runtime.pythonURL.path)
            && FileManager.default.fileExists(atPath: runtime.vera1Root.appending(path: "Support/silero-tts/worker.py").path)
    }

    public init(runtime: ModelRuntime, voice: String = "baya") {
        self.voice = voice
        let script = runtime.vera1Root.appending(path: "Support/silero-tts/worker.py")
        worker = JSONLineWorker(name: "silero-tts", pythonURL: runtime.pythonURL, scriptURL: script,
                                environment: ["PYTHONUNBUFFERED": "1"],
                                logURL: runtime.appSupportURL.appending(path: "Logs/silero-tts.stderr.log"))
    }

    public func warm() async throws { _ = try await worker.warm() }

    public var processIdentifier: Int32? { worker.processIdentifier }

    public func synthesize(text: String) async throws -> Data {
        let request = try JSONSerialization.data(withJSONObject: ["text": text, "speaker": voice, "speed": 1.0] as [String: Any])
        let line = try await worker.send(String(decoding: request, as: UTF8.self), timeout: 45)
        guard let data = line.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WorkerError.badResponse }
        if let error = object["error"] as? String { throw WorkerError.inferenceFailed(error) }
        guard let encoded = object["audio"] as? String, let audio = Data(base64Encoded: encoded) else { throw WorkerError.badResponse }
        return audio
    }

    public func stop() async { await worker.stop() }
}
