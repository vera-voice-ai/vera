import Foundation
import Security

/// Where Vera 2 finds an API key. Deliberately narrow: the process environment, then Vera 2's own Keychain item.
/// It does not scan shell files or other applications' stores.
public enum Secrets {
    public static let keychainService = "space.vera.v2"

    public static func key(named name: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[name], !value.trimmingCharacters(in: .whitespaces).isEmpty {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: name, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
