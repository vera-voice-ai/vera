import Foundation
import Testing
import Scene
import SignalBus

// Replays Vera 1 corpus episodes through SceneBuilder and compares the scene's ready decisions
// with the v1 turn labels. The judge is a deterministic stand-in. Only counts are printed,
// never transcript text.

private struct CorpusSegment: Decodable {
    let idx: Int
    let capturedAt: String
    let durationS: Double
    let text: String
    let turnId: String?
}

private struct CorpusTurn: Decodable {
    let turnId: String
    let segmentIdxs: [Int]
}

private struct CorpusEpisode: Decodable {
    let episodeId: String
    let segments: [CorpusSegment]
    let turns: [CorpusTurn]
}

private struct ReadyDecision {
    let idxs: [Int]
    let decidedAt: Date
}

private struct PendingVerdict {
    let due: Date
    let turnID: String
    let revision: Int
    let choice: String
}

private struct Metrics {
    var episodes = 0
    var v1Turns = 0
    var segments = 0
    var negativeSegments = 0
    var decisions = 0
    var readyDecisions = 0
    var readyMatching = 0
    var matchedTurns = 0
    var overMerge = 0
    var overSplit = 0
    var negativeInReady = 0
    var basis: [String: Int] = [:]
    var heard: [String: Int] = [:]
    var delays: [Double] = []
    var delayMissing = 0
    var unparsed = 0

    mutating func add(_ other: Metrics) {
        episodes += other.episodes
        v1Turns += other.v1Turns
        segments += other.segments
        negativeSegments += other.negativeSegments
        decisions += other.decisions
        readyDecisions += other.readyDecisions
        readyMatching += other.readyMatching
        matchedTurns += other.matchedTurns
        overMerge += other.overMerge
        overSplit += other.overSplit
        negativeInReady += other.negativeInReady
        basis.merge(other.basis, uniquingKeysWith: +)
        heard.merge(other.heard, uniquingKeysWith: +)
        delays += other.delays
        delayMissing += other.delayMissing
        unparsed += other.unparsed
    }
}

/// Stand-in for the real judge: a placeholder rule, not a quality measure.
private func stubChoice(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let last = trimmed.last, ".?!…".contains(last) { return "complete" }
    return trimmed.split(whereSeparator: \.isWhitespace).count >= 5 ? "complete" : "continue"
}

private func verdictMessage(_ verdict: PendingVerdict) -> SignalMessage {
    SignalMessage(
        kind: .event,
        domain: .scene,
        source: "judge-stub",
        type: "scene.turn.verdict",
        timestamp: verdict.due,
        payload: [
            "turn_id": verdict.turnID,
            "turn_revision": "\(verdict.revision)",
            "choice": verdict.choice,
            "confidence": "0.9"
        ]
    )
}

/// Feeds messages to a fresh builder on a virtual clock: ticks every 0.5 s, and judge verdicts
/// 0.3 s after each snapshot that asks for one.
private struct Replay {
    var builder = SceneBuilder()
    var nextTick: Date
    var pending: [PendingVerdict] = []
    var scheduled: Set<String> = []
    var decisions: [SceneTurn] = []

    init(start: Date) { nextTick = start }

    mutating func pump(until time: Date) {
        while true {
            let earliest = pending.indices.min { pending[$0].due < pending[$1].due }
            if let index = earliest, pending[index].due <= time, pending[index].due <= nextTick {
                let verdict = pending.remove(at: index)
                ingest(verdictMessage(verdict))
            } else if nextTick <= time {
                absorb(builder.tick(now: nextTick))
                nextTick = nextTick.addingTimeInterval(0.5)
            } else {
                break
            }
        }
    }

    mutating func ingest(_ message: SignalMessage) {
        absorb(builder.ingest(message))
    }

    mutating func absorb(_ snapshot: SceneSnapshot?) {
        guard let snapshot else { return }
        decisions += snapshot.decisions
        for turn in snapshot.content.turns where turn.needsVerdict {
            let key = "\(turn.id)#\(turn.textRevision)"
            guard scheduled.insert(key).inserted else { continue }
            pending.append(PendingVerdict(
                due: snapshot.at.addingTimeInterval(0.3),
                turnID: turn.id,
                revision: turn.textRevision,
                choice: stubChoice(turn.text)
            ))
        }
    }
}

/// Utterance ids are "utterance/s1-seg<idx>"; returns the segment idx.
private func segmentIndex(_ utteranceID: String) -> Int? {
    guard let range = utteranceID.range(of: "seg", options: .backwards) else { return nil }
    return Int(utteranceID[range.upperBound...])
}

private func parseCaptured(_ value: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: value) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
}

/// Returns every decision the scene made, and the derived end time of each segment.
private func replay(_ episode: CorpusEpisode) -> (decisions: [SceneTurn], segmentEnd: [Int: Date]) {
    var planned: [(time: Date, order: Int, message: SignalMessage)] = []
    var segmentEnd: [Int: Date] = [:]
    var order = 0
    func plan(_ message: SignalMessage) {
        planned.append((message.timestamp, order, message))
        order += 1
    }
    for segment in episode.segments {
        guard let finalAt = parseCaptured(segment.capturedAt) else { continue }
        let end = finalAt.addingTimeInterval(-0.8)
        let start = end.addingTimeInterval(-segment.durationS)
        let subject = "utterance/s1-seg\(segment.idx)"
        segmentEnd[segment.idx] = end
        plan(SignalMessage(source: "corpus", type: "speech.segment.started", timestamp: start, subjectID: subject))
        plan(SignalMessage(source: "corpus", type: "speech.segment.ended", timestamp: end, subjectID: subject,
                           payload: ["reason": "silence"]))
        plan(SignalMessage(source: "corpus", type: "speech.transcript.final", timestamp: finalAt, subjectID: subject,
                           revision: 1, payload: ["lane": "raw", "text": segment.text]))
    }
    planned.sort { $0.time != $1.time ? $0.time < $1.time : $0.order < $1.order }
    guard let first = planned.first, let last = planned.last else { return ([], segmentEnd) }

    var driver = Replay(start: first.time)
    for entry in planned {
        driver.pump(until: entry.time)
        driver.ingest(entry.message)
    }
    driver.pump(until: last.time.addingTimeInterval(20))
    return (driver.decisions, segmentEnd)
}

private func score(_ episode: CorpusEpisode, decisions: [SceneTurn], segmentEnd: [Int: Date]) -> Metrics {
    var m = Metrics()
    m.episodes = 1
    m.v1Turns = episode.turns.count
    m.segments = episode.segments.count
    let negatives = Set(episode.segments.filter { $0.turnId == nil }.map(\.idx))
    m.negativeSegments = negatives.count

    var turnOf: [Int: String] = [:]
    for turn in episode.turns {
        for idx in turn.segmentIdxs { turnOf[idx] = turn.turnId }
    }

    var ready: [ReadyDecision] = []
    var negativeHit: Set<Int> = []
    m.decisions = decisions.count
    for decision in decisions {
        let idxs = decision.utteranceIDs.compactMap(segmentIndex)
        switch decision.state {
        case .ready(let basis):
            m.readyDecisions += 1
            m.basis[basis, default: 0] += 1
            ready.append(ReadyDecision(idxs: idxs, decidedAt: decision.decidedAt ?? decision.endedAt))
            let hits = Set(idxs.compactMap { turnOf[$0] })
            if !hits.isEmpty { m.readyMatching += 1 }
            if hits.count >= 2 { m.overMerge += 1 }
            for idx in idxs where negatives.contains(idx) { negativeHit.insert(idx) }
        case .heard(let reason):
            m.heard[reason, default: 0] += 1
        case .awaiting:
            break
        }
    }
    m.negativeInReady = negativeHit.count

    for turn in episode.turns {
        let members = Set(turn.segmentIdxs)
        let hitting = ready.filter { !Set($0.idxs).isDisjoint(with: members) }
        if !hitting.isEmpty { m.matchedTurns += 1 }
        if hitting.count >= 2 { m.overSplit += 1 }
        if let last = turn.segmentIdxs.max(), let end = segmentEnd[last] {
            let deciding = ready.filter { $0.idxs.contains(last) }.map(\.decidedAt).min()
            if let deciding {
                m.delays.append(deciding.timeIntervalSince(end))
            } else {
                m.delayMissing += 1
            }
        }
    }
    return m
}

private func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

private func report(_ label: String, _ m: Metrics) {
    func ratio(_ part: Int, _ whole: Int) -> String {
        whole > 0 ? String(format: "%.3f", Double(part) / Double(whole)) : "n/a"
    }
    func counts(_ dict: [String: Int]) -> String {
        dict.isEmpty ? "none" : dict.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
    let median = median(m.delays).map { String(format: "%.1f", $0) } ?? "n/a"
    print("[\(label)] episodes=\(m.episodes) segments=\(m.segments) v1_turns=\(m.v1Turns) v1_negative_segments=\(m.negativeSegments) unparsed_lines=\(m.unparsed)")
    print("[\(label)] scene_decisions=\(m.decisions) ready=\(m.readyDecisions) heard=\(m.decisions - m.readyDecisions)")
    print("[\(label)] recall=\(ratio(m.matchedTurns, m.v1Turns)) matched_turns=\(m.matchedTurns)/\(m.v1Turns) precision=\(ratio(m.readyMatching, m.readyDecisions)) matching_ready=\(m.readyMatching)/\(m.readyDecisions)")
    print("[\(label)] over_merge=\(m.overMerge) over_split=\(m.overSplit)")
    print("[\(label)] ready_by_basis \(counts(m.basis))")
    print("[\(label)] heard_by_reason \(counts(m.heard))")
    print("[\(label)] negative_segments_in_ready=\(m.negativeInReady) of \(m.negativeSegments)")
    print("[\(label)] median_delay_s=\(median) turns_with_timed_last_segment=\(m.delays.count) turns_without=\(m.delayMissing)")
}

@Test func corpusReplay() throws {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VeraSensorPrototype/Corpus/v1-episodes.jsonl")
    guard FileManager.default.fileExists(atPath: url.path) else {
        print("corpus not found, skipped")
        return
    }

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    var overall = Metrics()
    var episodes: [CorpusEpisode] = []
    for line in try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
        if let episode = try? decoder.decode(CorpusEpisode.self, from: Data(line)) {
            episodes.append(episode)
        } else {
            overall.unparsed += 1
        }
    }

    for episode in episodes {
        let result = replay(episode)
        let m = score(episode, decisions: result.decisions, segmentEnd: result.segmentEnd)
        report(episode.episodeId, m)
        overall.add(m)
    }
    report("overall", overall)

    #expect(episodes.isEmpty || overall.decisions > 0)
}
