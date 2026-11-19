import AppKit
import Core
import Foundation
import SwiftUI
import WebKit

/// Her own browser: a real WebKit engine in a window the owner can see, use or hide. Pages run JavaScript, so Google and
/// ordinary sites work. Her browser has its own persistent profile (cookies and logins survive closing the window and
/// restarts) that is not shared with the owner's other browsers. Downloads and private addresses are refused.
@MainActor
public final class BrowserEngine: NSObject, BrowserDriving, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    /// Identifies her browser profile. Fixed, so the same logins come back every time.
    public static let profileIdentifier = UUID(uuidString: "6F1C2B7A-4D3E-4A8B-9C5D-2E7F1A0B9D43")!
    /// UserDefaults key of the owner's choice: whether her window is shown. True by default.
    public static let visibleDefaultsKey = "VeraBrowserVisible"
    private static let downloadNotice = "это загрузка файла, а не страница; файлы я не скачиваю"

    private let defaults: UserDefaults
    private let injectedStore: WKWebsiteDataStore?
    private var window: NSWindow?
    private var webView: WKWebView?
    private let chrome = BrowserChrome()
    private var notice: String?
    /// Whether the owner wants the window on screen. Hiding keeps the window and the engine working.
    public private(set) var isWindowVisible: Bool
    /// Tests turn it off: the window is then never put on screen. A hidden or shown window is not affected otherwise.
    public var showsWindow = true
    /// An open window nobody used for this long closes itself (seconds), so a page does not stay open for hours.
    public var idleLimit: TimeInterval = 600
    public var idleCheckInterval: TimeInterval = 30
    private var lastUsed = Date()
    /// Actions in progress: the window is not idle while she is working in it.
    private var operations = 0
    /// Numbers each `open`, so an older open that was replaced by a newer one can tell it was superseded.
    private var openSerial = 0
    private var idleWatch: Swift.Task<Void, Never>?
    private var eventMonitor: Any?

    /// `dataStore` is for tests only (a non-persistent store); the app uses her own persistent profile.
    public init(defaults: UserDefaults = .standard, dataStore: WKWebsiteDataStore? = nil) {
        self.defaults = defaults
        self.injectedStore = dataStore
        self.isWindowVisible = defaults.object(forKey: Self.visibleDefaultsKey) as? Bool ?? true
        super.init()
    }

    private var store: WKWebsiteDataStore { injectedStore ?? WKWebsiteDataStore(forIdentifier: Self.profileIdentifier) }

    /// For tests: a page from a string, bypassing the address rules.
    func loadHTML(_ html: String) async -> BrowserPage {
        beginOperation(); defer { endOperation() }
        let view = ensureWindow()
        view.loadHTMLString(html, baseURL: URL(string: "https://example.test/"))
        await settle()
        return await snapshot()
    }

    // MARK: BrowserDriving

    public func open(_ url: URL) async -> BrowserPage {
        beginOperation(); defer { endOperation() }
        if let refusal = BrowserGate.urlRefusal(url) { return BrowserPage(error: refusal) }
        let view = ensureWindow()
        openSerial += 1
        let mine = openSerial
        view.load(URLRequest(url: url, timeoutInterval: 20))
        await settle()
        if mine != openSerial { return BrowserPage(error: "открытие заменено другим адресом; прочитай страницу заново (browser_read)") }
        return await snapshot()
    }

    public func read() async -> BrowserPage { await snapshot() }

    public func click(_ id: Int) async -> BrowserPage {
        beginOperation(); defer { endOperation() }
        guard let view = webView else { return closedPage }
        _ = try? await view.evaluateJavaScript("(function(){var e=document.querySelector('[data-vera-id=\"\(id)\"]'); if(!e) return 'none'; e.scrollIntoView({block:'center'}); e.click(); return 'ok';})()")
        await settle()
        return await snapshot()
    }

    public func type(_ id: Int, text: String, submit: Bool) async -> BrowserPage {
        beginOperation(); defer { endOperation() }
        guard let view = webView else { return closedPage }
        let literal = Self.jsonString(text)
        let script = """
        (function(){var e=document.querySelector('[data-vera-id="\(id)"]'); if(!e) return 'none';
        e.focus(); var proto = e.tagName==='TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        var setter = Object.getOwnPropertyDescriptor(proto,'value'); if(setter&&setter.set){setter.set.call(e,\(literal));} else {e.value=\(literal);}
        e.dispatchEvent(new Event('input',{bubbles:true})); e.dispatchEvent(new Event('change',{bubbles:true}));
        if(\(submit ? "true" : "false")){ if(e.form && e.form.requestSubmit){e.form.requestSubmit();} else {e.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,bubbles:true}));} }
        return 'ok';})()
        """
        _ = try? await view.evaluateJavaScript(script)
        await settle()
        return await snapshot()
    }

    public func back() async -> BrowserPage {
        beginOperation(); defer { endOperation() }
        guard let view = webView, view.canGoBack else { return BrowserPage(error: "назад идти некуда") }
        view.goBack()
        await settle()
        return await snapshot()
    }

    /// Closes the window and drops the page. Her profile (cookies, logins) stays on disk.
    public func close() async {
        let closing = window
        discardWindow()
        closing?.close()
    }

    // MARK: Owner's controls

    /// Shows or hides her window. Hidden, the engine keeps working: the page is still loaded and operations finish.
    /// Showing it does not activate the app or take keyboard focus from the main window.
    public func setWindowVisible(_ visible: Bool) {
        isWindowVisible = visible
        defaults.set(visible, forKey: Self.visibleDefaultsKey)
        guard let window else { return }
        if visible { presentWindow() } else { window.orderOut(nil) }
    }

    /// Erases everything her profile holds, logins included. The window is closed first. Not a tool for the model.
    public func clearData() async {
        await close()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    // MARK: Window and page

    private var closedPage: BrowserPage { BrowserPage(error: "окно браузера ещё не открыто") }

    private func beginOperation() {
        operations += 1
        notice = nil
    }

    private func endOperation() {
        operations -= 1
        lastUsed = Date()
    }

    /// Drops the page and the window's state without touching her profile. Idempotent.
    private func discardWindow() {
        idleWatch?.cancel()
        idleWatch = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        window?.delegate = nil
        window = nil
        webView = nil
        notice = nil
        chrome.reset()
    }

    private func ensureWindow() -> WKWebView {
        if let webView { presentWindow(); return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 740), configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.underPageBackgroundColor = BrowserPalette.nsBackground

        let toolbar = NSHostingView(rootView: BrowserChromeView(
            chrome: chrome,
            onBack: { [weak self] in self?.ownerNavigation { if $0.canGoBack { $0.goBack() } } },
            onReload: { [weak self] in self?.ownerNavigation { $0.reload() } },
            onHide: { [weak self] in self?.setWindowVisible(false) }))
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: view.frame)
        container.addSubview(toolbar)
        container.addSubview(view)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 40),
            view.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Вера · браузер"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = BrowserPalette.nsBackground
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        self.webView = view
        lastUsed = Date()

        // The owner's own clicks, keys and scrolling in the window count as use, so the idle timer does not close a page he is reading.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.window { self.lastUsed = Date() }
            }
            return event
        }
        idleWatch = Swift.Task { @MainActor [weak self] in
            while !Swift.Task.isCancelled {
                try? await Swift.Task.sleep(for: .seconds(self?.idleCheckInterval ?? 30))
                guard let self, self.webView != nil else { return }
                if self.operations == 0, Date().timeIntervalSince(self.lastUsed) > self.idleLimit { await self.close(); return }
            }
        }
        presentWindow()
        return view
    }

    /// Puts the window on screen if the owner wants it there and it is not already visible. No activation of the app.
    private func presentWindow() {
        guard showsWindow, isWindowVisible, let window, !window.isVisible else { return }
        window.orderFront(nil)
    }

    private func ownerNavigation(_ action: (WKWebView) -> Void) {
        lastUsed = Date()
        guard let webView else { return }
        action(webView)
    }

    /// The owner closed the window with its close button: the page is dropped, the profile stays.
    public func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        discardWindow()
    }

    /// Waits for a load to start and finish, then a moment more for scripts to draw the page.
    private func settle() async {
        guard let view = webView else { return }
        try? await Task.sleep(for: .milliseconds(500))
        var waited = 0.0
        while view.isLoading, waited < 20 { try? await Task.sleep(for: .milliseconds(200)); waited += 0.2 }
        try? await Task.sleep(for: .milliseconds(900))
    }

    private func syncChrome() {
        guard let webView else { return }
        chrome.url = webView.url?.absoluteString ?? ""
        chrome.title = webView.title ?? ""
        chrome.isLoading = webView.isLoading
        chrome.canGoBack = webView.canGoBack
    }

    private static let snapshotScript = """
    (function(){
      document.querySelectorAll('[data-vera-id]').forEach(function(e){e.removeAttribute('data-vera-id');});
      var out=[], n=0;
      function visible(e){var r=e.getBoundingClientRect(), s=getComputedStyle(e); return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';}
      document.querySelectorAll('a[href],button,input:not([type=hidden]),textarea,select,[role=button]').forEach(function(e){
        if(out.length>=60||!visible(e)) return;
        n++; e.setAttribute('data-vera-id',n);
        var label=(e.innerText||e.value||e.getAttribute('aria-label')||e.placeholder||e.name||e.title||'').trim().replace(/\\s+/g,' ').slice(0,80);
        var form=e.form||null, hasPass=false;
        if(form){hasPass=!!form.querySelector('input[type=password]');}
        out.push({id:n,tag:e.tagName.toLowerCase(),type:(e.type||'').toLowerCase(),label:label,href:e.tagName==='A'?e.href:'',name:e.name||'',
                  autocomplete:(e.getAttribute('autocomplete')||'').toLowerCase(),inForm:!!form,formHasPassword:hasPass});
      });
      return JSON.stringify({title:document.title,url:location.href,text:document.body?document.body.innerText.slice(0,12000):'',els:out});
    })()
    """

    private func snapshot() async -> BrowserPage {
        lastUsed = Date()   // idle time counts from the end of what she did, not from its start
        guard let view = webView else { return closedPage }
        syncChrome()
        guard let json = (try? await view.evaluateJavaScript(Self.snapshotScript)) as? String,
              let data = json.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return BrowserPage(url: view.url?.absoluteString ?? "", error: notice ?? "страницу прочитать не удалось")
        }
        let elements = ((object["els"] as? [[String: Any]]) ?? []).map { item in
            BrowserElement(id: item["id"] as? Int ?? 0, tag: item["tag"] as? String ?? "", type: item["type"] as? String ?? "",
                           label: item["label"] as? String ?? "", href: item["href"] as? String ?? "", name: item["name"] as? String ?? "",
                           autocomplete: item["autocomplete"] as? String ?? "", inForm: item["inForm"] as? Bool ?? false,
                           formHasPassword: item["formHasPassword"] as? Bool ?? false)
        }
        return BrowserPage(url: object["url"] as? String ?? "", title: object["title"] as? String ?? "", text: object["text"] as? String ?? "",
                           elements: elements, error: notice)
    }

    /// A string as a JavaScript literal, safely quoted.
    static func jsonString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]), let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    /// A response the page cannot show, or one the server marks as a file to save, is a download: she does not save files.
    nonisolated static func isAttachment(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse,
              let disposition = http.value(forHTTPHeaderField: "Content-Disposition") else { return false }
        return disposition.lowercased().trimmingCharacters(in: .whitespaces).hasPrefix("attachment")
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, let refusal = BrowserGate.urlRefusal(url), url.scheme != "about" {
            notice = refusal
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload {
            notice = Self.downloadNotice
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType || Self.isAttachment(navigationResponse.response) {
            if navigationResponse.isForMainFrame { notice = Self.downloadNotice }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        notice = nil
        lastUsed = Date()
        syncChrome()
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { syncChrome() }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastUsed = Date()
        syncChrome()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    /// A load that fails shows the browser's own error page; say so instead of reading that page as the result.
    /// Cancelled loads (replaced by a newer address, or refused by our own policy) are not failures to report.
    private func navigationFailed(_ error: Error) {
        syncChrome()
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }   // interrupted by our policy: notice already set
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            notice = "страница не ответила за 20 секунд"
        } else {
            notice = "страница не открылась: \(error.localizedDescription)"
        }
    }

    // MARK: WKUIDelegate

    /// A link that opens a new window (target=_blank) loads in this same view instead. The gate checks that load too.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.request.url != nil { webView.load(navigationAction.request) }
        return nil
    }
}
