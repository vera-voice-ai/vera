import Foundation
import Scene

/// A hand-made label for one utterance. Any field may be unknown (nil).
public struct UtteranceLabel: Sendable, Decodable, Equatable {
    public let utterance: String
    public let addressed: Bool?
    public let complete: Bool?

    public init(utterance: String, addressed: Bool?, complete: Bool?) {
        self.utterance = utterance
        self.addressed = addressed
        self.complete = complete
    }
}

public enum Labels {
    /// Reads a JSON Lines file of `{"utterance": ..., "addressed": ..., "complete": ...}`. Later lines win.
    public static func load(_ url: URL) throws -> [String: UtteranceLabel] {
        let decoder = JSONDecoder()
        var labels: [String: UtteranceLabel] = [:]
        for line in try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let label = try? decoder.decode(UtteranceLabel.self, from: Data(line)) else { continue }
            labels[label.utterance] = label
        }
        return labels
    }
}

/// Numbers computed from one replay. Unlabelled fields need nothing but the RunResult; label fields are
/// filled only when labels are passed. Combined values are sums, so Metrics over several scenarios add up.
public struct Metrics: Sendable {
    public var durationHours = 0.0
    /// Distinct utterances that ended.
    public var utterances = 0
    public var turnsDecided = 0
    public var ready = 0
    public var heardByReason: [String: Int] = [:]
    public var readyByBasis: [String: Int] = [:]
    /// Decided turns by the rule's addressed level (likely, possible, unlikely).
    public var addressedCounts: [String: Int] = [:]
    /// Sum of utterances over all decided turns (for the mean).
    public var utterancesInTurns = 0
    /// Seconds from the end of a ready turn's last utterance to its decision.
    public var latencies: [Double] = []
    public var awaitingAtEnd = 0

    public var labelled = false
    /// Ready turns that contain at least one labelled utterance.
    public var readyLabelled = 0
    public var readyCorrect = 0
    public var addressedLabelled = 0
    public var addressedRecalled = 0
    public var earlyCuts = 0

    public init() {}

    public init(_ result: RunResult, labels: [String: UtteranceLabel]? = nil) {
        durationHours = result.durationSeconds / 3_600
        utterances = result.endedUtterances.count
        turnsDecided = result.decisions.count
        awaitingAtEnd = result.awaitingAtEnd.count
        utterancesInTurns = result.decisions.reduce(0) { $0 + $1.utteranceIDs.count }
        for turn in result.decisions {
            addressedCounts[turn.addressed.rawValue, default: 0] += 1
            switch turn.state {
            case let .ready(basis):
                ready += 1
                readyByBasis[basis, default: 0] += 1
                latencies.append((turn.decidedAt ?? turn.endedAt).timeIntervalSince(turn.endedAt))
            case let .heard(reason):
                heardByReason[reason, default: 0] += 1
            case .awaiting:
                break
            }
        }
        if let labels { applyLabels(labels, result.decisions) }
    }

    private mutating func applyLabels(_ labels: [String: UtteranceLabel], _ decisions: [SceneTurn]) {
        labelled = true
        for label in labels.values where label.addressed == true { addressedLabelled += 1 }
        for turn in decisions {
            guard case .ready = turn.state else { continue }
            let judged = turn.utteranceIDs.compactMap { labels[$0] }
            let known = judged.filter { $0.addressed != nil }
            if !known.isEmpty {
                readyLabelled += 1
                if known.contains(where: { $0.addressed == true }) { readyCorrect += 1 }
            }
            addressedRecalled += judged.filter { $0.addressed == true }.count
            if let last = turn.utteranceIDs.last, labels[last]?.complete == false { earlyCuts += 1 }
        }
    }

    public var heard: Int { heardByReason.values.reduce(0, +) }
    public var readyPerHour: Double? { durationHours > 0 ? Double(ready) / durationHours : nil }
    public var utterancesPerTurn: Double? { turnsDecided > 0 ? Double(utterancesInTurns) / Double(turnsDecided) : nil }
    public var medianLatency: Double? { Metrics.percentile(latencies, 0.5) }
    public var p90Latency: Double? { Metrics.percentile(latencies, 0.9) }
    public var precision: Double? { readyLabelled > 0 ? Double(readyCorrect) / Double(readyLabelled) : nil }
    public var recall: Double? { addressedLabelled > 0 ? Double(addressedRecalled) / Double(addressedLabelled) : nil }
    /// Share of all turns (decided plus still waiting) that were still waiting at the end.
    public var awaitingShare: Double? {
        let total = turnsDecided + awaitingAtEnd
        return total > 0 ? Double(awaitingAtEnd) / Double(total) : nil
    }

    public static func combined(_ parts: [Metrics]) -> Metrics {
        var total = Metrics()
        for part in parts {
            total.durationHours += part.durationHours
            total.utterances += part.utterances
            total.turnsDecided += part.turnsDecided
            total.ready += part.ready
            total.heardByReason.merge(part.heardByReason, uniquingKeysWith: +)
            total.readyByBasis.merge(part.readyByBasis, uniquingKeysWith: +)
            total.addressedCounts.merge(part.addressedCounts, uniquingKeysWith: +)
            total.utterancesInTurns += part.utterancesInTurns
            total.latencies += part.latencies
            total.awaitingAtEnd += part.awaitingAtEnd
            total.labelled = total.labelled || part.labelled
            total.readyLabelled += part.readyLabelled
            total.readyCorrect += part.readyCorrect
            total.addressedLabelled += part.addressedLabelled
            total.addressedRecalled += part.addressedRecalled
            total.earlyCuts += part.earlyCuts
        }
        return total
    }

    /// Linear interpolation between the closest ranks.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = p * Double(sorted.count - 1)
        let low = Int(rank.rounded(.down)), high = Int(rank.rounded(.up))
        return sorted[low] + (sorted[high] - sorted[low]) * (rank - Double(low))
    }
}

/// Ready decisions that differ between a configuration and the baseline. Turns are matched by their first utterance id.
public struct ReadyDifference: Sendable, Equatable {
    public let onlyInConfiguration: Int
    public let onlyInBaseline: Int
    public var total: Int { onlyInConfiguration + onlyInBaseline }

    public init(onlyInConfiguration: Int, onlyInBaseline: Int) {
        self.onlyInConfiguration = onlyInConfiguration
        self.onlyInBaseline = onlyInBaseline
    }

    public static func between(baseline: RunResult, configuration: RunResult) -> ReadyDifference {
        let base = readyKeys(baseline), other = readyKeys(configuration)
        return ReadyDifference(onlyInConfiguration: other.subtracting(base).count,
                               onlyInBaseline: base.subtracting(other).count)
    }

    private static func readyKeys(_ result: RunResult) -> Set<String> {
        Set(result.decisions.compactMap { turn -> String? in
            guard case .ready = turn.state else { return nil }
            return turn.utteranceIDs.first
        })
    }
}
