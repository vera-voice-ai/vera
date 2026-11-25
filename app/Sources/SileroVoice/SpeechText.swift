import Foundation

/// Text for the Russian voice (Silero `v5_ru`): it reads only Cyrillic letters and silently drops digits, Latin and
/// most signs. Only what the answers really contain is turned into words — numbers (with the noun after them left as
/// the agent wrote it), decimals, time, signs (+ − % ° = / & №), Latin words by sound. Picked from what Vera 2's
/// normaliser did, nothing more: no currencies, dates or versions until an answer needs them.
public enum SpeechText {
    public static func forVoice(_ text: String) -> String {
        var s = text
        // time 14:30, 09:05
        s = s.replacing(/\b([01]?\d|2[0-3]):([0-5]\d)\b/) { m in
            let h = Int(m.output.1)!, mm = Int(m.output.2)!
            return " " + number(h) + " " + (mm == 0 ? "ноль ноль" : (mm < 10 ? "ноль " + number(mm) : number(mm))) + " "
        }
        // signs right before a number: +3, −5, -5 (not inside a word or a range like 3-5)
        s = s.replacing(/(^|[\s(:,;])([+−–-])\s?(\d)/) { m in
            m.output.1 + (m.output.2 == "+" ? " плюс " : " минус ") + m.output.3
        }
        // decimals 2.5 / 2,5
        s = s.replacing(/\b(\d+)[.,](\d{1,3})\b/) { m in " " + decimal(m.output.1, m.output.2) + " " }
        // percent and degrees, with the noun agreed to the number
        s = s.replacing(/(\d+)\s?%/) { m in
            let n = Int(m.output.1) ?? 0; return " " + number(n) + " " + agree(n, "процент", "процента", "процентов") + " "
        }
        s = s.replacing(/(\d+)\s?°\s?[CС]?/) { m in
            let n = Int(m.output.1) ?? 0; return " " + number(n) + " " + agree(n, "градус", "градуса", "градусов") + " "
        }
        // whole numbers: up to 6 digits as words, longer (phones, ids) digit by digit
        s = s.replacing(/\d+/) { m in
            let d = String(m.output)
            if d.count > 6 { return " " + d.map { digits[Int(String($0))!] }.joined(separator: " ") + " " }
            return " " + number(Int(d) ?? 0) + " "
        }
        // signs left alone
        for (sign, word) in [("+", " плюс "), ("=", " равно "), ("%", " процентов "), ("°", " градусов "), ("&", " и "),
                             ("№", " номер "), ("/", " слэш "), ("→", " "), ("—", " — ")] {
            s = s.replacingOccurrences(of: sign, with: word)
        }
        // Latin words by sound
        s = s.replacing(/[A-Za-z]+/) { m in " " + latin(String(m.output)) + " " }
        s = s.replacing(/\s+/, with: " ").replacing(/\s+([.,!?…:;])/) { m in String(m.output.1) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Numbers (nominative)

    private static let digits = ["ноль", "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять"]
    private static let teens = ["десять", "одиннадцать", "двенадцать", "тринадцать", "четырнадцать", "пятнадцать",
                                "шестнадцать", "семнадцать", "восемнадцать", "девятнадцать"]
    private static let tens = ["", "", "двадцать", "тридцать", "сорок", "пятьдесят", "шестьдесят", "семьдесят", "восемьдесят", "девяносто"]
    private static let hundreds = ["", "сто", "двести", "триста", "четыреста", "пятьсот", "шестьсот", "семьсот", "восемьсот", "девятьсот"]

    public static func number(_ n: Int, feminine: Bool = false) -> String {
        if n == 0 { return "ноль" }
        if n < 0 { return "минус " + number(-n, feminine: feminine) }
        var parts: [String] = []
        let groups: [(Int, (String, String, String)?, Bool)] = [
            (1_000_000_000, ("миллиард", "миллиарда", "миллиардов"), false),
            (1_000_000, ("миллион", "миллиона", "миллионов"), false),
            (1_000, ("тысяча", "тысячи", "тысяч"), true),
        ]
        var rest = n
        for (size, names, fem) in groups where rest >= size {
            let k = rest / size
            rest %= size
            parts.append(triple(k, feminine: fem))
            if let names { parts.append(agree(k, names.0, names.1, names.2)) }
        }
        if rest > 0 { parts.append(triple(rest, feminine: feminine)) }
        return parts.joined(separator: " ")
    }

    private static func triple(_ n: Int, feminine: Bool) -> String {
        var w: [String] = []
        if n >= 100 { w.append(hundreds[n / 100]) }
        let r = n % 100
        if r >= 10 && r < 20 { w.append(teens[r - 10]) }
        else {
            if r >= 20 { w.append(tens[r / 10]) }
            let u = r % 10
            if u > 0 { w.append(feminine && u == 1 ? "одна" : (feminine && u == 2 ? "две" : digits[u])) }
        }
        return w.joined(separator: " ")
    }

    /// 1 процент, 2 процента, 5 процентов, 11 процентов, 21 процент.
    public static func agree(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let r100 = n % 100, r10 = n % 10
        if r100 >= 11 && r100 <= 14 { return many }
        if r10 == 1 { return one }
        if r10 >= 2 && r10 <= 4 { return few }
        return many
    }

    /// 2.5 → «две целых пять десятых», 1.05 → «одна целая пять сотых».
    private static func decimal(_ whole: Substring, _ frac: Substring) -> String {
        let w = Int(whole) ?? 0, f = Int(frac) ?? 0
        let denom: (String, String) = switch frac.count { case 1: ("десятая", "десятых"); case 2: ("сотая", "сотых"); default: ("тысячная", "тысячных") }
        let wholeWord = (w % 10 == 1 && w % 100 != 11) ? "целая" : "целых"
        let fracWord = (f % 10 == 1 && f % 100 != 11) ? denom.0 : denom.1
        return "\(number(w, feminine: true)) \(wholeWord) \(number(f, feminine: true)) \(fracWord)"
    }

    // MARK: Latin by sound

    private static let pairs: [(String, String)] = [
        ("sch", "ш"), ("ch", "ч"), ("sh", "ш"), ("zh", "ж"), ("th", "т"), ("ph", "ф"), ("kh", "х"), ("ts", "ц"),
        ("yo", "ё"), ("yu", "ю"), ("ya", "я"), ("ee", "и"), ("oo", "у"), ("ck", "к"), ("qu", "кв"), ("x", "кс"),
    ]
    private static let letters: [Character: String] = [
        "a": "а", "b": "б", "c": "к", "d": "д", "e": "е", "f": "ф", "g": "г", "h": "х", "i": "и", "j": "дж", "k": "к",
        "l": "л", "m": "м", "n": "н", "o": "о", "p": "п", "q": "к", "r": "р", "s": "с", "t": "т", "u": "у", "v": "в",
        "w": "в", "y": "и", "z": "з",
    ]
    private static let letterNames: [Character: String] = [
        "a": "эй", "b": "би", "c": "си", "d": "ди", "e": "и", "f": "эф", "g": "джи", "h": "эйч", "i": "ай", "j": "джей",
        "k": "кей", "l": "эл", "m": "эм", "n": "эн", "o": "оу", "p": "пи", "q": "кью", "r": "ар", "s": "эс", "t": "ти",
        "u": "ю", "v": "ви", "w": "дабл ю", "x": "икс", "y": "уай", "z": "зед",
    ]

    /// «Hermes» → «хермес», «Telegram» → «телеграм»; short all-caps (API, MCP) are spelled by letter names.
    public static func latin(_ word: String) -> String {
        if word.count <= 4, word == word.uppercased(), word.count > 1 {
            return word.lowercased().compactMap { letterNames[$0] }.joined(separator: " ")
        }
        var s = word.lowercased()
        for (a, b) in pairs { s = s.replacingOccurrences(of: a, with: b) }
        return s.map { c in letters[c] ?? String(c) }.joined()
    }
}
