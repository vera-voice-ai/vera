import SwiftUI
import Response

/// The Response tile for now: what Vera has said aloud, with the voice and the timings.
struct ResponsePanel: View {
    let speaker: ResponseSpeaker
    let available: Bool
    private let accent = Color(red: 0.29, green: 0.87, blue: 0.5)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(available ? (speaker.isMuted ? .orange : .green) : .gray).frame(width: 7, height: 7)
                Text(!available ? "Озвучка недоступна" : speaker.isMuted ? "Озвучка выключена" : "Озвучка Silero · голос \(speaker.voice)")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.88))
                Spacer()
                Text("предложения по команде output.speech.requested от Core; output.speech.stop обрывает").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
            }
            Text("СКАЗАНО ВСЛУХ").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(accent.opacity(0.85))
            if speaker.utterances.isEmpty {
                Text("пока ничего не говорила").font(.system(size: 11)).foregroundStyle(.white.opacity(0.42))
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(speaker.utterances.prefix(3)) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Image(systemName: icon(item.state)).font(.system(size: 10)).foregroundStyle(tint(item.state))
                                Text(stateText(item)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
                                Spacer(minLength: 6)
                                if item.state == .done || item.state == .speaking {
                                    Text("синтез \(item.synthesisMilliseconds) мс\(item.state == .done ? " · звучала \(Double(item.speakingMilliseconds) / 1000, format: .number.precision(.fractionLength(1))) с" : "")")
                                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                                }
                            }
                            Text(item.text).lineLimit(2).truncationMode(.tail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).padding(.leading, 16)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func icon(_ state: ResponseSpeaker.Utterance.State) -> String {
        switch state { case .synthesizing: return "hourglass"; case .speaking: return "speaker.wave.2.fill"; case .done: return "checkmark.circle.fill"; case .failed: return "xmark.circle.fill" }
    }
    private func tint(_ state: ResponseSpeaker.Utterance.State) -> Color {
        switch state { case .synthesizing: return .orange; case .speaking: return .green; case .done: return .green.opacity(0.7); case .failed: return .red }
    }
    private func stateText(_ item: ResponseSpeaker.Utterance) -> String {
        switch item.state {
        case .synthesizing: return "синтез…"
        case .speaking: return "говорит"
        case .done: return "сказано"
        case .failed: return "не удалось: \(item.error ?? "")"
        }
    }
}
