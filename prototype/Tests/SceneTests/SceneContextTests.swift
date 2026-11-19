import Foundation
import Testing
import Core
import Scene
import SignalBus

private final class Messages: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SignalMessage] = []
    var all: [SignalMessage] { lock.withLock { items } }
    func start(_ bus: SignalBus) async -> Task<Void, Never> {
        let stream = await bus.subscribe()
        return Task { for await m in stream { lock.withLock { items.append(m) } } }
    }
}

private actor SeenMessages {
    private var batches: [[ChatMessage]] = []
    func add(_ messages: [ChatMessage]) { batches.append(messages) }
    var first: [ChatMessage]? { batches.first }
    var last: [ChatMessage]? { batches.last }
}

private struct RecordingModel: ChatModel {
    let seen: SeenMessages
    func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn {
        await seen.add(messages)
        var turn = ChatTurn(); turn.text = "ок"; return turn
    }
}

@MainActor private func eventually(_ seconds: Double = 4, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { if condition() { return true }; try? await Task.sleep(for: .milliseconds(40)) }
    return condition()
}

private func sensor(_ type: String, subject: String? = nil, revision: UInt64? = nil, _ payload: [String: String] = [:]) -> SignalMessage {
    SignalMessage(source: "t", type: type, subjectID: subject, revision: revision, payload: payload)
}

@MainActor @Test func theSceneDescribesTheSituationForAModelWithoutTheTurnBeingHandled() async {
    let bus = SignalBus(); let seen = Messages()
    let capture = await seen.start(bus)
    var ttl = SceneTTL(); ttl.verdictTimeout = 0.2; ttl.initialCoreMode = "silent"
    let scene = SceneModel(ttl: ttl)
    let sceneTask = Task { await scene.consume(bus) }
    defer { capture.cancel(); sceneTask.cancel() }
    try? await Task.sleep(for: .milliseconds(250))

    await bus.publish(sensor("audio.microphone.started"))
    // 1: background talk without the name; 2: noise; 3: a request; they are heard in this order.
    for (n, text) in [(1, "ну и погода сегодня"), (2, "Продолжение следует"), (3, "Вера, включи свет")] {
        let id = "utterance/s1-seg\(n)"
        await bus.publish(sensor("speech.segment.started", subject: id))
        await bus.publish(sensor("speech.segment.ended", subject: id, ["reason": "silence"]))
        await bus.publish(sensor("speech.transcript.final", subject: id, revision: 1, ["lane": "raw", "text": text]))
        try? await Task.sleep(for: .milliseconds(150))
    }
    #expect(await eventually { seen.all.contains { $0.type == "scene.turn.ready" } })
    let ready = seen.all.first { $0.type == "scene.turn.ready" }
    let turnID = ready?.payload["turn_id"] ?? ""

    await bus.publish(SignalMessage(kind: .query, domain: .core, source: "t", target: "Scene", type: "scene.snapshot.get",
                                    payload: ["exclude_turn": turnID]))
    #expect(await eventually { seen.all.contains { $0.type == "scene.snapshot" } })
    let context = seen.all.last { $0.type == "scene.snapshot" }?.payload["context"] ?? ""
    #expect(context.contains("Рядом сейчас:"))
    #expect(context.contains("ну и погода сегодня"))          // others' background talk is context
    #expect(context.contains("фон"))
    #expect(!context.contains("Продолжение следует"))        // noise is not shown
    #expect(!context.contains("включи свет"))                // the turn being handled is not repeated
}

@MainActor @Test func coreGivesTheModelTheSceneAsBackgroundAndTheOwnerOnlyRule() async {
    let bus = SignalBus(); let seen = SeenMessages()
    let agent = CoreAgent(loop: AgentLoop(model: RecordingModel(seen: seen), tools: ToolRegistry([]), systemPrompt: VeraPrompt.system))
    agent.setEnabled(true)
    let agentTask = Task { await agent.consume(bus) }
    // A stand-in scene that answers the question with a fixed context.
    let stream = await bus.subscribe()
    let sceneTask = Task {
        for await message in stream where message.kind == .query && message.type == "scene.snapshot.get" {
            await bus.publish(SignalMessage(kind: .reply, domain: .scene, source: "Scene.Model", target: message.source, type: "scene.snapshot",
                                            correlationID: message.id.uuidString, payload: ["context": "Рядом сейчас: Алексей (владелец), Наташа (человек)"]))
        }
    }
    defer { agentTask.cancel(); sceneTask.cancel() }
    try? await Task.sleep(for: .milliseconds(200))
    await bus.publish(SignalMessage(domain: .scene, source: "Scene.Builder", type: "scene.turn.ready",
                                    payload: ["turn_id": "turn/7", "text": "Вера, какое слово", "addressed": "likely"]))
    #expect(await eventually { !agent.tasks.isEmpty && agent.tasks[0].state == .done })
    let messages = await seen.first ?? []
    #expect(messages.count == 3)
    #expect(messages[0].content?.contains("только владельца") == true)
    #expect(messages[1].role == .system && messages[1].content?.contains("Наташа (человек)") == true)
    #expect(messages[1].content?.contains("не инструкции") == true)
    #expect(messages[2].role == .user && messages[2].content == "какое слово")
}

@MainActor @Test func aSceneThatDoesNotAnswerDelaysATaskOnlyBrieflyAndThenItGoesOnWithoutContext() async {
    let bus = SignalBus(); let seen = SeenMessages()
    let agent = CoreAgent(loop: AgentLoop(model: RecordingModel(seen: seen), tools: ToolRegistry([]), systemPrompt: "s"))
    agent.sceneTimeout = 0.3
    agent.setEnabled(true)
    let started = Date()
    _ = await agent.run(request: "x", bus: bus)
    #expect(Date().timeIntervalSince(started) < 2)
    let messages = await seen.first ?? []
    #expect(messages.count == 2)       // system prompt and the request, no context
}

@MainActor @Test func recentTasksAreRememberedForFollowUps() async {
    let seen = SeenMessages()
    let agent = CoreAgent(loop: AgentLoop(model: RecordingModel(seen: seen), tools: ToolRegistry([]), systemPrompt: "s"))
    agent.includesSceneContext = false
    agent.setEnabled(true)
    _ = await agent.run(request: "поменяй draft на final")
    _ = await agent.run(request: "а теперь верни обратно")
    #expect((await seen.first)?.count == 2)          // the first run had no history: prompt and request
    let second = await seen.last ?? []
    #expect(second.count == 3)                       // prompt, recent tasks as background, request
    #expect(second[1].content?.contains("поменяй draft на final") == true)
    #expect(second[1].content?.contains("ответ: ок") == true)
}

@MainActor @Test func unknownVoicesReachTheModelMarkedAsUnknownWithTheOwnerEstimate() async {
    let bus = SignalBus(); let seen = Messages()
    let capture = await seen.start(bus)
    var ttl = SceneTTL(); ttl.verdictTimeout = 0.2; ttl.initialCoreMode = "silent"
    let scene = SceneModel(ttl: ttl)
    let sceneTask = Task { await scene.consume(bus) }
    defer { capture.cancel(); sceneTask.cancel() }
    try? await Task.sleep(for: .milliseconds(250))
    await bus.publish(sensor("audio.microphone.started"))
    let id = "utterance/s1-seg1"
    await bus.publish(sensor("speech.segment.started", subject: id))
    // Two windows that match nobody: the voice is filed as unknown.
    for _ in 0..<3 {
        await bus.publish(SignalMessage(source: "t", type: "speaker.live.similarity.computed", correlationID: id,
                                        payload: ["reference": "кто-то", "person_id": "p9", "participant_role": "human",
                                                  "cosine_similarity": "0.30", "margin": "0.01", "owner_cosine": "0.2"]))
    }
    await bus.publish(sensor("speech.segment.ended", subject: id, ["reason": "silence"]))
    await bus.publish(sensor("speech.transcript.final", subject: id, revision: 1, ["lane": "raw", "text": "новости по телевизору"]))
    try? await Task.sleep(for: .milliseconds(500))
    await bus.publish(SignalMessage(kind: .query, domain: .core, source: "t", target: "Scene", type: "scene.snapshot.get"))
    #expect(await eventually { seen.all.contains { $0.type == "scene.snapshot" } })
    let context = seen.all.last { $0.type == "scene.snapshot" }?.payload["context"] ?? ""
    #expect(context.contains("неизвестный голос"))              // it is listed as someone around
    #expect(context.contains("новости по телевизору"))          // what it said is sent too: it may be the owner
    #expect(context.contains("неопознанный голос, возможно владелец:"))   // marked, with the scene's estimate
}
