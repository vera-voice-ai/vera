import Foundation
import Observation
import SignalBus

final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}

/// Core's hands: takes what the scene hands over (`scene.turn.ready`) and runs it as a task through the agent loop.
/// Every step is also a bus event of the core domain, so it can be recorded, replayed and shown.
@MainActor
@Observable
public final class CoreAgent {
    public struct Task: Identifiable, Sendable {
        public enum State: Sendable { case running, done, failed }
        public let id: String
        public let request: String
        public var state: State = .running
        public var answer = ""
        public var toolCalls: [ToolCallRecord] = []
        public var steps = 0
        public var totalMilliseconds = 0
        public var firstTokenMilliseconds: Int?
        public var error: String?
        public let startedAt = Date()
        /// When the scene handed the turn over (the start of Core's part of the delay).
        public var readyAt = Date()
        /// Stage timings, milliseconds: waiting in the queue, asking the scene, then the model and tools (`totalMilliseconds`).
        public var queueMilliseconds = 0
        public var contextMilliseconds = 0
        /// From the hand-over to the first sound of the spoken answer; nil until she starts speaking.
        public var speechStartMilliseconds: Int?
    }

    /// Newest first, the last 20.
    public private(set) var tasks: [Task] = []
    public private(set) var isEnabled = false
    public private(set) var unavailableReason: String?
    /// Only turns where the assistant is addressed by name (`addressed == likely`) run as tasks. A turn that merely
    /// continues a conversation (`possible`) is not an instruction to act: the owner talks a lot near the microphone.
    public var actsOnPossibleAddress = false
    /// Speak each sentence as soon as the model has written it, instead of the whole answer at the end.
    public var streamsSpeech = true
    /// Facts and finished tasks kept between restarts; nil means Core forgets everything when the app closes.
    public var memory: MemoryStore?

    private let loop: AgentLoop?
    private var handled: Set<String> = []
    private var pendingScene: [String: CheckedContinuation<String?, Never>] = [:]
    /// Tasks run one at a time, in the order heard: two of them editing the same folder at once would race.
    private var queueTail: Swift.Task<Void, Never>?
    /// Every task started and not yet finished, so that "стоп" can cancel them all.
    private var live: [UUID: Swift.Task<Void, Never>] = [:]
    /// Ask the scene for the situation and pass it to the model with every task.
    public var includesSceneContext = true
    /// How long a task waits for the scene's answer before going on without context.
    public var sceneTimeout: TimeInterval = 1.5

    /// `loop` is nil when no model is configured (for example no key): the agent then reports why instead of acting.
    public init(loop: AgentLoop?, unavailableReason: String? = nil, memory: MemoryStore? = nil) {
        self.loop = loop
        self.memory = memory
        self.unavailableReason = loop == nil ? (unavailableReason ?? "no model configured") : nil
    }

    public func setEnabled(_ enabled: Bool) { isEnabled = enabled && loop != nil }

    public func consume(_ bus: SignalBus) async {
        let stream = await bus.subscribe()
        for await message in stream {
            if message.kind == .reply, message.type == "scene.snapshot", let id = message.correlationID,
               let waiting = pendingScene.removeValue(forKey: id) {
                waiting.resume(returning: message.payload["context"])
                continue
            }
            if message.domain == .response, message.type == "output.speech.started", let taskID = message.payload["task_id"] {
                update(taskID) { task in
                    if task.speechStartMilliseconds == nil { task.speechStartMilliseconds = Int(Date().timeIntervalSince(task.readyAt) * 1000) }
                }
                continue
            }
            guard isEnabled, message.domain == .scene, message.kind == .event, message.type == "scene.turn.ready",
                  actsOnPossibleAddress || message.payload["addressed"] == "likely",
                  let turnID = message.payload["turn_id"], handled.insert(turnID).inserted else { continue }
            let text = Self.stripAddress(message.payload["text"] ?? "")
            guard !text.isEmpty else { continue }
            // Not awaited here: this loop must stay free to receive the scene's answer to the question the task asks.
            if Self.isStopCommand(text) {
                await cancelAll(bus: bus, reason: "voice")
                continue
            }
            let previous = queueTail
            let key = UUID()
            let work = Swift.Task { @MainActor in
                await previous?.value
                if !Swift.Task.isCancelled {
                    _ = await self.run(request: text, turnID: turnID, bus: bus, causation: message.id, readyAt: message.timestamp)
                }
                self.live[key] = nil
            }
            live[key] = work
            queueTail = work
        }
    }

    /// Stops what Core is doing and what Response is saying: the running task, the queued ones, the speech.
    public func cancelAll(bus: SignalBus?, reason: String) async {
        for work in live.values { work.cancel() }
        live.removeAll()
        queueTail = nil
        await bus?.publish(SignalMessage(kind: .event, domain: .core, source: "Core.Agent", type: "core.tasks.cancelled",
                                         payload: ["reason": reason]))
        await bus?.publish(SignalMessage(kind: .command, domain: .core, source: "Core.Agent", target: "Response",
                                         type: "output.speech.stop", payload: ["reason": reason]))
    }

    /// A short imperative that ends what is going on: "стоп", "отмена", "хватит", "замолчи", "подожди".
    public static func isStopCommand(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard (1...3).contains(words.count) else { return false }
        let stops: Set<String> = ["стоп", "отмена", "отмени", "хватит", "замолчи", "молчи", "подожди", "погоди", "тихо", "перестань"]
        let fillers: Set<String> = ["вера", "вер", "пожалуйста", "ну", "давай", "всё", "все", "уже", "так"]
        return words.contains { stops.contains($0) } && words.allSatisfy { stops.contains($0) || fillers.contains($0) }
    }

    /// Reads the scene by asking it (query/reply on the bus). Nil when it does not answer in time.
    private func sceneContext(bus: SignalBus?, excluding turnID: String?) async -> String? {
        guard includesSceneContext, let bus else { return nil }
        let query = SignalMessage(kind: .query, domain: .core, source: "Core.Agent", target: "Scene", type: "scene.snapshot.get",
                                  payload: ["exclude_turn": turnID ?? ""])
        let key = query.id.uuidString
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            pendingScene[key] = continuation
            Swift.Task { @MainActor in
                await bus.publish(query)
                try? await Swift.Task.sleep(for: .seconds(self.sceneTimeout))
                if let waiting = self.pendingScene.removeValue(forKey: key) { waiting.resume(returning: nil) }
            }
        }
    }

    /// What the owner and Vera did a moment ago, so that a follow-up ("а теперь верни обратно") makes sense.
    private func recentTasksText() -> String? {
        let recent = tasks.filter { $0.state != .running && Date().timeIntervalSince($0.startedAt) < 600 }.prefix(3).reversed()
        guard !recent.isEmpty else { return nil }
        return "Недавние задачи (старые сверху):\n" + recent.map { "- просьба: \(String($0.request.prefix(200))) → ответ: \(String($0.answer.prefix(200)))" }.joined(separator: "\n")
    }

    /// Runs one task. Also the entry point for benchmarks.
    @discardableResult
    public func run(request: String, turnID: String? = nil, bus: SignalBus? = nil, causation: UUID? = nil, readyAt: Date? = nil) async -> AgentResult {
        guard let loop else {
            var result = AgentResult(); result.error = unavailableReason
            return result
        }
        let id = "task/\(turnID?.replacingOccurrences(of: "turn/", with: "") ?? UUID().uuidString.prefix(8).lowercased())"
        var task = Task(id: id, request: request)
        task.readyAt = readyAt ?? task.startedAt
        task.queueMilliseconds = max(0, Int(task.startedAt.timeIntervalSince(task.readyAt) * 1000))
        tasks.insert(task, at: 0)
        if tasks.count > 20 { tasks.removeLast(tasks.count - 20) }
        await bus?.publish(SignalMessage(kind: .event, domain: .core, source: "Core.Agent", type: "core.task.started",
                                         subjectID: id, causationID: causation?.uuidString.lowercased(),
                                         payload: ["task_id": id, "request_chars": "\(request.count)"]))
        let contextStart = Date()
        var context = await sceneContext(bus: bus, excluding: turnID)
        update(id) { $0.contextMilliseconds = Int(Date().timeIntervalSince(contextStart) * 1000) }
        if let facts = memory?.factsText() { context = [context, facts].compactMap { $0 }.joined(separator: "\n") }
        if let recent = recentTasksText() { context = [context, recent].compactMap { $0 }.joined(separator: "\n") }
        // The answer is spoken sentence by sentence as it is written, one command per sentence, in order.
        let chunker = Locked(SpeechChunker())
        let (sentences, sink) = AsyncStream<String>.makeStream()
        let speaker = Swift.Task { @MainActor in
            var index = 0
            for await sentence in sentences {
                index += 1
                await bus?.publish(SignalMessage(kind: .command, domain: .core, source: "Core.Agent", target: "Response",
                                                 type: "output.speech.requested", subjectID: id, correlationID: id,
                                                 payload: ["text": sentence, "task_id": id, "part": "\(index)"]))
            }
        }
        let streams = streamsSpeech && bus != nil
        let result = await loop.run(request: request, context: context) { [weak self] event in
            guard let self else { return }
            if streams, case let .text(delta) = event { for sentence in chunker.withLock({ $0.feed(delta) }) { sink.yield(sentence) } }
            Swift.Task { @MainActor in
                if case let .toolCalled(record) = event {
                    self.update(id) { $0.toolCalls.append(record) }
                    await bus?.publish(SignalMessage(kind: .event, domain: .core, source: "Core.Agent", type: "core.tool.called",
                                                     subjectID: id, payload: ["task_id": id, "tool": record.name, "ok": "\(record.ok)",
                                                                              "ms": "\(record.milliseconds)"]))
                }
            }
        }
        update(id) {
            $0.state = result.succeeded ? .done : .failed
            $0.answer = result.answer
            $0.steps = result.steps
            $0.totalMilliseconds = result.totalMilliseconds
            $0.firstTokenMilliseconds = result.firstTokenMilliseconds
            $0.error = result.error
        }
        await bus?.publish(SignalMessage(kind: .event, domain: .core, source: "Core.Agent", type: "core.task.finished",
                                         subjectID: id,
                                         payload: ["task_id": id, "success": "\(result.succeeded)", "answer": result.answer,
                                                   "steps": "\(result.steps)", "tool_calls": "\(result.toolCalls.count)",
                                                   "first_token_ms": result.firstTokenMilliseconds.map(String.init) ?? "",
                                                   "total_ms": "\(result.totalMilliseconds)",
                                                   "queue_ms": "\(tasks.first(where: { $0.id == id })?.queueMilliseconds ?? 0)",
                                                   "context_ms": "\(tasks.first(where: { $0.id == id })?.contextMilliseconds ?? 0)",
                                                   "prompt_tokens": "\(result.usage.promptTokens)",
                                                   "completion_tokens": "\(result.usage.completionTokens)",
                                                   "error": result.error ?? ""]))
        if result.succeeded { memory?.recordTask(request: request, answer: result.answer) }
        if result.succeeded {
            // What the stream did not already cover: a tail without a full stop, or the whole answer when nothing streamed.
            if streams, let tail = chunker.withLock({ $0.flush() }) { sink.yield(tail) }
            if !streams || chunker.withLock({ $0.emitted.isEmpty }) { sink.yield(result.answer) }
        }
        sink.finish()
        await speaker.value
        return result
    }

    private func update(_ id: String, _ change: (inout Task) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[index])
    }

    /// "Вера, прочитай файл" → "прочитай файл": the address is not part of the task.
    public static func stripAddress(_ text: String) -> String {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let names: Set<String> = ["вера", "веры", "вере", "веру", "верой", "верочка", "верка", "вер"]
        while let first = rest.split(whereSeparator: { !$0.isLetter }).first, names.contains(first.lowercased()),
              rest.lowercased().hasPrefix(first.lowercased()) {
            rest = rest.dropFirst(first.count)
            rest = rest.drop(while: { $0 == "," || $0 == ":" || $0 == "-" || $0 == " " || $0 == "!" })
        }
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
