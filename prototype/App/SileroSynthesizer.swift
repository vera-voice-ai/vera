import Foundation
import Response
import Sensors

/// Response's speech engine for now: Silero (voice baya) through the local worker.
struct SileroSynthesizer: Synthesizer {
    let speech: SileroSpeech
    func synthesize(text: String) async throws -> Data { try await speech.synthesize(text: text) }
}
