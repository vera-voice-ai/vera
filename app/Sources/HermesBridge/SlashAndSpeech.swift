import Foundation

/// What to do with a `slash.exec` / `command.dispatch` answer — the same rules as Hermes' TUI
/// (`ui-tui/src/app/createSlashHandler.ts`).
public enum SlashOutcome: Sendable, Equatable {
    /// `exec` / `plugin`: show the command's output.
    case show(String)
    /// `alias`: run `/<target>` with the same arguments instead.
    case alias(String)
    /// `send` / `skill`: send `message` to the agent; `display` is what the transcript shows (nil → the message).
    case send(message: String, display: String?, notice: String?)
    /// `prefill`: put `message` into the composer (e.g. `/undo` gives back the last message).
    case prefill(String, notice: String?)
    case problem(String)

    public static func from(_ r: JSONValue, command: String) -> SlashOutcome {
        let type = r["type"]?.string
        let output = r["output"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = r["message"]?.string
        let notice = r["notice"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let warning = r["warning"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        switch type {
        case "alias":
            guard let target = r["target"]?.string, !target.isEmpty else { return .problem("/\(command): пустой псевдоним") }
            return .alias(target)
        case "send", "skill":
            guard let m = message?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty else {
                return .problem("/\(command): пустое сообщение")
            }
            let display = r["display"]?.string.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            return .send(message: m, display: display, notice: notice)
        case "prefill":
            return .prefill(message ?? "", notice: notice)
        default:
            // exec, plugin, or an older bare `{output}`.
            let body = output.flatMap { $0.isEmpty ? nil : $0 } ?? "/\(command): нет вывода"
            return .show(warning.map { "предупреждение: \($0)\n\(body)" } ?? body)
        }
    }
}

/// Turns a streamed answer into speakable phrases: buffers deltas until a sentence ends, strips markdown and emoji.
/// Same idea as Hermes' streaming TTS (sentence by sentence, at least ~20 characters).
public struct SpeechChunker: Sendable {
    private var buffer = ""
    public let minimum: Int

    public init(minimum: Int = 20) { self.minimum = minimum }

    /// Add streamed text; returns the phrases that are complete now.
    public mutating func add(_ delta: String) -> [String] {
        buffer += delta
        var out: [String] = []
        while let cut = Self.sentenceEnd(in: buffer, minimum: minimum) {
            let phrase = String(buffer[..<cut])
            buffer = String(buffer[cut...])
            let clean = Self.speakable(phrase)
            if !clean.isEmpty { out.append(clean) }
        }
        return out
    }

    /// The rest, when the answer is complete.
    public mutating func flush() -> [String] {
        let clean = Self.speakable(buffer)
        buffer = ""
        return clean.isEmpty ? [] : [clean]
    }

    public mutating func reset() { buffer = "" }

    /// The index just after the first sentence end (`.`, `!`, `?`, newline) at or after `minimum` characters.
    static func sentenceEnd(in text: String, minimum: Int) -> String.Index? {
        var count = 0
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            count += 1
            let next = text.index(after: i)
            if count >= minimum {
                if ch == "\n" { return next }
                // An ellipsis ("...", "…") pauses a sentence, it does not end it.
                let ellipsis = ch == "." && i > text.startIndex && text[text.index(before: i)] == "."
                if ".!?".contains(ch), !ellipsis {
                    // A sentence ends only when followed by a space or a newline (not "3.14").
                    if next < text.endIndex, text[next] == " " || text[next] == "\n" { return next }
                }
            }
            i = next
        }
        return nil
    }

    /// Without markdown marks, code fences, links' URLs and emoji: what a voice should say.
    public static func speakable(_ text: String) -> String {
        var s = text
        s = s.replacing(/```[\s\S]*?```/, with: " ")
        s = s.replacing(/\[([^\]]*)\]\([^)]*\)/) { String($0.output.1) }
        s = s.replacing(/https?:\/\/\S+/, with: "ссылка")
        s = s.replacing(/[*_`#>|~]+/, with: "")
        s = String(s.unicodeScalars.filter { !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000)) })
        s = s.replacing(/\s+/, with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A spoken answer to the agent's approval question: only short, unambiguous phrases count.
public enum VoiceApproval: Sendable, Equatable {
    case once, deny

    public static func parse(_ text: String) -> VoiceApproval? {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if ["да", "разреши", "разрешаю", "можно", "давай", "да разреши", "окей", "ок"].contains(t) { return .once }
        if ["нет", "запрети", "запрещаю", "нельзя", "не надо", "отмена", "стоп"].contains(t) { return .deny }
        return nil
    }
}
