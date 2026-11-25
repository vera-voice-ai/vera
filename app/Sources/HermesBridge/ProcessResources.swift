import Foundation
import Darwin

/// What Vera costs the machine: resident memory and CPU of Vera's own process tree (the app, the mouth, Smart Turn)
/// and of Hermes' gateway tree (it runs detached, so its pid comes from Vera's own `<HERMES_HOME>/gateway.pid`).
/// No shell, no `ps`: the trees are walked with libproc from the two roots — nothing else on the machine is looked at.
/// Pure math lives here so it can be tested; the walk is a thin layer over `proc_pidinfo`.
public enum ProcessResources {
    public struct ProcessSample: Sendable, Equatable {
        public let pid: Int32
        public let name: String
        public let residentBytes: UInt64
        /// User + system time used since the process started.
        public let cpuSeconds: Double
        public init(pid: Int32, name: String, residentBytes: UInt64, cpuSeconds: Double) {
            self.pid = pid; self.name = name; self.residentBytes = residentBytes; self.cpuSeconds = cpuSeconds
        }
    }

    /// One tree: «Вера» or «Hermes».
    public struct Group: Sendable, Equatable {
        public let name: String
        public let processes: [ProcessSample]
        public init(name: String, processes: [ProcessSample]) { self.name = name; self.processes = processes }
    }

    public struct Snapshot: Sendable, Equatable {
        public let time: TimeInterval
        public let groups: [Group]
        public init(time: TimeInterval, groups: [Group]) { self.time = time; self.groups = groups }
    }

    public struct GroupReading: Sendable, Equatable {
        public let name: String
        public let memoryBytes: UInt64
        /// Can exceed 100 when several cores are busy.
        public let cpuPercent: Double
        public let processCount: Int
    }

    public struct Reading: Sendable, Equatable {
        public let groups: [GroupReading]
        public var memoryBytes: UInt64 { groups.reduce(0) { $0 + $1.memoryBytes } }
        public var cpuPercent: Double { groups.reduce(0) { $0 + $1.cpuPercent } }
        public var processCount: Int { groups.reduce(0) { $0 + $1.processCount } }
        public init(groups: [GroupReading]) { self.groups = groups }
    }

    /// Memory is the sum of resident sizes. CPU is the CPU time used by processes present in both snapshots, divided
    /// by the wall time between them: a process that started or exited in between adds nothing to the percent.
    public static func summarize(_ current: Snapshot, previous: Snapshot?) -> Reading {
        let before = Dictionary((previous?.groups ?? []).flatMap(\.processes).map { ($0.pid, $0.cpuSeconds) }, uniquingKeysWith: { $1 })
        let wall = previous.map { current.time - $0.time } ?? 0
        return Reading(groups: current.groups.map { g in
            var cpu = 0.0
            if wall > 0 {
                let used = g.processes.reduce(0.0) { sum, p in before[p.pid].map { sum + max(0, p.cpuSeconds - $0) } ?? sum }
                cpu = used / wall * 100
            }
            return GroupReading(name: g.name, memoryBytes: g.processes.reduce(0) { $0 + $1.residentBytes },
                                cpuPercent: cpu, processCount: g.processes.count)
        })
    }

    /// "1,9 ГБ", "640 МБ".
    public static func memoryText(_ bytes: UInt64) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .memory).locale(Locale(identifier: "ru_RU")))
    }

    /// The pid Hermes wrote to `<HERMES_HOME>/gateway.pid` (`{"pid": …, "kind": "hermes-gateway", …}`), if that
    /// process still runs.
    public static func gatewayPID(hermesHome: URL) -> Int32? {
        guard let data = try? Data(contentsOf: hermesHome.appending(path: "gateway.pid")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (json["pid"] as? NSNumber)?.int32Value, pid > 0, kill(pid, 0) == 0 else { return nil }
        return pid
    }

    /// Each root with all its descendants; a process already counted under an earlier root is not counted again.
    public static func takeSnapshot(at time: TimeInterval, roots: [(name: String, pid: Int32)]) -> Snapshot {
        var seen: Set<Int32> = []
        let timebase = timebaseRatio()
        let groups = roots.map { root -> Group in
            var processes: [ProcessSample] = []
            var queue = [root.pid]
            while let pid = queue.popLast(), seen.count < 1000 {
                guard seen.insert(pid).inserted else { continue }
                if let s = sample(of: pid, timebase: timebase) { processes.append(s) }
                queue.append(contentsOf: childPIDs(of: pid))
            }
            return Group(name: root.name, processes: processes)
        }
        return Snapshot(time: time, groups: groups)
    }

    static func sample(of pid: Int32, timebase: Double) -> ProcessSample? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        _ = proc_name(pid, &buffer, UInt32(buffer.count))
        let name = String(cString: buffer)
        // Task times are Mach absolute-time ticks, not nanoseconds.
        let ticks = Double(info.pti_total_user) + Double(info.pti_total_system)
        return ProcessSample(pid: pid, name: name.isEmpty ? "процесс \(pid)" : name, residentBytes: info.pti_resident_size,
                             cpuSeconds: ticks * timebase / 1_000_000_000)
    }

    /// `proc_listchildpids` may report a count or a byte size, so the buffer is read up to its first zero.
    static func childPIDs(of pid: Int32) -> [Int32] {
        var buffer = [Int32](repeating: 0, count: 256)
        _ = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<Int32>.size))
        return buffer.prefix { $0 > 0 }.map { $0 }
    }

    static func timebaseRatio() -> Double {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }
}

/// The current provider's plan limits as Hermes reads them (`plugin.vera-setup.account_usage`, Hermes' own
/// `fetch_account_usage` — the key stays inside Hermes): OpenCode Go 5 h / week / month, Codex, Claude, OpenRouter….
public struct AccountUsage: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        public let label: String
        public let usedPercent: Double?
        public let resetAt: Date?
    }
    public let provider: String
    public let plan: String?
    public let windows: [Window]
    public let unavailable: String?

    public init(provider: String, plan: String? = nil, windows: [Window], unavailable: String? = nil) {
        self.provider = provider; self.plan = plan; self.windows = windows; self.unavailable = unavailable
    }

    /// The plugin's answer; nil for `{ok: false}`.
    public init?(_ v: JSONValue) {
        guard v["ok"]?.bool == true, let provider = v["provider"]?.string else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        self.provider = provider
        plan = v["plan"]?.string
        unavailable = v["unavailable_reason"]?.string
        windows = (v["windows"]?.array ?? []).map { w in
            let reset = w["reset_at"]?.string.flatMap { iso.date(from: $0) ?? plain.date(from: $0) }
            return Window(label: w["label"]?.string ?? "", usedPercent: w["used_percent"]?.number, resetAt: reset)
        }
    }

    /// Hermes' English window labels, short and Russian for the board.
    public static func shortLabel(_ label: String) -> String {
        switch label.lowercased() {
        case let l where l.contains("rolling") || l.contains("5h") || l.contains("5-hour") || l.contains("5 hour") || l.contains("session"): "5 ч"
        case let l where l.contains("week"): "неделя"
        case let l where l.contains("month"): "месяц"
        case let l where l.contains("day"): "сутки"
        default: label
        }
    }
}
