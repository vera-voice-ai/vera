import Foundation
import Testing
import SignalBus

private final class FakeClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
    var read: @Sendable () -> Date { { [self] in self.now } }
}

private let moscow: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
    return calendar
}()

private func moscowDate(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
    moscow.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private func incoming(_ text: String, at: Date) -> SignalMessage {
    SignalMessage(domain: .sensors, source: "Sensors.Telegram", type: "sensors.text.received", timestamp: at,
                  subjectID: "tg-1", payload: ["text": text, "channel": "telegram", "authenticated": "true", "turn_id": "tg-1"])
}

private func answer(_ text: String, success: Bool = true, subject: String = "task/tg-1") -> SignalMessage {
    SignalMessage(kind: .event, domain: .core, source: "Core.Agent", type: "core.task.finished", subjectID: subject,
                  payload: ["success": "\(success)", "answer": text, "error": success ? "" : "сбой"])
}

@MainActor
@Test func telegramLinkStates() {
    let model = TelegramSensorModel(calendar: moscow)
    model.configure(polls: true, hasToken: false)
    #expect(model.link == .noToken)

    model.configure(polls: false, hasToken: true)
    #expect(model.link == .notPolling)

    model.configure(polls: true, hasToken: true)
    #expect(model.link == .starting)
    model.handle(SignalMessage(domain: .sensors, source: "Sensors.Telegram", type: "sensors.telegram.status",
                               payload: ["state": "pairing", "bot": "vera_test_bot", "code": "123456"]))
    #expect(model.link == .pairing(code: "123456"))
    #expect(model.botName == "vera_test_bot")
    model.handle(SignalMessage(domain: .sensors, source: "Sensors.Telegram", type: "sensors.telegram.status",
                               payload: ["state": "paired", "bot": "vera_test_bot", "code": ""]))
    #expect(model.link == .paired)
}

@MainActor
@Test func telegramCountersAndLastMessage() {
    let clock = FakeClock(moscowDate(19, 12, 0))
    let model = TelegramSensorModel(clock: clock.read, calendar: moscow)
    #expect(model.agoText(now: clock.now) == nil)

    model.handle(incoming("привет", at: moscowDate(19, 11, 58)))
    model.handle(incoming("сколько времени", at: moscowDate(19, 11, 58)))
    model.handle(answer("12:00"))
    model.handle(answer("", success: true))
    model.handle(answer("[молчу]"))
    model.handle(answer("Не вышло", success: false))
    model.handle(answer("чужая задача", subject: "task/cli-3"))

    #expect(model.incomingToday == 2)
    // The answer, and the failure (always sent). An empty or silent answer is not sent.
    #expect(model.answersToday == 2)
    #expect(model.lastText == "сколько времени")
    #expect(model.agoText(now: clock.now) == "2 мин назад")
}

@MainActor
@Test func telegramIgnoresOtherChannels() {
    let model = TelegramSensorModel(calendar: moscow)
    model.handle(SignalMessage(domain: .sensors, source: "Sensors.Microphone", type: "sensors.text.received",
                               payload: ["text": "голос", "channel": "microphone"]))
    #expect(model.incomingToday == 0)
    #expect(model.lastText.isEmpty)
}

@MainActor
@Test func telegramPreviewIsTrimmedToSixtyCharacters() {
    let long = String(repeating: "я", count: 80)
    let preview = TelegramSensorModel.preview("  " + long + "\nхвост  ")
    #expect(preview == String(repeating: "я", count: 60) + "…")
    #expect(TelegramSensorModel.preview("  коротко \n да ") == "коротко да")
}

@MainActor
@Test func telegramCountersResetAtLocalMidnight() {
    let clock = FakeClock(moscowDate(19, 23, 50))
    let model = TelegramSensorModel(clock: clock.read, calendar: moscow)
    model.handle(incoming("раз", at: moscowDate(19, 23, 51)))
    model.handle(answer("ответ"))
    #expect(model.incomingToday == 1 && model.answersToday == 1)

    clock.now = moscowDate(20, 0, 10)
    #expect(model.incomingToday == 0 && model.answersToday == 0)
    // The last message stays visible across midnight; only the counters restart.
    #expect(model.lastText == "раз")

    model.handle(incoming("два", at: moscowDate(20, 0, 10)))
    #expect(model.incomingToday == 1)
    #expect(model.agoText(now: moscowDate(20, 0, 10).addingTimeInterval(30)) == "только что")
    #expect(model.agoText(now: moscowDate(20, 0, 12)) == "2 мин назад")
}
