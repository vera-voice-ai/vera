import Foundation

/// What Vera does with what she hears (ADR-013). Every owner reply restarts the timer of Ready and Working.
public enum VeraMode: String, Sendable, CaseIterable {
    /// After launch or an activation phrase: answers without her name, goes quiet after a minute.
    case ready
    /// After a request that needed a tool: answers without her name for ten minutes.
    case working
    /// Listens but does not speak; finishes what is running; wakes on her name.
    case silent
    /// Not listening, nothing running; wakes when the microphone is switched on.
    case sleep

    public var title: String {
        switch self {
        case .ready: return "Готовность"
        case .working: return "В работе"
        case .silent: return "Тишина"
        case .sleep: return "Сон"
        }
    }
}
