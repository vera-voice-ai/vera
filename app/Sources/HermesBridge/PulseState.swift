import Foundation

/// Vera's observation in one place: the vera-pulse journal as it comes in, the summary built from it and the main
/// conversation's turns laid out in time (journal lines plus what the ears, the adapter and the mouth report).
/// The board's «Пульс» draws all three; nothing here acts — it only watches.
public struct PulseState: Sendable {
    /// The last journal lines (newest last).
    public private(set) var events: [PulseEvent] = []
    public private(set) var stats = PulseStats()
    public var turns = TurnRecorder()
    /// The last 10 requests to Hermes from every channel, one per Hermes turn.
    public private(set) var requests = RequestLog()
    public static let keep = 4000

    public init() {}

    public mutating func take(_ batch: [PulseEvent]) {
        for e in batch { stats.apply(e); turns.pulse(e); requests.apply(e) }
        events.append(contentsOf: batch)
        if events.count > Self.keep { events.removeFirst(events.count - Self.keep) }
    }
}
