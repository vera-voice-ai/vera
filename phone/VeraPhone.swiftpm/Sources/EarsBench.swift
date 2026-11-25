import AVFoundation
import CSherpaPhone
import Darwin
import Foundation
import UIKit

/// `--ears-bench` (launch argument, for measuring): GigaAM on this iPhone on the CPU and through Core ML (the Neural
/// Engine where it can), on `Documents/bench.wav` — in the foreground; then the CPU again once the app is in the
/// background (inside a background task): Core ML there crashed the app (onnxruntime throws on Run). For each: model load, wall time and CPU time per decode, the
/// text (to see that it still hears the same). Results: `Documents/Sensors/ears-bench.json` and the log.
enum EarsBench {
    struct Run: Codable {
        var provider: String
        var phase: String
        var loadMs: Int
        var wallMs: [Int]
        var cpuMs: [Int]
        var audioSeconds: Double
        var text: String
        var problem: String?
    }

    static let rounds = 5

    static func runIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("--ears-bench") else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let out = docs.appending(path: "Sensors/ears-bench.json")
        DispatchQueue.global(qos: .userInitiated).async {
            var runs: [Run] = []
            func save() {
                try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                try? enc.encode(runs).write(to: out)
            }
            guard let samples = load(docs.appending(path: "bench.wav")) else {
                runs.append(Run(provider: "-", phase: "-", loadMs: 0, wallMs: [], cpuMs: [], audioSeconds: 0, text: "",
                                problem: "нет Documents/bench.wav")); save(); return
            }
            for p in ["cpu", "coreml"] { runs.append(measure(p, samples, phase: "foreground")); save() }
            NSLog("VERA-BENCH на экране готово — жду фона")
            // The same once the app is in the background (the owner or another app's launch sends it there).
            let entered = DispatchSemaphore(value: 0)
            let token = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                               object: nil, queue: nil) { _ in entered.signal() }
            guard entered.wait(timeout: .now() + 120) == .success else { NSLog("VERA-BENCH фона не дождался"); return }
            NotificationCenter.default.removeObserver(token)
            nonisolated(unsafe) var task = UIBackgroundTaskIdentifier.invalid
            DispatchQueue.main.sync { task = UIApplication.shared.beginBackgroundTask(withName: "ears-bench") }
            // CPU only: in the background Core ML does not run — onnxruntime throws and the app dies (measured 24.11).
            runs.append(measure("cpu", samples, phase: "background")); save()
            DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(task) }
            NSLog("VERA-BENCH готово: %@", out.path)
        }
    }

    /// The file as 16 kHz mono.
    static func load(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil else { return nil }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let conv = AVAudioConverter(from: buf.format, to: target),
              let res = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * 16_000 / buf.format.sampleRate) + 1024)
        else { return nil }
        var given = false
        conv.convert(to: res, error: nil) { _, st in
            if given { st.pointee = .endOfStream; return nil }
            given = true; st.pointee = .haveData; return buf
        }
        return Array(UnsafeBufferPointer(start: res.floatChannelData![0], count: Int(res.frameLength)))
    }

    /// The process's CPU time (all threads, user + system), ms. Work on the Neural Engine does not count here.
    static func cpuMs() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) * 1000 + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1000
    }

    static func measure(_ provider: String, _ samples: [Float], phase: String) -> Run {
        var run = Run(provider: provider, phase: phase, loadMs: 0, wallMs: [], cpuMs: [], audioSeconds: Double(samples.count) / 16_000, text: "")
        guard let dir = Bundle.main.url(forResource: "Models", withExtension: nil) else { run.problem = "нет Models"; return run }
        let t0 = Date()
        guard let r = vera_offline_create_nemo_ctc_on(dir.appending(path: "gigaam/model.int8.onnx").path,
                                                      dir.appending(path: "gigaam/tokens.txt").path, 64, 2, provider) else {
            run.problem = "модель не загрузилась"; return run
        }
        defer { vera_offline_destroy(r) }
        run.loadMs = Int(Date().timeIntervalSince(t0) * 1000)
        func decode() -> String {
            let p = samples.withUnsafeBufferPointer { vera_offline_decode(r, $0.baseAddress, Int32($0.count), 16_000) }
            defer { vera_sherpa_free(p) }
            return p.map { String(cString: $0) } ?? ""
        }
        _ = decode()   // warm-up: Core ML compiles its part on the first run
        for _ in 0..<rounds {
            let w0 = Date(), c0 = cpuMs()
            run.text = decode().trimmingCharacters(in: .whitespacesAndNewlines)
            run.wallMs.append(Int(Date().timeIntervalSince(w0) * 1000))
            run.cpuMs.append(Int(cpuMs() - c0))
        }
        NSLog("VERA-BENCH %@ %@: загрузка %d мс, раз %@ мс, процессор %@ мс · «%@»", provider, phase, run.loadMs,
              run.wallMs.map(String.init).joined(separator: "/"), run.cpuMs.map(String.init).joined(separator: "/"), run.text)
        return run
    }
}
