import Foundation
import Testing
@testable import Core

private func sample(_ pid: Int32, _ name: String, mb: UInt64, cpu: Double) -> ProcessResources.ProcessSample {
    .init(pid: pid, name: name, residentBytes: mb * 1_048_576, cpuSeconds: cpu)
}

@Test func memoryIsTheSumAndCPUIsTheTimeUsedByProcessesPresentInBothSnapshots() {
    let before = ProcessResources.Snapshot(time: 10, processes: [sample(1, "Vera", mb: 500, cpu: 20), sample(2, "python", mb: 700, cpu: 5)])
    let after = ProcessResources.Snapshot(time: 12, processes: [sample(1, "Vera", mb: 520, cpu: 20.5), sample(2, "python", mb: 710, cpu: 6),
                                                                  sample(3, "new", mb: 90, cpu: 3)])
    let reading = ProcessResources.summarize(after, previous: before)
    #expect(reading.memoryBytes == (520 + 710 + 90) * 1_048_576)
    #expect(abs(reading.cpuPercent - 75) < 0.001)               // (0.5 + 1.0) s of CPU in 2 s; the new process adds nothing
    #expect(reading.processCount == 3)
    #expect(reading.top.map(\.name) == ["python", "Vera", "new"])
    #expect(ProcessResources.summarize(after, previous: nil).cpuPercent == 0)
}

@Test func theRussianMemoryText() {
    #expect(ProcessResources.memoryText(1_900_000_000).contains("ГБ"))
    #expect(ProcessResources.memoryText(640_000_000).contains("МБ"))
}

@Test func thisProcessReportsMemoryAndTheCPUUnitIsRight() {
    let first = ProcessResources.takeSnapshot(at: ProcessInfo.processInfo.systemUptime)
    #expect(first.processes.first?.residentBytes ?? 0 > 0)
    // Burn about half a second of CPU on this thread: the measured CPU seconds must grow by about that, not by a thousandth or a thousand times.
    let started = Date()
    var x = 0.0
    while Date().timeIntervalSince(started) < 0.5 { for i in 1...10_000 { x += sin(Double(i)) } }
    #expect(x != 12345.678)
    let second = ProcessResources.takeSnapshot(at: ProcessInfo.processInfo.systemUptime)
    let used = (second.processes.first?.cpuSeconds ?? 0) - (first.processes.first?.cpuSeconds ?? 0)
    #expect(used > 0.3 && used < 3, "CPU seconds grew by \(used) for about 0.5 s of work")
}
