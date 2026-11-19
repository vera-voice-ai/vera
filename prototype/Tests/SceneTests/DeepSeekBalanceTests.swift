import Foundation
import Testing
@testable import Core

/// Answers from a table keyed by the Authorization header, so parallel tests cannot mix their replies.
/// It also rejects any URL other than the balance endpoint, so a wrong address shows up as HTTP 404.
private final class DeepSeekStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var replies: [String: (status: Int, body: Data)] = [:]
    private static let lock = NSLock()

    static func reply(for key: String, status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        replies["Bearer " + key] = (status, Data(body.utf8))
    }

    private static func lookup(_ authorization: String) -> (status: Int, body: Data)? {
        lock.lock(); defer { lock.unlock() }
        return replies[authorization]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let onEndpoint = request.url == DeepSeekBalance.endpoint
        let (status, body) = onEndpoint ? (Self.lookup(authorization) ?? (500, Data())) : (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DeepSeekStubProtocol.self]
    return URLSession(configuration: configuration)
}

private let sample = #"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}"#

private func freshKey() -> String { "test-key-\(UUID().uuidString)" }

@Test func parsesTheSampleBalanceIntoTheFirstEntry() async {
    let key = freshKey()
    DeepSeekStubProtocol.reply(for: key, status: 200, body: sample)
    let balance = DeepSeekBalance(session: stubSession(), keyProvider: { key })
    let state = await balance.refresh()
    #expect(state == .balance(.init(amount: "110.00", currency: "USD")))
    if case .balance(let value) = state { #expect(value.display == "$110.00") }
}

@Test func missingKeyFailsWithoutTouchingTheNetwork() async {
    let balance = DeepSeekBalance(session: stubSession(), keyProvider: { nil })
    let state = await balance.refresh()
    guard case .failed(let reason) = state else { Issue.record("expected failure, got \(state)"); return }
    #expect(reason.contains("DEEPSEEK_API_KEY"))
    #expect(!reason.contains("api.deepseek.com"))
}

@Test func emptyKeyCountsAsMissing() async {
    let balance = DeepSeekBalance(session: stubSession(), keyProvider: { "" })
    if case .failed = await balance.refresh() {} else { Issue.record("empty key must not be sent") }
}

@Test func httpErrorReportsStatusAndNeverTheKey() async {
    let key = freshKey()
    DeepSeekStubProtocol.reply(for: key, status: 401, body: #"{"error":"invalid key"}"#)
    let balance = DeepSeekBalance(session: stubSession(), keyProvider: { key })
    let state = await balance.refresh()
    guard case .failed(let reason) = state else { Issue.record("expected failure, got \(state)"); return }
    #expect(reason == "DeepSeek ответил HTTP 401")
    #expect(!reason.contains(key) && !reason.contains("api.deepseek.com"))
}

@Test func malformedBodyFails() async {
    let key = freshKey()
    DeepSeekStubProtocol.reply(for: key, status: 200, body: "<html>not json</html>")
    let balance = DeepSeekBalance(session: stubSession(), keyProvider: { key })
    #expect(await balance.refresh() == .failed("неожиданный ответ DeepSeek"))
}

@Test func emptyOrNonNumericBalanceIsMalformed() async {
    let emptyKey = freshKey()
    DeepSeekStubProtocol.reply(for: emptyKey, status: 200, body: #"{"is_available":true,"balance_infos":[]}"#)
    let emptyList = DeepSeekBalance(session: stubSession(), keyProvider: { emptyKey })
    #expect(await emptyList.refresh() == .failed("неожиданный ответ DeepSeek"))

    let badKey = freshKey()
    DeepSeekStubProtocol.reply(for: badKey, status: 200, body: #"{"balance_infos":[{"currency":"USD","total_balance":"n/a"}]}"#)
    let badAmount = DeepSeekBalance(session: stubSession(), keyProvider: { badKey })
    #expect(await badAmount.refresh() == .failed("неожиданный ответ DeepSeek"))
}

@Test func parseRejectsMissingFields() {
    #expect(throws: DeepSeekBalance.ParseError.self) {
        try DeepSeekBalance.parse(Data(#"{"balance_infos":[{"currency":"USD"}]}"#.utf8))
    }
}
