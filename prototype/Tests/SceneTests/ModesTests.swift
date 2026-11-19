import Foundation
import Testing
import Core
import SignalBus

private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

/// First request: one tool call; second: an answer. Or a fixed answer when `reply` is set.
private struct ScriptedModel: ChatModel {
    var reply: String?
    let steps = Steps()
    func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn {
        var turn = ChatTurn()
        if let reply { turn.text = reply; onText(reply); return turn }
        if steps.next() == 1 {
            turn.toolCalls = [ToolCall(id: "c1", name: "list_dir", arguments: #"{"path":"."}"#)]
        } else {
            turn.text = "Готово."
            onText(turn.text)
        }
        return turn
    }
}

private func readyTurn(_ id: String, _ text: String) -> SignalMessage {
    SignalMessage(domain: .scene, source: "t", type: "scene.turn.ready",
                  payload: ["turn_id": id, "text": text, "addressed": "possible"])
}

private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<60 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

private final class Messages: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SignalMessage] = []
    var all: [SignalMessage] { lock.withLock { items } }
    func start(_ bus: SignalBus) async -> Task<Void, Never> {
        let stream = await bus.subscribe()
        return Task { for await message in stream { lock.withLock { items.append(message) } } }
    }
}

@MainActor @Test func theActivationPhraseIsHerNameAmongTheFirstOrLastThreeWords() {
    #expect(CoreAgent.isActivation("Привет, Вера"))
    #expect(CoreAgent.isActivation("Вера как дела"))
    #expect(CoreAgent.isActivation("посмотри файл, Вера"))
    #expect(CoreAgent.isActivation("Вера, прочитай файл notes.txt и скажи, какое слово во второй строке"))
    #expect(!CoreAgent.isActivation("а в середине длинной фразы про Веру Павловну она не включается совсем"))
    #expect(!CoreAgent.isActivation("ну и погода сегодня"))
}

@MainActor @Test func sleepCommandsAreShortImperativesAndTheSilenceMarkerIsExact() {
    #expect(CoreAgent.isSleepCommand("Вера, засыпай"))
    #expect(CoreAgent.isSleepCommand("иди спать"))
    #expect(CoreAgent.isSleepCommand("Вера, спать"))
    #expect(CoreAgent.isSleepCommand("Спать."))
    #expect(!CoreAgent.isSleepCommand("я хочу спать"))
    #expect(!CoreAgent.isSleepCommand("вчера я долго не мог уснуть и вообще спал плохо"))
    #expect(CoreAgent.isSilenceMarker("[молчу]"))
    #expect(CoreAgent.isSilenceMarker(" [Молчу]. "))
    #expect(!CoreAgent.isSilenceMarker("Я молчу, но отвечу"))
}

@MainActor @Test func readyRunsOutToSilentAfterAMinuteAndWorkingAfterTen() async {
    var now = Date(timeIntervalSince1970: 1_000_000)
    let agent = CoreAgent(loop: AgentLoop(model: ScriptedModel(reply: "ок"), tools: ToolRegistry([]), systemPrompt: "s"))
    agent.clock = { now }
    #expect(agent.readyWindow == 60)
    await agent.setMode(.ready, bus: nil, reason: "test")
    #expect(agent.mode == .ready)
    now = now.addingTimeInterval(59)
    await agent.expireIfNeeded(bus: nil)
    #expect(agent.mode == .ready)
    now = now.addingTimeInterval(2)
    await agent.expireIfNeeded(bus: nil)
    #expect(agent.mode == .silent)

    await agent.setMode(.working, bus: nil, reason: "test")
    #expect(agent.modeDeadline == now.addingTimeInterval(600))
    now = now.addingTimeInterval(599)
    await agent.expireIfNeeded(bus: nil)
    #expect(agent.mode == .working)
    now = now.addingTimeInterval(2)
    await agent.expireIfNeeded(bus: nil)
    #expect(agent.mode == .silent)
}

@MainActor @Test func aRequestThatCallsAToolMovesReadyToWorkingAndEveryReplyRestartsTheClock() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "vera-modes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var now = Date(timeIntervalSince1970: 2_000_000)
    let bus = SignalBus(); let messages = Messages()
    let capture = await messages.start(bus)
    defer { capture.cancel() }
    let agent = CoreAgent(loop: AgentLoop(model: ScriptedModel(), tools: WorkspaceTools(root: root).registry, systemPrompt: "s"))
    agent.includesSceneContext = false
    agent.setEnabled(true)
    agent.clock = { now }
    let consuming = Task { await agent.consume(bus) }
    defer { consuming.cancel() }
    try? await Task.sleep(for: .milliseconds(150))
    #expect(agent.mode == .ready)
    await bus.publish(readyTurn("turn/1", "что у меня в папке"))
    #expect(await waitUntil { agent.mode == .working })
    #expect(messages.all.contains { $0.type == "core.mode.changed" && $0.payload["mode"] == "working" && $0.payload["reason"] == "task" })
    #expect(await waitUntil { agent.tasks.first?.state == .done })
    // A reply five minutes later restarts the ten minutes.
    now = now.addingTimeInterval(300)
    await bus.publish(readyTurn("turn/2", "а ещё что-нибудь"))
    #expect(await waitUntil { agent.modeDeadline == now.addingTimeInterval(600) })
}

@MainActor @Test func sleepCancelsEverythingStopsTheMicrophoneAndTheMicrophoneWakesHer() async {
    let bus = SignalBus(); let messages = Messages()
    let capture = await messages.start(bus)
    defer { capture.cancel() }
    let agent = CoreAgent(loop: AgentLoop(model: ScriptedModel(reply: "ок"), tools: ToolRegistry([]), systemPrompt: "s"))
    agent.includesSceneContext = false
    agent.setEnabled(true)
    let consuming = Task { await agent.consume(bus) }
    defer { consuming.cancel() }
    try? await Task.sleep(for: .milliseconds(150))
    await bus.publish(readyTurn("turn/1", "Вера, засыпай"))
    #expect(await waitUntil { agent.mode == .sleep })
    #expect(await waitUntil { messages.all.contains { $0.type == "sensors.microphone.stop" } })
    #expect(messages.all.contains { $0.type == "output.speech.requested" && $0.payload["text"] == "Засыпаю" })
    // Nothing is heard while she sleeps.
    await bus.publish(readyTurn("turn/2", "Вера, ты тут?"))
    try? await Task.sleep(for: .milliseconds(300))
    #expect(agent.tasks.isEmpty)
    // The microphone coming on wakes her.
    await bus.publish(SignalMessage(source: "Sensors.Microphone", type: "audio.microphone.started"))
    #expect(await waitUntil { agent.mode == .ready })
    #expect(await waitUntil { messages.all.contains { $0.payload["text"] == "Просыпаюсь" } })
}

@MainActor @Test func theActivationPhraseAloneWakesHerAndSheSaysShesListening() async {
    let bus = SignalBus(); let messages = Messages()
    let capture = await messages.start(bus)
    defer { capture.cancel() }
    let agent = CoreAgent(loop: AgentLoop(model: ScriptedModel(reply: "ок"), tools: ToolRegistry([]), systemPrompt: "s"))
    agent.includesSceneContext = false
    agent.setEnabled(true)
    let consuming = Task { await agent.consume(bus) }
    defer { consuming.cancel() }
    try? await Task.sleep(for: .milliseconds(150))
    await agent.setMode(.silent, bus: bus, reason: "test")
    await bus.publish(readyTurn("turn/1", "Вера"))
    #expect(await waitUntil { agent.mode == .ready })
    #expect(await waitUntil { messages.all.contains { $0.payload["text"] == "Слушаю" } })
    // A greeting is greeted back; the name alone only gets "Слушаю".
    await agent.setMode(.silent, bus: bus, reason: "test")
    await bus.publish(readyTurn("turn/2", "Привет, Вера"))
    #expect(await waitUntil { messages.all.contains { $0.payload["text"] == "Привет, Алексей" } })
    #expect(agent.tasks.isEmpty)
}

@MainActor @Test func aReplyThatIsPlainlyNotForHerIsNotSpoken() async {
    let bus = SignalBus(); let messages = Messages()
    let capture = await messages.start(bus)
    defer { capture.cancel() }
    let agent = CoreAgent(loop: AgentLoop(model: ScriptedModel(reply: "[молчу]"), tools: ToolRegistry([]), systemPrompt: "s"))
    agent.includesSceneContext = false
    agent.setEnabled(true)
    let consuming = Task { await agent.consume(bus) }
    defer { consuming.cancel() }
    try? await Task.sleep(for: .milliseconds(150))
    await bus.publish(readyTurn("turn/1", "да я скоро буду, подъезжаю"))
    #expect(await waitUntil { agent.tasks.first?.state == .done })
    try? await Task.sleep(for: .milliseconds(200))
    #expect(!messages.all.contains { $0.type == "output.speech.requested" })
}

@MainActor @Test func goingSilentByTheTimerIsAnnouncedAloud() async {
    var now = Date(timeIntervalSince1970: 3_000_000)
    let bus = SignalBus(); let messages = Messages()
    let capture = await messages.start(bus)
    defer { capture.cancel() }
    let agent = CoreAgent(loop: AgentLoop(model: ScriptedModel(reply: "ок"), tools: ToolRegistry([]), systemPrompt: "s"))
    agent.clock = { now }
    await agent.setMode(.ready, bus: bus, reason: "test")
    now = now.addingTimeInterval(agent.readyWindow + 1)
    await agent.expireIfNeeded(bus: bus)
    #expect(agent.mode == .silent)
    #expect(await waitUntil { messages.all.contains { $0.type == "output.speech.requested" && $0.payload["text"] == "Режим тишины" } })
    // Going quiet is said at 78 % volume; other announcements are not turned down.
    #expect(messages.all.first { $0.payload["text"] == "Режим тишины" }?.payload["volume"] == "0.78")
}

/// Says "[молчу]" to everything until it is told that silence is not allowed.
private struct StubbornModel: ChatModel {
    func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn {
        var turn = ChatTurn()
        let forbidden = messages.last?.content?.contains("недопустим") == true
        turn.text = forbidden ? "Всё хорошо, спасибо." : "[молчу]"
        onText(turn.text)
        return turn
    }
}

@MainActor @Test func calledByNameSheAnswersEvenIfTheModelWantsToStaySilent() async {
    let bus = SignalBus(); let messages = Messages()
    let capture = await messages.start(bus)
    defer { capture.cancel() }
    let agent = CoreAgent(loop: AgentLoop(model: StubbornModel(), tools: ToolRegistry([]), systemPrompt: "s"))
    agent.includesSceneContext = false
    agent.setEnabled(true)
    let consuming = Task { await agent.consume(bus) }
    defer { consuming.cancel() }
    try? await Task.sleep(for: .milliseconds(150))
    await bus.publish(readyTurn("turn/1", "Какая сейчас погода, Вера?"))
    #expect(await waitUntil { agent.tasks.first?.state == .done })
    #expect(agent.tasks.first?.answer == "Всё хорошо, спасибо.")
    #expect(await waitUntil { messages.all.contains { $0.type == "output.speech.requested" && $0.payload["text"] == "Всё хорошо, спасибо." } })
}

/// Remembers every system message it was shown.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock(); private var items: [String] = []
    var all: String { lock.withLock { items.joined(separator: "\n") } }
    func add(_ messages: [ChatMessage]) { lock.withLock { items += messages.filter { $0.role == .system }.compactMap(\.content) } }
}
private struct Watching: ChatModel {
    let seen: Seen
    func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn {
        seen.add(messages); var turn = ChatTurn(); turn.text = "Ответ."; onText("Ответ."); return turn
    }
}

@MainActor @Test func theOptionToStayQuietIsOfferedOnlyWithARepliedWithoutHerName() async {
    let seen = Seen(); let bus = SignalBus()
    let agent = CoreAgent(loop: AgentLoop(model: Watching(seen: seen), tools: ToolRegistry([]), systemPrompt: VeraPrompt.system))
    agent.includesSceneContext = false
    agent.setEnabled(true)
    let consuming = Task { await agent.consume(bus) }
    defer { consuming.cancel() }
    try? await Task.sleep(for: .milliseconds(150))
    #expect(!VeraPrompt.system.contains("[молчу]"))                       // never in the general prompt
    await bus.publish(readyTurn("turn/1", "Вера, удали всё"))
    #expect(await waitUntil { agent.tasks.first?.state == .done })
    #expect(!seen.all.contains("[молчу]"))                                // not for a request that names her
    await bus.publish(readyTurn("turn/2", "а удали всё"))
    #expect(await waitUntil { agent.tasks.filter { $0.state == .done }.count == 2 })
    #expect(seen.all.contains("[молчу]"))                                 // offered with a reply without her name
}
