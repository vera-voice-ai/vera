import Foundation
import Observation
import SignalBus

struct BusSecond {
    let time: Int
    private(set) var counts: [SignalDomain: Int] = [:]
    private(set) var bytes = 0

    var messages: Int { counts.values.reduce(0, +) }

    mutating func record(_ domain: SignalDomain, bytes: Int) {
        counts[domain, default: 0] += 1
        self.bytes += bytes
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
            bucket.record(message.domain, bytes: (try? encoder.encode(message).count) ?? 0)
            buckets[index] = bucket
            messages.insert(message, at: 0)
            if messages.count > 300 { messages.removeLast(messages.count - 300) }
        }
    }
}
