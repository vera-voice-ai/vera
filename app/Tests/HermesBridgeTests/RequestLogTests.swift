import Foundation
import Testing
@testable import HermesBridge

@Suite struct RequestLogTests {
    typealias E = PulseEvent

    @Test func overlappingTurnsKeepTheirOwnCallsAndOutcomes() {
        var log = RequestLog()
        for e in [
            E(ts: 1, kind: "session.open", session: "mac", platform: "desktop"),
            E(ts: 2, kind: "session.open", session: "tg", platform: "telegram"),
            E(ts: 10, kind: "llm.start", session: "mac", turn: "m1", callId: "a", model: "muse"),
            E(ts: 11, kind: "llm.start", session: "tg", turn: "t1", callId: "b", model: "muse"),
            E(ts: 12, kind: "tool.start", session: "mac", turn: "m1", callId: "c", name: "terminal"),
            E(ts: 13, kind: "llm.end", session: "tg", turn: "t1", callId: "b", status: "ok", tokensOut: 40),
            E(ts: 13.5, kind: "session.end", session: "tg", turn: "t1", status: "ok"),
            E(ts: 14, kind: "tool.end", session: "mac", turn: "m1", callId: "c", status: "ok"),
        ] { log.apply(e) }
        let r = log.requests
        #expect(r.map(\.id) == ["m1", "t1"])
        #expect(r[0].platform == "desktop" && r[0].running)          // the first one still runs…
        #expect(r[1].platform == "telegram" && r[1].status == "ok")   // …while the second already answered
        #expect(r[1].end == 13.5 && r[1].tokensOut == 40)
        #expect(r[0].steps.map(\.kind) == [.model, .tool] && r[0].steps[1].end == 14 && r[0].steps[0].end == nil)
        log.apply(E(ts: 20, kind: "llm.error", session: "mac", turn: "m1", callId: "a", status: "error"))
        log.apply(E(ts: 20.1, kind: "session.end", session: "mac", turn: "m1", status: "failed"))
        #expect(log.requests[0].status == "failed" && log.requests[0].steps[0].failed)
    }

    @Test func aTurnWithoutAnEndIsCutWhenItsSessionGoesOn() {
        var log = RequestLog()
        log.apply(E(ts: 10, kind: "llm.start", session: "s", turn: "t1", callId: "a"))
        log.apply(E(ts: 12, kind: "llm.end", session: "s", turn: "t1", callId: "a", status: "ok"))
        log.apply(E(ts: 11, kind: "llm.start", session: "other", turn: "o1", callId: "b"))
        log.apply(E(ts: 300, kind: "llm.start", session: "s", turn: "t2", callId: "c"))
        #expect(log.requests.first { $0.id == "t1" }?.status == "cut" && log.requests.first { $0.id == "t1" }?.end == 12)
        #expect(log.requests.first { $0.id == "o1" }?.running == true)   // another session's turn is not touched
        #expect(log.requests.first { $0.id == "t2" }?.running == true)
    }

    @Test func keepsTheLastTenAndIgnoresLinesWithoutATurn() {
        var log = RequestLog()
        log.apply(E(ts: 0, kind: "session.open", session: "s"))
        for i in 0..<14 {
            log.apply(E(ts: Double(i * 10), kind: "llm.start", session: "s", turn: "t\(i)", callId: "c\(i)"))
            log.apply(E(ts: Double(i * 10 + 2), kind: "session.end", session: "s", turn: "t\(i)", status: i == 5 ? "interrupted" : "ok"))
        }
        #expect(log.requests.count == RequestLog.keep)
        #expect(log.requests.first?.id == "t4" && log.requests.last?.id == "t13")
        #expect(log.requests.first { $0.id == "t5" }?.status == "interrupted")
        // a late end of a turn that already left the window does not come back
        log.apply(E(ts: 999, kind: "session.end", session: "s", turn: "t0", status: "ok"))
        #expect(!log.requests.contains { $0.id == "t0" })
    }
}
