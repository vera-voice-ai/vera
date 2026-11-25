import Foundation

/// Vera's settings (every `vera.*` key: home, work and places, recording, theme, voice, route preferences…) kept also
/// as a file in Documents. Installing a new build over the old one wiped the app's preferences file on the iPhone
/// (Documents — the music, the journals — stayed), so the owner's places were gone after every delivery. At launch the
/// keys missing from UserDefaults come back from the file; every change is merged into it (a wiped key is never
/// dropped from the file).
@MainActor
enum SettingsVault {
    static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appending(path: "Settings").appending(path: "vera-settings.plist")
    private static var pending = false
    private static var observer: NSObjectProtocol?

    /// Call first thing at launch, before anything reads its settings.
    static func start() {
        restore()
        save()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { scheduleSave() }
        }
    }

    private static func stored() -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let saved = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return saved
    }

    private static func restore() {
        let saved = stored()
        let d = UserDefaults.standard
        let had = d.dictionaryRepresentation().keys.filter { $0.hasPrefix("vera.") }.count
        var back: [String] = []
        for (k, v) in saved where d.object(forKey: k) == nil { d.set(v, forKey: k); back.append(k) }
        // At every launch: how many of Vera's settings were there and what came back from the file.
        DayLog(name: "app.jsonl").write(["ev": "settings", "had": had, "inFile": saved.count, "restored": back.sorted()])
    }

    private static func scheduleSave() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { pending = false; save() } }
    }

    private static func save() {
        // Merged, never replaced: a key that vanished from the preferences (wiped) stays in the file.
        var all = stored()
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() where k.hasPrefix("vera.") { all[k] = v }
        guard !all.isEmpty, let data = try? PropertyListSerialization.data(fromPropertyList: all, format: .binary, options: 0) else { return }
        if let old = try? Data(contentsOf: url), old == data { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
