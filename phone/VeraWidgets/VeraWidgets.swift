import ActivityKit
import SwiftUI
import WidgetKit

/// The extension of Vera's iPhone app: the Live Activity in the Dynamic Island and on the lock screen. (Home-screen
/// widgets with live data need an App Group, which a free developer account does not have.)
@main
struct VeraWidgets: WidgetBundle {
    var body: some Widget {
        VeraLiveActivity()
    }
}

private enum Tone {
    static let vera = Color(red: 0.94, green: 0.13, blue: 0.61)
    static let human = Color(red: 0.957, green: 0.447, blue: 0.714)
    static let llm = Color(red: 0.980, green: 0.800, blue: 0.082)
    static let ok = Color(red: 0.42, green: 0.86, blue: 0.56)
    static let session = Color(red: 0.655, green: 0.545, blue: 0.980)
    static let background = Color(red: 0.035, green: 0.025, blue: 0.047)

    static func stage(_ s: VeraActivityAttributes.ContentState) -> Color {
        if s.paused { return .white.opacity(0.5) }
        switch s.stage {
        case "listening": return vera
        case "hearing": return human
        case "thinking": return llm
        case "speaking": return ok
        default: return .white.opacity(0.4)
        }
    }
}

struct VeraLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VeraActivityAttributes.self) { ctx in
            LockPlate(s: ctx.state)
                .activityBackgroundTint(Tone.background.opacity(0.92))
                .activitySystemActionForegroundColor(Tone.vera)
        } dynamicIsland: { ctx in
            let s = ctx.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Circle().fill(Tone.stage(s)).frame(width: 9, height: 9)
                        Text(s.stageWord).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Tone.stage(s))
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(s.macOnline ? "Мак" : "нет Мака").font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(s.macOnline ? Tone.ok : .orange).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 5) {
                        if let turn = s.turn {
                            Text(turn).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                            if let trip = s.trip { Text(trip).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.65)) }
                        }
                        if let line = s.line, !line.isEmpty {
                            Text(line).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                        }
                        if let track = s.track {
                            Label(track, systemImage: "music.note").font(.system(size: 11)).foregroundStyle(Tone.session).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Circle().fill(Tone.stage(s)).frame(width: 10, height: 10)
            } compactTrailing: {
                Text(compactRight(s)).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(s.turn != nil ? Tone.ok : Tone.stage(s)).lineLimit(1)
            } minimal: {
                Circle().fill(Tone.stage(s)).frame(width: 10, height: 10)
            }
            .keylineTint(Tone.vera)
        }
    }

    /// The island's right side: the trip's time left while navigating, otherwise the stage in one short word.
    private func compactRight(_ s: VeraActivityAttributes.ContentState) -> String {
        if let trip = s.trip, let first = trip.split(separator: "·").first { return String(first).trimmingCharacters(in: .whitespaces) }
        if s.track != nil && s.stage == "off" { return "♪" }
        return s.stageWord
    }
}

/// The lock-screen plate: the stage, the turn and the trip, the last sentence, the track.
private struct LockPlate: View {
    let s: VeraActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(Tone.stage(s)).frame(width: 9, height: 9)
                Text("Вера · \(s.stageWord)").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                Spacer()
                Text(s.macOnline ? "Мак на связи" : "нет связи с Маком").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(s.macOnline ? Tone.ok : .orange)
            }
            if let turn = s.turn {
                Text(turn).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                if let trip = s.trip { Text(trip).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.65)) }
            }
            if let line = s.line, !line.isEmpty {
                Text(line).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
            }
            if let track = s.track {
                Label(track, systemImage: "music.note").font(.system(size: 11)).foregroundStyle(Tone.session).lineLimit(1)
            }
        }
        .padding(14)
    }
}
