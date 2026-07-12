import Foundation
import Security

/// Minimal Keychain wrapper. Every item is written as *synchronizable*, so
/// iCloud Keychain carries it to the user's other devices — end-to-end
/// encrypted, no entitlement or CloudKit container required. Two item
/// families share the same primitives:
///   - per-host secrets (password / private key / passphrase)
///   - mirrored host records: the non-secret `Host` JSON, one item per host,
///     which is how the host list itself crosses devices
///
/// Every query MUST include `kSecAttrSynchronizable` (we use `…Any`): a query
/// without the key matches only device-local items, so synced secrets would
/// silently become invisible.
enum KeychainStore {
    private static let secretService = "dev.multiplexterm.multiplex"
    private static let hostRecordService = "dev.multiplexterm.multiplex.hosts"

    enum Kind: String {
        case password
        case privateKey
        case keyPassphrase
    }

    private static func account(_ hostID: UUID, _ kind: Kind) -> String {
        "\(hostID.uuidString).\(kind.rawValue)"
    }

    // MARK: - Secrets

    static func set(_ value: String, for hostID: UUID, kind: Kind) {
        setItem(Data(value.utf8), service: secretService, account: account(hostID, kind))
    }

    static func get(for hostID: UUID, kind: Kind) -> String? {
        getItem(service: secretService, account: account(hostID, kind))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    static func delete(for hostID: UUID) {
        for kind in [Kind.password, .privateKey, .keyPassphrase] {
            deleteItem(service: secretService, account: account(hostID, kind))
        }
    }

    // MARK: - Host record mirror

    @discardableResult
    static func setHostRecord(_ record: Data, for hostID: UUID) -> Bool {
        setItem(record, service: hostRecordService, account: hostID.uuidString)
    }

    static func hostRecords() -> [Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: hostRecordService,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [Data]
        else { return [] }
        return items
    }

    static func deleteHostRecord(for hostID: UUID) {
        deleteItem(service: hostRecordService, account: hostID.uuidString)
    }

    // MARK: - Migration

    /// One-shot at launch: re-adds secrets written by pre-sync builds (which
    /// were device-local) as synchronizable items. If a synced copy already
    /// arrived from an already-migrated device, it wins and the local one is
    /// simply dropped. Cheap no-op once nothing device-local remains.
    static func migrateDeviceOnlyItems() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: secretService,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data
            else { continue }
            let status = addItem(data, service: secretService, account: account)
            guard status == errSecSuccess || status == errSecDuplicateItem else { continue }
            let deviceOnly: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: secretService,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false,
            ]
            SecItemDelete(deviceOnly as CFDictionary)
        }
    }

    // MARK: - Primitives

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }

    @discardableResult
    private static func setItem(_ data: Data, service: String, account: String) -> Bool {
        // Delete-then-add keeps the write deterministic and upgrades any
        // stray device-local copy of the same account in one shot.
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        return addItem(data, service: service, account: account) == errSecSuccess
    }

    private static func addItem(_ data: Data, service: String, account: String) -> OSStatus {
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,
            // Sync forbids the ThisDeviceOnly accessibility classes; this is
            // the standard class for credentials a network app replays.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        return SecItemAdd(add as CFDictionary, nil)
    }

    private static func getItem(service: String, account: String) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return data
    }

    private static func deleteItem(service: String, account: String) {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }
}
