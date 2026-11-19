import Testing
import Core
import Scene

@MainActor @Test func aNameOrAGreetingAloneIsAnAddressNotARequest() {
    #expect(CoreAgent.isOnlyAddress("Привет, Вера"))
    #expect(CoreAgent.isOnlyAddress("Вера, привет!"))
    #expect(CoreAgent.isOnlyAddress("Вера"))
    #expect(!CoreAgent.isOnlyAddress("Привет, Вера, как дела?"))
    #expect(!CoreAgent.isOnlyAddress("Вера, прочитай файл"))
}

@MainActor @Test func aContinuationRunsOnlyWhenTheOwnerIsClearlyAboveTheBackground() {
    #expect(CoreAgent.runsAsTask(addressed: "likely", loudness: "тише обычного", aboveFloor: 1, allowPossible: false))
    #expect(CoreAgent.runsAsTask(addressed: "possible", loudness: "обычно", aboveFloor: 12, allowPossible: true))
    #expect(!CoreAgent.runsAsTask(addressed: "possible", loudness: "обычно", aboveFloor: 3, allowPossible: true))
    #expect(!CoreAgent.runsAsTask(addressed: "possible", loudness: "тише обычного", aboveFloor: 12, allowPossible: true))
    #expect(!CoreAgent.runsAsTask(addressed: "possible", loudness: "обычно", aboveFloor: 12, allowPossible: false))
    #expect(!CoreAgent.runsAsTask(addressed: "unlikely", loudness: "громче обычного", aboveFloor: 20, allowPossible: true))
}

@MainActor @Test func loudnessIsComparedWithTheOwnersUsualLevel() {
    #expect(SceneBuilder.loudnessLabel(-20, baseline: -20) == "обычно")
    #expect(SceneBuilder.loudnessLabel(-30, baseline: -20) == "тише обычного")
    #expect(SceneBuilder.loudnessLabel(-10, baseline: -20) == "громче обычного")
    #expect(SceneBuilder.loudnessLabel(-10, baseline: nil) == "нет базы")
}

@MainActor @Test func theLoudnessNoteTellsTheModelWhatQuietSpeechOnLoudBackgroundMeans() {
    let note = CoreAgent.loudnessNote("тише обычного", aboveFloor: 2.4)
    #expect(note?.contains("тише обычного") == true)
    #expect(note?.contains("на 2 дБ выше фона") == true)
    #expect(CoreAgent.loudnessNote("нет базы", aboveFloor: nil) == nil)
}
