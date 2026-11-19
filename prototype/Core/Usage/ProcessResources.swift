import Foundation
import Darwin

/// Vera's footprint: resident memory and CPU of this process plus all of its descendants (the Python workers, the CLI tools it
/// started). Pure math and the libproc walk live here (not in the app target) so that they can be tested.
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

    public struct Snapshot: Sendable, Equatable {
        public let time: TimeInterval
        public let processes: [ProcessSample]
        public init(time: TimeInterval, processes: [ProcessSample]) { self.time = time; self.processes = processes }
    }

    public struct TopProcess: Sendable, Equatable {
        public let name: String
        public let residentBytes: UInt64
    }

    public struct Reading: Sendable, Equatable {
        public let memoryBytes: UInt64
        /// Can exceed 100 when several cores are busy.
        public let cpuPercent: Double
        public let processCount: Int
        /// Biggest three by resident memory.
        public let top: [TopProcess]
    }

    /// Memory is the sum of resident sizes. CPU is the CPU time used by processes present in both snapshots, divided
    /// by the wall time between them. Processes that started or exited in between do not add to the percent.
    public static func summarize(_ current: Snapshot, previous: Snapshot?) -> Reading {
        let memory = current.processes.reduce(UInt64(0)) { $0 + $1.residentBytes }
        var cpu = 0.0
        if let previous, current.time > previous.time {
            let before = Dictionary(previous.processes.map { ($0.pid, $0.cpuSeconds) }, uniquingKeysWith: { $1 })
            let used = current.processes.reduce(0.0) { sum, process in
                guard let start = before[process.pid] else { return sum }
                return sum + max(0, process.cpuSeconds - start)
            }
            cpu = used / (current.time - previous.time) * 100
        }
        let top = current.processes.sorted { $0.residentBytes > $1.residentBytes }.prefix(3)
            .map { TopProcess(name: $0.name, residentBytes: $0.residentBytes) }
        return Reading(memoryBytes: memory, cpuPercent: cpu, processCount: current.processes.count, top: Array(top))
    }

    /// "1,9 ГБ", "640 МБ" with the Russian locale.
    public static func memoryText(_ bytes: UInt64) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .file).locale(Locale(identifier: "ru_RU")))
    }

    /// Reads `root` (default: this process) and all its descendants. Processes that cannot be read are skipped.
    public static func takeSnapshot(at time: TimeInterval, root: Int32 = getpid()) -> Snapshot {
        var processes: [ProcessSample] = []
        var queue: [Int32] = [root]
        var seen: Set<Int32> = []
        let timebase = timebaseRatio()
        while let pid = queue.popLast(), seen.count < 1000 {
            guard seen.insert(pid).inserted else { continue }
            if let sample = sample(of: pid, timebase: timebase) { processes.append(sample) }
            queue.append(contentsOf: childPIDs(of: pid))
        }
        return Snapshot(time: time, processes: processes)
    }

    static func sample(of pid: Int32, timebase: Double) -> ProcessSample? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        var nameBuffer = [CChar](repeating: 0, count: 256)
        _ = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = String(cString: nameBuffer)
        // Task times are in Mach absolute-time ticks, not nanoseconds (a test burns the CPU to check this).
        let ticks = Double(info.pti_total_user) + Double(info.pti_total_system)
        return ProcessSample(pid: pid, name: name.isEmpty ? "процесс \(pid)" : name, residentBytes: info.pti_resident_size,
                             cpuSeconds: ticks * timebase / 1_000_000_000)
    }

    /// `proc_listchildpids` may report a count or a byte size, so the buffer is read up to its first zero entry.
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
