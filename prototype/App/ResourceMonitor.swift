import Foundation
import Darwin
import Observation
import Core

/// Vera's total footprint: resident memory and CPU of this process plus all of its descendants (Python workers, CLI
/// tools it started). Sampled every 2 seconds by walking the process tree from getpid() with libproc; no shell, no `ps`.
@MainActor
@Observable
final class ResourceMonitor {
    typealias Snapshot = ProcessResources.Snapshot
    typealias TopProcess = ProcessResources.TopProcess

    private(set) var memoryBytes: UInt64 = 0
    private(set) var cpuPercent: Double = 0
    private(set) var processCount = 0
    private(set) var topProcesses: [TopProcess] = []
    private var previous: Snapshot?
    private var loop: Task<Void, Never>?

    /// "1,9 ГБ · CPU 12%" for the header.
    var headerText: String {
        "\(ProcessResources.memoryText(memoryBytes)) · CPU \(Int(cpuPercent.rounded()))%"
    }

    /// The tooltip: process count and the biggest three by memory.
    var helpText: String {
        var lines = ["Процессов Vera: \(processCount)"]
        lines += topProcesses.map { "\($0.name) — \(ProcessResources.memoryText($0.residentBytes))" }
        return lines.joined(separator: "\n")
    }

    /// Samples now and then every 2 seconds. Calling it again while running does nothing.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                let snapshot = await Task.detached(priority: .utility) { ProcessResources.takeSnapshot(at: now) }.value
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
        let reading = ProcessResources.summarize(snapshot, previous: previous)
        previous = snapshot
        memoryBytes = reading.memoryBytes
        cpuPercent = reading.cpuPercent
        processCount = reading.processCount
        topProcesses = reading.top
    }
}
