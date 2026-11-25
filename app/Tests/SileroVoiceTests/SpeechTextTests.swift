import Testing
@testable import SileroVoice

@Suite struct SpeechTextTests {
    @Test func numbersBecomeWords() {
        #expect(SpeechText.number(25) == "двадцать пять")
        #expect(SpeechText.number(2021) == "две тысячи двадцать один")
        #expect(SpeechText.number(1_500_000) == "один миллион пятьсот тысяч")
        #expect(SpeechText.forVoice("Сейчас 25 градусов") == "Сейчас двадцать пять градусов")
    }

    @Test func signsPercentDegreesAndDecimals() {
        #expect(SpeechText.forVoice("плюс: +3, минус: -5") == "плюс: плюс три, минус: минус пять")
        #expect(SpeechText.forVoice("скидка 21%") == "скидка двадцать один процент")
        #expect(SpeechText.forVoice("на улице 30°C") == "на улице тридцать градусов")
        #expect(SpeechText.forVoice("скорость 1.05") == "скорость одна целая пять сотых")
        #expect(SpeechText.forVoice("2 + 2 = 4") == "два плюс два равно четыре")
    }

    @Test func timeAndLongNumbers() {
        #expect(SpeechText.forVoice("в 14:30") == "в четырнадцать тридцать")
        #expect(SpeechText.forVoice("в 09:05") == "в девять ноль пять")
        #expect(SpeechText.forVoice("номер 89161234567") == "номер восемь девять один шесть один два три четыре пять шесть семь")
    }

    @Test func latinIsSpokenBySound() {
        #expect(SpeechText.forVoice("через Telegram") == "через телеграм")
        #expect(SpeechText.forVoice("Hermes и API") == "хермес и эй пи ай")
        #expect(SpeechText.forVoice("/Users/alex") == "слэш усерс слэш алекс")
    }
}
