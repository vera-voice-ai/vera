import AppKit
import SwiftUI
import HermesBridge
import VeraEars

/// `Vera [--mute] [--snapshot <file.png> [--wait <seconds>]]`
///   --mute       no gateway attach, no pulse journal: the bare board.
///   --snapshot   draw the board off-screen to PNG and quit (no window, no Screen Recording permission).
///   --wait       with --snapshot and without --mute: seconds of live data to gather first (default 4).
///   --snapshot-setup <file.png>  with --snapshot: also draw the «Настройка» window.
///   --snapshot-flows             with --snapshot: one dot on every line (checks the drawing only).
///   --snapshot-kit <file.png>    with --snapshot: also draw the UI kit window (VeraKit's parts in their states).
///   --say <text> --series-dir <dir> [--shots N]  with --snapshot: send one real message to the main session and
///                                snapshot the board every 0.7 s while the agent works (a live run for the record).
///   --hear <file.wav> [--engine gigaam|tone]  run the ears on a recording, as if it came from the microphone,
///                                and print what was heard and how long it took (both engines when none is given).
///   --transcribe <file>          a voice message → text on stdout with GigaAM (for Hermes' vera-ears plugin).
///   --browser <open|show|hide|close|status>   Vera's browser on the Mac, one sentence on stdout (plugin vera-browser).
let arguments = CommandLine.arguments

func argument(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

let muted = arguments.contains("--mute")

if let text = argument("--mouth-check") {
    exit(MouthCheck.run(text: text))
}
if arguments.contains("--mic-check") {
    exit(MicCheck.run(seconds: argument("--mic-check").flatMap(Double.init) ?? 5))
}
// For Hermes' vera-ears plugin: a voice message → text on stdout (GigaAM from the box). Nothing else is printed there.
if let path = argument("--transcribe") {
    guard let runtime = EarsRuntime.resolve() else { FileHandle.standardError.write(Data("ушей нет в коробке\n".utf8)); exit(2) }
    do {
        print(try VoiceNote.transcribe(file: URL(filePath: path), runtime: runtime))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1)
    }
}
if let action = argument("--browser") {
    let browser = MainActor.assumeIsolated { MacBrowser(dataRoot: HermesRuntime.resolve().dataRoot) }
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result = (false, "")
    Task { @MainActor in result = await browser.act(action); done.signal() }
    while done.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    print(result.1)
    exit(result.0 ? 0 : 1)
}
if let path = argument("--hear") {
    exit(HearCheck.run(file: URL(filePath: path), engines: argument("--engine").flatMap(EarsEngine.init(rawValue:)).map { [$0] } ?? EarsEngine.allCases))
}

if let path = argument("--snapshot") {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let wait = argument("--wait").flatMap(Double.init) ?? (muted ? 0 : 4)
    let setupPath = argument("--snapshot-setup")
    Task { @MainActor in
        let model = BoardModel(muted: muted)
        let main = ChatModel(board: model, pinnedStore: model.runtime.dataRoot.appending(path: "main-session.json"))
        let voice = VoiceModel(chat: main)
        voice.speakReplies = false   // snapshots are silent
        let phone = PhoneModel(board: model)   // drawn, its door not opened (the running app holds the port)
        model.start()
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        if !muted { await main.openPinned() }
        // Snapshot-only check of the drawing: one dot on every line, half-way. Never in a normal run.
        if arguments.contains("--snapshot-flows") {
            for c in FlowChannel.allCases { model.noteFlow(c, at: Date().addingTimeInterval(-FlowMonitor.flight / 2)) }
            DrawingSample.fill(board: model, voice: voice)
        }
        var ok = Snapshot.write(ContentView(model: model, voice: voice, phone: phone, scrollable: false), to: URL(filePath: path))
        if let musicPath = argument("--snapshot-music") {
            await voice.music.scan()
            ok = Snapshot.write(MusicWindow(music: voice.music).frame(width: 720, height: 760), to: URL(filePath: musicPath)) && ok
        }
        if let kitPath = argument("--snapshot-kit") {
            ok = Snapshot.write(KitView(scrollable: false), to: URL(filePath: kitPath)) && ok
        }
        if let setupPath {
            let setup = SetupModel(board: model)
            await setup.load()
            ok = Snapshot.write(SetupView(setup: setup, scrollable: false), to: URL(filePath: setupPath)) && ok
        }
        // A live run for the record: one real message to the main session, the board snapshotted while the agent works.
        if let say = argument("--say"), let dir = argument("--series-dir") {
            await main.openPinned()
            await main.sendText(say)
            let shots = argument("--shots").flatMap(Int.init) ?? 30
            for i in 0..<shots {
                try? await Task.sleep(for: .milliseconds(700))
                _ = Snapshot.write(ContentView(model: model, voice: voice, phone: phone, scrollable: false),
                                   to: URL(filePath: dir).appending(path: String(format: "board-%02d.png", i)))
            }
        }
        exit(ok ? 0 : 1)
    }
    app.run()
} else {
    VeraApp.main()
}

struct VeraApp: App {
    @State private var model: BoardModel
    @State private var main: ChatModel
    @State private var voice: VoiceModel
    @State private var phone: PhoneModel

    init() {
        KeepAwake.start()
        let board = BoardModel(muted: muted)
        let main = ChatModel(board: board, pinnedStore: board.runtime.dataRoot.appending(path: "main-session.json"))
        _model = State(initialValue: board)
        _main = State(initialValue: main)
        _voice = State(initialValue: VoiceModel(chat: main))
        _phone = State(initialValue: PhoneModel(board: board))
    }

    var body: some Scene {
        WindowGroup("Vera v0.3", id: "board") {
            ContentView(model: model, voice: voice, phone: phone)
                .onAppear { model.start(); if !muted { phone.start(); Task { await voice.startRecordingIfOn() } } }
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1500, height: 980)

        Window("Медиатека Веры", id: "music") { MusicWindow(music: voice.music).preferredColorScheme(.dark) }
            .defaultSize(width: 720, height: 760)
        Window("UI-кит Веры", id: "kit") {
            KitView().preferredColorScheme(.dark)
        }
        .defaultSize(width: 960, height: 900)

    }
}

/// While Vera runs, the Mac does not fall asleep on idle: Hermes, its cron and the phone sensor live on this Mac.
/// The display may still go dark; closing the lid on battery still sleeps (macOS decides that, not apps).
enum KeepAwake {
    nonisolated(unsafe) private static var activity: NSObjectProtocol?
    static func start() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                         reason: "Vera: Hermes, cron и телефон работают на этом Маке")
    }
}

@MainActor
enum Snapshot {
    static func write<V: View>(_ content: V, to url: URL) -> Bool {
        ParticleSphere.offscreen = true   // ImageRenderer cannot draw Metal: the sphere draws its particles on a Canvas
        let view = content.environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage else {
            FileHandle.standardError.write(Data("snapshot: nothing rendered\n".utf8))
            return false
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            print(url.path)
            return true
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
            return false
        }
    }
}
