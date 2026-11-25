import Foundation
import Testing
@testable import PhoneGate
import PhoneWire

@Suite struct DeviceBookTests {
    @Test func codeWorksOnceAndTokenIsChecked() {
        let book = DeviceBook(store: nil)
        let code = book.newCode()
        #expect(code.count == 8)
        let token = book.pair(code: code.lowercased(), device: "  iPhone владельца ")
        #expect(token != nil && token!.count >= 40)
        #expect(book.pair(code: code, device: "второй") == nil)   // one use
        #expect(book.check(token: token!)?.name == "iPhone владельца")
        #expect(book.check(token: token! + "x") == nil)
    }

    @Test func codeExpiresAndWrongTriesBurnIt() {
        let book = DeviceBook(store: nil)
        let now = Date()
        let code = book.newCode(now: now)
        #expect(book.pair(code: code, device: "a", now: now.addingTimeInterval(DeviceBook.codeLifetime + 1)) == nil)
        let fresh = book.newCode(now: now)
        for _ in 0..<DeviceBook.maxWrongCodes { #expect(book.pair(code: "WRONG000", device: "a", now: now) == nil) }
        #expect(book.pair(code: fresh, device: "a", now: now) == nil)
    }

    @Test func storeKeepsOnlyTheHash() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "phone-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let book = DeviceBook(store: url)
        let token = book.pair(code: book.newCode(), device: "iPhone")!
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains(token))
        #expect(DeviceBook(store: url).check(token: token)?.name == "iPhone")
    }
}

@Suite struct WireTests {
    @Test func pairingLinkRoundTrip() {
        let url = PhoneWire.tunnelURL(host: "vera.example.com")!
        #expect(url.absoluteString == "wss://vera.example.com/phone")
        #expect(PhoneWire.tunnelURL(host: " ") == nil && PhoneWire.tunnelURL(host: "https://x") == nil)
        let link = PhoneWire.pairingLink(url: url, code: "ABCD2345")
        let parsed = PhoneWire.parsePairingLink(link)
        #expect(parsed?.code == "ABCD2345")
        #expect(parsed?.url == url)
    }

    @Test func pcmRoundTrip() {
        let back = PhoneWire.floats(PhoneWire.pcm16([0, 0.5, -0.5, 1, -1]))
        #expect(back.count == 5)
        #expect(abs(back[1] - 0.5) < 0.001 && abs(back[4] + 1) < 0.001)
    }

    @Test func spokenRoundTrip() {
        #expect(PhoneWire.decode(PhoneToVera.self, PhoneWire.encode(PhoneToVera.spoken(text: "привет"))) == .spoken(text: "привет"))
    }

    @Test func messagesRoundTrip() {
        let m: [VeraToPhone] = [.paired(token: "t"), .items([PhoneItem(id: 1, role: .assistant, text: "привет", done: true)]),
                                .state(PhoneState(connected: true, running: false, thinking: nil))]
        for x in m { #expect(PhoneWire.decode(VeraToPhone.self, PhoneWire.encode(x)) == x) }
    }
}

/// A real WebSocket on loopback: pairing, a message, a refused stranger.
@Suite(.serialized) struct ServerTests {
    final class Box: @unchecked Sendable { var got: [PhoneToVera] = []; var audio = 0 }

    @MainActor @Test func pairThenSayThenHelloAgain() async throws {
        let port = UInt16.random(in: 40000...50000)
        let book = DeviceBook(store: nil)
        let server = PhoneServer(book: book, port: port)
        let box = Box()
        server.onMessage = { _, m in box.got.append(m) }
        server.onAudio = { _, d in box.audio += d.count }
        server.start()
        for _ in 0..<50 where !server.listening { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.listening)

        let url = URL(string: "ws://127.0.0.1:\(port)/phone")!
        let ws = URLSession.shared.webSocketTask(with: url)
        ws.resume()
        try await ws.send(.string(String(decoding: PhoneWire.encode(PhoneToVera.pair(code: book.newCode(), device: "test")), as: UTF8.self)))
        guard case .string(let d) = try await ws.receive(), case .paired(let token)? = PhoneWire.decode(VeraToPhone.self, Data(d.utf8)) else {
            Issue.record("no token"); return
        }
        try await ws.send(.string(String(decoding: PhoneWire.encode(PhoneToVera.say(text: "привет")), as: UTF8.self)))
        try await ws.send(.data(PhoneWire.pcm16([0.1, 0.2])))
        for _ in 0..<50 where box.got.isEmpty || box.audio == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(box.got == [.say(text: "привет")])
        #expect(box.audio == 4)
        #expect(server.peers.map(\.device) == ["test"])
        ws.cancel(with: .goingAway, reason: nil)
        for _ in 0..<50 where !server.peers.isEmpty { try await Task.sleep(for: .milliseconds(20)) }

        let again = URLSession.shared.webSocketTask(with: url)
        again.resume()
        try await again.send(.string(String(decoding: PhoneWire.encode(PhoneToVera.hello(token: token, device: "test")), as: UTF8.self)))
        for _ in 0..<100 where server.peers.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(server.peers.count == 1)
        server.broadcast(.heard(text: "ок"))
        guard case .string(let d2) = try await again.receive() else { Issue.record("no reply"); return }
        #expect(PhoneWire.decode(VeraToPhone.self, Data(d2.utf8)) == .heard(text: "ок"))
        again.cancel(with: .goingAway, reason: nil)

        let stranger = URLSession.shared.webSocketTask(with: url)
        stranger.resume()
        try await stranger.send(.string(String(decoding: PhoneWire.encode(PhoneToVera.hello(token: "nope", device: "x")), as: UTF8.self)))
        guard case .string(let d3) = try await stranger.receive(), case .refused? = PhoneWire.decode(VeraToPhone.self, Data(d3.utf8)) else {
            Issue.record("stranger not refused"); return
        }
        stranger.cancel(with: .goingAway, reason: nil)
        server.stop()
    }
}
