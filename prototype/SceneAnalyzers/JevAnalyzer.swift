import Foundation
import Sensors

public struct JevDecision: Sendable {
    /// `complete` or `continue`.
    public let choice: String
    /// The model's probability for its choice. Not calibrated.
    public let confidence: Double
    public let modelMilliseconds: Int
}

/// Jev-Style-2B-Decision (v4, MLX): answers one question, "has the person finished this turn?".
/// It reads text only. The worker script is Vera 1's, copied unchanged in logic.
public final class JevAnalyzer: Sendable {
    private let worker: JSONLineWorker

    public init(runtime: ModelRuntime) {
        let script = Bundle.module.resourceURL!.appending(path: "Workers/jev-worker.py")
        worker = JSONLineWorker(name: "jev", pythonURL: runtime.jevPythonURL, scriptURL: script,
                                environment: ["HF_HUB_OFFLINE": "1", "PYTHONUNBUFFERED": "1"],
                                logURL: runtime.appSupportURL.appending(path: "Logs/jev.stderr.log"))
    }

    public func warm() async throws { _ = try await worker.warm() }

    public var processIdentifier: Int32? { worker.processIdentifier }

    public func decide(transcript: String, context: [String]) async throws -> JevDecision {
        let request = try JSONSerialization.data(withJSONObject: ["context": context.joined(separator: "\n"), "transcript": transcript])
        let line = try await worker.send(String(decoding: request, as: UTF8.self), timeout: 20)
        guard let data = line.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WorkerError.badResponse }
        if let error = object["error"] as? String { throw WorkerError.inferenceFailed(error) }
        guard let choice = object["choice"] as? String else { throw WorkerError.badResponse }
        return JevDecision(choice: choice, confidence: object["confidence"] as? Double ?? 0,
                           modelMilliseconds: object["elapsed_ms"] as? Int ?? 0)
    }

    public func stop() async { await worker.stop() }
}
