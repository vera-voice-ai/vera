import AppKit
import Foundation
import HermesBridge
import Observation

/// Vera's browser on the Mac: the Chromium Hermes installed for itself (`<Vera data>/hermes/tools/chromium-*`), run by
/// Vera with its own lasting profile (logins stay — sign in to hh once) and Vera's colours (a theme extension), with the
/// DevTools port open on loopback only. Hermes drives it through `browser.cdp_url` (its `browser_exec` works in this
/// window, the owner sees it), and the owner does what is his: a CAPTCHA, the final «Откликнуться».
///
/// Open / show / hide / close — from the board (the «Браузер» column next to the music), from Hermes (plugin
/// vera-browser → `Vera --browser <action>`), and from the terminal. The state is read from the browser itself.
@MainActor @Observable
final class MacBrowser {
    nonisolated static let port = 9333
    nonisolated static var endpoint: String { "http://127.0.0.1:\(port)" }

    struct Tab: Equatable, Identifiable, Sendable { let id: String; let title: String; let url: String }

    private(set) var running = false
    private(set) var tabs: [Tab] = []
    private(set) var problem: String?

    let dataRoot: URL
    @ObservationIgnored private var timer: Timer?

    init(dataRoot: URL) { self.dataRoot = dataRoot }

    var root: URL { dataRoot.appending(path: "browser") }
    var profile: URL { root.appending(path: "profile") }
    var theme: URL { root.appending(path: "theme") }
    var startPage: URL { root.appending(path: "start.html") }

    /// The newest Chromium Hermes installed (its package manager puts it in Vera's data, inside the box).
    var app: URL? {
        let tools = dataRoot.appending(path: "hermes/tools")
        let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: tools.path)) ?? [])
            .filter { $0.hasPrefix("chromium-") }.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        for d in dirs {
            let a = tools.appending(path: "\(d)/chrome-mac-arm64/Google Chrome for Testing.app")
            if FileManager.default.fileExists(atPath: a.path) { return a }
        }
        return nil
    }

    // MARK: Watching (for the board)

    func watch() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.refresh() } }
        }
        Task { await refresh() }
    }

    func refresh() async {
        let list = await Self.pages()
        running = list != nil
        tabs = list ?? []
    }

    // MARK: Actions — one sentence back, for Hermes and the terminal

    func act(_ action: String) async -> (Bool, String) {
        switch action {
        case "open", "show":
            if await Self.pages() != nil {
                await window(state: "normal")
                Self.activate()
                await refresh()
                return (true, "браузер Веры открыт на Маке\(tabsLine)")
            }
            return await launch()
        case "hide":
            guard await Self.pages() != nil else { return (true, "браузер Веры и так закрыт") }
            await window(state: "minimized")
            return (true, "браузер Веры свёрнут — вкладки остались\(tabsLine)")
        case "close":
            guard await Self.pages() != nil else { return (true, "браузер Веры и так закрыт") }
            _ = await Self.cdpBrowser("Browser.close")
            try? await Task.sleep(for: .milliseconds(600))
            await refresh()
            return (true, "браузер Веры закрыт; вход на сайты сохранён в его профиле")
        case "status":
            await refresh()
            return (true, running ? "браузер Веры открыт\(tabsLine)" : "браузер Веры закрыт")
        default:
            return (false, "действие одно из: open, show, hide, close, status")
        }
    }

    private var tabsLine: String {
        let pages = tabs.filter { !$0.url.hasPrefix("devtools") && !$0.url.hasPrefix("chrome-extension") }
        guard !pages.isEmpty else { return "" }
        return " · вкладок \(pages.count): " + pages.prefix(5).map { $0.title.isEmpty ? $0.url : $0.title }.joined(separator: " | ")
    }

    private func launch() async -> (Bool, String) {
        guard let app else { return (false, "у Hermes ещё нет своего Chromium (он ставит его при первом обращении к браузеру)") }
        prepare()
        let args = ["-n", "-a", app.path, "--args",
                    "--user-data-dir=\(profile.path)",
                    "--remote-debugging-port=\(Self.port)", "--remote-debugging-address=127.0.0.1",
                    "--load-extension=\(theme.path)", "--disable-extensions-except=\(theme.path)",
                    "--no-first-run", "--no-default-browser-check", "--disable-sync", "--force-dark-mode",
                    // Its own key for saved logins, not the macOS keychain: launched by Hermes (its own HOME) Chromium
                    // finds no keychain and asks to «Reset To Defaults»; one key for every launch keeps the logins readable.
                    "--use-mock-keychain", "--password-store=basic",
                    "--disable-features=Translate",
                    "--window-size=1320,900", "--lang=ru", startPage.absoluteString]
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/open")
        p.arguments = args
        do { try p.run() } catch { return (false, "не запустился: \(error.localizedDescription)") }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            if await Self.pages() != nil { await refresh(); return (true, "открыла браузер Веры на Маке") }
        }
        return (false, "Chromium запустился, но не отвечает на порту \(Self.port)")
    }

    /// The profile, Vera's theme and the start page — written each launch (they are ours, small).
    private func prepare() {
        let fm = FileManager.default
        try? fm.createDirectory(at: profile, withIntermediateDirectories: true)
        try? fm.createDirectory(at: theme, withIntermediateDirectories: true)
        try? Data(Self.themeManifest.utf8).write(to: theme.appending(path: "manifest.json"))
        try? Data(Self.startHTML.utf8).write(to: startPage)
    }

    // MARK: The browser's window and tabs, over its DevTools port

    nonisolated static func pages() async -> [Tab]? {
        guard let url = URL(string: endpoint + "/json/list") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 1.5
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return list.filter { ($0["type"] as? String) == "page" }.map {
            Tab(id: $0["id"] as? String ?? "", title: $0["title"] as? String ?? "", url: $0["url"] as? String ?? "")
        }
    }

    private func window(state: String) async {
        guard let first = await Self.pages()?.first,
              let w = await Self.cdpBrowser("Browser.getWindowForTarget", ["targetId": first.id]),
              let id = (w["result"] as? [String: Any])?["windowId"] else { return }
        _ = await Self.cdpBrowser("Browser.setWindowBounds", ["windowId": id, "bounds": ["windowState": state]])
    }

    private static func activate() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.chrome.for.testing").first?
            .activate(options: [.activateAllWindows])
    }

    /// One command to the browser target (`/json/version` → its WebSocket), the answer as JSON.
    nonisolated static func cdpBrowser(_ method: String, _ params: [String: Any] = [:]) async -> [String: Any]? {
        guard let v = URL(string: endpoint + "/json/version"),
              let (data, _) = try? await URLSession.shared.data(from: v),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ws = (info["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) else { return nil }
        let task = URLSession.shared.webSocketTask(with: ws)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        guard let body = try? JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params]),
              let text = String(data: body, encoding: .utf8) else { return nil }
        do {
            try await task.send(.string(text))
            if method == "Browser.close" { return [:] }
            let message = try await task.receive()
            if case .string(let s) = message { return try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] }
        } catch { return nil }
        return nil
    }

    // MARK: Vera's look

    /// A Chromium theme in Vera's colours: the dark violet background, the pink accent.
    static let themeManifest = """
    {
      "manifest_version": 3,
      "name": "Вера",
      "version": "0.3",
      "description": "Цвета Веры",
      "theme": {
        "colors": {
          "frame": [18, 10, 24], "frame_inactive": [14, 9, 18],
          "toolbar": [30, 16, 38], "toolbar_text": [245, 220, 238], "toolbar_button_icon": [240, 33, 156],
          "tab_text": [255, 255, 255], "tab_background_text": [190, 160, 190], "tab_background_text_inactive": [150, 125, 150],
          "bookmark_text": [230, 200, 225], "button_background": [30, 16, 38],
          "omnibox_background": [22, 12, 28], "omnibox_text": [255, 235, 248],
          "ntp_background": [9, 6, 12], "ntp_text": [240, 220, 235], "ntp_link": [240, 33, 156]
        },
        "tints": { "buttons": [0.89, 0.85, 0.75] }
      }
    }
    """

    static let startHTML = """
    <!doctype html><html lang="ru"><head><meta charset="utf-8"><title>Браузер Веры</title>
    <style>
      body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;background:radial-gradient(circle at 30% 20%,#3a0f2e 0,#09060c 60%);
           color:#f5dcee;font:16px -apple-system,system-ui,sans-serif}
      .card{max-width:560px;padding:32px 36px;border-radius:18px;background:#120a18cc;border:1.5px dashed #f0219c99}
      h1{margin:0 0 6px;font-size:30px;color:#fff} h1 span{color:#f0219c}
      p{line-height:1.5;color:#d9bfd2} code{color:#f0219c}
    </style></head><body><div class="card">
      <h1><span>●</span> Браузер Веры</h1>
      <p>Здесь Вера открывает сайты и заполняет формы. Вход на сайты сохраняется — войди в hh.ru один раз.</p>
      <p>Капчу и последнюю кнопку («Откликнуться», «Отправить») нажимаешь ты. Скажи Вере «покажи браузер», «спрячь» или «закрой».</p>
    </div></body></html>
    """
}
