import Foundation
import Testing
import Core
import Response
import Scene
import SignalBus

private struct FakeSynthesizer: Synthesizer {
    var failure: String?
    func synthesize(text: String) async throws -> Data {
        if let failure { throw ChatError.badResponse(failure) }
        return Data("wav:\(text)".utf8)
    }
}

private struct FakePlayer: AudioPlaying {
    func play(wav: Data) async throws { try await Task.sleep(for: .milliseconds(30)) }
}

/// Collects messages from the bus in the background.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SignalMessage] = []
    var messages: [SignalMessage] { lock.withLock { items } }
    func start(_ bus: SignalBus) async -> Task<Void, Never> {
        let stream = await bus.subscribe()
        return Task { for await m in stream { lock.withLock { items.append(m) } } }
    }
}

@MainActor private func eventually(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { if condition() { return true }; try? await Task.sleep(for: .milliseconds(30)) }
    return condition()
}

private func command(_ text: String, target: String = "Response", kind: SignalKind = .command) -> SignalMessage {
    SignalMessage(kind: kind, domain: .core, source: "Core.Agent", target: target, type: "output.speech.requested", payload: ["text": text])
}

@MainActor @Test func responseExecutesASpeechCommandAndReportsWhatActuallyHappened() async {
    let bus = SignalBus(); let collector = Collector()
    let capture = await collector.start(bus)
    let speaker = ResponseSpeaker(synthesizer: FakeSynthesizer(), player: FakePlayer(), voice: "baya")
    let task = Task { await speaker.consume(bus) }
    defer { capture.cancel(); task.cancel() }
    try? await Task.sleep(for: .milliseconds(150))
    await bus.publish(command("Готово, статус изменён."))
    #expect(await eventually { collector.messages.contains { $0.type == "output.speech.ended" } })
    let types = collector.messages.filter { $0.domain == .response }.map(\.type)
    #expect(types == ["output.speech.started", "output.speech.ended"])
    #expect(collector.messages.first { $0.type == "output.speech.started" }?.payload["voice"] == "baya")
    #expect(speaker.utterances.first?.state == .done)
}

@MainActor @Test func responseIgnoresWhatIsNotACommandForIt() async {
    let bus = SignalBus(); let collector = Collector()
    let capture = await collector.start(bus)
    let speaker = ResponseSpeaker(synthesizer: FakeSynthesizer(), player: FakePlayer())
    let task = Task { await speaker.consume(bus) }
    defer { capture.cancel(); task.cancel() }
    try? await Task.sleep(for: .milliseconds(150))
    await bus.publish(command("не мне", target: "Scene"))
    await bus.publish(command("не команда", kind: .event))
    try? await Task.sleep(for: .milliseconds(300))
    #expect(speaker.utterances.isEmpty)
    #expect(!collector.messages.contains { $0.domain == .response })
}

@MainActor @Test func responseReportsMutedAndFailedSynthesisAsFailures() async {
    let bus = SignalBus(); let collector = Collector()
    let capture = await collector.start(bus)
    let muted = ResponseSpeaker(synthesizer: FakeSynthesizer(), player: FakePlayer())
    muted.isMuted = true
    await muted.speak("тихо", bus: bus)
    let broken = ResponseSpeaker(synthesizer: FakeSynthesizer(failure: "engine down"), player: FakePlayer())
    await broken.speak("сломано", bus: bus)
    #expect(await eventually { collector.messages.filter { $0.type == "output.speech.failed" }.count == 2 })
    capture.cancel()
    let reasons = collector.messages.filter { $0.type == "output.speech.failed" }.compactMap { $0.payload["reason"] }
    #expect(reasons == ["muted", "synthesis"])
    #expect(!collector.messages.contains { $0.type == "output.speech.started" })
}

@MainActor @Test func coreAsksResponseToSpeakTheAnswerOfASuccessfulTask() async {
    struct Model: ChatModel {
        func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn {
            var turn = ChatTurn(); turn.text = "Кодовое слово сокол."; return turn
        }
    }
    let bus = SignalBus(); let collector = Collector()
    let capture = await collector.start(bus)
    defer { capture.cancel() }
    let agent = CoreAgent(loop: AgentLoop(model: Model(), tools: ToolRegistry([]), systemPrompt: "s"))
    agent.setEnabled(true)
    _ = await agent.run(request: "какое слово", bus: bus)
    #expect(await eventually { collector.messages.contains { $0.type == "output.speech.requested" } })
    let ask = collector.messages.first { $0.type == "output.speech.requested" }
    #expect(ask?.kind == .command && ask?.domain == .core && ask?.target == "Response")
    #expect(ask?.payload["text"] == "Кодовое слово сокол.")
}

// MARK: - The scene and Vera's own voice

@Test func theScenePassesNoRequestHeardWhileVeraSpeaksOrJustAfter() {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var builder = SceneBuilder()
    var decisions: [SceneTurn] = []
    func send(_ type: String, at t: Double, domain: SignalDomain = .sensors, subject: String? = nil, revision: UInt64? = nil, _ payload: [String: String] = [:]) {
        let m = SignalMessage(domain: domain, source: "t", type: type, timestamp: base.addingTimeInterval(t), subjectID: subject, revision: revision, payload: payload)
        if let snap = builder.ingest(m) { decisions += snap.decisions }
    }
    func say(_ n: Int, _ start: Double, _ end: Double, _ text: String) {
        let id = "utterance/s1-seg\(n)"
        send("speech.segment.started", at: start, subject: id)
        send("speech.segment.ended", at: end, subject: id, ["reason": "silence"])
        send("speech.transcript.final", at: end + 0.5, subject: id, revision: 1, ["lane": "raw", "text": text])
    }
    send("audio.microphone.started", at: 0)
    send("output.speech.started", at: 10, domain: .response)
    say(1, 11, 13, "Вера, включи свет")                    // her own voice picked up by the microphone
    send("output.speech.ended", at: 14, domain: .response)
    say(2, 14.2, 15.5, "Вера, включи свет")                // inside the tail: still her room reverb
    say(3, 18, 20, "Вера, включи свет")                    // after the tail: a real request
    for t in stride(from: 20.0, to: 30.0, by: 0.5) { if let snap = builder.tick(now: base.addingTimeInterval(t)) { decisions += snap.decisions } }
    let reasons = decisions.compactMap { turn -> String? in if case let .heard(r) = turn.state { return r } else { return nil } }
    let ready = decisions.filter { if case .ready = $0.state { return true } else { return false } }
    #expect(reasons == ["vera_voice", "vera_voice"])
    #expect(ready.count == 1)
    #expect(ready.first?.utteranceIDs == ["utterance/s1-seg3"])
}

// MARK: - Speaking while the answer is written

@Test func chunkerCutsSentencesAndHoldsShortOnesAndNumbers() {
    var chunker = SpeechChunker(minimumLength: 12)
    var out: [String] = []
    for piece in ["Кодовое слово", " сокол. Вто", "рая фраза, в файле 3.5 строки! Да", ". Хвост без точки"] { out += chunker.feed(piece) }
    #expect(out == ["Кодовое слово сокол.", "Вторая фраза, в файле 3.5 строки!"])
    #expect(chunker.flush() == "Да. Хвост без точки")
}

@MainActor @Test func coreSpeaksEachSentenceAsItStreamsAndNothingTwice() async {
    struct Model: ChatModel {
        func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn {
            var turn = ChatTurn()
            for piece in ["Первое предложение готово. ", "Второе предложение тоже. ", "Без точки в конце"] { onText(piece); turn.text += piece }
            return turn
        }
    }
    let bus = SignalBus(); let collector = Collector()
    let capture = await collector.start(bus)
    defer { capture.cancel() }
    let agent = CoreAgent(loop: AgentLoop(model: Model(), tools: ToolRegistry([]), systemPrompt: "s"))
    agent.setEnabled(true)
    _ = await agent.run(request: "скажи", bus: bus)
    #expect(await eventually { collector.messages.filter { $0.type == "output.speech.requested" }.count == 3 })
    let spoken = collector.messages.filter { $0.type == "output.speech.requested" }.compactMap { $0.payload["text"] }
    #expect(spoken == ["Первое предложение готово.", "Второе предложение тоже.", "Без точки в конце"])
}

// MARK: - Stop and cancel

@MainActor @Test func shortImperativesStopWhileOrdinaryRequestsDoNot() {
    #expect(CoreAgent.isStopCommand("Вера, стоп!"))
    #expect(CoreAgent.isStopCommand("Отмена"))
    #expect(CoreAgent.isStopCommand("ну всё хватит"))
    #expect(!CoreAgent.isStopCommand("останови сервер на порту 80"))
    #expect(!CoreAgent.isStopCommand("подожди пять минут и прочитай файл"))
    #expect(!CoreAgent.isStopCommand(""))
}

@MainActor @Test func cancelStopsARunningTaskAndAsksResponseToStopSpeaking() async {
    struct SlowModel: ChatModel {
        func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn {
            try await Task.sleep(for: .seconds(30)); return ChatTurn()
        }
    }
    let bus = SignalBus(); let collector = Collector()
    let capture = await collector.start(bus)
    defer { capture.cancel() }
    let agent = CoreAgent(loop: AgentLoop(model: SlowModel(), tools: ToolRegistry([]), systemPrompt: "s"))
    agent.setEnabled(true)
    let consuming = Task { await agent.consume(bus) }
    defer { consuming.cancel() }
    try? await Task.sleep(for: .milliseconds(200))
    await bus.publish(SignalMessage(kind: .event, domain: .scene, source: "t", type: "scene.turn.ready",
                                    payload: ["turn_id": "turn/a", "text": "Вера, очень долгая задача", "addressed": "likely"]))
    #expect(await eventually { agent.tasks.first?.state == .running })
    await bus.publish(SignalMessage(kind: .event, domain: .scene, source: "t", type: "scene.turn.ready",
                                    payload: ["turn_id": "turn/b", "text": "Вера, стоп", "addressed": "likely"]))
    #expect(await eventually { agent.tasks.first?.state == .failed })
    #expect(agent.tasks.first?.error == "cancelled")
    #expect(await eventually { collector.messages.contains { $0.type == "output.speech.stop" } })
}

@MainActor @Test func stopHeardButNotAddressedStillCancelsARunningTask() async {
    struct SlowModel: ChatModel {
        func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn {
            try await Task.sleep(for: .seconds(30)); return ChatTurn()
        }
    }
    let bus = SignalBus()
    let agent = CoreAgent(loop: AgentLoop(model: SlowModel(), tools: ToolRegistry([]), systemPrompt: "s"))
    agent.setEnabled(true)
    #expect(CoreAgent.isStopCommand("Stop."))
    let consuming = Task { await agent.consume(bus) }
    defer { consuming.cancel() }
    try? await Task.sleep(for: .milliseconds(200))
    await bus.publish(SignalMessage(kind: .event, domain: .scene, source: "t", type: "scene.turn.ready",
                                    payload: ["turn_id": "turn/a", "text": "Вера, долгая задача", "addressed": "likely"]))
    let collector = Collector(); _ = collector
    #expect(await eventually { agent.tasks.first?.state == .running })
    await bus.publish(SignalMessage(kind: .event, domain: .scene, source: "t", type: "scene.turn.heard",
                                    payload: ["turn_id": "turn/b", "text": "Stop.", "addressed": "no", "reason": "not_addressed"]))
    #expect(await eventually { agent.tasks.first?.state == .failed })
}

// MARK: - Silence mode

@MainActor @Test func silenceCommandsAreShortImperativesOnly() {
    #expect(CoreAgent.silenceCommand("Вера, режим тишины") == true)
    #expect(CoreAgent.silenceCommand("помолчи пожалуйста") == true)
    #expect(CoreAgent.silenceCommand("Вера, выйди из режима тишины") == false)
    #expect(CoreAgent.silenceCommand("говори") == false)
    #expect(CoreAgent.silenceCommand("вчера в комнате была тишина и я долго думал об этом") == nil)
    #expect(CoreAgent.silenceCommand("прочитай файл") == nil)
}

@MainActor @Test func inSilenceModeTheModeIsAnnouncedOnceAndAnswersAreNotSpoken() async {
    struct Model: ChatModel {
        func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn {
            var turn = ChatTurn(); turn.text = "Ответ готов, но вслух не скажу."; onText(turn.text); return turn
        }
    }
    let bus = SignalBus(); let collector = Collector()
    let capture = await collector.start(bus)
    defer { capture.cancel() }
    let agent = CoreAgent(loop: AgentLoop(model: Model(), tools: ToolRegistry([]), systemPrompt: "s"))
    agent.setEnabled(true)
    let consuming = Task { await agent.consume(bus) }
    defer { consuming.cancel() }
    try? await Task.sleep(for: .milliseconds(200))
    await bus.publish(SignalMessage(kind: .event, domain: .scene, source: "t", type: "scene.turn.ready",
                                    payload: ["turn_id": "turn/s", "text": "Вера, режим тишины", "addressed": "likely"]))
    #expect(await eventually { agent.isSilent })
    #expect(await eventually { collector.messages.contains { $0.type == "output.speech.requested" && $0.payload["text"] == "Режим тишины" } })
    await bus.publish(SignalMessage(kind: .event, domain: .scene, source: "t", type: "scene.turn.ready",
                                    payload: ["turn_id": "turn/t", "text": "Вера, скажи что-нибудь", "addressed": "likely"]))
    #expect(await eventually { agent.tasks.first?.state == .done })
    #expect(await eventually { collector.messages.contains { $0.type == "core.speech.suppressed" } })
    #expect(collector.messages.filter { $0.type == "output.speech.requested" }.count == 1)
    await bus.publish(SignalMessage(kind: .event, domain: .scene, source: "t", type: "scene.turn.ready",
                                    payload: ["turn_id": "turn/u", "text": "Вера, говори", "addressed": "likely"]))
    #expect(await eventually { !agent.isSilent })
    #expect(await eventually { collector.messages.contains { $0.payload["text"] == "Голос включён" } })
}
