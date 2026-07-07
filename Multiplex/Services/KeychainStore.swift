import Foundation
import Security

/// Minimal Keychain wrapper for per-host secrets (passwords, private keys).
enum KeychainStore {
    private static let service = "tools.bricks.multiplex"

    enum Kind: String {
        case password
        case privateKey
        case keyPassphrase
    }

    private static func account(_ hostID: UUID, _ kind: Kind) -> String {
        "\(hostID.uuidString).\(kind.rawValue)"
    }

    static func set(_ value: String, for hostID: UUID, kind: Kind) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(hostID, kind),
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func get(for hostID: UUID, kind: Kind) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(hostID, kind),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for hostID: UUID) {
        for kind in [Kind.password, .privateKey, .keyPassphrase] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account(hostID, kind),
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
