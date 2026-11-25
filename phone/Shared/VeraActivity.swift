import ActivityKit
import Foundation

/// Vera's Live Activity — the Dynamic Island and the lock-screen plate. Shared by the app (it starts and updates the
/// activity) and the extension VeraWidgets (it draws it). Only what is happening on the phone right now: the
/// conversation's stage and last words, the navigator's next turn and arrival, the track. Updated by the app itself
/// while it runs (no push: the free account has none).
struct VeraActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// `off`, `starting`, `listening`, `hearing`, `thinking`, `speaking`.
        var stage: String
        var paused: Bool
        /// Vera's last sentence (or what the ears heard while you speak).
        var line: String?
        /// Navigator: the next maneuver as Google says it, and «14 мин · 9.3 км · 15:42».
        var turn: String?
        var trip: String?
        /// Music: «Artist — Title» while it plays.
        var track: String?
        /// Whether the Mac (Hermes) answers.
        var macOnline: Bool
    }

    var started: Date
}

extension VeraActivityAttributes.ContentState {
    /// The stage as a word and as a colour name the views map to the palette.
    var stageWord: String {
        if paused && stage != "off" && stage != "speaking" { return "жду «Привет, Вера»" }
        switch stage {
        case "listening": return "слушаю"
        case "hearing": return "слышу"
        case "thinking": return "думает"
        case "speaking": return "говорит"
        case "starting": return "включаю"
        default: return "выкл"
        }
    }
}
