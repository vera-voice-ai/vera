import Foundation
import Testing
@testable import Core
import SignalBus

private let codexJSONL = """
{"type":"thread.started","thread_id":"t1"}
{"type":"turn.started"}
{"type":"item.started","item":{"id":"i1","type":"command_execution","command":"ls -la","status":"in_progress"}}
{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"Смотрю структуру проекта"}}
{"type":"turn.completed","usage":{"input_tokens":12,"output_tokens":3}}
"""

private let claudeStreamJSON = """
{"type":"system","subtype":"init","session_id":"s1","tools":["Read"]}
{"type":"assistant","message":{"content":[{"type":"text","text":"Сейчас посмотрю файлы"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"u1","name":"Read","input":{"file_path":"a.txt"}}]}}
{"type":"result","subtype":"success","is_error":false,"result":"Итог: всё работает"}
"""

@Suite struct EngineParsingTests {
    @Test func codexProgressTakesTextLikeFieldsAndIgnoresTheRest() {
        let lines = codexJSONL.split(separator: "\n").map(String.init)
        let progress = lines.compactMap(EngineProgress.codexLine)
        #expect(progress == ["ls -la", "Смотрю структуру проекта"])
        #expect(EngineProgress.codexLine("not json at all") == nil)
        #expect(EngineProgress.codexLine("") == nil)
        #expect(EngineProgress.codexLine(#"{"type":"turn.completed","usage":{"input_tokens":1}}"#) == nil)
    }

    @Test func codexProgressIsOneShortLine() {
        let long = "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"первая строка\\nвторая строка\"}}"
        let line = EngineProgress.codexLine(long) ?? ""
        #expect(!line.contains("\n"))
        #expect(line.hasPrefix("первая строка"))
        let huge = #"{"text":"\#(String(repeating: "я", count: 500))"}"#
        #expect((EngineProgress.codexLine(huge) ?? "").count == 120)
    }

    @Test func claudeStreamGivesProgressAndTheFinalResult() {
        let events = claudeStreamJSON.split(separator: "\n").map { EngineProgress.claudeLine(String($0)) }
        #expect(events == [
            .ignored,
            .progress("Сейчас посмотрю файлы"),
            .progress("инструмент: Read"),
            .result(text: "Итог: всё работает", isError: false)
        ])
        #expect(EngineProgress.claudeLine("{broken") == .ignored)
    }

    @Test func sanitizedErrorTextHasNoHomePathOrSecret() {
        let text = EngineText.sanitize("failed at \(NSHomeDirectory())/x and /Users/someone/y with sk-abcdefgh12345 Bearer tok123")
        #expect(!text.contains(NSHomeDirectory()))
        #expect(!text.contains("/Users/someone"))
        #expect(!text.contains("sk-abcdefgh12345"))
        #expect(!text.contains("tok123"))
        #expect(EngineText.sanitize("line one\nline two", limit: 200) == "line one line two")
    }
}

@Suite struct EngineToolTests {
    @Test func codexRunReturnsTheLastMessageAndRecordsProgress() async throws {
        let fake = FakeEngines()
        defer { fake.cleanUp() }
        fake.install("codex")
        fake.behave("codex", stdout: codexJSONL + "\n", exit: 0, lastMessage: "Готово: проект читается.")
        let board = ToolRunBoard()
        let registry = ToolRegistry.engineTools(workspace: fake.workspace, board: board, locator: fake.locator)

        let result = await callEngineTool(registry, "codex", jsonArguments(task: "Разбери структуру"))
        #expect(result.ok)
        #expect(result.text.hasSuffix("Готово: проект читается."))
        #expect(result.text.hasPrefix(EngineText.answerHeader))

        let run = try #require(board.all().first)
        #expect(run.state == .done)
        #expect(run.tool == "codex")
        #expect(run.title == "Разбери структуру")
        #expect(run.lastProgress == "Смотрю структуру проекта")
        #expect(run.summary == "Готово: проект читается.")
    }

    @Test func codexArgumentsAreTheDocumentedFlagsWithReadOnlyByDefault() async throws {
        let fake = FakeEngines()
        defer { fake.cleanUp() }
        fake.install("codex")
        fake.behave("codex", exit: 0, lastMessage: "ok")
        let registry = ToolRegistry.engineTools(workspace: fake.workspace, board: ToolRunBoard(), locator: fake.locator)

        _ = await callEngineTool(registry, "codex", jsonArguments(task: "Посмотри"))
        let argv = fake.argv("codex")
        #expect(Array(argv.prefix(4)) == ["exec", "--json", "--skip-git-repo-check", "-C"])
        #expect(argv[4] == fake.workspace.path)
        #expect(argv[5] == "-s" && argv[6] == "read-only")
        #expect(argv.contains("--output-last-message"))

        _ = await callEngineTool(registry, "codex", jsonArguments(task: "Поправь", mode: "write"))
        let writeArgv = fake.argv("codex")
        #expect(writeArgv[6] == "workspace-write")
    }

    @Test func taskIsOneArgumentEvenWithQuotesSubstitutionsAndNewlines() async throws {
        let fake = FakeEngines()
        defer { fake.cleanUp() }
        fake.install("codex")
        fake.install("claude")
        fake.behave("codex", exit: 0, lastMessage: "ok")
        fake.behave("claude", stdout: #"{"type":"result","is_error":false,"result":"ok"}"# + "\n")
        let registry = ToolRegistry.engineTools(workspace: fake.workspace, board: ToolRunBoard(), locator: fake.locator)
        let marker = fake.base.appending(path: "injected-codex")
        let secondMarker = fake.base.appending(path: "injected-backtick")
        let task = "Найди \"кавычки\" 'одинарные' $(touch \(marker.path)) `touch \(secondMarker.path)`\nвторая строка; rm -rf ~"

        _ = await callEngineTool(registry, "codex", jsonArguments(task: task))
        #expect(fake.argv("codex").last == task)
        _ = await callEngineTool(registry, "claude", jsonArguments(task: task))
        #expect(fake.argv("claude")[1] == task)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: secondMarker.path))
    }

    @Test func claudeReadAndWriteUseTheDocumentedFlags() async throws {
        let fake = FakeEngines()
        defer { fake.cleanUp() }
        fake.install("claude")
        fake.behave("claude", stdout: #"{"type":"result","is_error":false,"result":"готово"}"# + "\n")
        let registry = ToolRegistry.engineTools(workspace: fake.workspace, board: ToolRunBoard(), locator: fake.locator)

        let read = await callEngineTool(registry, "claude", jsonArguments(task: "Изучи код"))
        #expect(read.ok)
        #expect(read.text.hasSuffix("готово"))
        var argv = fake.argv("claude")
        #expect(argv == ["-p", "Изучи код", "--output-format", "stream-json", "--verbose", "--permission-mode", "plan"])

        _ = await callEngineTool(registry, "claude", jsonArguments(task: "Правь", mode: "write"))
        argv = fake.argv("claude")
        #expect(argv == ["-p", "Правь", "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits",
                         "--allowedTools", "Read", "Grep", "Glob", "Edit", "Write"])
        #expect(!argv.contains("--dangerously-skip-permissions"))
        #expect(!argv.contains("bypassPermissions"))
    }

    @Test func childSeesItsOwnConfigHomeButNotASecretFromTheParent() async throws {
        let fake = FakeEngines()
        defer { fake.cleanUp() }
        fake.install("codex")
        fake.behave("codex", exit: 0, lastMessage: "ok")
        let secretName = "VERA_TEST_PARENT_SECRET_\(UUID().uuidString.prefix(8))"
        setenv(secretName, "parent-only-value", 1)
        defer { unsetenv(secretName) }
        let registry = ToolRegistry.engineTools(workspace: fake.workspace, board: ToolRunBoard(), locator: fake.locator)

        _ = await callEngineTool(registry, "codex", jsonArguments(task: "Проверка окружения"))
        let env = fake.environment("codex")
        #expect(env["CODEX_HOME"] == fake.locator.configHome(.codex).path)
        #expect(env[secretName] == nil)
        #expect(env["OPENAI_API_KEY"] == nil)
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(!env.values.contains("parent-only-value"))
    }

    @Test func missingCLIIsAnHonestRussianFailure() async throws {
        let fake = FakeEngines()
        defer { fake.cleanUp() }
        let board = ToolRunBoard()
        let registry = ToolRegistry.engineTools(workspace: fake.workspace, board: board, locator: fake.locator)

        let result = await callEngineTool(registry, "codex", jsonArguments(task: "Разбери"))
        #expect(!result.ok)
        #expect(result.text == "Codex не найден: нужно поставить в папку движков")
        #expect(board.all().first?.state == .failed)
    }

    @Test func notLoggedInIsRecognisedAndNamesTheFixWithoutPaths() async throws {
        let fake = FakeEngines()
        defer { fake.cleanUp() }
        fake.install("codex")
        fake.behave("codex", stderr: "Error: not logged in. Run codex login to continue.\n", exit: 1)
        let registry = ToolRegistry.engineTools(workspace: fake.workspace, board: ToolRunBoard(), locator: fake.locator)

        let result = await callEngineTool(registry, "codex", jsonArguments(task: "Разбери"))
        #expect(!result.ok)
        #expect(result.text == "Codex не вошёл в аккаунт: нужно один раз войти")
        #expect(!result.text.contains(NSHomeDirectory()))
    }

    @Test func nonZeroExitShowsTheLastStderrLineSanitised() async throws {
        let fake = FakeEngines()
        defer { fake.cleanUp() }
        fake.install("codex")
        fake.behave("codex", stderr: "warning: first\nboom at \(NSHomeDirectory())/secret sk-abcdefgh12345\n", exit: 2)
        let registry = ToolRegistry.engineTools(workspace: fake.workspace, board: ToolRunBoard(), locator: fake.locator)

        let result = await callEngineTool(registry, "codex", jsonArguments(task: "Разбери"))
        #expect(!result.ok)
        #expect(result.text.hasPrefix("Codex завершился с ошибкой (код 2): boom at ~/secret"))
        #expect(!result.text.contains(NSHomeDirectory()))
        #expect(!result.text.contains("sk-abcdefgh12345"))
    }

    @Test func timeoutKillsTheCLIAndSaysSo() async throws {
        let fake = FakeEngines()
        defer { fake.cleanUp() }
        fake.install("codex")
        fake.behave("codex", sleeps: true)
        let board = ToolRunBoard()
        let registry = ToolRegistry.engineTools(workspace: fake.workspace, board: board, locator: fake.locator, timeout: 0.5)

        let started = Date()
        let result = await callEngineTool(registry, "codex", jsonArguments(task: "Долго"))
        #expect(!result.ok)
        #expect(result.text == "Codex не ответил вовремя и был остановлен")
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(board.all().first?.state == .failed)
    }

    @Test func cancellingTheCallRecordsACancelledRun() async throws {
        let fake = FakeEngines()
        defer { fake.cleanUp() }
        fake.install("claude")
        fake.behave("claude", sleeps: true)
        let board = ToolRunBoard()
        let registry = ToolRegistry.engineTools(workspace: fake.workspace, board: board, locator: fake.locator)

        let call = Task { await callEngineTool(registry, "claude", jsonArguments(task: "Долго")) }
        try await Task.sleep(for: .milliseconds(400))
        call.cancel()
        _ = await call.value
        #expect(board.all().first?.state == .cancelled)
    }

    @Test func longAnswerIsCappedWithANote() async throws {
        let fake = FakeEngines()
        defer { fake.cleanUp() }
        fake.install("codex")
        fake.behave("codex", exit: 0, lastMessage: String(repeating: "x", count: 5_000))
        let registry = ToolRegistry.engineTools(workspace: fake.workspace, board: ToolRunBoard(), locator: fake.locator)

        let result = await callEngineTool(registry, "codex", jsonArguments(task: "Длинно"))
        #expect(result.ok)
        #expect(result.text.contains(EngineText.cutNote))
        #expect(result.text.filter { $0 == "x" }.count == EngineText.answerLimit)
    }

    @Test func badArgumentsAreRefusedBeforeAnythingStarts() async throws {
        let fake = FakeEngines()
        defer { fake.cleanUp() }
        let board = ToolRunBoard()
        let registry = ToolRegistry.engineTools(workspace: fake.workspace, board: board, locator: fake.locator)

        #expect(!(await callEngineTool(registry, "codex", "{}")).ok)
        #expect(!(await callEngineTool(registry, "codex", jsonArguments(task: "   "))).ok)
        #expect(!(await callEngineTool(registry, "codex", jsonArguments(task: "x", mode: "delete"))).ok)
        #expect(board.all().isEmpty)
    }

    @Test func descriptionsAreShortAndSayWhenToUseThem() {
        let registry = ToolRegistry.engineTools(workspace: URL(fileURLWithPath: "/tmp"), board: ToolRunBoard())
        for definition in registry.definitions {
            #expect(definition.description.count <= 140)
            #expect(definition.description.contains("Алексей"))
        }
        #expect(Set(registry.definitions.map(\.name)) == ["codex", "claude"])
    }

    @Test func eventsArriveInOrderOnTheBus() async throws {
        let fake = FakeEngines()
        defer { fake.cleanUp() }
        fake.install("codex")
        fake.behave("codex", stdout: codexJSONL + "\n", exit: 0, lastMessage: "Готово")
        let bus = SignalBus()
        let stream = await bus.subscribe()
        let registry = ToolRegistry.engineTools(workspace: fake.workspace, board: ToolRunBoard(bus: bus), locator: fake.locator)

        _ = await callEngineTool(registry, "codex", jsonArguments(task: "Порядок событий"))

        var seen: [SignalMessage] = []
        for await message in stream where message.source == "Core.Tools" {
            seen.append(message)
            if message.type == "core.toolrun.finished" { break }
        }
        let types = seen.map(\.type)
        #expect(types.first == "core.toolrun.started")
        #expect(types.last == "core.toolrun.finished")
        #expect(types.dropFirst().dropLast().allSatisfy { $0 == "core.toolrun.progress" })
        #expect(types.filter { $0 == "core.toolrun.progress" }.count >= 2)

        let started = try #require(seen.first)
        #expect(started.domain == .core)
        #expect(started.kind == .event)
        #expect(started.payload["state"] == "running")
        #expect(started.payload["tool"] == "codex")
        #expect(started.payload["title"] == "Порядок событий")
        #expect(started.payload["started_at"] != nil)
        let id = try #require(started.payload["id"])
        #expect(started.subjectID == "toolrun/\(id)")

        let finished = try #require(seen.last)
        #expect(finished.payload["id"] == id)
        #expect(finished.payload["state"] == "done")
        #expect(finished.payload["summary"] == "Готово")
        #expect(finished.payload["elapsed_s"] != nil)
        #expect(seen.dropFirst().dropLast().allSatisfy { $0.payload["id"] == id && $0.payload["line"] != nil })
    }
}
