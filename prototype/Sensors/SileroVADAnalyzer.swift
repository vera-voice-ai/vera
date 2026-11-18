import Foundation

public struct SpeechProbability: Sendable {
    /// One value per 512-sample (32 ms) window of the chunk.
    public let windows: [Double]
    public var maximum: Double { windows.max() ?? 0 }
    public var mean: Double { windows.isEmpty ? 0 : windows.reduce(0, +) / Double(windows.count) }
}

/// Silero VAD: how likely each 32 ms of audio is speech. Stateful across the chunks of one stream, so chunks must
/// be fed in order; `reset()` starts a new stream. It does not decide anything: the energy gate still cuts utterances.
public final class SileroVADAnalyzer: Sendable {
    private let worker: JSONLineWorker

    public init(runtime: ModelRuntime) {
        let script = Bundle.module.resourceURL!.appending(path: "Workers/silero-vad-worker.py")
        worker = JSONLineWorker(name: "silero-vad", pythonURL: runtime.pythonURL, scriptURL: script,
                                environment: ["VERA_SILERO_VAD_MODEL": runtime.sileroVADModelURL.path, "PYTHONUNBUFFERED": "1"],
                                logURL: runtime.appSupportURL.appending(path: "Logs/silero-vad.stderr.log"))
    }

    public func warm() async throws { _ = try await worker.warm() }

    public var processIdentifier: Int32? { worker.processIdentifier }

    public func score(_ samples: [Float]) async throws -> SpeechProbability {
        let raw = samples.withUnsafeBytes { Data($0) }
        let line = try JSONSerialization.data(withJSONObject: ["pcm_f32le_base64": raw.base64EncodedString()])
        let response = try await worker.send(String(decoding: line, as: UTF8.self), timeout: 5)
        guard let data = response.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WorkerError.badResponse }
        if let error = object["error"] as? String { throw WorkerError.inferenceFailed(error) }
        guard let windows = object["probabilities"] as? [Double] else { throw WorkerError.badResponse }
        return SpeechProbability(windows: windows)
    }

    public func reset() async {
        _ = try? await worker.send("{\"reset\": true}", timeout: 5)
    }

    public func stop() async { await worker.stop() }
}
