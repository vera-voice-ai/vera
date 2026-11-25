import ActivityKit
import Foundation
import UIKit

/// Vera in the Dynamic Island and on the lock screen: one Live Activity while something is going on — the
/// conversation is on, the navigator has a route, or music plays — and none when all is quiet. The app updates it
/// itself, at most once a second and only when something changed (the extension VeraWidgets draws it).
@MainActor @Observable
final class LiveVera {
    /// For the scheme: whether Vera is in the Dynamic Island now, and what it shows there.
    private(set) var showing = false
    private(set) var shown: VeraActivityAttributes.ContentState?
    private(set) var allowed = ActivityAuthorizationInfo().areActivitiesEnabled
    /// Why iOS refused the activity, if it did (shown on the scheme instead of guessing).
    private(set) var problem: String?
    @ObservationIgnored private var activity: Activity<VeraActivityAttributes>?
    @ObservationIgnored private var last: VeraActivityAttributes.ContentState?
    @ObservationIgnored private var loop: Task<Void, Never>?

    func run(talk: Conversation, nav: Navigator, music: Music, link: Link) {
        loop?.cancel()
        // An activity left from the app's previous life (it was killed) is taken over, not doubled.
        activity = Activity<VeraActivityAttributes>.activities.first
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.push(Self.state(talk: talk, nav: nav, music: music, link: link))
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func push(_ s: VeraActivityAttributes.ContentState) {
        let busy = s.stage != "off" || s.turn != nil || s.track != nil
        guard busy else { end(); return }
        // A refused start is tried again — iOS starts activities only while the app is on screen.
        guard s != last || (activity == nil && UIApplication.shared.applicationState == .active) else { return }
        last = s; shown = s
        allowed = ActivityAuthorizationInfo().areActivitiesEnabled
        let content = ActivityContent(state: s, staleDate: Date().addingTimeInterval(120))
        if let activity, activity.activityState == .active {
            nonisolated(unsafe) let a = activity   // ActivityKit's handle is not Sendable; it is only used here
            Task { await a.update(content) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            guard UIApplication.shared.applicationState == .active else {
                problem = "начнётся, когда откроешь Веру"; showing = false; return
            }
            do {
                activity = try Activity.request(attributes: VeraActivityAttributes(started: Date()), content: content)
                problem = nil
            } catch {
                problem = "iOS отказала: \(error.localizedDescription)"
                NSLog("VERA-LIVE отказ: %@", String(describing: error))
            }
        } else {
            problem = "Live Activities выключены в настройках iOS для Веры"
        }
        showing = activity != nil
    }

    private func end() {
        guard let a = activity else { return }
        activity = nil; last = nil; showing = false; shown = nil
        nonisolated(unsafe) let ending = a
        Task { await ending.end(nil, dismissalPolicy: .immediate) }
    }

    static func state(talk: Conversation, nav: Navigator, music: Music, link: Link) -> VeraActivityAttributes.ContentState {
        let line = !talk.partial.isEmpty ? talk.partial : (!talk.saying.isEmpty ? talk.saying : talk.lastAnswer)
        var turn: String?, trip: String?
        if [.ready, .guiding].contains(nav.phase) {
            turn = nav.phase == .guiding ? (nav.nextStep ?? nav.destination.map { "к «\($0)»" }) : nav.destination.map { "маршрут до «\($0)»" }
            var parts: [String] = []
            if let s = nav.remainingSeconds, s > 0 {
                parts.append("\(Int((s / 60).rounded())) мин")
                parts.append(Date().addingTimeInterval(s).formatted(date: .omitted, time: .shortened))
            }
            if let m = nav.remainingMeters, m > 0 { parts.append(String(format: "%.1f км", m / 1000)) }
            trip = parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        let track = music.playing ? music.current.map { [$0.artist, $0.title].filter { !$0.isEmpty }.joined(separator: " — ") } : nil
        return .init(stage: talk.stage.wire, paused: talk.paused, line: line.map { String($0.prefix(160)) },
                     turn: turn, trip: trip, track: track,
                     macOnline: link.phase == .online && link.state.connected)
    }
}
