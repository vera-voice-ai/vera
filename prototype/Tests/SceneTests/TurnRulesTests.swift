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

@MainActor @Test func aKnownVoiceRunsInReadyAndLoudnessIsNotACondition() {
    #expect(CoreAgent.runsAsTask(addressed: "likely"))
    #expect(CoreAgent.runsAsTask(addressed: "possible"))
    #expect(!CoreAgent.runsAsTask(addressed: "unlikely"))
    #expect(!CoreAgent.runsAsTask(addressed: ""))
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
    // A loud turn gets the facts without the warning.
    let loud = CoreAgent.loudnessNote("громче обычного", aboveFloor: 11)
    #expect(loud?.contains("на 11 дБ выше фона") == true)
    #expect(loud?.contains("фон, а не обращение") == false)
}

@MainActor @Test func theBackgroundDeltaIsDroppedWhenTheFloorIsDigitalSilence() {
    #expect(SceneBuilder.aboveFloor(-30, floor: -100) == nil)
    #expect(SceneBuilder.aboveFloor(-30, floor: nil) == nil)
    #expect(SceneBuilder.aboveFloor(-30, floor: -50) == 20)
}

@MainActor @Test func theModelIsToldWhichModeItIsInSoItDoesNotMakeUpItsOwnRules() {
    let ready = CoreAgent.modeNote(.ready, readyWindow: 20, workingWindow: 600)
    #expect(ready?.contains("Готовность") == true && ready?.contains("20 с") == true)
    let working = CoreAgent.modeNote(.working, readyWindow: 20, workingWindow: 600)
    #expect(working?.contains("10 мин") == true)
    #expect(CoreAgent.modeNote(.silent, readyWindow: 20, workingWindow: 600) == nil)
}
