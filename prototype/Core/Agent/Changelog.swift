import Foundation

/// What is new in Vera, with dates, in her own context: so that she knows which abilities appeared lately, where a tool or
/// a skill came from and what she could not do before. Kept short on purpose (every line costs tokens on each request);
/// the full history is the changelog section of docs/index.html. A test keeps the newest entry in step with `VeraRelease`.
public enum VeraChangelog {
    public struct Entry: Sendable {
        public let version: String
        public let date: String
        public let notes: String
    }

    /// Newest first.
    public static let entries: [Entry] = [
        Entry(version: "0.1.6", date: "19 ноября 2026",
              notes: "реплики другого человека, узнанного по голосу, до тебя не доходят; если в ответе на реплику без имени есть пометка о молчании, он считается молчанием и обрывает речь."),
        Entry(version: "0.1.5", date: "19 ноября 2026",
              notes: "ты видишь проект FamilyOS Алексея: инструменты familyos_notes, familyos_tasks, familyos_projects (только чтение, расшифровки разговоров не показываются); у тебя есть его профиль; запрос к модели стал короче."),
        Entry(version: "0.1.4", date: "19 ноября 2026",
              notes: "Телеграм идёт через сцену (бот @veragovoritbot, ответ уходит в чат, вслух только если он рядом); выключатели автоматики голосом («выключи тихие часы»); архив заметок и review_notes для пересмотра заметок."),
        Entry(version: "0.1.3", date: "19 ноября 2026",
              notes: "команды, которые ты запускаешь сама, идут в песочнице (без сети, запись только в рабочую папку); свой браузер хранит входы и может скрываться; в окне видны размеры хранилища и расход подписок."),
        Entry(version: "0.1.2", date: "19 ноября 2026", notes: "появился Телеграм как канал."),
        Entry(version: "0.1.1", date: "19 ноября 2026", notes: "до 24 шагов на задачу, на последнем шаге ты отвечаешь по найденному; git для чтения без вопросов."),
        Entry(version: "0.1.0", date: "19 ноября 2026",
              notes: "первая сборка: режимы, параллельные задачи, веб, команды по «выполняй», браузер, Mac, заметки, напоминания.")
    ]

    /// The newest entries as a short block for the model's context.
    public static func contextText(limit: Int = 3) -> String {
        let lines = entries.prefix(limit).map { "- \($0.version), \($0.date): \($0.notes)" }
        return "Что нового у тебя (последние обновления, новые сверху; если Алексей спрашивает, умеешь ли ты что-то новое, ориентируйся на это):\n" + lines.joined(separator: "\n")
    }
}
