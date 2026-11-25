import Testing
@testable import HermesBridge

@Suite struct TurnTraceTests {
    func ev(_ ts: Double, _ kind: String, _ call: String, name: String? = nil, session: String = "main") -> PulseEvent {
        PulseEvent(ts: ts, kind: kind, session: session, callId: call, name: name, status: kind.hasSuffix("end") ? "ok" : nil)
    }

    @Test func spokenTurnLaysOutEveryStep() {
        var r = TurnRecorder(); r.session = "main"
        r.phrase(start: 100, end: 102.1, decodeMs: 60)
        r.submitted(at: 102.2, ack: 102.24)
        r.pulse(ev(102.3, "llm.start", "a"))
        r.messageStarted(at: 103.5)
        r.pulse(ev(103.9, "llm.end", "a"))
        r.pulse(ev(103.95, "tool.start", "t", name: "read_file"))
        r.pulse(ev(104.0, "tool.end", "t", name: "read_file"))
        r.voiceStarted(at: 104.4)
        r.messageCompleted(at: 105.1, voicePending: true)
        #expect(r.current != nil)                      // still speaking
        r.voiceIdle(at: 107.4)
        #expect(r.current == nil)
        let t = r.recent.last!
        #expect(t.spoken && t.done)
        #expect(t.steps.map(\.lane) == [.phrase, .phrase, .gateway, .model, .text, .tool, .voice])
        #expect(abs(t.total - 7.4) < 0.001)
        #expect(abs((t.toFirstWord ?? 0) - (104.4 - 102.16)) < 0.001)
        #expect(t.steps.first { $0.lane == .tool }?.name == "read_file")
    }

    @Test func wordsInTheMiddleOfTheTurnAreVoiceToo() {
        var r = TurnRecorder(); r.session = "main"
        r.phrase(start: 100, end: 101, decodeMs: 50)
        r.submitted(at: 101.1, ack: 101.2)
        r.voiceStarted(at: 103)          // «Проверяю погоду…» while the tools run
        r.voiceStarted(at: 103.5)        // next sentence of the same stretch
        r.voiceIdle(at: 104)
        #expect(r.current != nil)        // not answered yet: the turn goes on
        r.messageCompleted(at: 110, voicePending: true)
        r.voiceStarted(at: 110.5)
        r.voiceIdle(at: 113)
        let voice = r.recent.last!.steps.filter { $0.lane == .voice }
        #expect(voice.count == 2)
        #expect(voice.map(\.start) == [103, 110.5] && voice.map(\.end) == [104, 113])
    }

    @Test func otherSessionsAreNotThisTurn() {
        var r = TurnRecorder(); r.session = "main"
        r.submitted(at: 10, ack: 10.1)
        r.pulse(ev(10.2, "llm.start", "x", session: "telegram"))
        #expect(r.current?.steps.count == 1)
    }

    @Test func lateJournalLinesFindTheirTurn() {
        var r = TurnRecorder(); r.session = "main"
        r.submitted(at: 10, ack: 10.1)
        r.messageCompleted(at: 12, voicePending: false)
        r.pulse(ev(10.3, "llm.start", "a"))
        r.pulse(ev(11.8, "llm.end", "a"))
        let t = r.recent.last!
        #expect(t.steps.contains { $0.lane == .model && $0.end == 11.8 })
    }

    @Test func typedMessageAfterASpokenOneIsANewTurn() {
        var r = TurnRecorder(); r.session = "main"
        r.phrase(start: 0, end: 1, decodeMs: 50)
        r.submitted(at: 1.1, ack: 1.2)
        r.submitted(at: 5, ack: 5.1)
        #expect(r.recent.count == 1)
        #expect(r.current?.spoken == false)
    }
}

@Suite struct PulseStateTests {
    @Test func oneBatchFeedsJournalSummaryAndTurns() {
        var p = PulseState()
        p.turns.session = "main"
        p.turns.submitted(at: 10, ack: 10.1)
        p.take([PulseEvent(ts: 10.2, kind: "llm.start", session: "main", callId: "a"),
                PulseEvent(ts: 11.5, kind: "llm.end", session: "main", callId: "a", status: "ok", durationMs: 1300)])
        #expect(p.events.count == 2)
        #expect(p.stats.llmCalls == 1)
        #expect(p.turns.current?.steps.contains { $0.lane == .model && $0.end == 11.5 } == true)
    }
}
