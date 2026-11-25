import Foundation

/// The owner's own values for this install — what must not live in the code: the owner's name (for the agent's
/// context) and the host of the tunnel that brings the iPhone to Vera. `<Vera data>/local.json`, written by the owner:
/// `{"owner": "Имя", "phone_tunnel": "vera.example.com"}`. Missing file or keys — the defaults: «владелец», no tunnel.
public struct LocalSettings: Equatable, Sendable {
    public var owner: String?
    public var phoneTunnel: String?

    public init(owner: String? = nil, phoneTunnel: String? = nil) {
        self.owner = owner
        self.phoneTunnel = phoneTunnel
    }

    public static func file(dataRoot: URL) -> URL { dataRoot.appending(path: "local.json") }

    public static func load(dataRoot: URL) -> LocalSettings {
        guard let data = try? Data(contentsOf: file(dataRoot: dataRoot)) else { return LocalSettings() }
        return parse(data)
    }

    public static func parse(_ data: Data) -> LocalSettings {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return LocalSettings() }
        func text(_ key: String) -> String? {
            guard let s = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        return LocalSettings(owner: text("owner"), phoneTunnel: text("phone_tunnel"))
    }
}
