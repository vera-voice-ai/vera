import Foundation
import Testing
@testable import VeraEars
import VeraListen

@Suite struct BackgroundTests {
    @Test func keyPhraseAtTheStartOpens() {
        #expect(WakePhrase.match("Привет, Вера, какая погода?") == "какая погода?")
        #expect(WakePhrase.match("привет вера") == "")
        #expect(WakePhrase.match("  Привет, Вера!  ") == "")
        #expect(WakePhrase.match("ПРИВЕТ ВЕРА включи музыку") == "включи музыку")
        #expect(WakePhrase.match("«Привет, Вера», как дела") == "как дела")
    }

    @Test func keyPhraseAnywhereOpens() {
        #expect(WakePhrase.match("ну привет, Вера") == "")
        #expect(WakePhrase.match("— Слушаю. Привет, Вера. Как у тебя дела") == "Как у тебя дела")
        #expect(WakePhrase.match("так вот привет вера включи музыку") == "включи музыку")
        #expect(WakePhrase.match("Привет, Вера. Привет, Вера, стоп") == "стоп")
    }

    @Test func otherwiseDoesNot() {
        #expect(WakePhrase.match("Вера, какая погода?") == nil)
        #expect(WakePhrase.match("Привет, Верка") == nil)
        #expect(WakePhrase.match("Привет всем") == nil)
        #expect(WakePhrase.match("привет") == nil)
        #expect(WakePhrase.match("") == nil)
    }

    @Test func transcriptWritesAndReadsTheDay() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "vera-bg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = BackgroundTranscript(directory: dir)
        let now = Date().timeIntervalSince1970
        log.append(.init(ts: now, text: "чайник закипел", seconds: 1.2, db: -38, woke: false))
        log.append(.init(ts: now + 1, text: "Привет, Вера, который час", seconds: 1.5, db: -30, woke: true))
        let lines = log.read(day: Date(timeIntervalSince1970: now))
        #expect(lines.map(\.text) == ["чайник закипел", "Привет, Вера, который час"])
        #expect(lines.map(\.woke) == [false, true])
    }
}
