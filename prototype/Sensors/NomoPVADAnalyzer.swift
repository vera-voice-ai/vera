import Foundation

public final class NomoPVADAnalyzer: Sendable {
    private let worker: JSONLineWorker

    public init(runtime: ModelRuntime, enrollmentWAV: URL) {
        let script = Bundle.module.resourceURL!.appending(path: "Workers/NomoPVADWorker.py")
        worker = JSONLineWorker(name: "nomo-pvad", pythonURL: runtime.nomoPythonURL, scriptURL: script,
                                environment: ["VERA_NOMO_MODEL_DIR": runtime.nomoModelDirectory.path,
                                             "VERA_NOMO_ENROLLMENT_WAV": enrollmentWAV.path],
                                logURL: runtime.appSupportURL.appending(path: "Logs/nomo-pvad.stderr.log"))
    }

    public func warm() async throws {
        _ = try await worker.warm()
    }

    public func score(_ samples: [Float]) async throws -> Double {
        let raw = samples.withUnsafeBytes { Data($0) }
        let line = try JSONSerialization.data(withJSONObject: ["pcm_f32le_base64": raw.base64EncodedString()])
        let response = try await worker.send(String(decoding: line, as: UTF8.self), timeout: 8)
        guard let data = response.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkerError.badResponse
        }
        if let error = object["error"] as? String { throw WorkerError.inferenceFailed(error) }
        guard let probability = object["probability"] as? Double else { throw WorkerError.badResponse }
        return probability
    }

    public func stop() async { await worker.stop() }
}
