import Foundation
import Scene
import Sensors

/// Lets the scene ask Jev whether a turn of speech is finished.
public struct JevTurnJudge: TurnJudge {
    private let analyzer: JevAnalyzer

    public init(analyzer: JevAnalyzer) {
        self.analyzer = analyzer
    }

    public func judge(transcript: String, context: [String]) async throws -> (choice: String, confidence: Double, modelMilliseconds: Int) {
        let decision = try await analyzer.decide(transcript: transcript, context: context)
        return (decision.choice, decision.confidence, decision.modelMilliseconds)
    }
}
