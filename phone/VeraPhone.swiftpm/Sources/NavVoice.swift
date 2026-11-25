import AVFoundation
import Foundation
import GoogleNavigation
import SileroVoice

/// Turn-by-turn prompts in Vera's voice. Google gives each step's manoeuvre and the distance to it; the phrase is made
/// here in Russian from the manoeuvre (not Google's text: street names in Thai or Latin letters Silero cannot read).
/// Plain mechanics, no model: a heads-up about 30 s before the step (when it is far enough), the command itself
/// a few seconds before it, «Перестраиваю маршрут» on a reroute, «Приехали» at the end.
/// The owner can return Google's own voice in Settings → «Карта Google».
@MainActor
final class NavVoice {
    /// `vera.nav.voice`: "vera" (default) or "google".
    static var useVera: Bool { (UserDefaults.standard.string(forKey: "vera.nav.voice") ?? "vera") == "vera" }

    /// Speaks a prompt: Vera's mouth when the microphone is on (the echo is handled there), else its own speaker.
    var speak: (String) -> Void = { NavSpeaker.shared.say($0) }

    private var step = -1
    private var early = false
    private var warned = false
    private var commanded = false
    private var rerouting = false
    private var started = false
    private var updates = 0
    private var loggedAt = Date.distantPast
    /// What the voice did, for the day's journal (`Documents/Sensors/<day>/nav.jsonl`, copied to the Mac at home).
    private let log = DayLog(name: "nav.jsonl")

    func reset() { step = -1; early = false; warned = false; commanded = false; rerouting = false; started = false; updates = 0 }

    private func say(_ text: String, _ why: String) {
        log.write(["ev": "say", "text": text, "why": why])
        speak(text)
    }

    /// Google's cadence, in Vera's voice: on a new long step «Продолжайте движение N»; about a kilometre before the
    /// manoeuvre «Через километр …»; ~30 s before «Через N метров …»; at the manoeuvre the command itself (with
    /// «затем …» when the next one follows right after). The words are Google's own instruction (Russian — the app
    /// speaks Russian), with the street names in Thai or Latin letters left out; the manoeuvre's own phrase when
    /// nothing Russian is left.
    func update(_ info: GMSNavigationNavInfo) {
        updates += 1
        let s = info.currentStep
        if Date().timeIntervalSince(loggedAt) > 15 {
            loggedAt = Date()
            log.write(["ev": "info", "n": updates, "state": info.navState.rawValue, "step": s?.stepNumber ?? -1,
                       "maneuver": s.map { Int($0.maneuver.rawValue) } ?? -1, "m": Self.whole(info.distanceToCurrentStepMeters),
                       "s": Self.whole(info.timeToCurrentStepSeconds), "rest": info.remainingSteps.count, "vera": Self.useVera,
                       "google": s?.fullInstructionText ?? ""])
        }
        guard Self.useVera else { return }
        if info.navState == .rerouting {
            if !rerouting { rerouting = true; say("Перестраиваю маршрут.", "reroute") }
            return
        }
        rerouting = false
        guard info.navState == .enroute, let s else { return }
        // Google sends NaN / infinity while it does not know yet (right after «Поехали»): Int(NaN) traps.
        guard info.distanceToCurrentStepMeters.isFinite else { return }
        let meters = info.distanceToCurrentStepMeters
        let seconds = info.timeToCurrentStepSeconds.isFinite ? info.timeToCurrentStepSeconds : .greatestFiniteMagnitude
        let newStep = s.stepNumber != step
        if newStep { step = s.stepNumber; early = false; warned = false; commanded = false }
        guard let text = Self.words(s) else { return }
        if !started || newStep {
            let first = !started
            started = true
            if first || meters >= 1500 {
                // The start, or a long stretch after a manoeuvre: what comes next and how far.
                var line = first ? "Поехали. " : ""
                if meters >= 1500 { line += "Продолжайте движение \(Self.distance(meters)). Затем \(Self.lower(text))." ; early = true }
                else if meters >= 120 { line += "Через \(Self.distance(meters)) \(Self.lower(text))."; early = true; warned = true }
                else { line += text + "." ; early = true; warned = true; commanded = true }
                say(line, first ? "start" : "continue")
                return
            }
        }
        if !commanded, seconds <= 8 || meters <= 40 {
            commanded = true; warned = true; early = true
            var line = text + "."
            if let next = info.remainingSteps.first, next.distanceFromPrevStepMeters < 150, let then = Self.words(next) {
                line += " Затем \(Self.lower(then))."
            }
            say(line, "now")
        } else if !warned, seconds <= 35, meters >= 120 {
            warned = true; early = true
            say("Через \(Self.distance(meters)) \(Self.lower(text)).", "ahead")
        } else if !early, meters <= 1100, meters >= 700, seconds > 40 {
            early = true
            say("Через \(Self.distance(meters)) \(Self.lower(text)).", "early")
        }
    }

    /// What to say for a step: Google's Russian instruction without non-Russian names, else the manoeuvre's phrase.
    static func words(_ s: GMSNavigationStepInfo) -> String? {
        if let g = russian(s.fullInstructionText) { return g }
        return phrase(Int(s.maneuver.rawValue), exit: s.roundaboutTurnNumber)
    }

    /// Keeps the Russian words (and numbers) of Google's instruction; drops Thai and Latin names and the prepositions
    /// they leave hanging. Nil when it is not Russian at all.
    static func russian(_ text: String) -> String? {
        let cyr = CharacterSet(charactersIn: "абвгдеёжзийклмнопрстуфхцчшщъыьэюяАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ")
        let lines = text.components(separatedBy: .newlines).joined(separator: " ")
        var words: [String] = []
        for raw in lines.split(separator: " ") {
            let w = String(raw)
            let letters = w.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            if letters.isEmpty { if w.rangeOfCharacter(from: .decimalDigits) != nil { words.append(w) }; continue }
            if letters.allSatisfy({ cyr.contains($0) }) { words.append(w) } else { words.append("|") }
        }
        // A dropped name cuts the sentence: «на», «по», «в сторону» before it go too.
        let hanging: Set<String> = ["на", "по", "в", "во", "к", "ко", "с", "со", "до", "через", "сторону", "направлении", "улицу", "улице", "шоссе", "дорогу", "дороге", "и", "/", "-", "—"]
        var out: [String] = []
        for w in words {
            if w == "|" {
                while let last = out.last, hanging.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) { out.removeLast() }
                continue
            }
            out.append(w)
        }
        while let last = out.last, hanging.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) { out.removeLast() }
        let joined = out.joined(separator: " ").trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        guard joined.unicodeScalars.contains(where: { cyr.contains($0) }), joined.count >= 4 else { return nil }
        return joined
    }

    func arrived() { if Self.useVera { say("Приехали.", "arrived") } }

    // MARK: Words

    /// The manoeuvre as a Russian command; nil for those not worth saying (depart, name change, unknown).
    static func phrase(_ m: Int, exit: Int) -> String? {
        switch m {
        case 2: "Вы у цели"
        case 3: "Цель слева"
        case 4: "Цель справа"
        case 5: "Прямо"
        case 6: "Поверните налево"
        case 7: "Поверните направо"
        case 8, 17, 19, 24, 35: "Держитесь левее"
        case 9, 18, 20, 25, 36: "Держитесь правее"
        case 10, 26, 37: "Плавно налево"
        case 11, 27, 38: "Плавно направо"
        case 12, 28, 39: "Резко налево"
        case 13, 29, 40: "Резко направо"
        case 14, 15, 30, 31, 41, 42: "Развернитесь"
        case 16: "Перестройтесь"
        case 21: "Заезжайте на эстакаду"
        case 22: "Налево на эстакаду"
        case 23: "Направо на эстакаду"
        case 32: "Съезд"
        case 33: "Съезд налево"
        case 34: "Съезд направо"
        case 43...60: roundabout(exit)
        case 61, 62: "Съезжайте с кольца"
        case 63, 64: "Паром"
        default: nil
        }
    }

    static func roundabout(_ exit: Int) -> String {
        let n = ["", "первый", "второй", "третий", "четвёртый", "пятый", "шестой", "седьмой"]
        return exit > 0 && exit < n.count ? "На кольце \(n[exit]) съезд" : "На кольце"
    }

    static func lower(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }

    /// Distance in words (Silero reads words better than digits): rounded the way a person says it.
    /// A Double as Int for the journal; -1 for NaN or infinity (Int() of those traps).
    static func whole(_ x: Double) -> Int { x.isFinite ? Int(max(-1e9, min(1e9, x))) : -1 }

    static func distance(_ m: Double) -> String {
        guard m.isFinite, m >= 0 else { return "немного" }
        if m < 1000 {
            let r = m < 300 ? (m / 50).rounded() * 50 : (m / 100).rounded() * 100
            let words = [50: "пятьдесят", 100: "сто", 150: "сто пятьдесят", 200: "двести", 250: "двести пятьдесят",
                         300: "триста", 400: "четыреста", 500: "пятьсот", 600: "шестьсот", 700: "семьсот",
                         800: "восемьсот", 900: "девятьсот"]
            if let w = words[Int(r)] { return "\(w) метров" }
            return "километр"
        }
        let km = (m / 500).rounded() / 2
        switch km {
        case ..<1.25: return "километр"
        case ..<1.75: return "полтора километра"
        case ..<2.5: return "два километра"
        case ..<3.5: return "три километра"
        case ..<4.5: return "четыре километра"
        default: return "\(Int(km.rounded())) километров"
        }
    }
}

/// Vera's voice for navigation while the microphone is off: Silero (or the system voice) into its own player, mixed
/// with the music — the music is not dimmed.
@MainActor
final class NavSpeaker {
    static let shared = NavSpeaker()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SileroVoice.sampleRate), channels: 1, interleaved: false)!
    private let system = AVSpeechSynthesizer()

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func say(_ text: String) {
        guard Mouth.usesSilero else {
            ensureSession()
            let u = AVSpeechUtterance(string: text)
            u.voice = Mouth.voice
            system.speak(u)
            return
        }
        PhoneSilero.shared.synthesize(text) { result in
            guard case .success(let samples) = result, !samples.isEmpty else { return }
            Task { @MainActor in NavSpeaker.shared.play(samples) }
        }
    }

    private func play(_ samples: [Float]) {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        ensureSession()
        if !engine.isRunning { do { try engine.start() } catch { NSLog("VERA-NAV голос: %@", error.localizedDescription); return } }
        player.scheduleBuffer(pcm)
        if !player.isPlaying { player.play() }
    }

    /// Plays alongside whatever the app plays: the music's session stays as it is; with nothing playing — playback,
    /// mixed with other apps.
    private func ensureSession() {
        let s = AVAudioSession.sharedInstance()
        guard s.category != .playback, s.category != .playAndRecord else { return }
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setActive(true)
    }
}
