import Foundation
import Testing
@testable import HermesBridge

@Suite struct LifeHistoryTests {
    func dir() -> URL { FileManager.default.temporaryDirectory.appending(path: "life-\(UUID().uuidString)") }

    @Test func gridCountsModelAndToolCallsByHour() throws {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_795_000_000)   // a fixed day
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let file = d.appending(path: f.string(from: now) + ".jsonl")
        let noon = cal.startOfDay(for: now).timeIntervalSince1970 + 12 * 3600
        let lines = [
            #"{"v":1,"ts":\#(noon),"kind":"llm.start"}"#, #"{"v":1,"ts":\#(noon + 5),"kind":"tool.start","name":"read_file"}"#,
            #"{"v":1,"ts":\#(noon + 6),"kind":"llm.end","duration_ms":1500,"tokens_in":100,"tokens_out":20,"status":"ok"}"#,
            #"{"v":1,"ts":\#(noon + 9),"kind":"llm.error","duration_ms":300}"#,
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let g = LifeHistory.grid(pulseDirectory: d, days: 2, now: now, calendar: cal)
        #expect(g.counts.count == 2)
        // TimeZone of the file name follows the formatter's (current) zone; the hour bucket uses `cal` (UTC).
        #expect(g.counts.last?.reduce(0, +) == 2)
        let calls = LifeHistory.modelCalls(pulseDirectory: d, now: now)
        #expect(calls.count == 2)
        #expect(calls.first?.ms == 1500 && calls.last?.failed == true)
    }

    @Test func usageIsRecordedHourlyOrOnChange() {
        let d = dir(); defer { try? FileManager.default.removeItem(at: d) }
        var u = DataUsage(); u.measured = true; u.total = 100; u.memoryFiles = 1
        let t = Date(timeIntervalSince1970: 1_000_000)
        #expect(LifeHistory.record(u, in: d, now: t).count == 1)
        #expect(LifeHistory.record(u, in: d, now: t.addingTimeInterval(60)).count == 1)      // same, too soon
        u.memoryFiles = 2
        #expect(LifeHistory.record(u, in: d, now: t.addingTimeInterval(120)).count == 2)     // memory changed
        #expect(LifeHistory.record(u, in: d, now: t.addingTimeInterval(4000)).count == 3)    // an hour later
    }
}

@Suite struct UpdateCheckTests {
    @Test func readsTheLatestStableAndComparesVersions() {
        #expect(UpdateCheck.latestReleaseURL(source: "https://github.com/NousResearch/hermes-agent.git")?.absoluteString
                == "https://api.github.com/repos/NousResearch/hermes-agent/releases/latest")
        #expect(UpdateCheck.tag(from: Data(#"{"tag_name":"v0.24.1","prerelease":false}"#.utf8)) == "v0.24.1")
        #expect(UpdateCheck.tag(from: Data(#"{"tag_name":"v0.25.0-rc1","prerelease":true}"#.utf8)) == nil)
        #expect(UpdateCheck.isNewer("v0.24.1", than: "v0.23.3"))
        #expect(!UpdateCheck.isNewer("v0.23.3", than: "v0.23.3"))
        #expect(!UpdateCheck.isNewer("v0.23.2", than: "v0.23.3"))
        #expect(UpdateCheck.isNewer("v1.0.0", than: "v0.99.9"))
    }
}
