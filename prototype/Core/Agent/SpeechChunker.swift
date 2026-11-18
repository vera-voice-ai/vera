import Foundation

/// Cuts streamed model text into sentences that can be spoken while the rest is still being written.
/// A sentence ends at `.`, `!`, `?`, `…` or a line break followed by a space or the end; very short pieces are held
/// back and joined to the next one so that "т. е." or "Да." do not become separate utterances.
public struct SpeechChunker: Sendable {
    public var minimumLength: Int
    private var buffer = ""
    /// Everything already handed out, to tell the caller what part of the final answer is left.
    public private(set) var emitted = ""

    public init(minimumLength: Int = 18) { self.minimumLength = minimumLength }

    /// Adds streamed text; returns the sentences that are now complete.
    public mutating func feed(_ text: String) -> [String] {
        buffer += text
        var out: [String] = []
        while let end = boundary() {
            let sentence = String(buffer[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[end...])
            if !sentence.isEmpty { out.append(sentence); emitted += sentence + " " }
        }
        return out
    }

    /// The tail that never got a sentence end (the model stopped without a full stop).
    public mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        guard !rest.isEmpty else { return nil }
        emitted += rest + " "
        return rest
    }

    private func boundary() -> String.Index? {
        var count = 0
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let ch = buffer[index]
            count += 1
            let next = buffer.index(after: index)
            if ".!?…\n".contains(ch), count >= minimumLength {
                // A terminator only counts when followed by whitespace (not "3.5" or "file.txt"); the final one waits for more text.
                if next < buffer.endIndex, buffer[next].isWhitespace { return next }
                if ch == "\n" { return next }
            }
            index = next
        }
        return nil
    }
}
