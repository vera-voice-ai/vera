import Foundation

/// What she was asked to do later: say something, or run a request as a task, at a set time. Kept in a JSON file, so a
/// restart does not lose it.
public final class ReminderStore: @unchecked Sendable {
    public struct Item: Codable, Sendable, Identifiable, Equatable {
        public let id: String
        public let dueAt: Date
        public let text: String
        /// false: say the text aloud; true: run the text as a task (a request to the agent) at that time.
        public let asTask: Bool
        /// Comes back every day at the same time (a morning briefing): after it fires it moves to the next day.
        public let repeatsDaily: Bool

        public init(id: String, dueAt: Date, text: String, asTask: Bool, repeatsDaily: Bool = false) {
            self.id = id; self.dueAt = dueAt; self.text = text; self.asTask = asTask; self.repeatsDaily = repeatsDaily
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            dueAt = try values.decode(Date.self, forKey: .dueAt)
            text = try values.decode(String.self, forKey: .text)
            asTask = try values.decode(Bool.self, forKey: .asTask)
            repeatsDaily = try values.decodeIfPresent(Bool.self, forKey: .repeatsDaily) ?? false
        }
    }

    private let url: URL
    private let lock = NSLock()
    private var items: [Item]

    public init(url: URL) {
        self.url = url
        let data = try? Data(contentsOf: url)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        items = data.flatMap { try? decoder.decode([Item].self, from: $0) } ?? []
    }

    @discardableResult
    public func add(dueAt: Date, text: String, asTask: Bool, repeatsDaily: Bool = false) -> Item {
        let item = Item(id: String(UUID().uuidString.prefix(6)).lowercased(), dueAt: dueAt, text: text, asTask: asTask, repeatsDaily: repeatsDaily)
        lock.withLock { items.append(item); save() }
        return item
    }

    public func list() -> [Item] { lock.withLock { items.sorted { $0.dueAt < $1.dueAt } } }

    @discardableResult
    public func cancel(_ id: String) -> Bool {
        lock.withLock {
            let before = items.count
            items.removeAll { $0.id == id }
            if items.count != before { save() }
            return items.count != before
        }
    }

    /// The reminders whose time has come. A single one is removed; a daily one moves to its next day.
    public func takeDue(now: Date, calendar: Calendar = .current) -> [Item] {
        lock.withLock {
            let due = items.filter { $0.dueAt <= now }.sorted { $0.dueAt < $1.dueAt }
            if !due.isEmpty {
                items = items.compactMap { item in
                    guard item.dueAt <= now else { return item }
                    guard item.repeatsDaily else { return nil }
                    var next = item.dueAt
                    while next <= now { next = calendar.date(byAdding: .day, value: 1, to: next) ?? next.addingTimeInterval(86_400) }
                    return Item(id: item.id, dueAt: next, text: item.text, asTask: item.asTask, repeatsDaily: true)
                }
                save()
            }
            return due
        }
    }

    private func save() {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// "через 10 минут" arrives as `minutes`; "в 18:30" as `at` ("HH:mm", the next such time, or a full ISO date).
    public static func dueDate(minutes: Double?, at: String?, now: Date, calendar: Calendar = .current) -> Date? {
        if let minutes, minutes > 0 { return now.addingTimeInterval(minutes * 60) }
        guard let at = at?.trimmingCharacters(in: .whitespaces), !at.isEmpty else { return nil }
        let parts = at.split(separator: ":").compactMap { Int($0) }
        if parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) {
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = parts[0]; components.minute = parts[1]; components.second = 0
            guard var date = calendar.date(from: components) else { return nil }
            if date <= now { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
            return date
        }
        return ISO8601DateFormatter().date(from: at)
    }
}

struct SetReminderTool: AgentTool {
    let store: ReminderStore
    var definition: ToolDefinition {
        ToolDefinition(name: "set_reminder", description: "Do something later: minutes from now, or at as HH:mm. text is said aloud; with as_task true it is a request you carry out yourself then.",
                       parametersJSON: #"{"type":"object","properties":{"minutes":{"type":"number"},"at":{"type":"string"},"text":{"type":"string"},"as_task":{"type":"boolean"},"repeat":{"type":"string","description":"daily: every day at that time"}},"required":["text"]}"#)
    }
    func run(argumentsJSON: String) -> ToolResult {
        guard let args = WorkspaceTools.arguments(argumentsJSON), let text = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return ToolResult(ok: false, text: "bad arguments: need text")
        }
        let minutes = (args["minutes"] as? Double) ?? (args["minutes"] as? Int).map(Double.init)
        guard let due = ReminderStore.dueDate(minutes: minutes, at: args["at"] as? String, now: Date()) else {
            return ToolResult(ok: false, text: "не поняла время: нужны minutes или at в виде HH:mm")
        }
        let daily = (args["repeat"] as? String)?.lowercased() == "daily"
        let item = store.add(dueAt: due, text: text, asTask: args["as_task"] as? Bool ?? false, repeatsDaily: daily)
        return ToolResult(ok: true, text: "запомнила, номер \(item.id), сработает \(Self.format(due))" + (daily ? " и потом каждый день" : ""))
    }
    static func format(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ru_RU"); formatter.dateFormat = "d MMMM, HH:mm"
        return formatter.string(from: date)
    }
}

struct ListRemindersTool: AgentTool {
    let store: ReminderStore
    var definition: ToolDefinition { ToolDefinition(name: "list_reminders", description: "List planned reminders.", parametersJSON: #"{"type":"object","properties":{}}"#) }
    func run(argumentsJSON: String) -> ToolResult {
        let items = store.list()
        if items.isEmpty { return ToolResult(ok: true, text: "ничего не запланировано") }
        return ToolResult(ok: true, text: items.map { "\($0.id): \(SetReminderTool.format($0.dueAt))\($0.repeatsDaily ? " и каждый день" : "") — \($0.asTask ? "задача" : "сказать"): \($0.text)" }.joined(separator: "\n"))
    }
}

struct CancelReminderTool: AgentTool {
    let store: ReminderStore
    var definition: ToolDefinition {
        ToolDefinition(name: "cancel_reminder", description: "Cancel a planned reminder by its number.",
                       parametersJSON: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}"#)
    }
    func run(argumentsJSON: String) -> ToolResult {
        guard let args = WorkspaceTools.arguments(argumentsJSON), let id = args["id"] as? String else { return ToolResult(ok: false, text: "bad arguments: need id") }
        return store.cancel(id) ? ToolResult(ok: true, text: "отменила \(id)") : ToolResult(ok: false, text: "нет такого номера")
    }
}

public extension ToolRegistry {
    static func reminderTools(_ store: ReminderStore) -> ToolRegistry {
        ToolRegistry([SetReminderTool(store: store), ListRemindersTool(store: store), CancelReminderTool(store: store)])
    }
}
