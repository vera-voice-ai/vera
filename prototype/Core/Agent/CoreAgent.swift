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
        public enum State: Sendable { case queued, running, done, failed, cancelled }
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
    /// Turns addressed by name (`addressed == likely`) always run as tasks. A continuation (`possible`) runs too, but
    /// only when `runsAsTask` allows it: the owner's voice clearly above the background and not quieter than usual.
    public var actsOnPossibleAddress = true
    /// Speak each sentence as soon as the model has written it, instead of the whole answer at the end.
    public var streamsSpeech = true
    /// Facts and finished tasks kept between restarts; nil means Core forgets everything when the app closes.
    public var memory: MemoryStore?
    /// Skills listed to the model by name and description; it loads the full text itself.
    public var skills: SkillStore?
    /// Silence mode: Vera still works on requests, but nothing is spoken aloud until the owner switches the voice back on.
    public private(set) var isSilent = false
    /// Her own source and the gates a change to it passes; nil when she may not change herself.
    public var selfModifier: SelfModifier?
    /// Called after a confirmed change was built, when the app should quit so that the new build can start.
    public var restartHandler: (@MainActor () -> Void)?

    private let loop: AgentLoop?
    private var handled: Set<String> = []
    private var pendingScene: [String: CheckedContinuation<String?, Never>] = [:]
    /// At most `maxParallelTasks` tasks run at once; the rest wait in the order heard.
    private let runGate = Lane(capacity: CoreAgent.maxParallelTasks)
    public static let maxParallelTasks = 3
    /// Speech is one voice: a task holds the speech lane from its first sentence to its last, so answers never overlap.
    private let speechLane = Lane(capacity: 1)
    /// The run that holds the voice right now, for the panel; nil when the voice is free.
    public private(set) var voiceTaskID: String?
    /// Raised by "стоп": sentences produced before the stop are dropped, even when they still wait for the speech lane.
    private var speechGeneration = 0
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
            // "Стоп" is heard even when it is not addressed or Vera's own speech gate dropped it, but only while there is
            // something to stop: a running task or speech that began less than a minute ago.
            if isEnabled, message.domain == .scene, message.kind == .event, message.type == "scene.turn.heard",
               Self.isStopCommand(message.payload["text"] ?? ""), hasSomethingToStop {
                await cancelAll(bus: bus, reason: "voice")
                continue
            }
            guard isEnabled, message.domain == .scene, message.kind == .event, message.type == "scene.turn.ready",
                  Self.runsAsTask(addressed: message.payload["addressed"] ?? "", loudness: message.payload["loudness_relative"] ?? "",
                                  aboveFloor: Double(message.payload["loudness_above_floor_db"] ?? ""), allowPossible: actsOnPossibleAddress),
                  let turnID = message.payload["turn_id"], handled.insert(turnID).inserted else { continue }
            let text = Self.stripAddress(message.payload["text"] ?? "")
            // Her name or a greeting alone is an address, not a request: nothing to do, so nothing is said.
            guard !text.isEmpty, !Self.isOnlyAddress(text) else {
                await bus.publish(SignalMessage(kind: .event, domain: .core, source: "Core.Agent", type: "core.turn.ignored",
                                                subjectID: turnID, causationID: message.id.uuidString.lowercased(),
                                                payload: ["turn_id": turnID, "reason": text.isEmpty ? "empty" : "only_address"]))
                continue
            }
            let note = Self.loudnessNote(message.payload["loudness_relative"] ?? "",
                                         aboveFloor: Double(message.payload["loudness_above_floor_db"] ?? ""))
            // Not awaited here: this loop must stay free to receive the scene's answer to the question the task asks.
            if Self.isStopCommand(text) {
                await cancelAll(bus: bus, reason: "voice")
                continue
            }
            if Self.isApplyCommand(text), let modifier = selfModifier, modifier.hasPendingApply {
                await applySelfChange(modifier, bus: bus)
                continue
            }
            if let change = Self.silenceCommand(text) {
                await setSilent(change, bus: bus, causation: message.id)
                continue
            }
            let id = Self.taskID(turnID: turnID)
            enqueue(id: id, request: text, readyAt: message.timestamp)
            await bus.publish(SignalMessage(kind: .event, domain: .core, source: "Core.Agent", type: "core.task.queued",
                                            subjectID: id, causationID: message.id.uuidString.lowercased(),
                                            payload: ["task_id": id]))
            let key = UUID()
            live[key] = Swift.Task { @MainActor in
                if await self.runGate.acquire() {
                    _ = await self.run(request: text, turnID: turnID, bus: bus, causation: message.id, readyAt: message.timestamp, note: note)
                    await self.runGate.release()
                } else {
                    self.update(id) { $0.state = .cancelled }
                }
                self.live[key] = nil
            }
        }
    }

    /// Enters or leaves silence mode. Entering is announced aloud once ("Режим тишины") and cuts what is being said;
    /// leaving is announced too, since by then speech is allowed again.
    public func setSilent(_ silent: Bool, bus: SignalBus?, causation: UUID? = nil) async {
        guard silent != isSilent else { return }
        if silent { await bus?.publish(SignalMessage(kind: .command, domain: .core, source: "Core.Agent", target: "Response", type: "output.speech.stop", payload: ["reason": "silence_mode"])) }
        let phrase = silent ? Self.silencePhrase : Self.voiceBackPhrase
        if !silent { isSilent = false }
        await bus?.publish(SignalMessage(kind: .event, domain: .core, source: "Core.Agent", type: "core.mode.changed",
                                         causationID: causation?.uuidString.lowercased(),
                                         payload: ["mode": silent ? "silent" : "speaking"]))
        await bus?.publish(SignalMessage(kind: .command, domain: .core, source: "Core.Agent", target: "Response",
                                         type: "output.speech.requested", payload: ["text": phrase, "mode_change": silent ? "silent" : "speaking"]))
        if silent { isSilent = true }
    }

    /// The owner's confirmation of a self-change: "применяй", "да, применяй", "применяй изменения".
    public static func isApplyCommand(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard (1...4).contains(words.count) else { return false }
        let allowed: Set<String> = ["да", "вера", "вер", "применяй", "применить", "примени", "изменения", "давай", "ну"]
        return words.contains(where: { ["применяй", "применить", "примени"].contains($0) }) && words.allSatisfy { allowed.contains($0) }
    }

    private func applySelfChange(_ modifier: SelfModifier, bus: SignalBus?) async {
        let summary = modifier.pendingDescription
        await bus?.publish(SignalMessage(kind: .event, domain: .core, source: "Core.Agent", type: "core.self.applying", payload: ["summary": summary]))
        await bus?.publish(SignalMessage(kind: .command, domain: .core, source: "Core.Agent", target: "Response", type: "output.speech.requested",
                                         payload: ["text": "Применяю изменения. Соберу себя и перезапущусь, это займёт несколько минут."]))
        let outcome = await Swift.Task.detached { modifier.applyConfirmed() }.value
        await bus?.publish(SignalMessage(kind: .event, domain: .core, source: "Core.Agent", type: outcome.ok ? "core.self.applied" : "core.self.failed",
                                         payload: ["log": outcome.log]))
        if outcome.ok {
            restartHandler?()
        } else {
            await bus?.publish(SignalMessage(kind: .command, domain: .core, source: "Core.Agent", target: "Response", type: "output.speech.requested",
                                             payload: ["text": "Сборка не удалась, остаюсь на прежней версии."]))
        }
    }

    public static let silencePhrase = "Режим тишины"
    public static let voiceBackPhrase = "Голос включён"

    /// true = go silent, false = speak again, nil = not a mode command. Short imperatives only, so that a sentence
    /// that merely mentions silence ("в комнате была тишина") is not taken for a command.
    public static func silenceCommand(_ text: String) -> Bool? {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard (1...6).contains(words.count) else { return nil }
        let joined = words.joined(separator: " ")
        let on = ["режим тишины", "тихий режим", "помолчи", "молчи", "не говори", "замолчи на время", "режим молчания"]
        let off = ["выйди из режима тишины", "выключи режим тишины", "режим тишины выключи", "говори", "включи голос", "можешь говорить", "голос включи", "заговори"]
        if off.contains(where: { joined.contains($0) }) { return false }
        if on.contains(where: { joined.contains($0) }) { return true }
        return nil
    }

    private var hasSomethingToStop: Bool {
        tasks.contains { $0.state == .running || ($0.speechStartMilliseconds != nil && Date().timeIntervalSince($0.readyAt) < 60) }
    }

    /// Stops what Core is doing and what Response is saying: the running task, the queued ones, the speech.
    public func cancelAll(bus: SignalBus?, reason: String) async {
        for work in live.values { work.cancel() }
        live.removeAll()
        speechGeneration += 1
        // Waiting tasks end here; running ones end when their loop returns "cancelled" (see `run`).
        for index in tasks.indices where tasks[index].state == .queued {
            tasks[index].state = .cancelled
            tasks[index].error = "cancelled"
        }
        await bus?.publish(SignalMessage(kind: .event, domain: .core, source: "Core.Agent", type: "core.tasks.cancelled",
                                         payload: ["reason": reason]))
        await bus?.publish(SignalMessage(kind: .command, domain: .core, source: "Core.Agent", target: "Response",
                                         type: "output.speech.stop", payload: ["reason": reason]))
    }

    /// A short imperative that ends what is going on: "стоп", "отмена", "хватит", "замолчи", "подожди".
    public static func isStopCommand(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard (1...3).contains(words.count) else { return false }
        let stops: Set<String> = ["stop", "top", "стоп", "стап", "отмена", "отмени", "хватит", "замолчи", "молчи", "подожди", "погоди", "тихо", "перестань"]
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
    public func run(request: String, turnID: String? = nil, bus: SignalBus? = nil, causation: UUID? = nil, readyAt: Date? = nil,
                    note: String? = nil) async -> AgentResult {
        guard let loop else {
            var result = AgentResult(); result.error = unavailableReason
            return result
        }
        let id = Self.taskID(turnID: turnID)
        if !tasks.contains(where: { $0.id == id }) { enqueue(id: id, request: request, readyAt: readyAt ?? Date()) }
        update(id) {
            $0.state = .running
            $0.queueMilliseconds = max(0, Int(Date().timeIntervalSince($0.readyAt) * 1000))
        }
        await bus?.publish(SignalMessage(kind: .event, domain: .core, source: "Core.Agent", type: "core.task.started",
                                         subjectID: id, causationID: causation?.uuidString.lowercased(),
                                         payload: ["task_id": id, "request_chars": "\(request.count)"]))
        let contextStart = Date()
        var context = await sceneContext(bus: bus, excluding: turnID)
        update(id) { $0.contextMilliseconds = Int(Date().timeIntervalSince(contextStart) * 1000) }
        if let catalog = skills?.catalogText() { context = [context, catalog].compactMap { $0 }.joined(separator: "\n") }
        if let facts = memory?.factsText() { context = [context, facts].compactMap { $0 }.joined(separator: "\n") }
        if let recent = recentTasksText() { context = [context, recent].compactMap { $0 }.joined(separator: "\n") }
        if let note { context = [context, note].compactMap { $0 }.joined(separator: "\n") }
        // The answer is spoken sentence by sentence as it is written, one command per sentence, in order.
        let chunker = Locked(SpeechChunker())
        let (sentences, sink) = AsyncStream<String>.makeStream()
        let generation = speechGeneration
        let speaker = Swift.Task { @MainActor in
            var index = 0
            var holdsVoice = false
            for await sentence in sentences {
                if self.isSilent {
                    await bus?.publish(SignalMessage(kind: .event, domain: .core, source: "Core.Agent", type: "core.speech.suppressed",
                                                     subjectID: id, payload: ["task_id": id, "chars": "\(sentence.count)"]))
                    continue
                }
                if generation != self.speechGeneration { continue }
                if !holdsVoice {
                    guard await self.speechLane.acquire() else { continue }
                    holdsVoice = true
                    self.voiceTaskID = id
                    if generation != self.speechGeneration { continue }
                }
                index += 1
                await bus?.publish(SignalMessage(kind: .command, domain: .core, source: "Core.Agent", target: "Response",
                                                 type: "output.speech.requested", subjectID: id, correlationID: id,
                                                 payload: ["text": sentence, "task_id": id, "part": "\(index)"]))
            }
            if holdsVoice {
                if self.voiceTaskID == id { self.voiceTaskID = nil }
                await self.speechLane.release()
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
            $0.state = result.succeeded ? .done : (result.error == "cancelled" ? .cancelled : .failed)
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

    static func taskID(turnID: String?) -> String {
        "task/\(turnID?.replacingOccurrences(of: "turn/", with: "") ?? UUID().uuidString.prefix(8).lowercased())"
    }

    /// A task that waits for a place: listed at once, so the owner sees what is heard and not yet started.
    private func enqueue(id: String, request: String, readyAt: Date) {
        var task = Task(id: id, request: request)
        task.state = .queued
        task.readyAt = readyAt
        tasks.insert(task, at: 0)
        if tasks.count > 20 { tasks.removeLast(tasks.count - 20) }
    }

    private func update(_ id: String, _ change: (inout Task) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[index])
    }

    /// Whether a handed-over turn becomes a task. Addressed by name: always. A continuation (`possible`): only when the
    /// owner's voice is clearly louder than the background and not quieter than her usual level.
    public static func runsAsTask(addressed: String, loudness: String, aboveFloor: Double?, allowPossible: Bool) -> Bool {
        if addressed == "likely" { return true }
        guard addressed == "possible", allowPossible else { return false }
        if loudness == "тише обычного" { return false }
        return (aboveFloor ?? 6) >= 6
    }

    /// A line for the model about how loud the turn was, so that quiet speech over loud background is read as background.
    public static func loudnessNote(_ relative: String, aboveFloor: Double?) -> String? {
        var parts: [String] = []
        if !relative.isEmpty, relative != "нет базы" { parts.append("громкость: \(relative)") }
        if let aboveFloor { parts.append("на \(Int(aboveFloor.rounded())) дБ выше фона") }
        return parts.isEmpty ? nil : "Эта реплика (\(parts.joined(separator: ", "))). Тихая речь на громком фоне — скорее фон, а не обращение."
    }

    /// Only a name and greetings, with no request in them: "Вера", "Привет, Вера", "Вера, привет!".
    public static func isOnlyAddress(_ text: String) -> Bool {
        let filler: Set<String> = ["привет", "здравствуй", "здравствуйте", "эй", "алло", "доброе", "добрый", "утро", "день", "вечер",
                                   "вера", "веры", "вере", "веру", "верой", "верочка", "верка", "вер"]
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.allSatisfy { filler.contains($0) }
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
