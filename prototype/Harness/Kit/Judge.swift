import Foundation

/// What answers the judge's question ("has the person finished?") during a replay.
public enum Judge: String, Sendable, CaseIterable {
    /// No verdicts: the scene falls back to its timeouts.
    case none
    /// The verdicts recorded in the scenario, at their original times. Stale ones are ignored by the scene.
    case recorded
    /// Stand-in rule, not a quality measure: complete if the text ends a sentence or has 5 or more words.
    case rule
    case alwaysComplete
    case alwaysContinue

    /// The answer this policy injects for a turn with the given text, or nil when it injects nothing.
    func answer(for text: String) -> String? {
        switch self {
        case .none, .recorded: return nil
        case .rule: return Judge.ruleChoice(text)
        case .alwaysComplete: return "complete"
        case .alwaysContinue: return "continue"
        }
    }

    static func ruleChoice(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.last, ".?!…".contains(last) { return "complete" }
        return trimmed.split(whereSeparator: \.isWhitespace).count >= 5 ? "complete" : "continue"
    }
}
