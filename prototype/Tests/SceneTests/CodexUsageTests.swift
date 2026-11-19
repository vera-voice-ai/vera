import Foundation
import Testing
@testable import Core

private let binary = URL(filePath: "/nonexistent/codex")

private let planLine = #"{"jsonrpc":"2.0","id":1,"result":{"planType":"plus","rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":1700000000},"secondary":{"usedPercent":29,"windowDurationMins":10080,"resetsAt":1700600000}}}}"#

private func usage(lines: @escaping @Sendable () -> [String]) -> CodexUsage {
    CodexUsage(binary: { binary }, run: { _, _, _ in lines() })
}

@Suite struct CodexUsageTests {
    @Test func parsesTheTwoWindowsAndThePlan() async {
        let state = await usage(lines: { [planLine] }).refresh()
        guard case let .limits(limits) = state else { Issue.record("expected limits, got \(state)"); return }
        #expect(limits.display == "5%/29%")
        #expect(limits.primary.windowMinutes == 300)
        #expect(limits.secondary.windowMinutes == 10080)
        #expect(limits.primary.resetsAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(limits.planType == "plus")
    }

    @Test func sendsHandshakeAndLimitsRequest() async {
        let sent = CodexUsage(binary: { binary }, run: { _, input, _ in
            #expect(input.count == 3)
            #expect(input.first?.contains(#""method":"initialize""#) == true)
            #expect(input.last == #"{"jsonrpc":"2.0","id":1,"method":"account/rateLimits/read","params":{}}"#)
            return [planLine]
        })
        #expect(await sent.refresh() != .unknown)
    }

    @Test func errorResponseIsShortAndHasNoDetails() async {
        let error = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"/Users/alex/secret token abc"}}"#
        let state = await usage(lines: { [error] }).refresh()
        #expect(state == .failed("Codex ответил ошибкой"))
    }

    @Test func missingPrimaryFailsWithoutLimits() async {
        let line = #"{"jsonrpc":"2.0","id":1,"result":{"rateLimits":{"secondary":{"usedPercent":29,"windowDurationMins":10080,"resetsAt":1}}}}"#
        #expect(await usage(lines: { [line] }).refresh() == .failed("Codex не вернул лимиты"))
    }

    @Test func timeoutIsReportedAsTimeout() async {
        let slow = CodexUsage(binary: { binary }, run: { _, _, _ in throw CodexUsage.RunError.timedOut })
        #expect(await slow.refresh() == .failed("Codex не ответил за 20 секунд"))
    }

    @Test func launchFailureAndMissingBinaryAreShort() async {
        let broken = CodexUsage(binary: { binary }, run: { _, _, _ in throw CodexUsage.RunError.cannotStart })
        #expect(await broken.refresh() == .failed("не удалось запустить Codex"))
        let missing = CodexUsage(binary: { nil }, run: { _, _, _ in [planLine] })
        #expect(await missing.refresh() == .failed("Codex не найден"))
    }

    @Test func garbageLinesAndOtherIdsAreIgnored() async {
        let lines = ["not json at all", "{truncated", #"{"jsonrpc":"2.0","id":0,"result":{}}"#, "", planLine]
        let state = await usage(lines: { lines }).refresh()
        guard case .limits = state else { Issue.record("expected limits, got \(state)"); return }
    }

    @Test func notificationsBeforeTheAnswerAreSkipped() async {
        let lines = [
            #"{"jsonrpc":"2.0","method":"account/rateLimits/updated","params":{"usedPercent":7}}"#,
            #"{"jsonrpc":"2.0","method":"thread/started","params":{}}"#,
            planLine,
        ]
        let state = await usage(lines: { lines }).refresh()
        #expect(state.limitsDisplay == "5%/29%")
    }

    @Test func noAnswerLineFailsWithoutTheRawOutput() async {
        let state = await usage(lines: { ["Error: /Users/alex/.codex/auth.json unreadable"] }).refresh()
        #expect(state == .failed("Codex не ответил на запрос лимитов"))
    }
}

private extension CodexUsage.State {
    var limitsDisplay: String? {
        if case let .limits(limits) = self { return limits.display }
        return nil
    }
}
