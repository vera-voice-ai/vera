import Foundation
import Testing
import Core
import Response
import SignalBus

// The four switches of the Core panel's "Автоматика" section: each one changes behaviour when it is off and leaves it
// alone when it is on. Time runs on a fake clock, as in ScenarioTests.

private let switchIDs = [AutomationSwitches.quietHours, AutomationSwitches.modeTimers,
                         AutomationSwitches.silenceOption, AutomationSwitches.replyWindow]

private struct Answer: ChatModel {
    var text: String
    func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn {
        var turn = ChatTurn(); turn.text = text; onText(text); return turn
    }
}

/// Remembers the text of every message it was shown, system ones included.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock(); private var items: [String] = []
    var all: String { lock.withLock { items.joined(separator: "\n") } }
    func add(_ messages: [ChatMessage]) { lock.withLock { items += messages.compactMap(\.content) } }
}

private struct Watching: ChatModel {
    let seen: Seen
    func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn {
        seen.add(messages); var turn = ChatTurn(); turn.text = "Ответ."; onText("Ответ."); return turn
    }
}

private final class Tape: @unchecked Sendable {
    private let lock = NSLock(); private var items: [SignalMessage] = []
    var all: [SignalMessage] { lock.withLock { items } }
    func spoke(_ text: String) -> Bool { all.contains { $0.type == "output.speech.requested" && $0.payload["text"] == text } }
    func start(_ bus: SignalBus) async -> Task<Void, Never> {
        let stream = await bus.subscribe()
        return Task { for await m in stream { lock.withLock { items.append(m) } } }
    }
}

@MainActor private final class Harness {
    let bus = SignalBus(); let tape = Tape(); let agent: CoreAgent
    var now = Date(timeIntervalSince1970: 7_000_000)
    private var tasks: [Task<Void, Never>] = []
    private var turn = 0

    init(model: any ChatModel, switches: AutomationSwitches = AutomationSwitches()) async {
        agent = CoreAgent(loop: AgentLoop(model: model, tools: ToolRegistry([]), systemPrompt: "s"))
        agent.switches = switches
        agent.includesSceneContext = false
        agent.setEnabled(true)
        agent.clock = { [unowned self] in self.now }
        tasks.append(await tape.start(bus))
        tasks.append(Task { [agent, bus] in await agent.consume(bus) })
        try? await Task.sleep(for: .milliseconds(150))
        await agent.setMode(.ready, bus: bus, reason: "test")
    }
    func say(_ text: String, addressed: String = "possible") async {
        turn += 1
        await bus.publish(SignalMessage(domain: .scene, source: "t", type: "scene.turn.ready",
                                        payload: ["turn_id": "turn/\(turn)", "text": text, "addressed": addressed]))
    }
    /// A reply the scene filed as "not addressed" (a one-word voice is not recognisable).
    func heard(_ id: String, _ text: String) async {
        await bus.publish(SignalMessage(domain: .scene, source: "t", type: "scene.turn.heard",
                                        payload: ["turn_id": id, "text": text, "reason": "not_addressed", "speaker": "Неизвестный голос"]))
    }
    func advance(_ seconds: TimeInterval) async { now = now.addingTimeInterval(seconds); await agent.expireIfNeeded(bus: bus) }
    func until(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<80 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
        return condition()
    }
    func finish() { tasks.forEach { $0.cancel() } }
}

private func offSwitches(_ ids: String...) -> AutomationSwitches {
    let switches = AutomationSwitches()
    for id in ids { switches.set(id, false) }
    return switches
}

/// "quiet.hours:off" style text for comparing parser results in one line.
@MainActor private func parsed(_ text: String) -> String {
    guard let change = CoreAgent.switchCommand(text) else { return "nil" }
    return "\(change.id):\(change.on ? "on" : "off")"
}

// MARK: - Store

@MainActor @Test func everySwitchIsOnByDefaultAndAnUnknownIdIsOnToo() {
    let switches = AutomationSwitches()
    for id in switchIDs + ["something.else"] { #expect(switches.isOn(id)) }
    #expect(CoreAgent(loop: nil).switches.isOn(AutomationSwitches.modeTimers))
}

@MainActor @Test func aSwitchIsStoredUnderItsKeyInTheDefaultsAndSurvivesARestart() throws {
    let suite = "vera.switches.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let switches = AutomationSwitches(defaults: defaults)
    switches.set(AutomationSwitches.quietHours, false)
    #expect(!switches.isOn(AutomationSwitches.quietHours))
    #expect(defaults.object(forKey: "VeraAutomation.quiet.hours") as? Bool == false)
    // A new instance on the same defaults (the next launch) reads the same state; the others stay on.
    let again = AutomationSwitches(defaults: defaults)
    #expect(!again.isOn(AutomationSwitches.quietHours))
    #expect(again.isOn(AutomationSwitches.modeTimers))
    again.set(AutomationSwitches.quietHours, true)
    #expect(AutomationSwitches(defaults: defaults).isOn(AutomationSwitches.quietHours))
}

@MainActor @Test func switchesCanBeFlippedFromManyTasksAtOnce() async {
    let switches = AutomationSwitches()
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<200 {
            group.addTask { switches.set(AutomationSwitches.replyWindow, index % 2 == 0) }
            group.addTask { _ = switches.isOn(AutomationSwitches.replyWindow) }
        }
    }
    switches.set(AutomationSwitches.replyWindow, false)
    #expect(!switches.isOn(AutomationSwitches.replyWindow))
}

// MARK: - Voice phrases

@MainActor @Test func theSwitchPhrasesMapToTheirIdAndState() {
    #expect(parsed("выключи тихие часы") == "quiet.hours:off")
    #expect(parsed("Вера, включи тихие часы") == "quiet.hours:on")
    #expect(parsed("отключи тихие часы") == "quiet.hours:off")
    #expect(parsed("выключи таймеры режимов") == "mode.timers:off")
    #expect(parsed("включи таймеры режимов, пожалуйста") == "mode.timers:on")
    #expect(parsed("Вера, выключи вариант молчу") == "silence.option:off")
    #expect(parsed("включи вариант молчу") == "silence.option:on")
    #expect(parsed("выключи окно ответа") == "reply.window:off")
    #expect(parsed("Вера, включи окно ответа") == "reply.window:on")
}

@MainActor @Test func otherSentencesAreNotSwitchCommands() {
    #expect(parsed("включи голос") == "nil")                       // the old voice command, handled by silenceCommand
    #expect(parsed("говори") == "nil")
    #expect(parsed("выключи режим тишины") == "nil")
    #expect(parsed("выключи свет в комнате") == "nil")
    #expect(parsed("тихие часы") == "nil")                         // no verb
    #expect(parsed("я вчера выключил тихие часы") == "nil")        // the verb is not first
    #expect(parsed("выключи тихие часы и таймеры режимов") == "nil")
    #expect(parsed("") == "nil")
}

@MainActor @Test func theAnnouncementNamesTheSwitchAndItsNewState() {
    #expect(CoreAgent.switchAnnouncement(id: AutomationSwitches.quietHours, on: false) == "Тихие часы выключены")
    #expect(CoreAgent.switchAnnouncement(id: AutomationSwitches.quietHours, on: true) == "Тихие часы включены")
    #expect(CoreAgent.switchAnnouncement(id: AutomationSwitches.modeTimers, on: false) == "Таймеры режимов выключены")
    #expect(CoreAgent.switchAnnouncement(id: AutomationSwitches.silenceOption, on: true) == "Вариант молчу включён")
    #expect(CoreAgent.switchAnnouncement(id: AutomationSwitches.replyWindow, on: false) == "Окно ответа выключено")
}

@MainActor @Test func theRegistryMarksExactlyTheFourSwitchesAndTheirVoicePhrases() {
    let entries = AutomationRegistry.all(agent: CoreAgent(loop: nil), quietHours: (startHour: 23, endHour: 7, nightLevel: 0.6))
    let switchable = entries.filter { $0.switchID != nil }
    #expect(Set(switchable.compactMap(\.switchID)) == Set(switchIDs))
    for entry in switchable {
        #expect(!entry.howToDisable.contains("пока только в коде"), "\(entry.id) still says code only")
        #expect(entry.howToDisable.contains("выключи"))
    }
    #expect(entries.first { $0.id == "command.stop" }?.switchID == nil)
}

// MARK: - Behaviour

@MainActor @Test func modeTimersOffKeepReadyAndWorkingUntilACommandChangesThem() async {
    let agent = CoreAgent(loop: nil)
    var now = Date(timeIntervalSince1970: 8_000_000)
    agent.clock = { now }
    await agent.setMode(.ready, bus: nil, reason: "test")
    now = now.addingTimeInterval(61)
    await agent.expireIfNeeded(bus: nil)
    #expect(agent.mode == .silent)                                  // on: the timer works

    let off = CoreAgent(loop: nil)
    off.switches = offSwitches(AutomationSwitches.modeTimers)
    off.clock = { now }
    await off.setMode(.ready, bus: nil, reason: "test")
    now = now.addingTimeInterval(61)
    await off.expireIfNeeded(bus: nil)
    #expect(off.mode == .ready)                                     // off: she stays
    await off.setMode(.working, bus: nil, reason: "test")
    now = now.addingTimeInterval(7_200)
    await off.expireIfNeeded(bus: nil)
    #expect(off.mode == .working)
    await off.setMode(.silent, bus: nil, reason: "command")         // a command still works
    #expect(off.mode == .silent)
}

@MainActor @Test func switchingModeTimersBackOnGivesAFullWindowFromThatMoment() async {
    let agent = CoreAgent(loop: nil)
    agent.switches = offSwitches(AutomationSwitches.modeTimers)
    var now = Date(timeIntervalSince1970: 8_100_000)
    agent.clock = { now }
    await agent.setMode(.ready, bus: nil, reason: "test")
    // The ticker runs once a second while the timers are off.
    for _ in 0..<300 { now = now.addingTimeInterval(1); await agent.expireIfNeeded(bus: nil) }
    #expect(agent.mode == .ready)
    agent.switches.set(AutomationSwitches.modeTimers, true)
    now = now.addingTimeInterval(1)
    await agent.expireIfNeeded(bus: nil)
    #expect(agent.mode == .ready)
    // The window runs from the last tick (at most a second before switching on): 60 s in all.
    now = now.addingTimeInterval(58)
    await agent.expireIfNeeded(bus: nil)
    #expect(agent.mode == .ready)
    now = now.addingTimeInterval(2)
    await agent.expireIfNeeded(bus: nil)
    #expect(agent.mode == .silent)
}

@MainActor @Test func theModeNoteDoesNotPromiseATimerThatIsOff() {
    let on = CoreAgent.modeNote(.ready, readyWindow: 60, workingWindow: 600)
    let off = CoreAgent.modeNote(.ready, readyWindow: 60, workingWindow: 600, timers: false)
    #expect(on?.contains("уходишь в «Тишину»") == true)
    #expect(off?.contains("таймер выключен") == true)
    #expect(CoreAgent.modeNote(.working, readyWindow: 60, workingWindow: 600, timers: false)?.contains("таймер выключен") == true)
}

@MainActor @Test func theSilenceOptionIsOfferedOnlyWhileItsSwitchIsOn() async {
    let seenOn = Seen(); let seenOff = Seen()
    let on = await Harness(model: Watching(seen: seenOn))
    defer { on.finish() }
    await on.say("а удали всё")
    #expect(await on.until { on.agent.tasks.first?.state == .done })
    #expect(seenOn.all.contains("[молчу]"))                         // on: offered to the model

    let off = await Harness(model: Watching(seen: seenOff), switches: offSwitches(AutomationSwitches.silenceOption))
    defer { off.finish() }
    await off.say("а удали всё")
    #expect(await off.until { off.agent.tasks.first?.state == .done })
    #expect(!seenOff.all.contains("[молчу]"))                       // off: not offered, the reply is answered as usual
}

@MainActor @Test func theReplyWindowSwitchDecidesWhetherAShortReplyIsTheAnswer() async {
    let on = await Harness(model: Answer(text: "Хочешь, чтобы я запомнила это?"))
    defer { on.finish() }
    await on.say("Вера, расскажи про память", addressed: "likely")
    #expect(await on.until { on.agent.tasks.first?.state == .done })
    await on.heard("turn/h1", "Да")
    #expect(await on.until { on.agent.tasks.count == 2 })           // on: the "Да" is the answer

    let off = await Harness(model: Answer(text: "Хочешь, чтобы я запомнила это?"), switches: offSwitches(AutomationSwitches.replyWindow))
    defer { off.finish() }
    await off.say("Вера, расскажи про память", addressed: "likely")
    #expect(await off.until { off.agent.tasks.first?.state == .done })
    await off.heard("turn/h1", "Да")
    try? await Task.sleep(for: .milliseconds(300))
    #expect(off.agent.tasks.count == 1)                              // off: ignored like other unaddressed speech
}

@MainActor @Test func theQuietHoursSwitchDecidesWhetherTheNightVolumeApplies() async {
    final class Levels: AudioPlaying, @unchecked Sendable {
        private let lock = NSLock(); private var items: [Float] = []
        var all: [Float] { lock.withLock { items } }
        func play(wav: Data) async throws {}
        func play(wav: Data, rate: Float, volume: Float) async throws { lock.withLock { items.append(volume) } }
    }
    struct Silent: Synthesizer {
        func synthesize(text: String) async throws -> Data { Data("wav:\(text)".utf8) }
    }
    let levels = Levels()
    let speaker = ResponseSpeaker(synthesizer: Silent(), player: levels)
    let switches = AutomationSwitches()
    speaker.quietHoursOn = { switches.isOn(AutomationSwitches.quietHours) }
    speaker.quietHours.enabled = true
    func at(_ hour: Int) -> Date { Calendar.current.date(bySettingHour: hour, minute: 30, second: 0, of: Date())! }
    speaker.clock = { at(2) }

    await speaker.speak("ночью", volume: 0.5, bus: nil)              // on: 0.5 x 0.6 = 0.3
    switches.set(AutomationSwitches.quietHours, false)
    await speaker.speak("ночью без тихих часов", volume: 0.5, bus: nil)   // off: the requested 0.5
    #expect(levels.all.count == 2)
    #expect(abs(levels.all[0] - 0.3) < 0.001)
    #expect(abs(levels.all[1] - 0.5) < 0.001)
}

@MainActor @Test func theVoiceCommandsSwitchEachAutomationAndSayIt() async {
    let w = await Harness(model: Answer(text: "Ответ."))
    defer { w.finish() }
    let steps: [(phrase: String, id: String, on: Bool, said: String)] = [
        ("Вера, выключи тихие часы", AutomationSwitches.quietHours, false, "Тихие часы выключены"),
        ("Вера, включи тихие часы", AutomationSwitches.quietHours, true, "Тихие часы включены"),
        ("Вера, выключи таймеры режимов", AutomationSwitches.modeTimers, false, "Таймеры режимов выключены"),
        ("Вера, включи таймеры режимов", AutomationSwitches.modeTimers, true, "Таймеры режимов включены"),
        ("Вера, выключи вариант молчу", AutomationSwitches.silenceOption, false, "Вариант молчу выключен"),
        ("Вера, включи вариант молчу", AutomationSwitches.silenceOption, true, "Вариант молчу включён"),
        ("Вера, выключи окно ответа", AutomationSwitches.replyWindow, false, "Окно ответа выключено"),
        ("Вера, включи окно ответа", AutomationSwitches.replyWindow, true, "Окно ответа включено"),
    ]
    for step in steps {
        await w.say(step.phrase, addressed: "likely")
        #expect(await w.until { w.agent.switches.isOn(step.id) == step.on && w.tape.spoke(step.said) }, "\(step.phrase)")
    }
    // A switch command is not a task.
    #expect(w.agent.tasks.isEmpty)
}

@MainActor @Test func theVoiceSwitchOfModeTimersChangesWhatHappensAfterAMinute() async {
    let w = await Harness(model: Answer(text: "Ответ."))
    defer { w.finish() }
    await w.say("Вера, выключи таймеры режимов", addressed: "likely")
    #expect(await w.until { w.tape.spoke("Таймеры режимов выключены") })
    await w.advance(61)
    #expect(w.agent.mode == .ready)
    await w.say("Вера, включи таймеры режимов", addressed: "likely")
    #expect(await w.until { w.tape.spoke("Таймеры режимов включены") })
    await w.advance(61)
    #expect(w.agent.mode == .silent)
}
