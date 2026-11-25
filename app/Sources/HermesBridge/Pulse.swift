import Foundation

/// One line of the vera-pulse journal (`hermes-plugin/vera-pulse`, schema v1). Never carries message text,
/// tool arguments or model output: names, ids, durations, statuses and counts only.
public struct PulseEvent: Sendable, Codable, Equatable, Identifiable {
    public var id: String { "\(ts)-\(kind)-\(callId ?? turn ?? session ?? "")" }

    public let v: Int?
    /// Unix time, seconds.
    public let ts: Double
    /// `session.open|start|end`, `llm.start|end|error`, `tool.start|end`, `subagent.start|stop`,
    /// `human.wait|done`, `compaction`.
    public let kind: String
    public let session: String?
    public let turn: String?
    public let callId: String?
    /// Tool name, skill, subagent role…
    public let name: String?
    public let model: String?
    public let provider: String?
    public let platform: String?
    public let status: String?
    public let durationMs: Double?
    public let tokensIn: Int?
    public let tokensOut: Int?
    /// A short safe note (finish reason, error type, outcome).
    public let detail: String?

    enum CodingKeys: String, CodingKey {
        case v, ts, kind, session, turn, name, model, provider, platform, status, detail
        case callId = "call_id", durationMs = "duration_ms", tokensIn = "tokens_in", tokensOut = "tokens_out"
    }

    public init(ts: Double, kind: String, session: String? = nil, turn: String? = nil, callId: String? = nil,
                name: String? = nil, model: String? = nil, provider: String? = nil, platform: String? = nil,
                status: String? = nil, durationMs: Double? = nil, tokensIn: Int? = nil, tokensOut: Int? = nil,
                detail: String? = nil) {
        self.v = 1
        self.ts = ts; self.kind = kind; self.session = session; self.turn = turn; self.callId = callId
        self.name = name; self.model = model; self.provider = provider; self.platform = platform
        self.status = status; self.durationMs = durationMs; self.tokensIn = tokensIn; self.tokensOut = tokensOut
        self.detail = detail
    }

    public var date: Date { Date(timeIntervalSince1970: ts) }
    /// `tool`, `llm`, `session`, … — the part before the dot; the board colours by it.
    public var domain: String { String(kind.split(separator: ".").first ?? Substring(kind)) }
}

/// Follows the vera-pulse journal: `<dir>/<yyyy-MM-dd>.jsonl`, one file per local day.
public actor PulseFeed {
    public nonisolated let events: AsyncStream<[PulseEvent]>
    private let continuation: AsyncStream<[PulseEvent]>.Continuation
    private let directory: URL
    private var file: URL?
    private var offset: UInt64 = 0
    private var remainder = Data()
    private var loop: Task<Void, Never>?

    /// `directory` is `HermesRuntime.pulseDirectory` (`<Vera data>/hermes/vera-pulse`).
    public init(directory: URL) {
        self.directory = directory
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    /// Starts with the last `backlogBytes` of today's file, then polls for appended lines.
    public func start(backlogBytes: UInt64 = 256 * 1024, interval: Duration = .milliseconds(400)) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                await self?.poll(backlog: first ? backlogBytes : 0)
                first = false
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public static func fileName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date) + ".jsonl"
    }

    private func poll(backlog: UInt64) {
        let today = directory.appending(path: Self.fileName(for: Date()))
        if file != today {
            file = today
            remainder = Data()
            let size = (try? FileManager.default.attributesOfItem(atPath: today.path)[.size] as? UInt64) ?? 0
            // First look: only the tail. A new day's file (rollover) is read from its start.
            offset = backlog > 0 && size > backlog ? size - backlog : 0
            // Starting mid-file: the first line is partial, drop it.
            skipPartial = offset > 0
        }
        guard let handle = try? FileHandle(forReadingFrom: today) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; remainder = Data() }  // truncated or replaced
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.read(upToCount: Int(size - offset)) else { return }
        offset = size
        var data = remainder + chunk
        if skipPartial, let nl = data.firstIndex(of: UInt8(ascii: "\n")) {
            data = data[(nl + 1)...]
            skipPartial = false
        }
        let parsed = Self.parse(data)
        remainder = parsed.remainder
        if !parsed.events.isEmpty { continuation.yield(parsed.events) }
    }

    private var skipPartial = false

    /// Complete lines become events (bad lines are skipped); the unterminated tail is returned to wait for more.
    public static func parse(_ data: Data) -> (events: [PulseEvent], remainder: Data) {
        var events: [PulseEvent] = []
        let decoder = JSONDecoder()
        var start = data.startIndex
        while let nl = data[start...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = data[start..<nl]
            if !line.isEmpty, let e = try? decoder.decode(PulseEvent.self, from: line) { events.append(e) }
            start = data.index(after: nl)
        }
        return (events, Data(data[start...]))
    }
}
