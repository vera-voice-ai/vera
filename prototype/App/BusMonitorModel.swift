import Foundation
import Observation
import SignalBus

struct BusSecond {
    let time: Int
    /// Messages per lane: the four modules plus the channels that are not a module (Telegram).
    private(set) var counts: [String: Int] = [:]
    private(set) var bytes = 0

    var messages: Int { counts.values.reduce(0, +) }

    mutating func record(_ lane: String, bytes: Int) {
        counts[lane, default: 0] += 1
        self.bytes += bytes
    }
}

extension SignalMessage {
    /// The lane of the timeline this message belongs to. Everything that travels through the Telegram channel (the
    /// incoming text, the turn the scene made of it, the task Core ran for it) is shown on its own lane, so that the
    /// channel is visible as such; the rest goes to its module's lane.
    var busLane: String {
        if source.contains("Telegram") || payload["channel"] == "telegram" || (subjectID?.hasPrefix("task/tg-") ?? false)
            || (subjectID?.hasPrefix("tg-") ?? false) || type == "sensors.telegram.status" { return "telegram" }
        return domain.rawValue
    }
}

@MainActor
@Observable
final class BusMonitorModel {
    static let historySeconds = 30
    private static let bucketCount = historySeconds + 1
    private(set) var messages: [SignalMessage] = []
    @ObservationIgnored private var buckets = [BusSecond?](repeating: nil, count: bucketCount)

    func activity(at date: Date) -> [BusSecond] {
        let end = Int(date.timeIntervalSince1970)
        return ((end - Self.historySeconds)..<end).map { second in
            let bucket = buckets[second % Self.bucketCount]
            if let bucket, bucket.time == second { return bucket }
            return BusSecond(time: second)
        }
    }

    func consume(_ bus: SignalBus) async {
        let stream = await bus.subscribe()
        let encoder = JSONEncoder()
        for await message in stream {
            let second = Int(Date.now.timeIntervalSince1970)
            let index = second % Self.bucketCount
            var bucket = buckets[index].flatMap { $0.time == second ? $0 : nil } ?? BusSecond(time: second)
            bucket.record(message.busLane, bytes: (try? encoder.encode(message).count) ?? 0)
            buckets[index] = bucket
            messages.insert(message, at: 0)
            if messages.count > 300 { messages.removeLast(messages.count - 300) }
        }
    }
}
