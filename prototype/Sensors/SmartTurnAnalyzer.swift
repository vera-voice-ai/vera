import Foundation

public struct SmartTurnEstimate: Sendable {
    /// Probability that the speaker has finished the turn, from audio alone. Not calibrated by us.
    public let probability: Double
    public let milliseconds: Int
}

/// Smart Turn v3.2: reads the last 8 s of audio (prosody and pauses, no text) and says whether the turn is
/// finished. Complements the text judge: it needs no transcript, so it can answer before the ASR text arrives.
public final class SmartTurnAnalyzer: Sendable {
    private let worker: JSONLineWorker

    public init(runtime: ModelRuntime) {
        let script = Bundle.module.resourceURL!.appending(path: "Workers/smart-turn-worker.py")
        worker = JSONLineWorker(name: "smart-turn", pythonURL: runtime.pythonURL, scriptURL: script,
                                environment: ["VERA_SMART_TURN_MODEL": runtime.smartTurnModelURL.path, "PYTHONUNBUFFERED": "1"],
                                logURL: runtime.appSupportURL.appending(path: "Logs/smart-turn.stderr.log"))
    }

    public func warm() async throws { _ = try await worker.warm() }

    public var processIdentifier: Int32? { worker.processIdentifier }

    public func estimate(wav: Data) async throws -> SmartTurnEstimate {
        let request = try JSONSerialization.data(withJSONObject: ["wav_base64": wav.base64EncodedString()])
        let line = try await worker.send(String(decoding: request, as: UTF8.self), timeout: 15)
        guard let data = line.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WorkerError.badResponse }
        if let error = object["error"] as? String { throw WorkerError.inferenceFailed(error) }
        guard let probability = object["probability"] as? Double else { throw WorkerError.badResponse }
        return SmartTurnEstimate(probability: probability, milliseconds: object["elapsed_ms"] as? Int ?? 0)
    }

    public func stop() async { await worker.stop() }
}
