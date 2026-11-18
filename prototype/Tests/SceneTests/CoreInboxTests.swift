import Foundation
import Testing
import Scene
import SignalBus
import Core

/// Waits until `condition` holds (the scene and Core run as tasks on the bus), up to `seconds`.
@MainActor private func eventually(_ seconds: Double = 4, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

@MainActor @Test func aTurnHandedOverByTheSceneReachesCoreAndCoreCanReadTheSceneBack() async {
    let bus = SignalBus()
    var ttl = SceneTTL()
    ttl.verdictTimeout = 0.2   // no judge here: the scene decides after this short wait
    let scene = SceneModel(ttl: ttl)
    let core = CoreInbox()
    let sceneTask = Task { await scene.consume(bus) }
    let coreTask = Task { await core.consume(bus) }
    defer { sceneTask.cancel(); coreTask.cancel() }
    _ = await eventually { core.isSubscribed }
    try? await Task.sleep(for: .milliseconds(200))   // both subscriptions are in place

    await bus.publish(SignalMessage(source: "t", type: "audio.microphone.started"))
    await bus.publish(SignalMessage(source: "t", type: "speech.segment.started", subjectID: "utterance/s1-seg1"))
    await bus.publish(SignalMessage(source: "t", type: "speech.segment.ended", subjectID: "utterance/s1-seg1", payload: ["reason": "silence"]))
    await bus.publish(SignalMessage(source: "t", type: "speech.transcript.final", subjectID: "utterance/s1-seg1", revision: 1,
                                    payload: ["lane": "raw", "text": "Вера, включи свет в гостиной"]))

    #expect(await eventually { core.readyCount == 1 })
    #expect(core.received.first?.isReady == true)
    #expect(core.received.first?.text == "Вера, включи свет в гостиной")
    #expect(core.received.first?.why == "no_verdict")

    // Core asked the scene for its picture on receiving the event, and the scene answered on the bus.
    #expect(await eventually { core.lastReply != nil })
    #expect(core.lastReply?.status.isEmpty == false)
    #expect(Int(core.lastReply?.turns ?? "") ?? 0 >= 1)
}

@MainActor @Test func coreKeepsContextEventsApartFromHandedOverOnes() async {
    let bus = SignalBus()
    let core = CoreInbox()
    let coreTask = Task { await core.consume(bus) }
    defer { coreTask.cancel() }
    _ = await eventually { core.isSubscribed }
    try? await Task.sleep(for: .milliseconds(100))
    await bus.publish(SignalMessage(domain: .scene, source: "Scene.Builder", type: "scene.turn.heard",
                                    payload: ["turn_id": "turn/1", "text": "разговор в комнате", "reason": "not_addressed"]))
    await bus.publish(SignalMessage(domain: .scene, source: "Scene.Builder", type: "scene.revision.created"))
    #expect(await eventually { core.heardCount == 1 })
    #expect(core.readyCount == 0)
    #expect(core.received.count == 1)        // revisions are not Core's inbox
    #expect(core.received.first?.why == "not_addressed")
}
