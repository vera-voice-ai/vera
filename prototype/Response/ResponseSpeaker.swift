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
    /// Plays faster or slower; 1.0 is as synthesized. A player without rate control plays at the normal speed.
    func play(wav: Data, rate: Float) async throws
    /// The same at a given volume, 0 to 1 (1 is as synthesized). A player without volume control plays at full volume.
    func play(wav: Data, rate: Float, volume: Float) async throws
    /// Cuts the current playback short; `play` then returns.
    func stop() async
}

public extension AudioPlaying {
    func stop() async {}
    func play(wav: Data, rate: Float) async throws { try await play(wav: wav) }
    func play(wav: Data, rate: Float, volume: Float) async throws { try await play(wav: wav, rate: rate) }
}

/// Quiet hours: at night everything she says is turned down, on top of any volume the request asked for.
public struct QuietHours: Sendable, Equatable {
    public var enabled = true
    public var startHour = 23
    public var endHour = 7
    /// How loud she is at night compared with the day (1 is the same).
    public var nightLevel: Float = 0.6

    public init() {}

    public func level(at date: Date, calendar: Calendar = .current) -> Float {
        guard enabled else { return 1 }
        let hour = calendar.component(.hour, from: date)
        let night = startHour > endHour ? (hour >= startHour || hour < endHour) : (hour >= startHour && hour < endHour)
        return night ? nightLevel : 1
    }
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
        /// The run whose answer this sentence belongs to; nil for speech not started by a task.
        public var taskID: String?
        public let requestedAt = Date()
    }

    /// Newest first, the last 20.
    public private(set) var utterances: [Utterance] = []
    public var isMuted = false
    public let voice: String
    public var quietHours = QuietHours()
    /// The current time; tests replace it.
    public var clock: () -> Date = { Date() }
    /// Playback speed: 1.0 is as synthesized, 1.05 is 5 % faster. Read for every sentence, so a change is heard at once.
    public var speed: Double = ResponseSpeaker.defaultSpeed
    public static let defaultSpeed = 1.05
    public static let speedRange: ClosedRange<Double> = 0.8...1.5

    /// Bumped by a stop command: sentences queued before it are dropped.
    private var generation = 0
    private var playTail: Swift.Task<Void, Never>?
    private let synthesizer: any Synthesizer
    private let player: any AudioPlaying

    public init(synthesizer: any Synthesizer, player: any AudioPlaying, voice: String = "baya") {
        self.synthesizer = synthesizer; self.player = player; self.voice = voice
    }

    public func consume(_ bus: SignalBus) async {
        let stream = await bus.subscribe()
        for await message in stream {
            if message.kind == .command, message.type == "output.speech.stop", message.target == "Response" {
                generation += 1
                playTail = nil
                await player.stop()
                await bus.publish(SignalMessage(kind: .event, domain: .response, source: "Response.Speaker", type: "output.speech.stopped",
                                                payload: ["reason": message.payload["reason"] ?? ""]))
                continue
            }
            guard message.kind == .command, message.type == "output.speech.requested", message.target == "Response",
                  let text = message.payload["text"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            // Synthesis of the next sentence starts at once and runs while the previous one is still playing; playback keeps the order.
            let prefetched = isMuted ? nil : Swift.Task { try await self.synthesizer.synthesize(text: text) }
            let previous = playTail
            let mine = generation
            let taskID = message.payload["task_id"]
            let volume = message.payload["volume"].flatMap(Float.init).map { min(1, max(0.05, $0)) } ?? 1
            playTail = Swift.Task { @MainActor in
                await previous?.value
                guard mine == self.generation else { prefetched?.cancel(); return }
                await self.speak(text, requestID: message.id, taskID: taskID, volume: volume, bus: bus, prefetched: prefetched)
            }
        }
    }

    public func speak(_ text: String, requestID: UUID = UUID(), taskID: String? = nil, volume: Float = 1, bus: SignalBus?,
                      prefetched: Swift.Task<Data, Error>? = nil) async {
        let id = requestID.uuidString.lowercased()
        func publish(_ type: String, _ payload: [String: String]) async {
            await bus?.publish(SignalMessage(kind: .event, domain: .response, source: "Response.Speaker", type: type,
                                             subjectID: id, correlationID: id, causationID: id,
                                             payload: payload.merging(["voice": voice, "task_id": taskID ?? ""]) { a, _ in a }))
        }
        var entry = Utterance(id: id, text: text)
        entry.taskID = taskID
        utterances.insert(entry, at: 0)
        if utterances.count > 20 { utterances.removeLast(utterances.count - 20) }
        if isMuted {
            update(id) { $0.state = .failed; $0.error = "muted" }
            await publish("output.speech.failed", ["reason": "muted"])
            return
        }
        let synthesisStart = ContinuousClock.now
        let wav: Data
        do {
            if let prefetched { wav = try await prefetched.value } else { wav = try await synthesizer.synthesize(text: text) }
        } catch {
            update(id) { $0.state = .failed; $0.error = "\(error)" }
            await publish("output.speech.failed", ["reason": "synthesis", "error": "\(error)"])
            return
        }
        let synthesisMs = Self.milliseconds(since: synthesisStart)
        update(id) { $0.state = .speaking; $0.synthesisMilliseconds = synthesisMs }
        await publish("output.speech.started", ["synthesis_ms": "\(synthesisMs)", "chars": "\(text.count)"])
        let playStart = ContinuousClock.now
        do { try await player.play(wav: wav, rate: Float(speed), volume: volume * quietHours.level(at: clock())) } catch {
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

    public func play(wav: Data) async throws { try await play(wav: wav, rate: 1.0, volume: 1) }

    public func play(wav: Data, rate: Float) async throws { try await play(wav: wav, rate: rate, volume: 1) }

    public func play(wav: Data, rate: Float, volume: Float) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                do {
                    let player = try AVAudioPlayer(data: wav)
                    player.volume = min(1, max(0, volume))
                    player.enableRate = true
                    player.rate = min(2.0, max(0.5, rate))
                    player.delegate = self
                    self.lock.withLock { self.player = player; self.continuation = continuation }
                    if !player.play() { self.finish(throwing: NSError(domain: "VeraResponse", code: 1, userInfo: [NSLocalizedDescriptionKey: "playback did not start"])) }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func stop() async {
        DispatchQueue.main.async { self.lock.withLock { self.player }?.stop() }
        finish(throwing: nil)
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(throwing: flag ? nil : NSError(domain: "VeraResponse", code: 2, userInfo: [NSLocalizedDescriptionKey: "playback failed"]))
    }

    private func finish(throwing error: Error?) {
        let pending: CheckedContinuation<Void, Error>? = lock.withLock { defer { continuation = nil; player = nil }; return continuation }
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}
