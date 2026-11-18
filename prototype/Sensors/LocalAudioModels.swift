import Foundation

public struct SpeakerEmbedding: Codable, Sendable {
    public let values: [Float]
    public let dimension: Int
}

public struct VoxLockResult: Sendable {
    public let wav: Data
    public let inferenceMilliseconds: Int
}

public final class GigaAMAnalyzer: Sendable {
    private let runtime: ModelRuntime
    private let worker: JSONLineWorker

    public init(runtime: ModelRuntime) {
        self.runtime = runtime
        let scripts = Bundle.module.resourceURL!.appending(path: "Workers", directoryHint: .isDirectory)
        self.worker = JSONLineWorker(
            name: "gigaam",
            pythonURL: runtime.pythonURL,
            scriptURL: scripts.appending(path: "gigaam-worker.py"),
            environment: [
                "VERA_GIGAAM_MODEL_DIR": runtime.gigaAMModelURL.path,
                "VERA_MODEL_CACHE": runtime.appSupportURL.appending(path: "Models/HuggingFace", directoryHint: .isDirectory).path,
                "GIGAAM_PROVIDERS": "CPUExecutionProvider",
                "PYTHONUNBUFFERED": "1"
            ],
            logURL: runtime.appSupportURL.appending(path: "Logs/gigaam.stderr.log")
        )
    }

    public func warm() async throws -> String { try await worker.warm() }

    public func transcribe(wav: Data) async throws -> String {
        let request = try JSONEncoder().encode(AudioRequest(wavBase64: wav.base64EncodedString()))
        let response = try await worker.send(String(decoding: request, as: UTF8.self))
        let result = try JSONDecoder().decode(TranscriptionResponse.self, from: Data(response.utf8))
        if let error = result.error { throw WorkerError.inferenceFailed(error) }
        return result.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private struct AudioRequest: Encodable { let wavBase64: String; enum CodingKeys: String, CodingKey { case wavBase64 = "wav_base64" } }
    private struct TranscriptionResponse: Decodable { let text: String?; let error: String? }
}

public final class SpeakerEmbeddingAnalyzer: Sendable {
    private let worker: JSONLineWorker

    public init(runtime: ModelRuntime) {
        let scripts = Bundle.module.resourceURL!.appending(path: "Workers", directoryHint: .isDirectory)
        self.worker = JSONLineWorker(
            name: "speaker-embedding",
            pythonURL: runtime.pythonURL,
            scriptURL: scripts.appending(path: "speaker-embedding-worker.py"),
            environment: ["VERA_SPEAKER_MODEL": runtime.speakerModelURL.path, "PYTHONUNBUFFERED": "1"],
            logURL: runtime.appSupportURL.appending(path: "Logs/speaker-embedding.stderr.log")
        )
    }

    public func warm() async throws -> String { try await worker.warm() }

    public func embed(wav: Data) async throws -> SpeakerEmbedding {
        let request = try JSONEncoder().encode(AudioRequest(wavBase64: wav.base64EncodedString()))
        let response = try await worker.send(String(decoding: request, as: UTF8.self))
        let result = try JSONDecoder().decode(EmbeddingResponse.self, from: Data(response.utf8))
        if let error = result.error { throw WorkerError.inferenceFailed(error) }
        guard let values = result.embedding, !values.isEmpty else { throw WorkerError.badResponse }
        return SpeakerEmbedding(values: values, dimension: result.dimension ?? values.count)
    }

    private struct AudioRequest: Encodable { let wavBase64: String; enum CodingKeys: String, CodingKey { case wavBase64 = "wav_base64" } }
    private struct EmbeddingResponse: Decodable {
        let embedding: [Float]?
        let dimension: Int?
        let error: String?
        enum CodingKeys: String, CodingKey { case embedding, error; case dimension = "dim" }
    }
}

public final class VoxLockAnalyzer: Sendable {
    private let worker: JSONLineWorker

    public init(runtime: ModelRuntime, ownerVoiceSample: URL) {
        let scripts = Bundle.module.resourceURL!.appending(path: "Workers", directoryHint: .isDirectory)
        self.worker = JSONLineWorker(
            name: "voxlock",
            pythonURL: runtime.pythonURL,
            scriptURL: scripts.appending(path: "voxlock-worker.py"),
            environment: [
                "VERA_VOXLOCK_MODEL_DIR": runtime.voxLockModelDirectory.path,
                "VERA_OWNER_VOICE_SAMPLE": ownerVoiceSample.path,
                "PYTHONUNBUFFERED": "1"
            ],
            logURL: runtime.appSupportURL.appending(path: "Logs/voxlock.stderr.log")
        )
    }

    public func warm() async throws -> String { try await worker.warm() }

    public func isolate(wav: Data) async throws -> VoxLockResult {
        let started = ContinuousClock.now
        let request = try JSONEncoder().encode(AudioRequest(wavBase64: wav.base64EncodedString()))
        let response = try await worker.send(String(decoding: request, as: UTF8.self))
        let result = try JSONDecoder().decode(IsolationResponse.self, from: Data(response.utf8))
        if let error = result.error { throw WorkerError.inferenceFailed(error) }
        guard let encoded = result.wavBase64, let output = Data(base64Encoded: encoded) else { throw WorkerError.badResponse }
        let elapsed = result.durationMilliseconds ?? Self.milliseconds(since: started)
        return VoxLockResult(wav: output, inferenceMilliseconds: elapsed)
    }

    private static func milliseconds(since instant: ContinuousClock.Instant) -> Int {
        let duration = instant.duration(to: .now)
        let parts = duration.components
        return Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    private struct AudioRequest: Encodable { let wavBase64: String; enum CodingKeys: String, CodingKey { case wavBase64 = "wav_base64" } }
    private struct IsolationResponse: Decodable {
        let wavBase64: String?
        let durationMilliseconds: Int?
        let error: String?
        enum CodingKeys: String, CodingKey { case error; case wavBase64 = "wav_base64"; case durationMilliseconds = "duration_ms" }
    }
}
