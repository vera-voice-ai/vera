import Foundation
import Testing
@testable import Core

private final class UsageStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply: (status: Int, body: String) = (200, "{}")
    nonisolated(unsafe) static var lastAuthorization: String?
    nonisolated(unsafe) static var lastURL: URL?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        Self.lastURL = request.url
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UsageStub.self]
    return URLSession(configuration: configuration)
}

@Suite(.serialized) struct OpenCodeUsageTests {
    private let sample = #"{"usage":{"rolling":{"status":"ok","percent":23.4,"resetsAt":"2026-11-19T10:00:00Z"},"weekly":{"status":"ok","percent":8,"resetsAt":"x"},"monthly":{"status":"ok","percent":2.6,"resetsAt":"y"}}}"#

    @Test func parsesTheThreeWindowsAndSendsTheBearerKey() async {
        UsageStub.reply = (200, sample)
        let usage = OpenCodeUsage(session: session(), keyProvider: { "test-key" })
        let state = await usage.refresh()
        guard case let .usage(value) = state else { Issue.record("expected usage, got \(state)"); return }
        #expect(value.display == "23%/8%/3%")
        #expect(UsageStub.lastAuthorization == "Bearer test-key")
        #expect(UsageStub.lastURL == OpenCodeUsage.endpoint)
    }

    @Test func missingKeyHttpErrorAndMalformedBodyFailWithoutSecrets() async {
        let none = OpenCodeUsage(session: session(), keyProvider: { nil })
        #expect(await none.refresh() == .failed("нет ключа OPENCODE_API_KEY"))
        UsageStub.reply = (401, "{}")
        let denied = await OpenCodeUsage(session: session(), keyProvider: { "secret-xyz" }).refresh()
        #expect(denied == .failed("OpenCode ответил HTTP 401"))
        UsageStub.reply = (200, #"{"usage":{}}"#)
        let broken = await OpenCodeUsage(session: session(), keyProvider: { "secret-xyz" }).refresh()
        #expect(broken == .failed("неожиданный ответ OpenCode"))
        for state in [denied, broken] { if case let .failed(text) = state { #expect(!text.contains("secret-xyz")) } }
    }
}
