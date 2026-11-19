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
    /// The mode she is in (ADR-013). She starts in Ready; timers and commands move her between modes.
    public private(set) var mode: VeraMode = .ready
    /// When Ready or Working runs out if the owner says nothing more; nil in Silent and Sleep.
    public private(set) var modeDeadline: Date?
    /// How long Ready and Working last after the owner's last reply (seconds).
    public var readyWindow: TimeInterval = 60
    public var workingWindow: TimeInterval = 600
    /// The current time; tests replace it to run the timers without waiting.
    public var clock: () -> Date = { Date() }
    private var activityAt = Date()
    /// Speak each sentence as soon as the model has written it, instead of the whole answer at the end.
    public var streamsSpeech = true
    /// Facts and finished tasks kept between restarts; nil means Core forgets everything when the app closes.
    public var memory: MemoryStore?
    /// Skills listed to the model by name and description; it loads the full text itself.
    public var skills: SkillStore?
    /// Silent: what is running is finished, but nothing is spoken aloud.
    public var isSilent: Bool { mode == .silent }
    /// A shell command that waits for the owner's word «выполняй»; nil when she has no command tool.
    public var commandApproval: CommandApproval?
    /// What she was asked to do later (say it or run it as a task); nil when she has no reminders.
    public var reminders: ReminderStore?
    /// Her own source and the gates a change to it passes; nil when she may not change herself.
    public var selfModifier: SelfModifier?
    /// Called after a confirmed change was built, when the app should quit so that the new build can start.
    public var restartHandler: (@MainActor () -> Void)?

    private let loop: AgentLoop?
    private var handled: Set<String> = []
    /// Remembers that a turn was taken (a turn is handed over once); forgets the oldest ones in bulk so the set stays small.
    private func firstTime(_ turnID: String) -> Bool {
        if handled.count > 2_000 { handled.removeAll() }
        return handled.insert(turnID).inserted
    }
    /// The task whose model call is running right now: a question about the work does not report itself.
    @TaskLocal static var currentTaskID: String?
    private var pendingScene: [String: CheckedContinuation<String?, Never>] = [:]
    /// At most `maxParallelTasks` tasks run at once; the rest wait in the order heard.
    /// After a question of hers the owner's next short reply is taken as the answer even when the voice was not recognised:
    /// "Да" is too short to tell by voice. Valid until this moment.
    private var awaitingReplyUntil: Date?
    public static let replyWindow: TimeInterval = 45
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
    /// The last time the owner's voice produced a request. Owner near the computer = this was recent.
    var lastOwnerVoiceAt: Date?
    /// How long after a voice request the owner counts as sitting next to Vera (seconds).
    static let ownerNearWindow: TimeInterval = 600

    /// How long a task waits for the scene's answer before going on without context.
    public var sceneTimeout: TimeInterval = 1.5

    /// `loop` is nil when no model is configured (for example no key): the agent then reports why instead of acting.
    public init(loop: AgentLoop?, unavailableReason: String? = nil, memory: MemoryStore? = nil) {
        self.loop = loop
        self.memory = memory
        self.unavailableReason = loop == nil ? (unavailableReason ?? "no model configured") : nil
        self.modeDeadline = activityAt.addingTimeInterval(readyWindow)
    }

    public func setEnabled(_ enabled: Bool) { isEnabled = enabled && loop != nil }

    public func consume(_ bus: SignalBus) async {
        let stream = await bus.subscribe()
        // Without new evidence nothing arrives, so a timer lets Ready and Working run out.
        let ticker = Swift.Task { @MainActor [weak self] in
            while !Swift.Task.isCancelled {
                try? await Swift.Task.sleep(for: .seconds(1))
                await self?.expireIfNeeded(bus: bus)
                await self?.fireDueReminders(bus: bus)
            }
        }
        defer { ticker.cancel() }
        for await message in stream {
            // Switching the microphone on wakes her from sleep.
            if message.type == "audio.microphone.started", mode == .sleep {
                await setMode(.ready, bus: bus, reason: "microphone", announce: Self.wakePhrase)
                continue
            }
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
            // A short reply to her own question: the scene filed it as "not addressed" (a one-word voice is not recognisable).
            if isEnabled, message.domain == .scene, message.kind == .event, message.type == "scene.turn.heard",
               let until = awaitingReplyUntil, clock() < until, mode == .ready || mode == .working,
               message.payload["reason"] == "not_addressed", let heardID = message.payload["turn_id"],
               (1...4).contains((message.payload["text"] ?? "").split(whereSeparator: { !$0.isLetter }).count),
               firstTime(heardID) {
                awaitingReplyUntil = nil
                touch()
                await startTask(request: message.payload["text"] ?? "", turnID: heardID, bus: bus, causation: message.id, readyAt: message.timestamp,
                                note: "Это короткий ответ Алексея на твой вопрос.", mustAnswer: false)
                continue
            }
            // A text message of the paired owner (Telegram): authenticated by the channel, so no voice or scene check applies.
            if isEnabled, message.domain == .sensors, message.kind == .event, message.type == "sensors.text.received",
               message.payload["authenticated"] == "true", let textTurnID = message.payload["turn_id"], firstTime(textTurnID) {
                await handleText(message, turnID: textTurnID, bus: bus)
                continue
            }
            guard isEnabled, message.domain == .scene, message.kind == .event, message.type == "scene.turn.ready",
                  let turnID = message.payload["turn_id"], firstTime(turnID) else { continue }
            lastOwnerVoiceAt = clock()
            let rawText = message.payload["text"] ?? ""
            let activation = Self.isActivation(rawText)
            let loudness = message.payload["loudness_relative"] ?? ""
            let aboveFloor = Double(message.payload["loudness_above_floor_db"] ?? "")
            // Sleep hears nothing. Silent reacts only to the activation phrase. Ready and Working take any reply of the
            // owner that the loudness rule lets through.
            switch mode {
            case .sleep: continue
            case .silent: guard activation else { continue }
            case .ready, .working:
                guard activation || Self.runsAsTask(addressed: message.payload["addressed"] ?? "") else { continue }
            }
            let text = Self.stripAddress(rawText)
            let note = [Self.modeNote(mode, readyWindow: readyWindow, workingWindow: workingWindow),
                        Self.loudnessNote(loudness, aboveFloor: aboveFloor),
                        activation ? "К тебе обратились по имени: отвечай, молчать нельзя." : Self.silenceOption]
                .compactMap { $0 }.joined(separator: " ")
            // Not awaited here: this loop must stay free to receive the scene's answer to the question the task asks.
            if Self.isStopCommand(text) {
                await cancelAll(bus: bus, reason: "voice")
                continue
            }
            if Self.isApplyCommand(text), let modifier = selfModifier, modifier.hasPendingApply {
                await applySelfChange(modifier, bus: bus)
                continue
            }
            if Self.isRunApproval(text), let approval = commandApproval, approval.hasPending {
                await runApprovedCommand(approval, bus: bus, message: message, turnID: turnID)
                continue
            }
            if let change = Self.silenceCommand(text) {
                await setMode(change ? .silent : .ready, bus: bus, reason: "command", causation: message.id,
                              announce: change ? Self.silencePhrase : Self.voiceBackPhrase)
                continue
            }
            if Self.isSleepCommand(text) {
                await setMode(.sleep, bus: bus, reason: "command", causation: message.id, announce: Self.sleepPhrase)
                continue
            }
            // Her name or a greeting alone is an address, not a request: it wakes her and she says that she listens.
            guard !text.isEmpty, !Self.isOnlyAddress(text) else {
                if mode == .silent { await setMode(.ready, bus: bus, reason: "activation", causation: message.id) }
                touch()
                await bus.publish(SignalMessage(kind: .command, domain: .core, source: "Core.Agent", target: "Response",
                                                type: "output.speech.requested", causationID: message.id.uuidString.lowercased(),
                                                payload: ["text": Self.isGreeting(text) ? Self.greetingPhrase : Self.listeningPhrase]))
                continue
            }
            if mode == .silent { await setMode(.ready, bus: bus, reason: "activation", causation: message.id) }
            touch()
            await startTask(request: text, turnID: turnID, bus: bus, causation: message.id, readyAt: message.timestamp,
                            note: note.isEmpty ? nil : note, mustAnswer: activation)
        }
    }

    /// The owner wrote to Vera (Telegram). The answer goes back as a message and is also spoken when he is next to her.
    private func handleText(_ message: SignalMessage, turnID: String, bus: SignalBus) async {
        let text = (message.payload["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if Self.isStopCommand(text) { await cancelAll(bus: bus, reason: "text"); return }
        if Self.isApplyCommand(text), let modifier = selfModifier, modifier.hasPendingApply { await applySelfChange(modifier, bus: bus); return }
        if Self.isRunApproval(text), let approval = commandApproval, approval.hasPending {
            await runApprovedCommand(approval, bus: bus, message: message, turnID: turnID)
            return
        }
        let near = lastOwnerVoiceAt.map { clock().timeIntervalSince($0) < Self.ownerNearWindow } ?? false
        let note = "Алексей пишет тебе в Телеграм текстом. Ответ уйдёт ему сообщением" + (near ? ", и ещё прозвучит вслух: он рядом." : ".")
            + " Отвечай по делу, можно подробнее, чем голосом, без разметки."
        await startTask(request: text, turnID: turnID, bus: bus, causation: message.id, readyAt: message.timestamp, note: note, mustAnswer: true, speaks: near)
    }

    /// Lists the task at once ("queued") and runs it when a place is free.
    private func startTask(request: String, turnID: String, bus: SignalBus?, causation: UUID?, readyAt: Date, note: String?, mustAnswer: Bool,
                           speaks: Bool = true) async {
        let id = Self.taskID(turnID: turnID)
        enqueue(id: id, request: request, readyAt: readyAt)
        await bus?.publish(SignalMessage(kind: .event, domain: .core, source: "Core.Agent", type: "core.task.queued",
                                         subjectID: id, causationID: causation?.uuidString.lowercased(), payload: ["task_id": id]))
        let key = UUID()
        live[key] = Swift.Task { @MainActor in
            if await self.runGate.acquire() {
                _ = await self.run(request: request, turnID: turnID, bus: bus, causation: causation, readyAt: readyAt, note: note, mustAnswer: mustAnswer, speaks: speaks)
                await self.runGate.release()
            } else {
                self.update(id) { $0.state = .cancelled }
            }
            self.live[key] = nil
        }
    }

    /// The owner said «выполняй» to a command that was waiting: run it, then let the model say what came of it.
    private func runApprovedCommand(_ approval: CommandApproval, bus: SignalBus, message: SignalMessage, turnID: String) async {
        guard let command = approval.take() else { return }
        await bus.publish(SignalMessage(kind: .command, domain: .core, source: "Core.Agent", target: "Response",
                                        type: "output.speech.requested", payload: ["text": Self.runningPhrase]))
        let directory = approval.workingDirectory
        let result = await Swift.Task.detached { ShellRunner.run(command, in: directory, timeout: 60) }.value
        await bus.publish(SignalMessage(kind: .event, domain: .core, source: "Core.Agent", type: "core.command.ran",
                                        causationID: message.id.uuidString.lowercased(),
                                        payload: ["command": command, "code": "\(result.code)", "timed_out": "\(result.timedOut)"]))
        let request = "Алексей разрешил выполнить команду «\(command)». Код возврата \(result.code)\(result.timedOut ? ", время вышло" : ""). Вывод:\n\(result.output)\nКоротко скажи, что получилось."
        await startTask(request: request, turnID: turnID + "-command", bus: bus, causation: message.id, readyAt: message.timestamp, note: nil, mustAnswer: true)
    }

    /// Reminders whose time has come: said aloud (even in Silent, the owner asked for it), or run as a task. Asleep she waits.
    public func fireDueReminders(bus: SignalBus?) async {
        guard let reminders, mode != .sleep else { return }
        for item in reminders.takeDue(now: clock()) {
            await bus?.publish(SignalMessage(kind: .event, domain: .core, source: "Core.Agent", type: "core.reminder.fired",
                                             payload: ["id": item.id, "text": item.text, "as_task": "\(item.asTask)"]))
            if item.asTask {
                await startTask(request: item.text, turnID: "reminder-" + item.id, bus: bus, causation: nil, readyAt: clock(),
                                note: "Это запланированная задача: Алексей просил выполнить её в это время.", mustAnswer: true)
            } else {
                await bus?.publish(SignalMessage(kind: .command, domain: .core, source: "Core.Agent", target: "Response",
                                                 type: "output.speech.requested", payload: ["text": "Напоминаю: " + item.text]))
            }
        }
    }

    /// «выполняй», «да, запускай»: the owner lets a waiting command run.
    public static func isRunApproval(_ text: String) -> Bool {
        let filler: Set<String> = ["да", "вера", "вер", "ну", "давай", "пожалуйста", "ладно", "хорошо", "можно", "можешь"]
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { !filler.contains($0) }
        guard (1...3).contains(words.count) else { return false }
        let allowed: Set<String> = ["выполняй", "выполни", "выполнить", "запускай", "запусти", "запустить", "разрешаю", "делай"]
        return words.allSatisfy { allowed.contains($0) }
    }

    /// Switches the mode, tells the bus (`core.mode.changed`, which the scene reads as a fact) and says `announce` if given.
    /// Silent cuts what is being said; Sleep cancels everything and asks Sensors to stop the microphone.
    public func setMode(_ new: VeraMode, bus: SignalBus?, reason: String, causation: UUID? = nil, announce: String? = nil) async {
        let old = mode
        guard new != old else { touch(); return }
        if new == .sleep {
            await cancelAll(bus: bus, reason: "sleep")
        } else if new == .silent {
            await bus?.publish(SignalMessage(kind: .command, domain: .core, source: "Core.Agent", target: "Response",
                                             type: "output.speech.stop", payload: ["reason": "silence_mode"]))
        }
        mode = new
        touch()
        await bus?.publish(SignalMessage(kind: .event, domain: .core, source: "Core.Agent", type: "core.mode.changed",
                                         causationID: causation?.uuidString.lowercased(),
                                         payload: ["mode": new.rawValue, "previous": old.rawValue, "reason": reason]))
        if let announce {
            // Going quiet is said quietly: the phrase that announces Silent is spoken at `quietVolume`.
            var payload = ["text": announce, "mode_change": new.rawValue]
            if new == .silent { payload["volume"] = String(Self.quietVolume) }
            await bus?.publish(SignalMessage(kind: .command, domain: .core, source: "Core.Agent", target: "Response",
                                             type: "output.speech.requested", payload: payload))
        }
        if new == .sleep {
            await bus?.publish(SignalMessage(kind: .command, domain: .core, source: "Core.Agent", target: "Sensors",
                                             type: "sensors.microphone.stop", payload: ["reason": reason]))
        }
    }

    /// Compatibility for callers that only know silence: Silent on, or back to Ready.
    public func setSilent(_ silent: Bool, bus: SignalBus?, causation: UUID? = nil) async {
        await setMode(silent ? .silent : .ready, bus: bus, reason: "command", causation: causation,
                      announce: silent ? Self.silencePhrase : Self.voiceBackPhrase)
    }

    /// An owner reply or a finished task restarts the clock of Ready and Working.
    private func touch() {
        activityAt = clock()
        switch mode {
        case .ready: modeDeadline = activityAt.addingTimeInterval(readyWindow)
        case .working: modeDeadline = activityAt.addingTimeInterval(workingWindow)
        case .silent, .sleep: modeDeadline = nil
        }
    }

    /// Ready and Working run out to Silent when the owner has said nothing for the whole window and nothing is running.
    public func expireIfNeeded(bus: SignalBus?) async {
        guard mode == .ready || mode == .working else { return }
        if tasks.contains(where: { $0.state == .running || $0.state == .queued }) { touch(); return }
        guard let deadline = modeDeadline, clock() >= deadline else { return }
        await setMode(.silent, bus: bus, reason: "timer", announce: Self.silencePhrase)
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

    /// The volume of the phrase that announces Silent: 78 % of the usual.
    public static let quietVolume = 0.78
    public static let silencePhrase = "Режим тишины"
    public static let voiceBackPhrase = "Голос включён"
    public static let listeningPhrase = "Слушаю"
    public static let runningPhrase = "Выполняю"
    /// The answer to a greeting alone ("Привет, Вера"): she greets back instead of only saying that she listens.
    public static let greetingPhrase = "Привет, Алексей"

    /// A greeting among the words of a reply that has nothing else in it (see `isOnlyAddress`).
    public static func isGreeting(_ text: String) -> Bool {
        let greetings: Set<String> = ["привет", "здравствуй", "здравствуйте", "добрый", "доброе", "утро", "день", "вечер"]
        return text.lowercased().split(whereSeparator: { !$0.isLetter }).contains { greetings.contains(String($0)) }
    }
    public static let sleepPhrase = "Засыпаю"
    public static let wakePhrase = "Просыпаюсь"
    /// What the model answers when a reply is plainly not meant for her: nothing is spoken.
    public static let silenceMarker = "[молчу]"
    /// Offered only with a reply that came without her name: the model may stay silent when it is plainly not for her.
    /// It is not in the general prompt, so a request that reaches her by name or by a benchmark can never be answered with it.
    static let silenceOption = "Это реплика без обращения по имени. Приветствия, вопросы и просьбы считай обращением к тебе и отвечай. Ответь ровно «[молчу]» и больше ничего, только если реплика бесспорно не тебе: пересказ видео или чужой разговор, обрывок фразы, звонок по телефону, слова себе под нос. Малейшее сомнение — отвечай как обычно."
    static let wakeWords: Set<String> = ["вера", "веры", "вере", "веру", "верой", "верочка", "верка", "вер"]

    /// The activation phrase: her name among the first three or the last three words of a reply, however long it is.
    public static func isActivation(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.prefix(3).contains(where: { wakeWords.contains($0) }) || words.suffix(3).contains(where: { wakeWords.contains($0) })
    }

    /// A short imperative that sends her to sleep: "спать", "засыпай", "спи", "иди спать", "режим сна". A sentence
    /// that merely mentions sleep ("хочу спать") is not a command.
    public static func isSleepCommand(_ text: String) -> Bool {
        let filler: Set<String> = ["вера", "вер", "пожалуйста", "ну", "давай", "теперь", "ладно", "а", "уже", "всё", "все"]
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { !filler.contains($0) }
        guard (1...4).contains(words.count) else { return false }
        let joined = words.joined(separator: " ")
        let strong = ["засыпай", "засни", "усни", "спи", "режим сна"]
        let exact: Set<String> = ["спать", "иди спать", "ложись спать", "пора спать", "иди спи", "переходи в режим сна", "включи режим сна"]
        return exact.contains(joined) || strong.contains(where: { joined.contains($0) })
    }

    /// True when the whole answer is the silence marker (the brackets and the case do not matter).
    public static func isSilenceMarker(_ answer: String) -> Bool {
        answer.lowercased().filter(\.isLetter) == "молчу"
    }

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
                    note: String? = nil, mustAnswer: Bool = false, speaks: Bool = true) async -> AgentResult {
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
                if !speaks { continue }
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
        let onEvent: @Sendable (AgentEvent) -> Void = { [weak self] event in
            guard let self else { return }
            if streams, case let .text(delta) = event { for sentence in chunker.withLock({ $0.feed(delta) }) { sink.yield(sentence) } }
            Swift.Task { @MainActor in
                if case let .toolCalled(record) = event {
                    // A request that needed a tool is real work: Ready becomes Working.
                    if self.mode == .ready { await self.setMode(.working, bus: bus, reason: "task") } else { self.touch() }
                    self.update(id) { $0.toolCalls.append(record) }
                    await bus?.publish(SignalMessage(kind: .event, domain: .core, source: "Core.Agent", type: "core.tool.called",
                                                     subjectID: id, payload: ["task_id": id, "tool": record.name, "ok": "\(record.ok)",
                                                                              "ms": "\(record.milliseconds)"]))
                }
            }
        }
        var result = await Self.$currentTaskID.withValue(id) { await loop.run(request: request, context: context, onEvent: onEvent) }
        // Called by her name she must answer: "[молчу]" is only for replies that are plainly not hers.
        if mustAnswer, result.succeeded, Self.isSilenceMarker(result.answer) {
            chunker.withLock { $0 = SpeechChunker() }   // the marker of the first try must not leak into her spoken answer
            result = await Self.$currentTaskID.withValue(id) {
                await loop.run(request: request + "\n(Тебя назвали по имени: ответь по существу, ответ «[молчу]» здесь недопустим.)",
                               context: context, onEvent: onEvent)
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
        let stayedSilent = result.succeeded && Self.isSilenceMarker(result.answer)
        if result.succeeded, !stayedSilent, result.answer.contains("?") { awaitingReplyUntil = clock().addingTimeInterval(Self.replyWindow) }
        if mode == .ready || mode == .working { touch() }
        if result.succeeded, !stayedSilent { memory?.recordTask(request: request, answer: result.answer) }
        if result.succeeded, !stayedSilent {
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
        // The list keeps the last 20, but never drops a task that is still running or waiting.
        while tasks.count > 20, let index = tasks.lastIndex(where: { $0.state != .running && $0.state != .queued }) { tasks.remove(at: index) }
    }

    private func update(_ id: String, _ change: (inout Task) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[index])
    }

    /// Whether a handed-over turn becomes a task in Ready and Working: addressed by name, or a reply of a known voice.
    /// Loudness is not a condition: the owner's own speech is often quiet, and a hard threshold cut off real requests.
    public static func runsAsTask(addressed: String) -> Bool {
        addressed == "likely" || addressed == "possible"
    }

    /// What the model is told about the mode she is in, so that she describes herself correctly.
    public static func modeNote(_ mode: VeraMode, readyWindow: TimeInterval, workingWindow: TimeInterval) -> String? {
        switch mode {
        case .ready:
            return "Режим сейчас «Готовность»: ты отвечаешь без имени; если Алексей молчит \(Int(readyWindow)) с, ты сама уходишь в «Тишину» и говоришь «Режим тишины»."
        case .working:
            return "Режим сейчас «В работе»: ты отвечаешь без имени; после \(Int(workingWindow / 60)) мин без его реплик ты сама уходишь в «Тишину»."
        case .silent, .sleep:
            return nil
        }
    }

    /// A line for the model about how loud the turn was. Only a quiet turn gets the warning that it may be background.
    public static func loudnessNote(_ relative: String, aboveFloor: Double?) -> String? {
        var parts: [String] = []
        if !relative.isEmpty, relative != "нет базы" { parts.append("громкость: \(relative)") }
        if let aboveFloor { parts.append("на \(Int(aboveFloor.rounded())) дБ выше фона") }
        guard !parts.isEmpty else { return nil }
        let quiet = relative == "тише обычного" || (aboveFloor ?? 99) < 4
        return "Эта реплика (\(parts.joined(separator: ", "))).\(quiet ? " Реплика тихая: возможно, это фон, а не обращение." : "")"
    }

    /// Only a name and greetings, with no request in them: "Вера", "Привет, Вера", "Вера, привет!".
    public static func isOnlyAddress(_ text: String) -> Bool {
        let filler: Set<String> = ["привет", "здравствуй", "здравствуйте", "эй", "алло", "доброе", "добрый", "утро", "день", "вечер",
                                   "вера", "веры", "вере", "веру", "верой", "верочка", "верка", "вер"]
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.allSatisfy { filler.contains($0) }
    }

    /// The work in words: what runs, waits and was finished lately, for «что там с задачей?».
    public func statusText(now: Date? = nil) -> String {
        let current = now ?? clock()
        func shorten(_ text: String) -> String { text.count > 70 ? String(text.prefix(70)) + "…" : text }
        var lines: [String] = []
        for task in tasks.prefix(9) where task.id != Self.currentTaskID {
            let age = Int(current.timeIntervalSince(task.startedAt))
            switch task.state {
            case .running: lines.append("идёт \(age) с: \(shorten(task.request))")
            case .queued: lines.append("ждёт в очереди: \(shorten(task.request))")
            case .done: lines.append("готово, \(task.totalMilliseconds / 1000) с: \(shorten(task.request)) → \(shorten(task.answer))")
            case .failed: lines.append("не удалось: \(shorten(task.request))")
            case .cancelled: lines.append("отменено: \(shorten(task.request))")
            }
        }
        return lines.isEmpty ? "задач ещё не было" : lines.joined(separator: "\n")
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
