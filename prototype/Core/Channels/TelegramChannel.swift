import Foundation
import SignalBus

/// Telegram as a text channel of Vera.
///
/// In: a message from the paired owner becomes the event `sensors.text.received` (authenticated by the Telegram user id,
/// not by voice). Out: the answer of a task that was started from Telegram is sent back to the same chat.
/// Pairing: until an owner is paired the window shows a one-time code; whoever sends it to the bot becomes the owner.
/// Everybody else is ignored without a reply, so the bot cannot be probed. The token lives only in the Keychain
/// and never appears in a message, a log line or an error text of this file.
public actor TelegramChannel {
    public static let taskPrefix = "tg-"

    private let token: String
    private let stateURL: URL
    private let session: URLSession
    private var ownerID: Int64?
    private var offset = 0
    private var hasOffset = false
    private var pairingCode = ""
    private var wrongAttempts = 0
    private var botName = ""

    public init(token: String, stateURL: URL, session: URLSession = .shared) {
        self.token = token
        self.stateURL = stateURL
        self.session = session
        if let data = try? Data(contentsOf: stateURL), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            ownerID = (object["owner_id"] as? NSNumber)?.int64Value
            if let saved = (object["offset"] as? NSNumber)?.intValue { offset = saved; hasOffset = true }
        }
        pairingCode = Self.newCode()
    }

    /// The current one-time pairing code (the window shows the same).
    func currentPairingCode() -> String { pairingCode }

    nonisolated static func newCode() -> String { String(format: "%06d", Int.random(in: 0...999_999)) }

    public func run(bus: SignalBus) async {
        if let name = try? await call("getMe", [:], timeout: 15), let result = name["result"] as? [String: Any] {
            botName = (result["username"] as? String) ?? ""
        }
        await announce(bus)
        let outgoing = Task { await self.sendAnswers(bus: bus) }
        defer { outgoing.cancel() }
        // First start: the old backlog must not run as commands. Skip to the end of the queue.
        if !hasOffset {
            if let skip = try? await call("getUpdates", ["offset": -1, "timeout": 0], timeout: 15),
               let last = (skip["result"] as? [[String: Any]])?.last, let id = (last["update_id"] as? NSNumber)?.intValue {
                offset = id + 1
            }
            hasOffset = true
            saveState()
        }
        while !Task.isCancelled {
            do {
                let reply = try await call("getUpdates", ["offset": offset, "timeout": 25, "allowed_updates": ["message"]], timeout: 40)
                let updates = reply["result"] as? [[String: Any]] ?? []
                for update in updates {
                    if let id = (update["update_id"] as? NSNumber)?.intValue { offset = id + 1 }
                    await handle(update, bus: bus)
                }
                if !updates.isEmpty { saveState() }
            } catch {
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: Incoming

    func handle(_ update: [String: Any], bus: SignalBus) async {
        guard let id = (update["update_id"] as? NSNumber)?.intValue,
              let message = update["message"] as? [String: Any],
              let from = message["from"] as? [String: Any], let fromID = (from["id"] as? NSNumber)?.int64Value,
              let chat = message["chat"] as? [String: Any], (chat["type"] as? String) == "private",
              let text = (message["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        guard let owner = ownerID else {
            // Pairing: the code shown in the Vera window, sent once.
            if text == pairingCode {
                ownerID = fromID
                saveState()
                _ = try? await call("sendMessage", ["chat_id": fromID, "text": "Привязано. Теперь пиши мне сюда, как в голосе."], timeout: 15)
                await announce(bus)
            } else {
                wrongAttempts += 1
                if wrongAttempts >= 5 { wrongAttempts = 0; pairingCode = Self.newCode(); await announce(bus) }
            }
            return
        }
        guard fromID == owner else { return }
        await bus.publish(SignalMessage(kind: .event, domain: .sensors, source: "Sensors.Telegram", type: "sensors.text.received",
                                        subjectID: Self.taskPrefix + String(id),
                                        payload: ["text": text, "channel": "telegram", "authenticated": "true", "turn_id": Self.taskPrefix + String(id)]))
    }

    // MARK: Outgoing

    private func sendAnswers(bus: SignalBus) async {
        for await message in await bus.subscribe() {
            guard message.domain == .core, let subject = message.subjectID, subject.hasPrefix("task/" + Self.taskPrefix), let owner = ownerID else { continue }
            switch message.type {
            case "core.task.started":
                _ = try? await call("sendChatAction", ["chat_id": owner, "action": "typing"], timeout: 10)
            case "core.task.finished":
                let answer = (message.payload["answer"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let ok = message.payload["success"] == "true"
                let text = ok ? answer : "Не получилось: \(message.payload["error"] ?? "ошибка")"
                if text.isEmpty || (ok && text.contains("[молчу]")) { continue }
                _ = try? await call("sendMessage", ["chat_id": owner, "text": String(text.prefix(3_900))], timeout: 20)
            default: break
            }
        }
    }

    // MARK: Plumbing

    private func announce(_ bus: SignalBus) async {
        let paired = ownerID != nil
        await bus.publish(SignalMessage(kind: .event, domain: .sensors, source: "Sensors.Telegram", type: "sensors.telegram.status",
                                        payload: ["state": paired ? "paired" : "pairing", "bot": botName, "code": paired ? "" : pairingCode]))
    }

    private func saveState() {
        var object: [String: Any] = ["offset": offset]
        if let ownerID { object["owner_id"] = ownerID }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: stateURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    private struct APIError: Error { let description: String }

    /// One Bot API call. Errors carry the description from Telegram only, never the address, so the token cannot leak into a log.
    private func call(_ method: String, _ body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else { throw APIError(description: "bad url") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        do { (data, _) = try await session.data(for: request) } catch { throw APIError(description: "network") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], (object["ok"] as? Bool) == true else {
            throw APIError(description: "api")
        }
        return object
    }
}
