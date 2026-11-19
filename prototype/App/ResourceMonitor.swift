import Foundation
import Darwin
import Observation

/// Vera's total footprint: resident memory and CPU of this process plus all of its descendants (Python workers, CLI
/// tools it started). Sampled every 2 seconds by walking the process tree from getpid() with libproc; no shell, no `ps`.
@MainActor
@Observable
final class ResourceMonitor {
    struct ProcessSample: Sendable, Equatable {
        let pid: Int32
        let name: String
        let residentBytes: UInt64
        /// User + system time used since the process started.
        let cpuSeconds: Double
    }

    struct Snapshot: Sendable, Equatable {
        let time: TimeInterval
        let processes: [ProcessSample]
    }

    struct TopProcess: Sendable, Equatable {
        let name: String
        let residentBytes: UInt64
    }

    struct Reading: Sendable, Equatable {
        let memoryBytes: UInt64
        /// Can exceed 100 when several cores are busy.
        let cpuPercent: Double
        let processCount: Int
        /// Biggest three by resident memory.
        let top: [TopProcess]
    }

    private(set) var memoryBytes: UInt64 = 0
    private(set) var cpuPercent: Double = 0
    private(set) var processCount = 0
    private(set) var topProcesses: [TopProcess] = []
    private var previous: Snapshot?
    private var loop: Task<Void, Never>?

    /// "1,9 ГБ · CPU 12%" for the header.
    var headerText: String {
        "\(Self.memoryText(memoryBytes)) · CPU \(Int(cpuPercent.rounded()))%"
    }

    /// The tooltip: process count and the biggest three by memory.
    var helpText: String {
        var lines = ["Процессов Vera: \(processCount)"]
        lines += topProcesses.map { "\($0.name) — \(Self.memoryText($0.residentBytes))" }
        return lines.joined(separator: "\n")
    }

    /// Samples now and then every 2 seconds. Calling it again while running does nothing.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                let snapshot = await Task.detached(priority: .utility) { Self.takeSnapshot(at: now) }.value
                self?.apply(snapshot)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func apply(_ snapshot: Snapshot) {
        let reading = Self.summarize(snapshot, previous: previous)
        previous = snapshot
        memoryBytes = reading.memoryBytes
        cpuPercent = reading.cpuPercent
        processCount = reading.processCount
        topProcesses = reading.top
    }

    // MARK: - Pure math (unit-tested)

    /// Memory is the sum of resident sizes. CPU is the CPU time used by processes present in both snapshots, divided
    /// by the wall time between them. Processes that started or exited in between do not add to the percent.
    nonisolated static func summarize(_ current: Snapshot, previous: Snapshot?) -> Reading {
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
        let top = current.processes
            .sorted { $0.residentBytes > $1.residentBytes }
            .prefix(3)
            .map { TopProcess(name: $0.name, residentBytes: $0.residentBytes) }
        return Reading(memoryBytes: memory, cpuPercent: cpu, processCount: current.processes.count, top: Array(top))
    }

    /// "1,9 ГБ", "640 МБ" with the Russian locale.
    nonisolated static func memoryText(_ bytes: UInt64) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .file).locale(Locale(identifier: "ru_RU")))
    }

    // MARK: - Process tree (smoke-tested)

    /// Reads Vera's process and all its descendants. Processes that cannot be read are skipped.
    nonisolated static func takeSnapshot(at time: TimeInterval) -> Snapshot {
        var processes: [ProcessSample] = []
        var queue: [Int32] = [getpid()]
        var seen: Set<Int32> = []
        let timebase = timebaseRatio()
        while let pid = queue.popLast(), seen.count < 1000 {
            guard seen.insert(pid).inserted else { continue }
            if let sample = sample(of: pid, timebase: timebase) { processes.append(sample) }
            queue.append(contentsOf: childPIDs(of: pid))
        }
        return Snapshot(time: time, processes: processes)
    }

    private nonisolated static func sample(of pid: Int32, timebase: Double) -> ProcessSample? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        var nameBuffer = [CChar](repeating: 0, count: 256)
        _ = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = String(cString: nameBuffer)
        // Task times are in Mach absolute-time ticks, not nanoseconds.
        let ticks = Double(info.pti_total_user) + Double(info.pti_total_system)
        return ProcessSample(pid: pid,
                             name: name.isEmpty ? "процесс \(pid)" : name,
                             residentBytes: info.pti_resident_size,
                             cpuSeconds: ticks * timebase / 1_000_000_000)
    }

    /// `proc_listchildpids` may report a count or a byte size, so the buffer is read up to its first zero entry.
    private nonisolated static func childPIDs(of pid: Int32) -> [Int32] {
        var buffer = [Int32](repeating: 0, count: 256)
        _ = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<Int32>.size))
        return buffer.prefix { $0 > 0 }.map { $0 }
    }

    private nonisolated static func timebaseRatio() -> Double {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }
}
