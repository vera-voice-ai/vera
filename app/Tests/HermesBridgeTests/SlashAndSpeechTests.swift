import Foundation
import Testing
@testable import HermesBridge

@Suite struct SlashOutcomeTests {
    func obj(_ s: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)) }

    /// The live `/help` answer of 2026-11-21.
    @Test func execShowsOutput() {
        #expect(SlashOutcome.from(obj(#"{"type":"exec","output":"📖 **Hermes Commands**"}"#), command: "help") == .show("📖 **Hermes Commands**"))
    }

    @Test func emptyOutputSaysSo() {
        #expect(SlashOutcome.from(obj(#"{"type":"exec"}"#), command: "title") == .show("/title: нет вывода"))
    }

    @Test func aliasSendSkillPrefill() {
        #expect(SlashOutcome.from(obj(#"{"type":"alias","target":"new"}"#), command: "reset") == .alias("new"))
        #expect(SlashOutcome.from(obj(#"{"type":"skill","message":"BODY","display":"/plan x"}"#), command: "plan")
                == .send(message: "BODY", display: "/plan x", notice: nil))
        #expect(SlashOutcome.from(obj(#"{"type":"send","message":"hi","notice":"queued"}"#), command: "retry")
                == .send(message: "hi", display: nil, notice: "queued"))
        #expect(SlashOutcome.from(obj(#"{"type":"prefill","message":"старый текст"}"#), command: "undo") == .prefill("старый текст", notice: nil))
        #expect(SlashOutcome.from(obj(#"{"type":"send"}"#), command: "x") == .problem("/x: пустое сообщение"))
    }
}

@Suite struct SpeechChunkerTests {
    @Test func speaksWholeSentencesAsTheyComplete() {
        var c = SpeechChunker()
        #expect(c.add("Привет! Сейчас посмо").isEmpty)  // «Привет!» is under the minimum: it waits
        #expect(c.add("трю, что в папке. Там три") == ["Привет! Сейчас посмотрю, что в папке."])
        #expect(c.add(" файла") .isEmpty)
        #expect(c.flush() == ["Там три файла"])
    }

    @Test func numbersAndEllipsisDoNotCut() {
        var c = SpeechChunker()
        #expect(c.add("Число пи равно 3.14 примерно, и это...").isEmpty)
        #expect(c.add(" важно. Дальше") == ["Число пи равно 3.14 примерно, и это... важно."])
    }

    @Test func markdownLinksCodeAndEmojiAreNotSpoken() {
        #expect(SpeechChunker.speakable("**Готово** ✅ см. [доку](https://x.y) и `ls`") == "Готово см. доку и ls")
        #expect(SpeechChunker.speakable("код:\n```\nrm -rf /\n```\nвсё") == "код: всё")
        #expect(SpeechChunker.speakable("тут https://opencode.ai/console") == "тут ссылка")
    }

    @Test func voiceApprovalOnlyShortPhrases() {
        #expect(VoiceApproval.parse("Да.") == .once)
        #expect(VoiceApproval.parse("нет") == .deny)
        #expect(VoiceApproval.parse("да, но сначала покажи") == nil)
    }
}
