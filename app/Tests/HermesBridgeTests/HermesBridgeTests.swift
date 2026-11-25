import Foundation
import Testing
@testable import HermesBridge

@Suite struct AttachTests {
    /// The shape `hermes gateway attach --json` printed on v0.23.2 (ticket values replaced).
    static let sample = """
    {"client_code_sha":"ae2a81ccc00e9b7c06301523e5bb09608397149c","detail":null,
     "endpoint":{"api_origin":"http://127.0.0.1:49523","authority_epoch":9,
       "capabilities":["durable-admission-v1","event-replay-v1","session-authority-v1"],
       "code_sha":"ae2a81ccc00e9b7c06301523e5bb09608397149c","control_home":null,
       "instance_id":"abc","profile_id":"/Users/user/.hermes","runtime_protocol":1,"supervisor":"launchd"},
     "protocol":"hermes-gateway-v1","protocols":["hermes-gateway-v1","hermes-gateway-ticket.SECRET-TICKET"],
     "reason_code":null,"start_context":{"windows_service_session":false},"state":"ready",
     "ticket":"SECRET-TICKET","url":"ws://127.0.0.1:49523/api/ws"}
    """

    @Test func decodesReadyAttach() throws {
        let a = try GatewayAttach.decode(Data(Self.sample.utf8))
        #expect(a.isReady)
        #expect(a.endpoint?.supervisor == "launchd")
        #expect(a.endpoint?.runtimeProtocol == 1)
        #expect(a.protocols?.count == 2)
    }

    @Test func descriptionNeverShowsTheTicket() throws {
        let a = try GatewayAttach.decode(Data(Self.sample.utf8))
        #expect(!String(describing: a).contains("SECRET"))
    }

    @Test func notReadyWithoutURL() throws {
        let a = try GatewayAttach.decode(Data(#"{"state":"absent","reason_code":"no_owner"}"#.utf8))
        #expect(!a.isReady)
    }
}

@Suite struct LockTests {
    let lock = HermesLock(version: "0.23.2", tag: "v0.23.2", commit: "aaa", gatewayProtocol: "hermes-gateway-v1",
                          runtimeProtocol: 1, contractPaths: [], hooksUsed: [])

    func install(_ commit: String) -> HermesInstall {
        HermesInstall(runtime: HermesRuntime(payload: URL(filePath: "/p"), dataRoot: URL(filePath: "/d"), plugins: [:]),
                      stamp: PayloadStamp(tag: "v0.23.3", commit: commit, builtAt: nil), versionLine: nil)
    }

    @Test func verifiedWhenEverythingMatches() {
        #expect(LockStatus.check(lock: lock, install: install("aaa"), gatewayCodeSha: "aaa", gatewayProtocol: "hermes-gateway-v1") == .verified)
    }

    @Test func unverifiedNamesEachMismatch() {
        guard case .unverified(let reasons) = LockStatus.check(lock: lock, install: install("bbb"), gatewayCodeSha: "ccc",
                                                              gatewayProtocol: "hermes-gateway-v2") else {
            Issue.record("expected unverified"); return
        }
        #expect(reasons.count == 3)
    }

    @Test func unknownBeforeAnythingIsKnown() {
        #expect(LockStatus.check(lock: lock, install: nil, gatewayCodeSha: nil, gatewayProtocol: nil) == .unknown)
        #expect(LockStatus.check(lock: nil, install: install("aaa"), gatewayCodeSha: nil, gatewayProtocol: nil) == .unknown)
    }

    @Test func repositoryLockDecodes() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../hermes.lock.json").standardized
        let l = try HermesLock.load(url)
        #expect(LockStatus.check(lock: l, install: nil, gatewayCodeSha: l.commit, gatewayProtocol: l.gatewayProtocol) == .verified)
        #expect(HermesLocator.isStableTag(l.tag))
    }

    @Test func stableTagsOnly() {
        #expect(HermesLocator.isStableTag("v0.23.2"))
        #expect(!HermesLocator.isStableTag("v0.23.2+canary.20261117T064624Z"))
        #expect(!HermesLocator.isStableTag("v2026.9.24-rc"))
    }
}

@Suite struct RuntimeTests {
    let runtime = HermesRuntime(payload: URL(filePath: "/A/Vera03.app/Contents/Resources/hermes"),
                                dataRoot: URL(filePath: "/D/Vera03"), plugins: [:])

    @Test func hermesRunsOnlyOnVerasPaths() {
        let env = runtime.environment
        #expect(env["HOME"] == "/D/Vera03/home")
        #expect(env["HERMES_HOME"] == "/D/Vera03/hermes")
        #expect(env["VERA_PULSE_DIR"] == "/D/Vera03/hermes/vera-pulse")
        #expect(env["VERA_DATA"] == "/D/Vera03")
        #expect(env["PATH"] == "/A/Vera03.app/Contents/Resources/hermes/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(runtime.binary.path == "/A/Vera03.app/Contents/Resources/hermes/bin/hermes")
    }

    @Test func userEnvironmentNeverLeaks() {
        let env = runtime.environment
        let allowed: Set = ["HOME", "HERMES_HOME", "PATH", "LANG", "LC_ALL", "SHELL", "PYTHONNOUSERSITE",
                            "VERA_PULSE_DIR", "VERA_DATA", "USER", "LOGNAME", "TMPDIR"]
        #expect(Set(env.keys).isSubset(of: allowed))
        #expect(env["HERMES_RUNTIME_DIR"] == nil && env["OPENAI_API_KEY"] == nil)
    }

    @Test func defaultsStayInsideVera() {
        let r = HermesRuntime.resolve(bundle: Bundle(for: BundleToken.self), environment: [:])
        #expect(r.dataRoot.path.hasSuffix("/Library/Application Support/Vera03"))
        #expect(!r.hermesHome.path.contains("/.hermes"))
        #expect(r.payloadDescription == "внутри Vera03.app" || r.payload.path.hasSuffix("/.vera03/build/payload"))
    }
}

private final class BundleToken {}

@Suite struct PulseTests {
    @Test func parseKeepsPartialTail() {
        let data = Data("""
        {"v":1,"ts":10,"kind":"tool.start","call_id":"c1","name":"terminal"}
        not json
        {"v":1,"ts":11,"kind":"tool.end","call_id":"c1","name":"terminal","duration_ms":42,"status":"success"}
        {"v":1,"ts":12,"kind":"llm.st
        """.utf8)
        let (events, rest) = PulseFeed.parse(data)
        #expect(events.map(\.kind) == ["tool.start", "tool.end"])
        #expect(String(decoding: rest, as: UTF8.self) == #"{"v":1,"ts":12,"kind":"llm.st"#)
    }

    @Test func statsFoldToolsModelAndRunning() {
        var s = PulseStats()
        s.apply(PulseEvent(ts: 1, kind: "tool.start", session: "s", callId: "c1", name: "terminal"))
        #expect(s.running.count == 1)
        s.apply(PulseEvent(ts: 2, kind: "tool.end", session: "s", callId: "c1", name: "terminal", status: "error", durationMs: 100))
        s.apply(PulseEvent(ts: 3, kind: "llm.end", session: "s", callId: "r1", model: "m", durationMs: 1500, tokensIn: 100, tokensOut: 20))
        s.apply(PulseEvent(ts: 4, kind: "session.end", session: "s", status: "ok"))
        #expect(s.running.isEmpty)
        #expect(s.tools["terminal"]?.errors == 1)
        #expect(s.tools["terminal"]?.averageMs == 100)
        #expect(s.tokensIn == 100 && s.tokensOut == 20 && s.models["m"] == 1)
        #expect(s.sessions["s"]?.turns == 1 && s.sessions["s"]?.toolCalls == 1)
    }

    @Test func cutModelCallEndsWithItsTurn() {
        var s = PulseStats()
        // An interrupt cut the request: llm.start, then no llm.end — only the turn's end.
        s.apply(PulseEvent(ts: 1, kind: "llm.start", session: "a", callId: "a:t1:api:1", model: "m"))
        s.apply(PulseEvent(ts: 1, kind: "llm.start", session: "b", callId: "b:t1:api:1", model: "m"))
        s.apply(PulseEvent(ts: 2, kind: "session.end", session: "a", status: "interrupted"))
        #expect(s.running.count == 1)
        #expect(s.running.values.first?.session == "b")
    }

    @Test func feedReadsAppendedLines() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "vera-pulse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: PulseFeed.fileName(for: Date()))
        try Data(#"{"v":1,"ts":1,"kind":"session.open","session":"s"}"#.utf8 + [10]).write(to: file)
        let feed = PulseFeed(directory: dir)
        await feed.start(interval: .milliseconds(50))
        var iterator = feed.events.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.first?.kind == "session.open")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"v":1,"ts":2,"kind":"tool.start","name":"web"}"#.utf8 + [10]))
        try handle.close()
        let second = await iterator.next()
        #expect(second?.first?.name == "web")
        await feed.stop()
    }
}

@Suite struct GatewayFrameLimitTests {
    /// Hermes' gateway sends frames up to 384 MiB; URLSession's default (1 MiB) dropped the link on a long history.
    @Test func acceptsFramesAsLargeAsTheGateway() {
        #expect(GatewayClient.maximumFrame == 384 * 1024 * 1024)
    }
}
