import Foundation
import Testing
import SignalBus

/// A clock the test moves by hand; the models read it through their injected closure.
private final class FakeClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
    var read: @Sendable () -> Date { { [self] in self.now } }
}

private let moscow: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
    return calendar
}()

private func moscowDate(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
    moscow.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private func toolEvent(_ type: String, _ payload: [String: String], at: Date = moscowDate(19, 12, 0)) -> SignalMessage {
    SignalMessage(kind: .event, domain: .core, source: "Core.Tools", type: type, timestamp: at,
                  subjectID: payload["id"].map { "toolrun/\($0)" }, payload: payload)
}

private func started(_ id: String, tool: String = "codex", title: String = "тест", at: Date = moscowDate(19, 12, 0)) -> SignalMessage {
    toolEvent("core.toolrun.started", ["id": id, "tool": tool, "title": title, "state": "running",
                                       "started_at": String(at.timeIntervalSince1970)], at: at)
}

@MainActor
@Test func toolRunStartsProgressesAndFinishesAsDone() {
    let clock = FakeClock(moscowDate(19, 12, 0))
    let model = ToolRunModel(clock: clock.read, calendar: moscow)
    model.handle(started("1", title: "рефакторинг"))
    #expect(model.runs.count == 1)
    #expect(model.runs[0].state == .running && model.runs[0].tool == "codex" && model.runs[0].title == "рефакторинг")

    model.handle(toolEvent("core.toolrun.progress", ["id": "1", "line": "читаю файлы", "elapsed_s": "3"]))
    #expect(model.runs[0].progressLine == "читаю файлы")

    model.handle(toolEvent("core.toolrun.finished", ["id": "1", "state": "done", "summary": "готово, 2 файла", "elapsed_s": "42"]))
    #expect(model.runs[0].state == .done)
    #expect(model.runs[0].summary == "готово, 2 файла")
    #expect(model.runs[0].finishedElapsed == 42)
    #expect(model.lastState(of: "codex") == .done)
    #expect(model.elapsed(of: model.runs[0], at: moscowDate(19, 13, 0)) == 42)
}

@MainActor
@Test func toolRunFailedAndCancelledStates() {
    let model = ToolRunModel(calendar: moscow)
    model.handle(started("1", tool: "claude"))
    model.handle(toolEvent("core.toolrun.finished", ["id": "1", "state": "failed", "summary": "нет доступа", "elapsed_s": "5"]))
    #expect(model.runs[0].state == .failed)
    #expect(model.lastState(of: "claude") == .failed)

    model.handle(started("2", tool: "claude"))
    model.handle(toolEvent("core.toolrun.finished", ["id": "2", "state": "cancelled", "summary": "", "elapsed_s": "1"]))
    #expect(model.runs[0].state == .cancelled)
    #expect(model.lastState(of: "claude") == .cancelled)
}

@MainActor
@Test func toolRunIgnoresProgressForUnknownOrFinishedRuns() {
    let model = ToolRunModel(calendar: moscow)
    model.handle(toolEvent("core.toolrun.progress", ["id": "missing", "line": "чужое", "elapsed_s": "1"]))
    #expect(model.runs.isEmpty)

    model.handle(started("1"))
    model.handle(toolEvent("core.toolrun.finished", ["id": "1", "state": "done", "summary": "ок", "elapsed_s": "2"]))
    model.handle(toolEvent("core.toolrun.progress", ["id": "1", "line": "поздно", "elapsed_s": "3"]))
    #expect(model.runs[0].progressLine.isEmpty)
    #expect(model.runs[0].summary == "ок")
    // A finish for an unknown id changes nothing either.
    model.handle(toolEvent("core.toolrun.finished", ["id": "nope", "state": "done", "summary": "x", "elapsed_s": "1"]))
    #expect(model.runs.count == 1)
}

@MainActor
@Test func toolRunIgnoresOtherSources() {
    let model = ToolRunModel(calendar: moscow)
    model.handle(SignalMessage(domain: .core, source: "Core.Agent", type: "core.toolrun.started",
                               payload: ["id": "1", "tool": "codex", "title": "x", "started_at": "1"]))
    #expect(model.runs.isEmpty)
}

@MainActor
@Test func toolRunListKeepsTwentyNewestFirst() {
    let model = ToolRunModel(calendar: moscow)
    for index in 1...25 {
        model.handle(started("\(index)", title: "run \(index)"))
    }
    #expect(model.runs.count == 20)
    #expect(model.runs.first?.id == "25")
    #expect(model.runs.last?.id == "6")
    // The cap drops the oldest; a late progress for a dropped run is ignored.
    model.handle(toolEvent("core.toolrun.progress", ["id": "1", "line": "поздно"]))
    #expect(!model.runs.contains { $0.progressLine == "поздно" })
}

@MainActor
@Test func toolRunDailyCountersResetAtLocalMidnight() {
    let clock = FakeClock(moscowDate(19, 23, 50))
    let model = ToolRunModel(clock: clock.read, calendar: moscow)
    model.handle(started("1", tool: "codex", at: moscowDate(19, 23, 50)))
    model.handle(started("2", tool: "codex", at: moscowDate(19, 23, 55)))
    model.handle(started("3", tool: "claude", at: moscowDate(19, 23, 56)))
    #expect(model.runsToday("codex") == 2)
    #expect(model.runsToday("claude") == 1)

    clock.now = moscowDate(20, 0, 5)
    #expect(model.runsToday("codex") == 0)
    #expect(model.runsToday("claude") == 0)

    model.handle(started("4", tool: "codex", at: moscowDate(20, 0, 5)))
    #expect(model.runsToday("codex") == 1)
    // The list keeps yesterday's runs; only the counters restart.
    #expect(model.runs.count == 4)
}

@MainActor
@Test func toolRunElapsedTicksWhileRunning() {
    let clock = FakeClock(moscowDate(19, 12, 0))
    let model = ToolRunModel(clock: clock.read, calendar: moscow)
    model.handle(started("1", at: moscowDate(19, 12, 0)))
    #expect(model.elapsed(of: model.runs[0], at: moscowDate(19, 12, 0).addingTimeInterval(65)) == 65)
    #expect(ToolRunModel.format(65) == "1:05")
    #expect(ToolRunModel.format(0) == "0:00")
}
