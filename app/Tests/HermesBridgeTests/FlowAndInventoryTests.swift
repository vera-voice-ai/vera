import Foundation
import Testing
@testable import HermesBridge

@Suite struct FlowMonitorTests {
    @Test func flowBucketsCountTheLastMinutesOldestFirst() {
        var f = FlowMonitor()
        let now = Date()
        f.note(.adapterToHermes, count: 2, now: now.addingTimeInterval(-590))
        f.note(.adapterToHermes, now: now.addingTimeInterval(-5))
        f.note(.adapterToHermes, now: now.addingTimeInterval(-700))   // older than 10 minutes: gone
        let b = f.buckets(.adapterToHermes, seconds: 600, count: 30, now: now)
        #expect(b.count == 30 && b.first == 2 && b.last == 1 && b.reduce(0, +) == 3)
    }

    @Test func dotsFlyThenLandAndCountsStay() {
        var f = FlowMonitor()
        let t0 = Date(timeIntervalSince1970: 1000)
        f.note(.adapterToHermes, now: t0)
        f.note(.hermesToAdapter, count: 9, now: t0)       // a burst: few dots, every one counted
        #expect(f.pulses.count == 1 + 4)
        #expect(f.perMinute(.hermesToAdapter, now: t0) == 9)
        f.trim(now: t0.addingTimeInterval(5))
        #expect(!f.active)                                   // the dots landed
        #expect(f.perMinute(.adapterToHermes, now: t0.addingTimeInterval(30)) == 1)
        #expect(f.perMinute(.adapterToHermes, now: t0.addingTimeInterval(90)) == 0)
        #expect(f.total10m(.hermesToAdapter) == 9)
    }
}

@Suite struct InventoryTests {
    func obj(_ s: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

    /// Shapes from the live gateway of 2026-11-21 (plugins.list, toolsets.list, skills.manage list, cron, mcp).
    @Test func readsOursStandardAndPlatforms() {
        let inv = HermesInventory.from(
            plugins: obj(#"{"plugins":[{"name":"xai","key":"model-providers/xai","enabled":true,"tools":[],"hooks":[]},{"name":"xai","key":"image_gen/xai","enabled":true},{"name":"vera-pulse","key":"vera-pulse","enabled":true,"hooks":["a","b"]},{"name":"telegram-platform","key":"platforms/telegram","enabled":true},{"name":"google_meet","key":"google_meet","enabled":false,"error":"not enabled in config"}]}"#),
            toolsets: obj(#"{"toolsets":[{"name":"file","enabled":true,"tool_count":4,"description":"files"},{"name":"a2a","enabled":false,"tool_count":5}]}"#),
            skills: obj(#"{"skills":{"apple":["apple-notes","findmy"],"creative":["p5js"]}}"#),
            cron: obj(#"{"success":true,"count":0,"jobs":[]}"#),
            mcp: obj(#"{"servers":[]}"#))
        #expect(inv.loaded)
        #expect(inv.ourPlugins.map(\.name) == ["vera-pulse"] && inv.ourPlugins[0].hooks == 2)
        #expect(inv.platforms.map(\.name) == ["telegram-platform"])
        #expect(Set(inv.otherPlugins.map(\.id)).count == inv.otherPlugins.count)   // two «xai» stay two rows
        #expect(inv.enabledToolsets.map(\.name) == ["file"] && inv.skillCount == 3)
        #expect(inv.cronJobs.isEmpty && inv.mcpServers.isEmpty)
    }
}

@Suite struct DataUsageTests {
    @Test func measuresWhereHermesKeepsThings() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "vera-du-\(UUID().uuidString)")
        let fm = FileManager.default
        for d in ["memories", "skills/my-skill", "logs", "vera-pulse"] { try fm.createDirectory(at: home.appending(path: d), withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: home) }
        try Data(count: 1000).write(to: home.appending(path: "state.db"))
        try Data(count: 200).write(to: home.appending(path: "state.db-wal"))
        try Data(count: 50).write(to: home.appending(path: "memories/USER.md"))
        try Data(count: 30).write(to: home.appending(path: "logs/agent.log"))
        try Data(count: 7).write(to: home.appending(path: "vera-pulse/2026-11-21.jsonl"))
        let u = DataUsage.scan(hermesHome: home)
        #expect(u.measured && u.conversations == 1200 && u.memoryFiles == 1 && u.memoryBytes == 50)
        #expect(u.skillDirs == 1 && u.logs == 30 && u.pulse == 7 && u.total == 1287)
    }
}

@Suite struct SkillUsageTests {
    func obj(_ s: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

    @Test func usedAndLastActiveFromCuratorFile() {
        let u = SkillUsage.parse(obj(#"""
        {"apple-notes":{"use_count":5,"last_used_at":"2026-11-20T10:00:00Z","state":"active"},
         "p5js":{"use_count":0,"created_at":1795000000},
         "my-flow":{"use_count":2,"last_patched_at":"1795253000","created_by":"agent","pinned":true}}
        """#))
        #expect(u.rows.count == 3)
        #expect(u.used.map(\.name) == ["apple-notes", "my-flow"])
        #expect(u.lastUsed?.name == "my-flow")                 // 1795253000 > 2026-11-20 10:00 UTC
        #expect(u.madeByAgent.map(\.name) == ["my-flow"] && u.madeByAgent[0].pinned)
    }

    @Test func missingFileMeansNothingUsedYet() {
        let u = SkillUsage.read(hermesHome: URL(filePath: "/nonexistent-vera"))
        #expect(u.rows.isEmpty && u.used.isEmpty && u.lastUsed == nil)
    }
}
