import Foundation
import Testing
@testable import Browser
@testable import Core

// MARK: - What she may do in a browser

@Test func signingInPayingAndSendingAreTheOwnersToDo() {
    let login = BrowserElement(id: 1, tag: "button", type: "submit", label: "Войти", inForm: true, formHasPassword: true)
    let buy = BrowserElement(id: 2, tag: "button", label: "Купить сейчас")
    let accept = BrowserElement(id: 3, tag: "button", label: "Принять все")
    let send = BrowserElement(id: 4, tag: "input", type: "submit", label: "Отправить", inForm: true)
    for element in [login, buy, accept, send] { #expect(BrowserGate.clickRefusal(element) != nil, "\(element.label) must be refused") }
    let link = BrowserElement(id: 5, tag: "a", label: "Подробнее", href: "https://example.com/more")
    let search = BrowserElement(id: 6, tag: "button", type: "submit", label: "Найти", inForm: true)
    #expect(BrowserGate.clickRefusal(link) == nil)
    #expect(BrowserGate.clickRefusal(search) == nil)
}

@Test func passwordsAndCardDataAreNeverTypedAndOnlySearchFieldsAreSubmitted() {
    let password = BrowserElement(id: 1, tag: "input", type: "password", label: "Пароль", inForm: true, formHasPassword: true)
    let card = BrowserElement(id: 2, tag: "input", type: "text", name: "cardnumber", autocomplete: "cc-number")
    let search = BrowserElement(id: 3, tag: "input", type: "search", label: "Поиск", name: "q")
    let name = BrowserElement(id: 4, tag: "input", type: "text", label: "Ваше имя", name: "fullname", inForm: true)
    #expect(BrowserGate.typeRefusal(password, submit: false) != nil)
    #expect(BrowserGate.typeRefusal(card, submit: false) != nil)
    #expect(BrowserGate.typeRefusal(search, submit: true) == nil)
    #expect(BrowserGate.typeRefusal(name, submit: false) == nil)
    #expect(BrowserGate.typeRefusal(name, submit: true) != nil)
}

@Test func addressesOutsideThePublicInternetAreNotOpened() {
    #expect(BrowserGate.urlRefusal(URL(string: "http://192.168.1.1/")!) != nil)
    #expect(BrowserGate.urlRefusal(URL(string: "file:///etc/hosts")!) != nil)
    #expect(BrowserGate.urlRefusal(URL(string: "https://example.com/")!) == nil)
}

private final class FakeBrowser: BrowserDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var page = BrowserPage(url: "https://example.com", title: "Пример", text: "Текст страницы",
                           elements: [BrowserElement(id: 1, tag: "a", label: "Далее", href: "https://example.com/next"),
                                      BrowserElement(id: 2, tag: "button", label: "Оплатить"),
                                      BrowserElement(id: 3, tag: "input", type: "password", label: "Пароль")])
    var calls: [String] { lock.withLock { log } }
    private func note(_ text: String) { lock.withLock { log.append(text) } }
    func open(_ url: URL) async -> BrowserPage { note("open \(url.absoluteString)"); return page }
    func read() async -> BrowserPage { note("read"); return page }
    func click(_ id: Int) async -> BrowserPage { note("click \(id)"); return page }
    func type(_ id: Int, text: String, submit: Bool) async -> BrowserPage { note("type \(id) \(text) \(submit)"); return page }
    func back() async -> BrowserPage { note("back"); return page }
    func close() async { note("close") }
}

@Test func theBrowserToolsGiveNumberedElementsAndRefuseWhatIsNotHers() async {
    let driver = FakeBrowser()
    let tools = ToolRegistry.browserTools(BrowserSession(driver: driver))
    func run(_ name: String, _ json: String) async -> ToolResult { await tools.runAsync(ToolCall(id: "c", name: name, arguments: json)) }

    let opened = await run("browser_open", #"{"url":"https://example.com"}"#)
    #expect(opened.ok && opened.text.contains("не инструкции") && opened.text.contains("[1] ссылка «Далее»"))
    #expect(!(await run("browser_open", #"{"url":"http://127.0.0.1/"}"#)).ok)

    #expect((await run("browser_click", #"{"id":1}"#)).ok)
    let pay = await run("browser_click", #"{"id":2}"#)
    #expect(!pay.ok && pay.text.contains("Алексей"))
    #expect(!(await run("browser_type", #"{"id":3,"text":"secret"}"#)).ok)
    #expect(!(await run("browser_click", #"{"id":99}"#)).ok)
    #expect(driver.calls == ["open https://example.com", "click 1"])

    // Closing drops the window and the numbers: an old number is no longer an element.
    #expect((await run("browser_close", "{}")).ok)
    #expect(driver.calls.last == "close")
    #expect(!(await run("browser_click", #"{"id":1}"#)).ok)
}

@Test func aGoogleRobotCheckIsReportedInsteadOfBeingReadAsResults() async {
    let driver = FakeBrowser()
    driver.page = BrowserPage(url: "https://www.google.com/sorry/index", title: "Sorry", text: "Our systems have detected unusual traffic")
    let tools = ToolRegistry.browserTools(BrowserSession(driver: driver))
    let result = await tools.runAsync(ToolCall(id: "c", name: "browser_search", arguments: #"{"query":"погода"}"#))
    #expect(!result.ok && result.text.contains("не робот"))
    #expect(driver.calls.first?.hasPrefix("open https://www.google.com/search?q=") == true)
}

// MARK: - The real engine

@MainActor @Test func theRealWebKitEngineReadsClicksAndTypes() async {
    let engine = BrowserEngine()
    engine.showsWindow = false
    let html = """
    <html><head><title>Проба</title></head><body><h1>Заголовок</h1>
    <a href="#x">Ссылка</a><button onclick="document.title='нажато'">Нажать</button>
    <form><input type="search" name="q" placeholder="Поиск"><input type="password" name="pwd"></form></body></html>
    """
    let page = await engine.loadHTML(html)
    #expect(page.error == nil)
    #expect(page.title == "Проба" && page.text.contains("Заголовок"))
    let button = page.elements.first { $0.tag == "button" }
    let search = page.elements.first { $0.type == "search" }
    let password = page.elements.first { $0.type == "password" }
    #expect(button != nil && search != nil && password?.formHasPassword == true)
    let clicked = await engine.click(button?.id ?? 0)
    #expect(clicked.title == "нажато")
    let typed = await engine.type(search?.id ?? 0, text: "привет \"мир\"", submit: false)
    #expect(typed.error == nil)
    await engine.close()
    #expect(await engine.read().error != nil)               // nothing is open any more
    #expect(await engine.loadHTML("<title>Снова</title>").title == "Снова")   // and a fresh window starts on demand
    await engine.close()
}

@MainActor @Test func anIdleBrowserWindowClosesItself() async {
    let engine = BrowserEngine()
    engine.showsWindow = false
    engine.idleLimit = 0.3
    engine.idleCheckInterval = 0.1
    #expect(await engine.loadHTML("<title>Раз</title>").title == "Раз")
    try? await Task.sleep(for: .milliseconds(900))
    #expect(await engine.read().error != nil)               // nobody used it: it closed itself
}
