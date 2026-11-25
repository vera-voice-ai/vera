import Foundation
import Testing
@testable import HermesBridge

@Suite struct ChatTranscriptTests {
    func obj(_ s: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

    @Test func hermesNotesInHistoryAreNoticesNotThePerson() {
        var t = ChatTranscript()
        t.load(snapshot: obj(#"""
            {"messages": [
              {"role": "user", "text": "запусти таймер"},
              {"role": "user", "text": "[IMPORTANT: Background process proc_1 completed normally]", "display_kind": "process_complete",
               "display_metadata": {"display_text": "Background Process Finished: sleep 30"}},
              {"role": "assistant", "text": "Готово."}]}
            """#))
        #expect(t.items.map(\.kind) == [.user("запусти таймер"), .notice("Background Process Finished: sleep 30", warning: false),
                                        .assistant("Готово.", done: true)])
    }

    /// `session.transcript` rows (the Telegram card): the same shape as a resume, plus a compaction handoff row.
    @Test func storedTranscriptRowsLoadLikeAResume() {
        var t = ChatTranscript()
        t.load(snapshot: obj(#"""
            {"messages": [
              {"row_kind": "compaction", "role": "system", "text": "Раньше говорили о погоде", "compacted_messages": 40},
              {"row_kind": "message", "role": "user", "text": "Как дела?", "timestamp": 1763900000},
              {"row_kind": "message", "role": "assistant", "text": "Работаю."}]}
            """#))
        #expect(t.items.map(\.kind) == [.notice("Раньше говорили о погоде", warning: false), .user("Как дела?"),
                                        .assistant("Работаю.", done: true)])
    }

    @Test func streamsAnAnswerAndTools() {
        var t = ChatTranscript()
        t.addUser("привет")
        t.apply(type: "message.start", payload: obj("{}"), meta: obj(#"{"execution_generation":1,"seq":2}"#))
        #expect(t.running && t.generation == 1)
        t.apply(type: "tool.start", payload: obj(#"{"tool_id":"t1","name":"terminal","preview":"ls"}"#))
        t.apply(type: "tool.complete", payload: obj(#"{"tool_id":"t1","name":"terminal","duration_s":0.4,"summary":"3 files"}"#))
        t.apply(type: "message.delta", payload: obj(#"{"text":"При"}"#))
        t.apply(type: "message.delta", payload: obj(#"{"text":"вет"}"#))
        t.apply(type: "message.complete", payload: obj(#"{"text":"Привет","usage":{"input":12,"output":3}}"#), meta: obj(#"{"seq":9}"#))
        #expect(!t.running)
        #expect(t.lastSequence == 9 && t.tokensIn == 12 && t.tokensOut == 3)
        let kinds = t.items.map(\.kind)
        #expect(kinds.first == .user("привет"))
        #expect(kinds.contains(.tool(id: "t1", name: "terminal", preview: "ls", durationS: 0.4, summary: "3 files", done: true)))
        #expect(kinds.last == .assistant("Привет", done: true))
    }

    /// The live probe of 2026-11-21: the provider refused, Hermes printed why and completed with an error text.
    @Test func providerRefusalShowsNoticesAndCompletes() {
        var t = ChatTranscript()
        t.apply(type: "message.start", payload: obj("{}"))
        t.apply(type: "agent.print", payload: obj(#"{"text":"⚠️  Attempt 1/3, not retryable failed: HTTP 400"}"#))
        t.apply(type: "status.update", payload: obj(#"{"kind":"lifecycle","text":"❌ OpenCode Go rejected the request"}"#))
        t.apply(type: "message.complete", payload: obj(#"{"text":"OpenCode Go rejected this request as malformed"}"#))
        #expect(!t.running)
        #expect(t.items.contains { if case .notice(_, true) = $0.kind { return true }; return false })
        #expect(t.items.last?.kind == .assistant("OpenCode Go rejected this request as malformed", done: true))
    }

    @Test func answerAroundAToolKeepsOrderWithoutDuplicates() {
        var t = ChatTranscript()
        t.addUser("проверь")
        t.apply(type: "message.start", payload: obj("{}"))
        t.apply(type: "message.delta", payload: obj(#"{"text":"Смотрю. "}"#))
        t.apply(type: "tool.start", payload: obj(#"{"tool_id":"t","name":"read_file"}"#))
        t.apply(type: "tool.complete", payload: obj(#"{"tool_id":"t","name":"read_file"}"#))
        t.apply(type: "message.delta", payload: obj(#"{"text":"Всё в порядке."}"#))
        t.apply(type: "message.complete", payload: obj(#"{"text":"Смотрю. Всё в порядке."}"#))
        #expect(t.items.map(\.kind) == [
            .user("проверь"),
            .assistant("Смотрю. ", done: true),
            .tool(id: "t", name: "read_file", preview: nil, durationS: nil, summary: nil, done: true),
            .assistant("Всё в порядке.", done: true)
        ])
    }

    /// The live screen of 2026-11-21: the same refusal came as agent.print and status.update, plus a reason code.
    @Test func sameFailureShownOnceAndCodeIsAHint() {
        var t = ChatTranscript()
        t.apply(type: "message.start", payload: obj("{}"))
        t.apply(type: "agent.print", payload: obj(#"{"text":"❌ OpenCode Go rejected the request: HTTP 400"}"#))
        t.apply(type: "status.update", payload: obj(#"{"kind":"lifecycle","text":"❌ OpenCode Go rejected the request: HTTP 400"}"#))
        t.apply(type: "agent.print", payload: obj(#"{"text":"   💡 Fix: pick another model"}"#))
        t.apply(type: "message.complete", payload: obj(#"{"text":"Provider said: HTTP 400","failure_reason":"format_error"}"#))
        let notices = t.items.compactMap { if case .notice(let s, _) = $0.kind { return s }; return nil }
        #expect(notices == ["❌ OpenCode Go rejected the request: HTTP 400", "💡 Fix: pick another model", "код причины: format_error"])
        #expect(!t.items.contains { if case .error = $0.kind { return true }; return false })
        // A new turn may report the same failure again.
        t.apply(type: "message.start", payload: obj("{}"))
        t.apply(type: "agent.print", payload: obj(#"{"text":"❌ OpenCode Go rejected the request: HTTP 400"}"#))
        #expect(t.items.filter { if case .notice = $0.kind { return true }; return false }.count == 4)
    }

    @Test func emptyCompletionLeavesNoEmptyBubble() {
        var t = ChatTranscript()
        t.apply(type: "message.start", payload: obj("{}"))
        t.apply(type: "message.complete", payload: obj(#"{"text":"","error":"boom"}"#))
        #expect(t.items.map(\.kind) == [.error("boom")])
    }

    @Test func questionsArriveAndResolve() {
        var t = ChatTranscript()
        t.addRequest(id: .string("srq-1"), method: "approval",
                     params: obj(#"{"session_id":"s","request_id":"r","command":"rm -rf build","choices":["once","deny"]}"#))
        t.addRequest(id: .string("srq-1"), method: "approval", params: .null)  // the same request twice: one card
        #expect(t.pending.count == 1 && t.pending[0].command == "rm -rf build" && t.pending[0].choices == ["once", "deny"])
        t.apply(type: "request.cancel", payload: obj(#"{"id":"srq-1","method":"approval","reason":"timeout"}"#))
        #expect(t.pending.isEmpty)
    }

    /// The stored shape of 2026-11-21 (Vera's main session): commentary in codex items, tool name on the result row.
    @Test func resumedToolCallShowsNameAndArgumentNotRawJSON() {
        var t = ChatTranscript()
        t.load(snapshot: obj(#"""
        {"messages":[{"role":"user","content":"Прочитай SOUL.md"},
          {"role":"assistant","tool_calls":[{"id":"c1","function":{"name":"read_file","arguments":"{\"path\":\"/x/y/SOUL.md\"}"}}],
           "codex_message_items":[{"content":[{"type":"output_text","text":"Читаю файл."}]}]},
          {"role":"tool","content":"{\"content\": \"1|You are Hermes\"}","tool_call_id":"c1","tool_name":"read_file"},
          {"role":"assistant","content":"Готово."}]}
        """#))
        #expect(t.items.map(\.kind) == [
            .user("Прочитай SOUL.md"), .assistant("Читаю файл.", done: true),
            .tool(id: "c1", name: "read_file", preview: "SOUL.md", durationS: nil, summary: "результат · 31 симв.", done: true),
            .assistant("Готово.", done: true)])
    }

    @Test func resumeLoadsHistoryAndOpenQuestions() {
        var t = ChatTranscript()
        t.load(snapshot: obj(#"""
        {"session_id":"s","running":false,"execution_generation":3,"last_sequence":40,
         "info":{"title":"Отчёт","model":"m"},
         "messages":[{"role":"user","text":"сделай"},{"role":"tool","name":"web","text":"ok"},{"role":"assistant","text":"готово"}],
         "open_requests":[{"id":"srq-7","method":"clarify","params":{"session_id":"s","questions":[{"qid":"q1","question":"Куда?","choices":["A","B"]}]}}]}
        """#))
        #expect(t.title == "Отчёт" && t.generation == 3 && t.lastSequence == 40)
        #expect(t.items.count == 3)
        #expect(t.pending.first?.questions.first?.choices == ["A", "B"])
    }
}
