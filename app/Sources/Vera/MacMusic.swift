import AVFoundation
import AppKit
import Observation
import VeraMusic

/// Music inside Vera on the Mac: the same library as the phone (VeraMusic) — what Hermes downloads into its workspace
/// (`soulseek/`, catalog `каталог.json`), read in place; the phone gets the same files as a mirror. Played by Vera
/// herself, so she sets its loudness: full while she waits for «Привет, Вера», low while she is active and listens, lower
/// while she speaks (`follow`). The Mac's other sound (Spotify, a browser) is not touched.
@MainActor @Observable
final class MacMusic {
    /// Loudness of the music by Vera's state (0…1): waits, listens, speaks.
    static let levels = (waiting: Float(1.0), listening: Float(0.15), speaking: Float(0.10))

    let workspace: URL
    private(set) var library = MusicLibrary([])
    var tracks: [LibraryTrack] { library.tracks }
    private(set) var current: LibraryTrack?
    private(set) var playing = false
    private(set) var problem: String?
    /// The level Vera asks for now.
    private(set) var level: Float = 1

    @ObservationIgnored private var queue = MusicQueue()
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ramp: Task<Void, Never>?

    init(dataRoot: URL) {
        workspace = dataRoot.appending(path: "hermes/workspace")
        engine.attach(player)
        Task { await scan() }
    }

    /// Re-reads Vera's catalog (it grows as Hermes downloads).
    func scan() async {
        library = MusicLibrary(await MusicSources.soulseek(workspace: workspace))
        queue.refresh(library)
        if let c = current { current = library.tracks.first { $0.url == c.url } ?? c }
    }

    func openFolder() { NSWorkspace.shared.open(workspace.appending(path: "soulseek/музыка")) }

    /// Seconds played of the current track.
    var position: Double {
        guard let file, let node = player.lastRenderTime, let t = player.playerTime(forNodeTime: node) else { return 0 }
        return Double(t.sampleTime) / file.processingFormat.sampleRate
    }

    /// Starts a track; `list` is the queue it was picked from (an album, an artist, the search, «Моё любимое»).
    func play(_ t: LibraryTrack, from list: [LibraryTrack]? = nil) {
        queue.start(t, from: list, library: library)
        generation += 1
        let gen = generation
        player.stop()
        do {
            let f = try AVAudioFile(forReading: t.url)
            file = f; current = t; problem = nil
            // Connected at the file's own rate: the mixer converts once to the output.
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: f.processingFormat)
            if !engine.isRunning { try engine.start() }
            player.volume = level
            player.scheduleFile(f, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self, gen == self.generation else { return }
                    self.next()
                }
            }
            player.play()
            playing = true
        } catch {
            problem = "не играет: \(error.localizedDescription)"
            playing = false
        }
    }

    func toggle() {
        if playing { player.pause(); playing = false; return }
        guard current != nil else {
            if let first = library.playlists.first?.tracks.first { play(first, from: library.playlists.first?.tracks) }
            return
        }
        if !engine.isRunning { try? engine.start() }
        player.play(); playing = true
    }

    func next() {
        guard let c = current else { return }
        if let t = queue.after(c) { play(t) } else { generation += 1; player.stop(); playing = false }
    }

    func previous() {
        guard let c = current else { return }
        play(queue.before(c, position: position) ?? c)
    }

    /// Vera's state → the music's loudness, ramped (down fast, back up a little slower).
    func follow(active: Bool, speaking: Bool) {
        let target = speaking ? Self.levels.speaking : active ? Self.levels.listening : Self.levels.waiting
        guard target != level else { return }
        let from = player.volume
        level = target
        ramp?.cancel()
        let seconds = target < from ? 0.25 : 0.8
        ramp = Task { [weak self] in
            let steps = 20
            for i in 1...steps {
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
                guard !Task.isCancelled, let self else { return }
                self.player.volume = from + (target - from) * Float(i) / Float(steps)
            }
        }
    }
}
