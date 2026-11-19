import Foundation
import Testing
import Core

@MainActor
private func registryEntries() -> [AutomationEntry] {
    let agent = CoreAgent(loop: nil)
    return AutomationRegistry.all(agent: agent, quietHours: (startHour: 23, endHour: 7, nightLevel: 0.6))
}

@MainActor @Test func automationIdsAreUniqueAndNoFieldIsEmpty() {
    let entries = registryEntries()
    #expect(entries.count >= 12)
    #expect(Set(entries.map(\.id)).count == entries.count)
    for entry in entries {
        #expect(!entry.id.isEmpty)
        #expect(!entry.title.trimmingCharacters(in: .whitespaces).isEmpty, "\(entry.id) has no title")
        #expect(!entry.trigger.trimmingCharacters(in: .whitespaces).isEmpty, "\(entry.id) has no trigger")
        #expect(!entry.effect.trimmingCharacters(in: .whitespaces).isEmpty, "\(entry.id) has no effect")
        #expect(!entry.howToDisable.trimmingCharacters(in: .whitespaces).isEmpty, "\(entry.id) has no howToDisable")
    }
}

@MainActor @Test func entriesMentionTheRealModeWindowsAndQuietHours() {
    let agent = CoreAgent(loop: nil)
    let text = registryEntries().map { [$0.title, $0.trigger, $0.effect, $0.howToDisable].joined(separator: " ") }.joined(separator: "\n")
    // The windows come from the agent instance: 60 s Ready, 10 min Working, 45 s reply window.
    #expect(Int(agent.readyWindow) == 60 && text.contains("60 с"))
    #expect(Int(agent.workingWindow / 60) == 10 && text.contains("10 мин"))
    #expect(Int(CoreAgent.replyWindow) == 45 && text.contains("45 с"))
    // Quiet hours 23:00 to 07:00 at 60 % volume.
    #expect(text.contains("23:00–07:00"))
    #expect(text.contains("60 %"))
    // The silence option, the stop word and the owner gate are all listed.
    #expect(text.contains("[молчу]"))
    #expect(text.contains("стоп"))
    #expect(text.contains("requireOwnerPresent"))
}

@MainActor @Test func everyRequiredAutomationHasAnEntry() {
    let ids = Set(registryEntries().map(\.id))
    for required in ["mode.timers", "activation.name", "command.silent", "command.sleep", "command.stop", "gate.owner",
                     "quiet.hours", "reminders.ticker", "reply.window", "silence.option", "agent.steps", "mode.note"] {
        #expect(ids.contains(required), "missing \(required)")
    }
}
