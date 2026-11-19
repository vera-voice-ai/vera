import Foundation

/// One thing Vera does without asking the model: what starts it, what happens, and how to switch it off.
public struct AutomationEntry: Identifiable, Equatable, Sendable {
    public let id: String
    /// Short, Russian.
    public let title: String
    /// When it fires.
    public let trigger: String
    /// What happens.
    public let effect: String
    /// Russian: the voice command, the setting, or «пока только в коде».
    public let howToDisable: String

    public init(id: String, title: String, trigger: String, effect: String, howToDisable: String) {
        self.id = id; self.title = title; self.trigger = trigger; self.effect = effect; self.howToDisable = howToDisable
    }
}

/// The list of everything Vera does on rules, timers and filters, for the owner to see. It is built from the live
/// values: the windows of the agent instance and the quiet hours the speaker runs with. Constants that are private
/// or live in another module (the wake words, the silence option, the scene settings) are named in the text only.
public enum AutomationRegistry {
    /// `quietHours` is passed in because Response is not a dependency of Core (`QuietHours()` in Response).
    @MainActor
    public static func all(agent: CoreAgent, quietHours: (startHour: Int, endHour: Int, nightLevel: Float)) -> [AutomationEntry] {
        let ready = "\(Int(agent.readyWindow)) с"
        let working = "\(Int(agent.workingWindow / 60)) мин"
        let reply = "\(Int(CoreAgent.replyWindow)) с"
        let night = "\(quietHours.startHour):00–\(String(format: "%02d", quietHours.endHour)):00"
        let nightVolume = "\(Int((quietHours.nightLevel * 100).rounded())) %"
        return [
            AutomationEntry(
                id: "mode.timers",
                title: "Таймеры режимов",
                trigger: "«Готовность» \(ready) и «В работе» \(working) после последней реплики владельца или завершённой задачи. Каждая реплика сдвигает таймер.",
                effect: "Когда время вышло, Вера уходит в «Тишину» и говорит «Режим тишины» (тихо, \(Int((CoreAgent.quietVolume * 100).rounded())) %).",
                howToDisable: "Пока только в коде: CoreAgent.readyWindow и workingWindow. Голосом можно выйти из режима сейчас: «молчи»."),
            AutomationEntry(
                id: "activation.name",
                title: "Обращение по имени",
                trigger: "Имя «Вера» (и формы «веры», «верочка», «вер») среди первых или последних трёх слов реплики. Список в CoreAgent.wakeWords.",
                effect: "Будит из «Тишины» в «Готовность» и обязывает ответить: молчать («[молчу]») в этом случае нельзя.",
                howToDisable: "Пока только в коде: CoreAgent.wakeWords. Без него она в «Тишине» не слушает."),
            AutomationEntry(
                id: "command.silent",
                title: "Команда «Тишина»",
                trigger: "Короткая фраза до 6 слов: «помолчи», «молчи», «режим тишины», «замолчи на время».",
                effect: "Переход в «Тишину», фраза «Режим тишины» произносится тихо (\(Int((CoreAgent.quietVolume * 100).rounded())) %).",
                howToDisable: "Вернуть голос: «говори», «включи голос», «можешь говорить». Выключить саму команду пока только в коде: CoreAgent.silenceCommand."),
            AutomationEntry(
                id: "command.sleep",
                title: "Команда «Сон»",
                trigger: "Короткий приказ 1–4 слова: «спать», «засыпай», «спи», «иди спать», «режим сна». Фраза «хочу спать» не считается.",
                effect: "Отменяет всё, что идёт, выключает микрофон (Sensors) и говорит «Засыпаю». Слушать она перестаёт.",
                howToDisable: "Проснуться: включить микрофон. Выключить саму команду пока только в коде: CoreAgent.isSleepCommand."),
            AutomationEntry(
                id: "command.stop",
                title: "Команда «Стоп»",
                trigger: "1–3 слова: «стоп», «отмена», «хватит», «подожди», «погоди», «тихо», «перестань». Слышится и без обращения по имени, но только пока есть что останавливать: идёт задача или речь началась меньше минуты назад. Во «Сне» не слышит.",
                effect: "Отменяет задачи в очереди и выполняемые, обрывает речь (core.tasks.cancelled, output.speech.stop).",
                howToDisable: "Пока только в коде: CoreAgent.isStopCommand. Голосом не отключается."),
            AutomationEntry(
                id: "gate.owner",
                title: "Только владелец",
                trigger: "Запрос из голоса доходит до Core, только когда владелец в сцене: голос подтверждён или он был слышен за последние 5 мин (SceneTTL.app, requireOwnerPresent).",
                effect: "Чужие голоса и фон не становятся задачами. Сообщения из Telegram проходят по своему каналу, без голосовой проверки.",
                howToDisable: "Пока только в коде: SceneTTL.app.requireOwnerPresent (Scene/SceneBuilder.swift)."),
            AutomationEntry(
                id: "quiet.hours",
                title: "Тихие часы",
                trigger: "Каждый день с \(night) (QuietHours: startHour, endHour).",
                effect: "Вся речь звучит на \(nightVolume) громкости поверх громкости, которую запросила задача.",
                howToDisable: "Пока только в коде: QuietHours.enabled в ResponseSpeaker (Response/ResponseSpeaker.swift)."),
            AutomationEntry(
                id: "reminders.ticker",
                title: "Напоминания",
                trigger: "Проверка раз в секунду (ticker в CoreAgent.consume). Срабатывает, когда пришло время записи.",
                effect: "Произносит текст вслух, даже в «Тишине», или запускает его как задачу. Во «Сне» ждёт пробуждения.",
                howToDisable: "Отменить одно голосом: «отмени напоминание N» (инструмент cancel_reminder). Весь механизм пока только в коде."),
            AutomationEntry(
                id: "reply.window",
                title: "Окно ответа на вопрос",
                trigger: "\(reply) после её вопроса (CoreAgent.replyWindow). Ответ без имени в этом окне принимается.",
                effect: "Короткая реплика владельца считается ответом, даже если голос распознан плохо.",
                howToDisable: "Пока только в коде: CoreAgent.replyWindow."),
            AutomationEntry(
                id: "silence.option",
                title: "Вариант «[молчу]»",
                trigger: "Реплика без имени, которую модель считает бесспорно не обращённой к ней (CoreAgent.silenceOption).",
                effect: "Ответ «[молчу]» не озвучивается и не записывается в историю задач.",
                howToDisable: "Пока только в коде: CoreAgent.silenceOption. Не предлагается, когда ее назвали по имени."),
            AutomationEntry(
                id: "agent.steps",
                title: "Лимит шагов агента",
                trigger: "На каждую задачу: не больше 24 запросов к модели (значение AgentLoop.maxSteps по умолчанию; поле в CoreAgent приватно).",
                effect: "На последнем шаге модель обязана ответить словами. Если лимит исчерпан, задача завершается ошибкой «step limit reached».",
                howToDisable: "Не отключается. Меняется пока только в коде: AgentLoop(maxSteps:)."),
            AutomationEntry(
                id: "mode.note",
                title: "Пометка режима в каждом запросе",
                trigger: "Каждая задача к модели (CoreAgent.modeNote и loudnessNote).",
                effect: "Модель знает режим («Готовность» \(ready) или «В работе» \(working)) и отвечает без имени. В «Тишине» и «Сне» пометка не добавляется.",
                howToDisable: "Пока только в коде: CoreAgent.modeNote. Меняется вместе с окнами режимов."),
        ]
    }
}
