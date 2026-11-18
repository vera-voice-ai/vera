import AVFoundation
import Foundation
import Observation
import SignalBus

/// Turns text into audio. Any engine can sit behind it.
public protocol Synthesizer: Sendable {
    /// WAV bytes for the text.
    func synthesize(text: String) async throws -> Data
}

/// Plays WAV audio and returns when it has finished.
public protocol AudioPlaying: Sendable {
    func play(wav: Data) async throws
}

/// The speaking half of Response. Core asks (`output.speech.requested`, a command only Core may send); this
/// executes and reports what actually happened as events: started, ended or failed. A command is not a result.
@MainActor
@Observable
public final class ResponseSpeaker {
    public struct Utterance: Identifiable, Sendable {
        public enum State: Sendable { case synthesizing, speaking, done, failed }
        public let id: String
        public let text: String
        public var state: State = .synthesizing
        public var synthesisMilliseconds = 0
        public var speakingMilliseconds = 0
        public var error: String?
        public let requestedAt = Date()
    }

    /// Newest first, the last 20.
    public private(set) var utterances: [Utterance] = []
    public var isMuted = false
    public let voice: String

    private let synthesizer: any Synthesizer
    private let player: any AudioPlaying

    public init(synthesizer: any Synthesizer, player: any AudioPlaying, voice: String = "baya") {
        self.synthesizer = synthesizer; self.player = player; self.voice = voice
    }

    public func consume(_ bus: SignalBus) async {
        let stream = await bus.subscribe()
        for await message in stream {
            guard message.kind == .command, message.type == "output.speech.requested", message.target == "Response",
                  let text = message.payload["text"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            await speak(text, requestID: message.id, bus: bus)
        }
    }

    public func speak(_ text: String, requestID: UUID = UUID(), bus: SignalBus?) async {
        let id = requestID.uuidString.lowercased()
        func publish(_ type: String, _ payload: [String: String]) async {
            await bus?.publish(SignalMessage(kind: .event, domain: .response, source: "Response.Speaker", type: type,
                                             subjectID: id, correlationID: id, causationID: id,
                                             payload: payload.merging(["voice": voice]) { a, _ in a }))
        }
        utterances.insert(Utterance(id: id, text: text), at: 0)
        if utterances.count > 20 { utterances.removeLast(utterances.count - 20) }
        if isMuted {
            update(id) { $0.state = .failed; $0.error = "muted" }
            await publish("output.speech.failed", ["reason": "muted"])
            return
        }
        let synthesisStart = ContinuousClock.now
        let wav: Data
        do { wav = try await synthesizer.synthesize(text: text) } catch {
            update(id) { $0.state = .failed; $0.error = "\(error)" }
            await publish("output.speech.failed", ["reason": "synthesis", "error": "\(error)"])
            return
        }
        let synthesisMs = Self.milliseconds(since: synthesisStart)
        update(id) { $0.state = .speaking; $0.synthesisMilliseconds = synthesisMs }
        await publish("output.speech.started", ["synthesis_ms": "\(synthesisMs)", "chars": "\(text.count)"])
        let playStart = ContinuousClock.now
        do { try await player.play(wav: wav) } catch {
            update(id) { $0.state = .failed; $0.error = "\(error)" }
            await publish("output.speech.failed", ["reason": "playback", "error": "\(error)"])
            return
        }
        let speakingMs = Self.milliseconds(since: playStart)
        update(id) { $0.state = .done; $0.speakingMilliseconds = speakingMs }
        await publish("output.speech.ended", ["speaking_ms": "\(speakingMs)"])
    }

    private func update(_ id: String, _ change: (inout Utterance) -> Void) {
        guard let index = utterances.firstIndex(where: { $0.id == id }) else { return }
        change(&utterances[index])
    }

    private static func milliseconds(since instant: ContinuousClock.Instant) -> Int {
        let d = instant.duration(to: .now)
        return Int(d.components.seconds * 1_000 + d.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// Plays through the default output with AVAudioPlayer.
public final class WavPlayer: NSObject, AudioPlaying, AVAudioPlayerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var player: AVAudioPlayer?

    public override init() { super.init() }

    public func play(wav: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                do {
                    let player = try AVAudioPlayer(data: wav)
                    player.delegate = self
                    self.lock.withLock { self.player = player; self.continuation = continuation }
                    if !player.play() { self.finish(throwing: NSError(domain: "VeraResponse", code: 1, userInfo: [NSLocalizedDescriptionKey: "playback did not start"])) }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(throwing: flag ? nil : NSError(domain: "VeraResponse", code: 2, userInfo: [NSLocalizedDescriptionKey: "playback failed"]))
    }

    private func finish(throwing error: Error?) {
        let pending: CheckedContinuation<Void, Error>? = lock.withLock { defer { continuation = nil; player = nil }; return continuation }
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}
