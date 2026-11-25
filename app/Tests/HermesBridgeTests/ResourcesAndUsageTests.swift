import Foundation
import Testing
@testable import HermesBridge

@Suite struct ResourcesAndUsageTests {
    typealias P = ProcessResources

    @Test func cpuCountsOnlyProcessesSeenTwiceAndGroupsStayApart() {
        let before = P.Snapshot(time: 10, groups: [
            .init(name: "Вера", processes: [.init(pid: 1, name: "Vera", residentBytes: 100, cpuSeconds: 5)]),
            .init(name: "Hermes", processes: [.init(pid: 2, name: "python3", residentBytes: 300, cpuSeconds: 1)])])
        let now = P.Snapshot(time: 12, groups: [
            .init(name: "Вера", processes: [.init(pid: 1, name: "Vera", residentBytes: 120, cpuSeconds: 6),
                                           .init(pid: 3, name: "python3", residentBytes: 50, cpuSeconds: 9)]),
            .init(name: "Hermes", processes: [.init(pid: 2, name: "python3", residentBytes: 310, cpuSeconds: 1.5)])])
        let r = P.summarize(now, previous: before)
        #expect(r.groups.map(\.name) == ["Вера", "Hermes"])
        #expect(r.groups[0].memoryBytes == 170 && r.groups[0].processCount == 2)
        #expect(abs(r.groups[0].cpuPercent - 50) < 0.001)   // pid 3 is new: its 9 s do not count
        #expect(abs(r.groups[1].cpuPercent - 25) < 0.001)
        #expect(r.memoryBytes == 480 && r.processCount == 3)
        #expect(P.summarize(now, previous: nil).cpuPercent == 0)
    }

    @Test func walksThisProcessAndReadsTheGatewayPidFile() throws {
        let snap = P.takeSnapshot(at: 0, roots: [("Вера", getpid()), ("Вера ещё раз", getpid())])
        #expect(snap.groups[0].processes.contains { $0.pid == getpid() && $0.residentBytes > 0 })
        #expect(snap.groups[1].processes.isEmpty)   // never counted twice

        let dir = FileManager.default.temporaryDirectory.appending(path: "vera-gw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(P.gatewayPID(hermesHome: dir) == nil)
        try Data(#"{"pid": \#(getpid()), "kind": "hermes-gateway"}"#.utf8).write(to: dir.appending(path: "gateway.pid"))
        #expect(P.gatewayPID(hermesHome: dir) == getpid())
    }

    @Test func parsesThePluginsPlanLimits() throws {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
            {"ok": true, "provider": "opencode-go", "plan": null, "unavailable_reason": null,
             "windows": [{"label": "Rolling window", "used_percent": 23.4, "reset_at": "2026-11-22T18:00:00+00:00"},
                         {"label": "Weekly", "used_percent": null, "reset_at": null},
                         {"label": "Monthly", "used_percent": 2.6, "reset_at": "2026-12-01T00:00:00.500000+00:00"}]}
            """#.utf8))
        let u = try #require(AccountUsage(v))
        #expect(u.provider == "opencode-go" && u.windows.count == 3)
        #expect(u.windows[0].usedPercent == 23.4 && u.windows[0].resetAt != nil)
        #expect(u.windows[1].usedPercent == nil)
        #expect(u.windows[2].resetAt != nil)
        #expect(u.windows.map { AccountUsage.shortLabel($0.label) } == ["5 ч", "неделя", "месяц"])
        #expect(AccountUsage(try JSONDecoder().decode(JSONValue.self, from: Data(#"{"ok": false, "error": "x"}"#.utf8))) == nil)
    }
}
