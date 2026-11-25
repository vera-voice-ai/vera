import AVFoundation
import HermesBridge
import Foundation
import VeraEars
import SileroVoice

/// `Vera --hear <file.wav>`: the ears on a recording, fed in 100 ms chunks like the microphone does.
/// Prints each partial with the moment it appeared, each final phrase and the decode time — to compare engines.
enum HearCheck {
    static func run(file: URL, engines: [EarsEngine]) -> Int32 {
        guard let runtime = EarsRuntime.resolve() else { print("ушей нет: scripts/build-ears.sh"); return 1 }
        let samples: [Float]
        do { samples = try AudioInput.readFile(file) } catch { print("файл не читается: \(error)"); return 1 }
        print("файл \(file.lastPathComponent): \(String(format: "%.1f", Double(samples.count) / 16_000)) с · sherpa-onnx \(runtime.version ?? "?")")
        var rigs: [(engine: EarsEngine, listener: Listener)] = []
        var all: [(EarsEngine, HearingEvent, Double)] = []
        var fed = 0
        for engine in engines {
            do {
                let t0 = Date()
                let recognizer = try Recognizers.make(engine, runtime: runtime)
                let judge = MouthRuntime.resolve().flatMap { SmartTurn(mouth: $0) }
                let gate = try SileroGate(runtime: runtime, minSilence: judge == nil ? 0.5 : 0.3)
                print("\n— \(engine.title) · загрузка \(Int(Date().timeIntervalSince(t0) * 1000)) мс")
                let speakers = try? SpeakerEmbedder(runtime: runtime)
                let eng = engine
                let l = Listener(gate: gate, recognizer: recognizer, judge: judge, speakers: speakers) { e in
                    all.append((eng, e, Double(fed) / 16_000))
                }
                rigs.append((engine: eng, listener: l))
            } catch {
                print("\(engine.title): \(error.localizedDescription)")
            }
        }
        guard !rigs.isEmpty else { return 1 }
        // One pass, same chunks to every engine: an honest A/B on identical audio.
        let started = Date()
        var i = 0
        while i < samples.count {
            let chunk = Array(samples[i..<min(i + 1600, samples.count)])
            fed += chunk.count
            for r in rigs { r.listener.feed(chunk) }
            i += 1600
        }
        // Silence after the recording, as a speaker who stopped talking.
        for r in rigs { r.listener.feed([Float](repeating: 0, count: 16_000)); r.listener.flush() }
        for (eng, e, at) in all {
            let t = String(format: "%5.2f", at)
            let tag = eng.title
            switch e {
            case .started: print("  [\(t) с] [\(tag)] голос")
            case .partial(let text): print("  [\(t) с] [\(tag)] … \(text)")
            case .voiceprint(let v): print("  [\(t) с] [\(tag)] отпечаток голоса · \(v.count) чисел")
            case .judged(let p, let done): print("  [\(t) с] [\(tag)] Smart Turn \(String(format: "%.2f", p)) → \(done ? "конец фразы" : "жду продолжения")")
            case .final(let text, let sec, let ms, let loud): print("  [\(t) с] [\(tag)] ✓ \(text)  (фраза \(String(format: "%.1f", sec)) с, дочитала за \(ms) мс, \(String(format: "%.0f", loud.db)) дБ)")
            }
        }
        for r in rigs {
            let finals = all.compactMap { (eng, e, _) -> Int? in
                guard eng == r.engine else { return nil }
                if case .final(_, _, let ms, _) = e { return ms } else { return nil }
            }
            let avg = finals.isEmpty ? 0 : finals.reduce(0, +) / finals.count
            print("  [\(r.engine.title)] фраз: \(finals.count), средний дочит: \(avg) мс")
        }
        let total = Date().timeIntervalSince(started)
        print("  всего: \(String(format: "%.2f", total)) с на \(String(format: "%.1f", Double(samples.count) / 16_000)) с звука")
        return 0
    }
}

/// `Vera --mic-check [seconds]`: the real microphone through the ears; prints the level and what was heard.
/// A plain input, as Vera opens it (no system voice processing).
enum MicCheck {
    static func run(seconds: Double) -> Int32 {
        guard let runtime = EarsRuntime.resolve() else { print("ушей нет"); return 1 }
        let session = EarsSession(runtime: runtime)
        nonisolated(unsafe) var peak: Float = 0
        nonisolated(unsafe) var chunks = 0
        do {
            let opened = try session.start(engine: .gigaam, voiceProcessing: false, onEvent: { e in print("  \(e)") },
                                           onLevel: { l, _, _ in chunks += 1; peak = max(peak, l) })
            print("микрофон открыт (обычный вход) · подавление эха: \(opened.echoCancelling) · загрузка \(opened.loadMs) мс")
        } catch { print("не открылся: \(error.localizedDescription)"); return 1 }
        Thread.sleep(forTimeInterval: seconds)
        session.stop(finish: true)
        print("кусков \(chunks) · пик уровня \(peak)")
        return 0
    }
}

/// `Vera --mouth-check "<text>"`: Silero from the box speaks the text aloud, sentence by sentence; prints the timings.
enum MouthCheck {
    static func run(text: String) -> Int32 {
        guard let rt = MouthRuntime.resolve() else { print("рта нет: scripts/build-mouth.sh"); return 1 }
        let mouth = Mouth(runtime: rt)
        let done = DispatchSemaphore(value: 0)
        let t0 = Date()
        mouth.onSentence = { s in print(String(format: "[%5.2f с] звучит: %@", Date().timeIntervalSince(t0), s.text)) }
        mouth.onError = { e in print("ошибка: \(e)") }
        mouth.onIdle = { done.signal() }
        var chunker = SpeechChunker()
        let sentences = chunker.add(text) + chunker.flush()
        print("предложений: \(sentences.count)")
        sentences.forEach { print("  → \(SpeechText.forVoice($0))"); mouth.say($0, voice: SpeechText.forVoice($0)) }
        _ = done.wait(timeout: .now() + 120)
        print(String(format: "всё: %.2f с · %@ · %@ · голос %@", Date().timeIntervalSince(t0), rt.modelName, rt.speaker, mouth.voiceEngine))
        return 0
    }
}
