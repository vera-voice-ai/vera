import Foundation
import Scene

public struct ScoreRow: Sendable {
    public let name: String
    public let metrics: Metrics
    /// nil for the baseline itself.
    public let difference: ReadyDifference?

    public init(name: String, metrics: Metrics, difference: ReadyDifference?) {
        self.name = name
        self.metrics = metrics
        self.difference = difference
    }
}

/// Renders numbers only: no utterance ids, no text.
public enum Scoreboard {
    public static func markdown(title: String, rows: [ScoreRow]) -> String {
        let labelled = rows.contains { $0.metrics.labelled }
        var header = ["config", "ready", "ready/h", "heard", "median latency s", "p90 latency s", "utterances/turn"]
        if labelled { header += ["precision", "recall", "early cuts"] }
        var lines = ["### \(title)", "", "| " + header.joined(separator: " | ") + " |",
                     "|" + header.map { _ in "---" }.joined(separator: "|") + "|"]
        for row in rows {
            let m = row.metrics
            var cells = [row.name, "\(m.ready)", fixed(m.readyPerHour, 1), "\(m.heard)",
                         fixed(m.medianLatency, 1), fixed(m.p90Latency, 1), fixed(m.utterancesPerTurn, 2)]
            if labelled {
                cells += [m.labelled ? fixed(m.precision, 2) : "n/a", m.labelled ? fixed(m.recall, 2) : "n/a",
                          m.labelled ? "\(m.earlyCuts)" : "n/a"]
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        lines.append("")
        if !labelled { lines.append("no labels") }
        let diffs = rows.compactMap { row -> String? in
            guard let d = row.difference else { return nil }
            return "- \(row.name): \(d.total) (\(d.onlyInConfiguration) only here, \(d.onlyInBaseline) only in baseline)"
        }
        if !diffs.isEmpty {
            lines.append("Ready decisions differing from baseline:")
            lines += diffs
            lines.append("")
        }
        lines.append("Breakdown (counts by reason code):")
        for row in rows {
            lines.append("- \(row.name): ready \(counts(row.metrics.readyByBasis)); heard \(counts(row.metrics.heardByReason)); addressed \(counts(row.metrics.addressedCounts))")
        }
        lines.append("")
        let awaiting = rows.map { "\($0.name) \(fixed($0.metrics.awaitingShare.map { $0 * 100 }, 1))%" }
        lines.append("Still awaiting at end (share of turns): " + awaiting.joined(separator: ", "))
        return lines.joined(separator: "\n") + "\n"
    }

    private static func counts(_ values: [String: Int]) -> String {
        guard !values.isEmpty else { return "none" }
        return values.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    private static func fixed(_ value: Double?, _ digits: Int) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.\(digits)f", value)
    }
}
