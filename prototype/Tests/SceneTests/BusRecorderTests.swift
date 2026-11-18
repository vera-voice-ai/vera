import Foundation
import Testing
import SignalBus

@Test func recorderWritesSensorMessagesAndSkipsSceneDomain() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "vera-recorder-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bus = SignalBus()
    let recorder = BusRecorder()
    let file = try await recorder.start(bus: bus, directory: directory, name: "test")

    await bus.publish(SignalMessage(source: "t", type: "audio.microphone.started"))
    await bus.publish(SignalMessage(source: "t", type: "speech.segment.started", subjectID: "utterance/s1-seg1",
                                    revision: 1, payload: ["rms": "0.0123"]))
    await bus.publish(SignalMessage(domain: .scene, source: "t", type: "scene.revision.created"))
    await bus.publish(SignalMessage(source: "t", type: "audio.microphone.stopped"))
    await recorder.stop()

    let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let messages = try lines.map { try decoder.decode(SignalMessage.self, from: Data($0.utf8)) }
    #expect(messages.map(\.type) == ["audio.microphone.started", "speech.segment.started", "audio.microphone.stopped"])
    #expect(messages[1].subjectID == "utterance/s1-seg1")
    #expect(messages[1].revision == 1)
    #expect(messages[1].payload["rms"] == "0.0123")
    #expect(await recorder.recordedCount == 3)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}
