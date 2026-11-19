import Foundation
import Testing
import Core
import SignalBus

// The manual voice checklist ("Проверка режимов Веры") as tests, one per scenario number. They feed the same events
// the scene would send and move a fake clock, so the timers of Ready and Working run in milliseconds. What needs a
// real microphone, speakers or a video in the background stays on the checklist (s10, s12, s13, s22 on hardware, s23, s27).

private struct Reply: ChatModel {
    var text = "Ответ."
    var tool: String? = nil
    var delay = 0
    let steps = StepCounter()
    func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn {
        if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
        var turn = ChatTurn()
        if let tool, steps.next() == 1 {
            turn.toolCalls = [ToolCall(id: "c1", name: tool, arguments: #"{"path":"."}"#)]
            return turn
        }
        turn.text = text; onText(text); return turn
    }
}

private final class StepCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
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

@MainActor private final class World {
    let bus = SignalBus(); let tape = Tape(); let agent: CoreAgent
    var now = Date(timeIntervalSince1970: 5_000_000)
    private var tasks: [Task<Void, Never>] = []
    private var turn = 0

    init(model: Reply = Reply(), root: URL? = nil) async {
        let registry = root.map { WorkspaceTools(root: $0).registry } ?? ToolRegistry([])
        agent = CoreAgent(loop: AgentLoop(model: model, tools: registry, systemPrompt: "s"))
        agent.includesSceneContext = false
        agent.setEnabled(true)
        agent.clock = { [unowned self] in self.now }
        tasks.append(await tape.start(bus))
        tasks.append(Task { [agent, bus] in await agent.consume(bus) })
        try? await Task.sleep(for: .milliseconds(150))
        await agent.setMode(.ready, bus: bus, reason: "test")   // same as the start of the app, with the fake clock
    }
    func say(_ text: String, addressed: String = "possible") async {
        turn += 1
        await bus.publish(SignalMessage(domain: .scene, source: "t", type: "scene.turn.ready",
                                        payload: ["turn_id": "turn/\(turn)", "text": text, "addressed": addressed]))
    }
    func advance(_ seconds: TimeInterval) async { now = now.addingTimeInterval(seconds); await agent.expireIfNeeded(bus: bus) }
    func until(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<80 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
        return condition()
    }
    func finish() { tasks.forEach { $0.cancel() } }
}

@MainActor @Test func s01_startsReadyAndGoesQuietAfterAMinuteSayingSo() async {
    let w = await World(); defer { w.finish() }
    #expect(w.agent.mode == .ready)
    #expect(w.agent.modeDeadline == w.now.addingTimeInterval(60))
    await w.advance(61)
    #expect(w.agent.mode == .silent)
    #expect(await w.until { w.tape.spoke("Режим тишины") })
}

@MainActor @Test func s02_s03_s04_theNameWakesHerFromSilence() async {
    let w = await World(); defer { w.finish() }
    await w.agent.setMode(.silent, bus: w.bus, reason: "test")
    await w.say("Вера", addressed: "likely")
    #expect(await w.until { w.agent.mode == .ready && w.tape.spoke("Слушаю") })
    await w.agent.setMode(.silent, bus: w.bus, reason: "test")
    await w.say("Привет, Вера", addressed: "likely")
    #expect(await w.until { w.tape.spoke("Привет, Алексей") })
    await w.agent.setMode(.silent, bus: w.bus, reason: "test")
    await w.say("Вера, как дела?", addressed: "likely")
    #expect(await w.until { w.agent.mode == .ready && w.tape.spoke("Ответ.") })
    await w.agent.setMode(.silent, bus: w.bus, reason: "test")
    await w.say("Какая сейчас погода, Вера?", addressed: "likely")
    #expect(await w.until { w.agent.tasks.filter { $0.state == .done }.count == 2 })   // the name and the greeting alone make no task
}

@MainActor @Test func s05_s17_inSilenceANameInTheMiddleOrNoNameStartsNothing() async {
    let w = await World(); defer { w.finish() }
    await w.agent.setMode(.silent, bus: w.bus, reason: "test")
    await w.say("Я вчера рассказывал Вере Павловне про проект, и она сказала, что подумает")
    await w.say("ну и погода сегодня")
    try? await Task.sleep(for: .milliseconds(400))
    #expect(w.agent.tasks.isEmpty)
    #expect(w.agent.mode == .silent)
}

@MainActor @Test func s06_s07_s11_inReadyNoNameIsNeededAndEveryReplyRestartsTheClock() async {
    let w = await World(); defer { w.finish() }
    for _ in 0..<4 {
        await w.advance(15)
        await w.say("Как твои дела?")
        #expect(await w.until { w.agent.modeDeadline == w.now.addingTimeInterval(60) })
    }
    #expect(w.agent.mode == .ready)
    #expect(await w.until { w.agent.tasks.filter { $0.state == .done }.count == 4 })
    await w.advance(61)
    #expect(w.agent.mode == .silent)
}

@MainActor @Test func s08_s09_aToolRequestMakesItWorkingForTenMinutes() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "vera-s08-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let w = await World(model: Reply(tool: "list_dir"), root: root); defer { w.finish() }
    await w.say("Вера, посмотри, какие файлы в рабочей папке", addressed: "likely")
    #expect(await w.until { w.agent.mode == .working })
    #expect(await w.until { w.agent.tasks.first?.state == .done })
    await w.advance(120)
    await w.say("А прочитай notes.txt")
    #expect(await w.until { w.agent.modeDeadline == w.now.addingTimeInterval(600) })
    // The modes do not run out while a task is still running: wait for the second one to finish before the clock jumps.
    #expect(await w.until { w.agent.tasks.allSatisfy { $0.state == .done } })
    await w.advance(601)
    #expect(w.agent.mode == .silent)
}

@MainActor @Test func s15_s16_theSilenceCommandSaysSoAndARunningTaskFinishesSilently() async {
    let w = await World(model: Reply(text: "Готово, но вслух нет.", delay: 400)); defer { w.finish() }
    await w.say("Вера, сделай что-нибудь", addressed: "likely")
    #expect(await w.until { w.agent.tasks.first?.state == .running })
    await w.say("Вера, режим тишины", addressed: "likely")
    #expect(await w.until { w.agent.mode == .silent && w.tape.spoke("Режим тишины") })
    #expect(await w.until { w.agent.tasks.first?.state == .done })
    // The task is marked done a moment before the speaker loop reports the suppressed sentence: wait for it.
    #expect(await w.until { w.tape.all.contains { $0.type == "core.speech.suppressed" } })
    #expect(!w.tape.spoke("Готово, но вслух нет."))
}

@MainActor @Test func s18_theOldVoiceCommandLeavesSilence() async {
    let w = await World(); defer { w.finish() }
    await w.agent.setMode(.silent, bus: w.bus, reason: "test")
    await w.say("Вера, говори", addressed: "likely")
    #expect(await w.until { w.agent.mode == .ready && w.tape.spoke("Голос включён") })
}

@MainActor @Test func s19_s20_s21_s22_s23_sleepStopsTheMicrophoneAndOnlyTheMicrophoneWakesHer() async {
    let w = await World(); defer { w.finish() }
    await w.say("Я хочу спать")
    #expect(await w.until { w.agent.tasks.first?.state == .done })
    #expect(w.agent.mode != .sleep)
    for phrase in ["Вера, спать", "Вера, засыпай", "Иди спать"] {
        await w.say(phrase, addressed: "likely")
        #expect(await w.until { w.agent.mode == .sleep })
        #expect(w.tape.all.contains { $0.type == "sensors.microphone.stop" })
        #expect(w.tape.spoke("Засыпаю"))
        // Asleep she hears nothing, not even her name.
        let before = w.agent.tasks.count
        await w.say("Вера, ты тут?", addressed: "likely")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(w.agent.tasks.count == before)
        await w.bus.publish(SignalMessage(source: "Sensors.Microphone", type: "audio.microphone.started"))
        #expect(await w.until { w.agent.mode == .ready })
    }
    #expect(w.tape.spoke("Просыпаюсь"))
}

@MainActor @Test func s24_stopCancelsTheRunningTaskAndTheSpeech() async {
    let w = await World(model: Reply(text: "Очень длинный ответ.", delay: 600)); defer { w.finish() }
    await w.say("Вера, расскажи длинную историю", addressed: "likely")
    #expect(await w.until { w.agent.tasks.first?.state == .running })
    await w.say("Вера, стоп", addressed: "likely")
    #expect(await w.until { w.agent.tasks.first?.state == .cancelled })
    #expect(w.tape.all.contains { $0.type == "output.speech.stop" })
}

@MainActor @Test func s25_aFourthRequestWaitsInTheQueueAndEveryRunHasAStatus() async {
    let w = await World(model: Reply(delay: 300)); defer { w.finish() }
    for n in 1...4 { await w.say("Вера, задача \(n)", addressed: "likely") }
    #expect(await w.until { w.agent.tasks.contains { $0.state == .queued } })
    #expect(await w.until { w.agent.tasks.filter { $0.state == .done }.count == 4 })
}

@MainActor @Test func s37_aShortReplyToHerQuestionIsTakenAsTheAnswerEvenFromAnUnknownVoice() async {
    let w = await World(model: Reply(text: "Хочешь, чтобы я запомнила это?")); defer { w.finish() }
    await w.say("Вера, расскажи про память", addressed: "likely")
    #expect(await w.until { w.agent.tasks.first?.state == .done })
    func heard(_ id: String, _ text: String) async {
        await w.bus.publish(SignalMessage(domain: .scene, source: "t", type: "scene.turn.heard",
                                          payload: ["turn_id": id, "text": text, "reason": "not_addressed", "speaker": "Неизвестный голос"]))
    }
    await heard("turn/h1", "Да")
    #expect(await w.until { w.agent.tasks.count == 2 })
    // A long remark is not an answer, and neither is a reply after the window.
    await w.say("Вера, ещё вопрос", addressed: "likely")
    #expect(await w.until { w.agent.tasks.filter { $0.state == .done }.count == 3 })
    await heard("turn/h2", "это совсем другой длинный разговор про что-то своё")
    try? await Task.sleep(for: .milliseconds(200))
    #expect(w.agent.tasks.count == 3)
    await w.advance(CoreAgent.replyWindow + 1)
    await heard("turn/h3", "Да")
    try? await Task.sleep(for: .milliseconds(200))
    #expect(w.agent.tasks.count == 3)
}
