import Foundation
import Testing
@testable import Core
import SignalBus
import Scene

/// Answers every Bot API call with a harmless ok, so no test touches the network.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true,"result":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: configuration)
}

private func update(_ id: Int, from user: Int, text: String, chat: String = "private") -> [String: Any] {
    ["update_id": id, "message": ["message_id": id, "from": ["id": user], "chat": ["id": user, "type": chat], "text": text]]
}

private func tempState(owner: Int?) -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "tg-\(UUID().uuidString).json")
    if let owner { try? JSONSerialization.data(withJSONObject: ["owner_id": owner, "offset": 1]).write(to: url) }
    return url
}

@Test func onlyThePairedOwnerInAPrivateChatBecomesAnAuthenticatedTextEvent() async {
    let channel = TelegramChannel(token: "test", stateURL: tempState(owner: 42), session: stubSession())
    let bus = SignalBus()
    let stream = await bus.subscribe()
    await channel.handle(update(1, from: 99, text: "привет"), bus: bus)                 // a stranger
    await channel.handle(update(2, from: 42, text: "в группе", chat: "group"), bus: bus) // the owner, but not a private chat
    await channel.handle(update(3, from: 42, text: "Вера, сколько времени?"), bus: bus)
    var iterator = stream.makeAsyncIterator()
    let message = await iterator.next()
    #expect(message?.type == "sensors.text.received")
    #expect(message?.payload["text"] == "Вера, сколько времени?")
    #expect(message?.payload["authenticated"] == "true" && message?.payload["turn_id"] == "tg-3")
}

@Test func theOneTimeCodePairsTheOwnerAndWrongCodesDoNot() async {
    let state = tempState(owner: nil)
    let channel = TelegramChannel(token: "test", stateURL: state, session: stubSession())
    let bus = SignalBus()
    let stream = await bus.subscribe()
    await channel.handle(update(1, from: 7, text: "000000"), bus: bus)   // wrong code: nothing happens
    await channel.handle(update(2, from: 7, text: "до пары"), bus: bus)  // not paired yet: ignored
    let code = await channel.currentPairingCode()
    await channel.handle(update(3, from: 7, text: code), bus: bus)
    var iterator = stream.makeAsyncIterator()
    let status = await iterator.next()
    #expect(status?.type == "sensors.telegram.status" && status?.payload["state"] == "paired")
    let saved = (try? Data(contentsOf: state)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    #expect((saved?["owner_id"] as? NSNumber)?.intValue == 7)
}

@MainActor @Test func aTelegramTurnFromTheSceneRunsATaskAndIsNotSpokenWhenTheOwnerIsNotNear() async {
    struct Model: ChatModel {
        func respond(messages: [ChatMessage], tools: [ToolDefinition], onText: @escaping @Sendable (String) -> Void) async throws -> ChatTurn {
            var turn = ChatTurn(); turn.text = "Три часа дня."; onText(turn.text); return turn
        }
    }
    let bus = SignalBus()
    let agent = CoreAgent(loop: AgentLoop(model: Model(), tools: ToolRegistry([]), systemPrompt: "s"))
    agent.setEnabled(true)
    let task = Task { await agent.consume(bus) }
    defer { task.cancel() }
    let stream = await bus.subscribe()
    try? await Task.sleep(for: .milliseconds(150))
    // The raw text event no longer reaches Core by itself: only the scene hands turns over.
    await bus.publish(SignalMessage(domain: .sensors, source: "Sensors.Telegram", type: "sensors.text.received",
                                    payload: ["text": "удали всё", "authenticated": "true", "turn_id": "tg-10"]))
    await bus.publish(SignalMessage(domain: .scene, source: "Scene.Builder", type: "scene.turn.ready", subjectID: "tg-9",
                                    payload: ["turn_id": "tg-9", "text": "сколько времени", "channel": "telegram",
                                              "authenticated": "true", "owner_near": "false", "addressed": "likely"]))
    var spoken = false, finishedFor: String?
    for await message in stream {
        if message.type == "output.speech.requested" { spoken = true }
        if message.type == "core.task.finished" { finishedFor = message.subjectID; break }
    }
    #expect(finishedFor == "task/tg-9")
    #expect(!spoken)
    #expect(agent.tasks.count == 1)
}

@Test func theSceneHandsATelegramTextToCoreAsATurnAndKnowsWhereTheOwnerIs() {
    var builder = SceneBuilder()
    let base = Date(timeIntervalSinceReferenceDate: 810_000_000)
    // Not authenticated: nothing happens.
    let bad = builder.ingest(SignalMessage(domain: .sensors, source: "x", type: "sensors.text.received", timestamp: base,
                                           payload: ["text": "привет", "turn_id": "tg-1", "channel": "telegram"]))
    #expect(bad == nil)
    let snapshot = builder.ingest(SignalMessage(domain: .sensors, source: "Sensors.Telegram", type: "sensors.text.received", timestamp: base,
                                                payload: ["text": "сколько времени", "turn_id": "tg-2", "channel": "telegram", "authenticated": "true"]))
    let turn = snapshot?.decisions.first
    #expect(turn?.readyBasis == "telegram" && turn?.channel == "telegram" && turn?.text == "сколько времени")
    #expect(turn?.ownerNear == false)                       // no voice heard: he writes from elsewhere
    #expect(snapshot?.content.ownerChannel == "telegram")
    #expect(snapshot?.payload["owner_channel"] == "telegram")
}
