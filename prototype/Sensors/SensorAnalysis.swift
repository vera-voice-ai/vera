import Foundation
import SignalBus

public struct AnalyzerSelection: Sendable {
    public var gigaAM = true
    public var camPlus = true
    public var voxLock = false
    public init(gigaAM: Bool = true, camPlus: Bool = true, voxLock: Bool = false) {
        self.gigaAM = gigaAM; self.camPlus = camPlus; self.voxLock = voxLock
    }
}

public struct SensorRunResult: Sendable {
    public let isolatedWav: Data?
}

public final class SensorAnalysis: Sendable {
    private let runtime: ModelRuntime
    private let gigaAM: GigaAMAnalyzer
    private let camPlus: SpeakerEmbeddingAnalyzer

    public init(runtime: ModelRuntime, gigaAM: GigaAMAnalyzer? = nil,
                camPlus: SpeakerEmbeddingAnalyzer? = nil) {
        self.runtime = runtime
        self.gigaAM = gigaAM ?? GigaAMAnalyzer(runtime: runtime)
        self.camPlus = camPlus ?? SpeakerEmbeddingAnalyzer(runtime: runtime)
    }

    public func run(segment: AudioSegment, selection: AnalyzerSelection, bus: SignalBus,
                    ownerVoiceSample: URL?, references: [SpeakerReference] = []) async -> SensorRunResult {
        let runID = UUID().uuidString.lowercased()
        let base = ["run_id": runID, "file": segment.sourceURL.lastPathComponent,
                    "offset_start_s": Self.number(segment.start), "offset_end_s": Self.number(segment.end),
                    "duration_s": Self.number(segment.duration), "sample_rate_hz": "\(segment.sampleRate)",
                    "channels": "\(segment.channels)", "pcm": "pcm_s16le"]
        await bus.publish(SignalMessage(source: "Sensors.AudioFile", type: "audio.segment.selected", payload: base))
        let energy = AudioEnergyAnalyzer.analyze(segment)
        await bus.publish(SignalMessage(source: "Sensors.AudioEnergy", type: "audio.energy.profile.completed",
                                        payload: base.merging([
                                            "rms": Self.number(energy.rms), "peak": Self.number(energy.peak),
                                            "active_percent": Self.number(energy.activePercent),
                                            "energy_threshold": Self.number(energy.threshold),
                                            "window_count": "\(energy.windows.count)",
                                            "method": "energy threshold baseline; not ML VAD"
                                        ]) { _, new in new }))

        async let transcriptTask = selection.gigaAM ? transcribe(segment.wav, model: gigaAM, runID: runID, lane: "raw", bus: bus) : nil
        async let speakerTask = selection.camPlus ? identify(segment.wav, runID: runID, bus: bus) : nil
        _ = await transcriptTask
        let embedding = await speakerTask
        if let embedding {
            for reference in references {
                guard let best = SpeakerReferenceStore.bestCosine(embedding.values, against: reference) else { continue }
                await bus.publish(SignalMessage(source: "Sensors.CAM++", type: "speaker.reference.similarity.computed",
                                                payload: ["run_id": runID, "reference": reference.label,
                                                          "cosine_similarity": Self.number(best.similarity),
                                                          "best_template_index": "\(best.templateIndex)",
                                                          "template_count": "\(reference.templateCount)",
                                                          "interpretation": "raw similarity; not a calibrated probability"]))
            }
        }

        var isolatedWav: Data?
        if selection.voxLock, let ownerVoiceSample {
            let source = VoxLockAnalyzer(runtime: runtime, ownerVoiceSample: ownerVoiceSample)
            await bus.publish(SignalMessage(source: "Sensors.VoxLock", type: "analyzer.started",
                                            payload: base.merging(["analyzer": "VoxLock", "input": "raw audio"]) { _, n in n }))
            let started = ContinuousClock.now
            do {
                let result = try await source.isolate(wav: segment.wav)
                isolatedWav = result.wav
                await bus.publish(SignalMessage(source: "Sensors.VoxLock", type: "audio.speaker.isolated",
                                                payload: base.merging(["analyzer": "VoxLock", "model_time_ms": "\(result.inferenceMilliseconds)",
                                                                       "output_sample_rate_hz": "16000", "output_channels": "1"]) { _, n in n }))
                let elapsed = Self.milliseconds(since: started)
                await transcribe(result.wav, model: gigaAM, runID: runID, lane: "voxlock", bus: bus)
                await bus.publish(SignalMessage(source: "Sensors.VoxLock", type: "analyzer.completed",
                                                payload: base.merging(["analyzer": "VoxLock", "elapsed_ms": "\(elapsed)"]) { _, n in n }))
            } catch {
                await bus.publish(SignalMessage(source: "Sensors.VoxLock", type: "analyzer.failed",
                                                payload: base.merging(["analyzer": "VoxLock", "error": error.localizedDescription]) { _, n in n }))
            }
        }
        await bus.publish(SignalMessage(source: "Sensors.Audio", type: "audio.segment.processing.completed",
                                        payload: base.merging(["gigaam_enabled": "\(selection.gigaAM)",
                                                               "campp_enabled": "\(selection.camPlus)",
                                                               "voxlock_enabled": "\(selection.voxLock)"]) { _, n in n }))
        return SensorRunResult(isolatedWav: isolatedWav)
    }

    private func transcribe(_ wav: Data, model: GigaAMAnalyzer, runID: String, lane: String,
                            bus: SignalBus) async {
        let start = ContinuousClock.now
        let origin = lane == "raw" ? "Sensors.GigaAM" : "Sensors.GigaAM.VoxLock"
        await bus.publish(SignalMessage(source: origin, type: "analyzer.started",
                                        payload: ["run_id": runID, "analyzer": "GigaAM v3", "lane": lane]))
        do {
            let transcript = try await model.transcribe(wav: wav)
            await bus.publish(SignalMessage(source: origin, type: "speech.transcript.final",
                                            payload: ["run_id": runID, "analyzer": "GigaAM v3", "lane": lane,
                                                      "text": transcript, "elapsed_ms": "\(Self.milliseconds(since: start))",
                                                      "confidence": "not provided by this model adapter"]))
        } catch {
            await bus.publish(SignalMessage(source: origin, type: "analyzer.failed",
                                            payload: ["run_id": runID, "analyzer": "GigaAM v3", "lane": lane,
                                                      "error": error.localizedDescription,
                                                      "elapsed_ms": "\(Self.milliseconds(since: start))"]))
        }
    }

    private func identify(_ wav: Data, runID: String, bus: SignalBus) async -> SpeakerEmbedding? {
        let start = ContinuousClock.now
        await bus.publish(SignalMessage(source: "Sensors.CAM++", type: "analyzer.started",
                                        payload: ["run_id": runID, "analyzer": "CAM++ speaker embedding"]))
        do {
            let result = try await camPlus.embed(wav: wav)
            let vectorData = try JSONEncoder().encode(result.values)
            await bus.publish(SignalMessage(source: "Sensors.CAM++", type: "speaker.embedding.extracted",
                                            payload: ["run_id": runID, "analyzer": "CAM++", "dimension": "\(result.dimension)",
                                                      "elapsed_ms": "\(Self.milliseconds(since: start))",
                                                      "embedding_json": String(decoding: vectorData, as: UTF8.self),
                                                      "classification": "none; embedding only"]))
            return result
        } catch {
            await bus.publish(SignalMessage(source: "Sensors.CAM++", type: "analyzer.failed",
                                            payload: ["run_id": runID, "analyzer": "CAM++", "error": error.localizedDescription,
                                                      "elapsed_ms": "\(Self.milliseconds(since: start))"]))
            return nil
        }
    }

    private static func milliseconds(since instant: ContinuousClock.Instant) -> Int {
        let duration = instant.duration(to: .now)
        return Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func number(_ value: Double) -> String { String(format: "%.3f", value) }
}

