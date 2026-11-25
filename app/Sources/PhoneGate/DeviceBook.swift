import CryptoKit
import Foundation

/// Phones paired with this Vera. Pairing: Vera shows a short one-time code in the QR on the «iPhone» tile; the phone
/// sends it once and gets a long random token, which it keeps in its Keychain. Vera stores only the token's SHA-256,
/// so the file (`<data>/phone-devices.json`) never holds anything that opens the door.
public final class DeviceBook {
    public struct Device: Codable, Equatable, Sendable {
        public let name: String
        let tokenHash: String
        public let pairedAt: Date
        public var lastSeen: Date?
    }

    public static let codeLifetime: TimeInterval = 300
    public static let maxWrongCodes = 5
    /// Letters that can't be mixed up when read off the screen.
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    public private(set) var devices: [Device] = []
    public private(set) var code: (value: String, until: Date)?
    private var wrong = 0
    private let store: URL?

    public init(store: URL?) {
        self.store = store
        if let store, let data = try? Data(contentsOf: store),
           let list = try? JSONDecoder.iso.decode([Device].self, from: data) { devices = list }
    }

    /// A fresh code (the old one stops working), valid for five minutes.
    @discardableResult
    public func newCode(now: Date = Date()) -> String {
        var g = SystemRandomNumberGenerator()
        let value = String((0..<8).map { _ in Self.alphabet.randomElement(using: &g)! })
        code = (value, now.addingTimeInterval(Self.codeLifetime))
        wrong = 0
        return value
    }

    /// The current code if it still works.
    public func liveCode(now: Date = Date()) -> String? {
        guard let code, code.until > now else { return nil }
        return code.value
    }

    /// A token for the device, or nil. The code works once; too many wrong tries burn it.
    public func pair(code given: String, device: String, now: Date = Date()) -> String? {
        guard let code, code.until > now else { return nil }
        guard Self.same(given.uppercased(), code.value) else {
            wrong += 1
            if wrong >= Self.maxWrongCodes { self.code = nil }
            return nil
        }
        self.code = nil
        var bytes = [UInt8](repeating: 0, count: 32)
        var g = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &g) }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let name = Self.cleanName(device)
        devices.removeAll { $0.name == name }
        devices.append(Device(name: name, tokenHash: Self.hash(token), pairedAt: now, lastSeen: now))
        save()
        return token
    }

    /// The device this token belongs to; marks it seen.
    public func check(token: String, now: Date = Date()) -> Device? {
        let h = Self.hash(token)
        guard let i = devices.firstIndex(where: { Self.same($0.tokenHash, h) }) else { return nil }
        devices[i].lastSeen = now
        save()
        return devices[i]
    }

    public func forget(_ name: String) {
        devices.removeAll { $0.name == name }
        save()
    }

    private func save() {
        guard let store, let data = try? JSONEncoder.iso.encode(devices) else { return }
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: store, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.path)
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func cleanName(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)
        return t.isEmpty ? "iPhone" : String(t)
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}
