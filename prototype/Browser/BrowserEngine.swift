import AppKit
import Core
import Foundation
import WebKit

/// Her own browser: a real WebKit engine in a window the owner can see and use. Pages run JavaScript, so Google and
/// ordinary sites work. The data store is not persistent: no cookies or logins survive a restart, and none are shared
/// with the owner's own browsers. Downloads and private addresses are refused.
@MainActor
public final class BrowserEngine: NSObject, BrowserDriving, WKNavigationDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var notice: String?
    /// Whether the window is brought to the front when it is used. Tests turn it off.
    public var showsWindow = true

    public override init() { super.init() }

    /// For tests: a page from a string, bypassing the address rules.
    func loadHTML(_ html: String) async -> BrowserPage {
        let view = ensureWindow()
        view.loadHTMLString(html, baseURL: URL(string: "https://example.test/"))
        await settle()
        return await snapshot()
    }

    // MARK: BrowserDriving

    public func open(_ url: URL) async -> BrowserPage {
        if let refusal = BrowserGate.urlRefusal(url) { return BrowserPage(error: refusal) }
        let view = ensureWindow()
        notice = nil
        view.load(URLRequest(url: url, timeoutInterval: 20))
        await settle()
        return await snapshot()
    }

    public func read() async -> BrowserPage { await snapshot() }

    public func click(_ id: Int) async -> BrowserPage {
        guard let view = webView else { return BrowserPage(error: "окно браузера ещё не открыто") }
        _ = try? await view.evaluateJavaScript("(function(){var e=document.querySelector('[data-vera-id=\"\(id)\"]'); if(!e) return 'none'; e.scrollIntoView({block:'center'}); e.click(); return 'ok';})()")
        await settle()
        return await snapshot()
    }

    public func type(_ id: Int, text: String, submit: Bool) async -> BrowserPage {
        guard let view = webView else { return BrowserPage(error: "окно браузера ещё не открыто") }
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
        guard let view = webView, view.canGoBack else { return BrowserPage(error: "назад идти некуда") }
        view.goBack()
        await settle()
        return await snapshot()
    }

    public func close() async {
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        window?.close()
        window = nil
        webView = nil
        notice = nil
    }

    // MARK: Window and page

    private func ensureWindow() -> WKWebView {
        if let webView { if showsWindow { window?.orderFrontRegardless() }; return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 780), configuration: configuration)
        view.navigationDelegate = self
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Вера · браузер"
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.center()
        if showsWindow { window.orderFrontRegardless() }
        self.window = window
        self.webView = view
        return view
    }

    /// Waits for a load to start and finish, then a moment more for scripts to draw the page.
    private func settle() async {
        guard let view = webView else { return }
        try? await Task.sleep(for: .milliseconds(500))
        var waited = 0.0
        while view.isLoading, waited < 20 { try? await Task.sleep(for: .milliseconds(200)); waited += 0.2 }
        try? await Task.sleep(for: .milliseconds(900))
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
        guard let view = webView else { return BrowserPage(error: "окно браузера ещё не открыто") }
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

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, let refusal = BrowserGate.urlRefusal(url), url.scheme != "about" {
            notice = refusal
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            notice = "это загрузка файла, а не страница; файлы я не скачиваю"
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
