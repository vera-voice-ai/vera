import Foundation
import Core
import Scene

/// The fast, cheap model (DeepSeek Flash, thinking off) as the judge of "has the person finished the thought?".
/// It reads the text the way a person does, so no list of hesitation words is needed: «то есть…», «я хочу, чтобы ты»,
/// «запиши заметку про» are unfinished because of what they say. The key comes from the Keychain only (`DEEPSEEK_API_KEY`);
/// the reply is a tiny JSON, about half a second. If the call fails, the next judge in the chain answers.
struct FastBrainJudge: TurnJudge {
    static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    static let model = "deepseek-flash"
    static let instruction = "Ты определяешь, закончил ли человек свою мысль. Тебе дают последние реплики и текущую фразу, распознанную с голоса: без точной пунктуации, с ошибками, может быть обрезана. Ответь только JSON {\"complete\": true|false, \"confidence\": число от 0 до 1}. complete=false, если человек, судя по тексту, ещё продолжит: фраза оборвана, на полуслове, на союзе или вводном слове, он ищет слова или думает вслух. complete=true, если это законченный вопрос, просьба или утверждение."

    var session: URLSession = .shared
    var keyProvider: @Sendable () -> String? = { Secrets.keychainKey(named: "DEEPSEEK_API_KEY") }

    enum Failure: Error { case noKey, badAnswer }

    func judge(transcript: String, context: [String]) async throws -> (choice: String, confidence: Double, modelMilliseconds: Int) {
        guard let key = keyProvider(), !key.isEmpty else { throw Failure.noKey }
        let earlier = context.isEmpty ? "" : "Последние реплики:\n" + context.joined(separator: "\n") + "\n\n"
        let body: [String: Any] = [
            "model": Self.model,
            "messages": [["role": "system", "content": Self.instruction], ["role": "user", "content": earlier + "Текущая фраза: " + transcript]],
            "response_format": ["type": "json_object"], "thinking": ["type": "disabled"], "max_tokens": 60, "temperature": 0]
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let started = ContinuousClock.now
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.badAnswer }
        let milliseconds = { () -> Int in let d = started.duration(to: .now); return Int(d.components.seconds * 1_000 + d.components.attoseconds / 1_000_000_000_000_000) }()
        return try Self.parse(data, milliseconds: milliseconds)
    }

    /// {"choices":[{"message":{"content":"{\"complete\": false, \"confidence\": 0.9}"}}]}
    static func parse(_ data: Data, milliseconds: Int) throws -> (choice: String, confidence: Double, modelMilliseconds: Int) {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = ((object["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any],
              let content = message["content"] as? String, let inner = content.data(using: .utf8),
              let verdict = try JSONSerialization.jsonObject(with: inner) as? [String: Any],
              let complete = verdict["complete"] as? Bool else { throw Failure.badAnswer }
        let confidence = min(1, max(0, (verdict["confidence"] as? NSNumber)?.doubleValue ?? 0.5))
        return (complete ? "complete" : "continue", confidence, milliseconds)
    }
}

/// The first judge that answers wins: the fast brain, then the local Jev if the call fails (no network, no key).
struct FallbackJudge: TurnJudge {
    let judges: [any TurnJudge]

    func judge(transcript: String, context: [String]) async throws -> (choice: String, confidence: Double, modelMilliseconds: Int) {
        var last: Error = FastBrainJudge.Failure.noKey
        for judge in judges {
            do { return try await judge.judge(transcript: transcript, context: context) } catch { last = error }
        }
        throw last
    }
}
