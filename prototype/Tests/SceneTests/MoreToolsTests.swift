import Foundation
import Testing
@testable import Core

private func tempDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "vera-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - The Mac

@Test func macActionsAreFixedScriptsWithCheckedValues() {
    func plan(_ action: String, _ value: String? = nil, app: String? = nil) -> MacControlTool.Plan { MacControlTool.plan(action: action, value: value, app: app) }
    #expect(plan("volume_set", "40") == .run("/usr/bin/osascript", ["-e", "set volume output volume 40"]))
    for bad in ["101", "-1", "abc", "40; do shell script \"rm -rf ~\""] {
        if case .refuse = plan("volume_set", bad) {} else { Issue.record("volume \(bad) must be refused") }
    }
    #expect(plan("media_next", app: "Spotify") == .run("/usr/bin/osascript", ["-e", "tell application \"Spotify\" to next track"]))
    if case .refuse = plan("media_next", app: "Terminal\" to do script \"x") {} else { Issue.record("only Music and Spotify are media apps") }
    #expect(plan("open_app", "Safari") == .run("/usr/bin/open", ["-a", "Safari"]))
    for bad in ["Safari; ls", "$(whoami)", "../../bin/sh", "", String(repeating: "a", count: 41)] {
        if case .refuse = plan("open_app", bad) {} else { Issue.record("app name \(bad) must be refused") }
    }
    // Quotes and backslashes cannot leave the notification text.
    let note = plan("notify", "чай\" & (do shell script \"ls\") & \"")
    if case let .run(_, args) = note { #expect(!args[1].contains("\\\"") && args[1].filter { $0 == "\"" }.count == 4) } else { Issue.record("notify should run") }
    if case .refuse = plan("shutdown") {} else { Issue.record("unknown actions are refused") }
}

// MARK: - Notes

@Test func notesAreWrittenByDayAndFoundByWords() throws {
    let directory = try tempDirectory("notes"); defer { try? FileManager.default.removeItem(at: directory) }
    let store = NoteStore(directory: directory)
    let calendar = Calendar(identifier: .gregorian)
    let day = DateComponents(calendar: calendar, year: 2026, month: 11, day: 18, hour: 21, minute: 5).date!
    #expect(store.add("купить зарядку для часов", at: day, calendar: calendar) == "2026-11-18.md")
    store.add("позвонить Наташе насчёт билетов", at: day.addingTimeInterval(86_400), calendar: calendar)
    #expect(store.search("зарядка часов") == ["2026-11-18 21:05 купить зарядку для часов"])   // endings do not matter
    #expect(store.search("зарядку часов") == ["2026-11-18 21:05 купить зарядку для часов"])
    #expect(store.search("наташе").count == 1)
    #expect(store.search("").count == 2)                      // an empty query gives the latest notes, newest first
    #expect(store.search("")[0].hasPrefix("2026-11-19"))
    let tools = ToolRegistry.noteTools(store)
    #expect(tools.run(ToolCall(id: "c", name: "find_notes", arguments: #"{"query":"ничего такого"}"#)).text == "заметок не нашла")
}

// MARK: - Daily reminders and task status

@Test func aDailyReminderMovesToTomorrowAndOlderFilesStillLoad() throws {
    let directory = try tempDirectory("daily"); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "r.json")
    let calendar = Calendar(identifier: .gregorian)
    let morning = DateComponents(calendar: calendar, year: 2026, month: 11, day: 19, hour: 5, minute: 30).date!
    let store = ReminderStore(url: url)
    store.add(dueAt: morning, text: "скажи погоду и дела", asTask: true, repeatsDaily: true)
    let fired = store.takeDue(now: morning.addingTimeInterval(10), calendar: calendar)
    #expect(fired.count == 1 && fired[0].repeatsDaily)
    let next = DateComponents(calendar: calendar, year: 2026, month: 11, day: 20, hour: 5, minute: 30).date!
    #expect(ReminderStore(url: url).list().first?.dueAt == next)
    // A missed few days jump to the next future morning, once.
    let late = store.takeDue(now: next.addingTimeInterval(3 * 86_400 + 60), calendar: calendar)
    #expect(late.count == 1)
    #expect(store.list().first?.dueAt == DateComponents(calendar: calendar, year: 2026, month: 11, day: 24, hour: 5, minute: 30).date!)
    // A file written before the repeat existed has no such key.
    let old = #"[{"id":"abc","dueAt":"2026-11-19T05:30:00Z","text":"x","asTask":false}]"#
    try old.write(to: directory.appending(path: "old.json"), atomically: true, encoding: .utf8)
    #expect(ReminderStore(url: directory.appending(path: "old.json")).list().first?.repeatsDaily == false)
}

@MainActor @Test func theStatusOfTheWorkIsToldInWords() async {
    struct Model: ChatModel {
        func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn {
            try? await Task.sleep(for: .milliseconds(300)); var turn = ChatTurn(); turn.text = "Готово."; return turn
        }
    }
    let agent = CoreAgent(loop: AgentLoop(model: Model(), tools: ToolRegistry([]), systemPrompt: "s"))
    agent.includesSceneContext = false
    #expect(agent.statusText() == "задач ещё не было")
    let running = Task { await agent.run(request: "посмотри файлы") }
    for _ in 0..<40 where agent.tasks.first?.state != .running { try? await Task.sleep(for: .milliseconds(25)) }
    #expect(agent.statusText().contains("идёт") && agent.statusText().contains("посмотри файлы"))
    _ = await running.value
    #expect(agent.statusText().contains("готово") && agent.statusText().contains("Готово."))
}

@MainActor @Test func theStatusReportDoesNotCountTheTaskThatAsks() async {
    final class Holder: @unchecked Sendable { weak var agent: CoreAgent? }
    struct Model: ChatModel {
        func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn {
            var turn = ChatTurn()
            if !messages.contains(where: { $0.role == .tool }) { turn.toolCalls = [ToolCall(id: "c1", name: "list_tasks", arguments: "{}")]; return turn }
            turn.text = messages.last(where: { $0.role == .tool })?.content ?? ""
            return turn
        }
    }
    let holder = Holder()
    let tools = ToolRegistry.taskTools { await MainActor.run { holder.agent?.statusText() ?? "" } }
    let agent = CoreAgent(loop: AgentLoop(model: Model(), tools: tools, systemPrompt: "s"))
    agent.includesSceneContext = false
    holder.agent = agent
    let first = await agent.run(request: "первая просьба")
    #expect(first.answer == "задач ещё не было")            // the only task is the one that asks, so it is not listed
    let second = await agent.run(request: "что с задачей?")
    #expect(second.answer.contains("первая просьба") && !second.answer.contains("что с задачей?"))
}

@Test func theNewGatesAreOutOfHerReachWhenSheChangesHerOwnCode() {
    for file in ["Core/Agent/ShellTool.swift", "Core/Agent/BrowserTools.swift", "Core/Agent/WebTools.swift", "Core/Agent/MacControl.swift",
                 "Core/Agent/Tools.swift", "Core/Agent/AgentLoop.swift", "Browser/BrowserEngine.swift", "Core/Agent/CoreAgent.swift"] {
        #expect(SelfModifier.protectedFiles.contains(file), "\(file) must be protected")
    }
}
