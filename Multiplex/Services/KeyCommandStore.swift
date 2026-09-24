import Foundation
import Observation

/// The app-wide Key Commands set — one list for every host and every
/// terminal, since a chord is keyboard-level, not host-level.
///
/// The set persists to `keycommands.json` beside `hosts.json` and mirrors to
/// one synchronizable Keychain item so iCloud Keychain carries it to the
/// user's other devices (the host list's channel; no CloudKit container).
/// The merge is `KeyCommandSync` — last writer wins by `updatedAt`.
@MainActor
@Observable
final class KeyCommandStore {
    static let shared = KeyCommandStore()

    /// A cloud refresh costs a synchronizable Keychain read; the set changes
    /// rarely, so panel opens inside this window reuse the last answer.
    nonisolated static let cloudRefreshInterval: TimeInterval = 60

    private(set) var commands: [KeyCommand]
    private(set) var updatedAt: Date

    private let fileURL: URL?
    private let usesKeychainMirror: Bool
    private var isRefreshingFromCloud = false
    private var lastCloudRefresh: Date?

    /// - Parameters:
    ///   - directory: where `keycommands.json` lives; nil keeps the set in
    ///     memory only (tests).
    ///   - usesKeychainMirror: whether saves publish to the synchronizable
    ///     Keychain item and `refreshFromCloud()` reads it. Tests keep the
    ///     device's real mirror out of the run.
    init(directory: URL? = nil, usesKeychainMirror: Bool = false) {
        fileURL = directory?.appendingPathComponent("keycommands.json")
        self.usesKeychainMirror = usesKeychainMirror
        let loaded = Self.load(from: fileURL) ?? .initial
        commands = KeyCommandSet.normalized(loaded.commands)
        updatedAt = loaded.updatedAt
    }

    private convenience init() {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Multiplex", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        self.init(directory: directory, usesKeychainMirror: true)
    }

    var set: KeyCommandSet {
        KeyCommandSet(commands: commands, updatedAt: updatedAt)
    }

    /// The editor's DONE: normalize once, stamp, persist, publish.
    func replace(_ commands: [KeyCommand], now: Date = Date()) {
        self.commands = KeyCommandSet.normalized(commands)
        updatedAt = now
        guard let data = encoded() else { return }
        persist(data)
        mirror(data)
    }

    /// Reconcile with the Keychain mirror. Synchronizable Keychain queries
    /// can involve securityd/iCloud, so the read leaves the main actor, and
    /// repeats inside `cloudRefreshInterval` are skipped unless `force`d.
    func refreshFromCloud(force: Bool = false, now: Date = Date()) async {
        guard usesKeychainMirror, !isRefreshingFromCloud else { return }
        if !force, let last = lastCloudRefresh,
           now.timeIntervalSince(last) < Self.cloudRefreshInterval {
            return
        }
        isRefreshingFromCloud = true
        defer { isRefreshingFromCloud = false }
        let record = await Task.detached(priority: .utility) {
            KeychainStore.keyCommandRecord()
        }.value
        lastCloudRefresh = now
        adopt(cloudRecord: record)
    }

    /// Apply the mirror's record through `KeyCommandSync`.
    func adopt(cloudRecord: Data?) {
        let cloud = cloudRecord.flatMap { try? Self.decoder.decode(KeyCommandSet.self, from: $0) }
        let resolution = KeyCommandSync.merge(local: set, cloud: cloud)
        if resolution.shouldPersist {
            commands = resolution.set.commands
            updatedAt = resolution.set.updatedAt
            if let data = encoded() { persist(data) }
        }
        if resolution.shouldPush, let data = encoded() {
            mirror(data)
        }
    }

    // MARK: - Persistence

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func load(from url: URL?) -> KeyCommandSet? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(KeyCommandSet.self, from: data)
    }

    private func encoded() -> Data? {
        try? Self.encoder.encode(set)
    }

    private func persist(_ data: Data) {
        guard let fileURL else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The mirror is fire-and-forget: two securityd round-trips that need
    /// not hold the DONE press on the main actor.
    private func mirror(_ data: Data) {
        guard usesKeychainMirror else { return }
        Task.detached(priority: .utility) {
            KeychainStore.setKeyCommandRecord(data)
        }
    }
}
