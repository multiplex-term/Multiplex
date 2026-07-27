import Foundation
import Observation
#if DEBUG
import notify
#endif

/// Hosts persisted as JSON in Application Support — a local cache of the
/// cross-device truth. Secrets and a mirrored copy of each host record live
/// in the Keychain as synchronizable items, so iCloud Keychain moves both to
/// the user's other devices; `refreshFromCloud()` reconciles the two after
/// the first frame and whenever the deck returns to the foreground (keychain
/// sync has no change notification to subscribe to).
@MainActor
@Observable
final class HostStore {
    private(set) var hosts: [Host] = []

    private let fileURL: URL
    private let persistsDevicePreferences: Bool

    /// Host IDs this device has confirmed in the Keychain mirror. Lets the
    /// merge tell "new local host, publish it" apart from "a peer deleted
    /// this host". Device-local bookkeeping, so UserDefaults is fine.
    private var mirroredIDs: Set<UUID>
    private static let mirroredIDsKey = "MultiplexMirroredHostIDs"
    /// Device-local deck preference: host ID → session names in display
    /// order. tmux remains the source of truth for which sessions exist.
    private var sessionOrders: [UUID: [String]] = [:]
    private static let sessionOrdersKey = "MultiplexSessionOrders"
    private var isRefreshingFromCloud = false

    init(
        directory overrideDirectory: URL? = nil,
        knownMirroredIDs: Set<UUID>? = nil
    ) {
        let dir = overrideDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Multiplex", isDirectory: true)
        persistsDevicePreferences = overrideDirectory == nil
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("hosts.json")
        mirroredIDs = knownMirroredIDs ?? Set(
            (UserDefaults.standard.stringArray(forKey: Self.mirroredIDsKey) ?? [])
                .compactMap(UUID.init)
        )
        // An injected directory is a persistence test boundary; do not pull
        // unrelated device presentation preferences into that isolated store.
        sessionOrders = overrideDirectory == nil ? Self.loadSessionOrders() : [:]
        load()
        if overrideDirectory == nil {
            seedFromEnvironmentIfNeeded()
            #if DEBUG
            installDebugHostEnableHook()
            #endif
        }
    }

    func add(_ host: Host) {
        var host = host
        host.updatedAt = .now
        hosts.append(host)
        save()
        mirror(host)
    }

    func update(_ host: Host) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        var host = host
        host.updatedAt = .now
        hosts[index] = host
        save()
        mirror(host)
    }

    func remove(_ host: Host) {
        hosts.removeAll { $0.id == host.id }
        KeychainStore.delete(for: host.id)
        SSHKeyPassphraseSession.forget(for: host.id)
        KeychainStore.deleteHostRecord(for: host.id)
        mirroredIDs.remove(host.id)
        persistMirroredIDs()
        sessionOrders.removeValue(forKey: host.id)
        persistSessionOrders()
        save()
    }

    /// Host order is a deck presentation preference. The Keychain mirror
    /// stores independent host records, so reordering stays device-local in
    /// `hosts.json` while cloud refreshes continue to preserve local order.
    func moveUp(_ host: Host) {
        move(host, offset: -1)
    }

    func moveDown(_ host: Host) {
        move(host, offset: 1)
    }

    func canMoveUp(_ host: Host) -> Bool {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return false }
        return index > hosts.startIndex
    }

    func canMoveDown(_ host: Host) -> Bool {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return false }
        return index < hosts.index(before: hosts.endIndex)
    }

    func host(id: UUID) -> Host? {
        hosts.first { $0.id == id }
    }

    /// The deck's per-host power switch. Off means the app never dials this
    /// host on its own — the wall stops probing it and every automatic
    /// connect path refuses it — while the record, its secrets, and its
    /// order all survive. It rides the synced host record like any other
    /// edit, so the choice follows the user to their other devices.
    func setEnabled(_ enabled: Bool, for hostID: UUID) {
        guard let host = host(id: hostID), host.isEnabled != enabled else { return }
        var updated = host
        updated.isEnabled = enabled
        update(updated)
    }

    func agentCommandConfiguration(for hostID: UUID) -> AgentCommandConfiguration {
        host(id: hostID)?.agentCommandConfiguration
            ?? AgentCommandConfiguration()
    }

    func replaceAgentCommandConfiguration(
        _ commands: [CustomAgentCommand],
        builtInPlacements: [String: AgentCommandPlacement],
        for agent: AgentKind,
        hostID: UUID
    ) {
        guard let host = host(id: hostID) else { return }
        var configuration = agentCommandConfiguration(for: hostID)
        configuration.replace(
            commands,
            builtInPlacements: builtInPlacements,
            for: agent
        )
        guard configuration != host.agentCommandConfiguration else { return }

        var updated = host
        updated.agentCommandConfiguration = configuration
        update(updated)
    }

    // MARK: - Session presentation order

    func orderedSessions(_ sessions: [TmuxSession], for hostID: UUID) -> [TmuxSession] {
        SessionOrdering.ordered(sessions, saved: sessionOrders[hostID])
    }

    func moveSessions(
        _ sources: [String], before destination: String?, for hostID: UUID,
        available sessions: [TmuxSession]
    ) {
        let current = orderedSessions(sessions, for: hostID).map(\.name)
        setSessionOrder(
            SessionOrdering.moving(sources, before: destination, in: current),
            for: hostID,
            replacing: current
        )
    }

    func moveSession(
        _ source: String, to target: String, for hostID: UUID,
        available sessions: [TmuxSession]
    ) {
        let current = orderedSessions(sessions, for: hostID).map(\.name)
        setSessionOrder(
            SessionOrdering.moving(source, to: target, in: current),
            for: hostID,
            replacing: current
        )
    }

    /// Re-reads the mirrored records after launch and whenever the deck becomes
    /// active, so hosts added or edited on another device appear without a
    /// relaunch. Synchronizable Keychain queries can involve securityd/iCloud
    /// and are intentionally kept off the main actor's first-frame path.
    func refreshFromCloud() async {
        guard !isRefreshingFromCloud else { return }
        isRefreshingFromCloud = true
        defer { isRefreshingFromCloud = false }

        let records = await Task.detached(priority: .utility) {
            KeychainStore.migrateDeviceOnlyItems()
            return KeychainStore.hostRecords()
        }.value
        syncWithCloud(records: records)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        hosts = (try? JSONDecoder().decode([Host].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(hosts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func move(_ host: Host, offset: Int) {
        guard let source = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        let destination = source + offset
        guard hosts.indices.contains(destination) else { return }
        let moved = hosts.remove(at: source)
        hosts.insert(moved, at: destination)
        save()
    }

    private func setSessionOrder(_ order: [String], for hostID: UUID, replacing old: [String]) {
        guard order != old else { return }
        sessionOrders[hostID] = order
        persistSessionOrders()
    }

    private static func loadSessionOrders() -> [UUID: [String]] {
        guard let data = UserDefaults.standard.data(forKey: sessionOrdersKey),
              let raw = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }

        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    private func persistSessionOrders() {
        guard persistsDevicePreferences else { return }
        let raw = Dictionary(uniqueKeysWithValues: sessionOrders.map { ($0.key.uuidString, $0.value) })
        guard !raw.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.sessionOrdersKey)
            return
        }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.sessionOrdersKey)
        }
    }

    // MARK: - Cloud mirror

    private func syncWithCloud(records: [Data]) {
        let decoder = JSONDecoder()
        let cloud = records.compactMap { try? decoder.decode(Host.self, from: $0) }
        let resolution = HostSync.merge(local: hosts, cloud: cloud, mirrored: mirroredIDs)

        // Only IDs whose record verifiably sits in the mirror may be marked
        // mirrored — a failed push must read as "publish again", never as
        // "peer deleted it".
        var confirmed = Set(resolution.hosts.map(\.id))
        for host in resolution.toPush where !push(host) {
            confirmed.remove(host.id)
        }
        mirroredIDs = confirmed
        persistMirroredIDs()

        if resolution.hosts != hosts {
            hosts = resolution.hosts
            save()
        }
    }

    private func mirror(_ host: Host) {
        if push(host) {
            mirroredIDs.insert(host.id)
            persistMirroredIDs()
        }
    }

    private func push(_ host: Host) -> Bool {
        guard let record = try? JSONEncoder().encode(host) else { return false }
        return KeychainStore.setHostRecord(record, for: host.id)
    }

    private func persistMirroredIDs() {
        guard persistsDevicePreferences else { return }
        UserDefaults.standard.set(mirroredIDs.map(\.uuidString).sorted(), forKey: Self.mirroredIDsKey)
    }

    /// Dev/verification hook: `MULTIPLEX_SEED_HOST` points at a JSON file
    /// (host fields + inline secrets) that is imported once at launch.
    /// Simulator-only convenience; ignored in release builds.
    private func seedFromEnvironmentIfNeeded() {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["MULTIPLEX_SEED_HOST"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let seed = try? JSONDecoder().decode(SeedHost.self, from: data)
        else { return }

        // Idempotent: update an existing host in place so its UUID survives —
        // restored terminal scenes reference hosts by id across relaunches.
        var host = hosts.first(where: { $0.name == seed.name }) ?? Host(
            name: seed.name,
            hostname: seed.hostname,
            username: seed.username
        )
        host.hostname = seed.hostname
        host.port = seed.port ?? 22
        host.username = seed.username
        host.authMethod = seed.privateKey != nil ? .privateKey : .password
        // Absent mosh keys leave the host's current setting alone, so a
        // hand-trimmed seed doesn't silently flip transports.
        if let useMosh = seed.useMosh { host.useMosh = useMosh }
        if let path = seed.moshServerPath { host.moshServerPath = path }
        if let ports = seed.moshPorts { host.moshPorts = ports }
        // Optional so existing seeds leave the host's dirs alone; used by
        // headless checks of the Starts-in pickers.
        if let dirs = seed.workingDirs { host.workingDirs = dirs }
        // Same deal for setup scripts — headless checks of the script paths
        // seed one with a known id so the remembered choice can target it.
        if let scripts = seed.sessionScripts {
            host.sessionScripts = SessionScript.normalized(scripts)
        }
        // And for launch models — headless checks of the model pickers seed
        // known per-agent lists; an absent key leaves the host's lists alone.
        if let models = seed.agentLaunchModels {
            host.agentLaunchModels = Host.normalizedLaunchModels(models)
        }
        // And for the new-session tmux conf — headless checks seed option
        // lines and read them back host-side with show-options. An absent
        // key keeps the host's current conf (the default on first import);
        // an empty one seeds the cleared state.
        if let conf = seed.newSessionTmuxConf {
            host.newSessionTmuxConf = TmuxProbe.normalizedTmuxConf(conf) ?? ""
        }
        // A seeded `enabled: false` starts the launch with the host switched
        // off, which is how the never-dials-it promise is checked headlessly
        // (the harness sshd log stays empty). Absent leaves it alone.
        if let enabled = seed.enabled { host.isEnabled = enabled }
        if let key = seed.privateKey { KeychainStore.set(key, for: host.id, kind: .privateKey) }
        if let password = seed.password { KeychainStore.set(password, for: host.id, kind: .password) }
        if hosts.contains(where: { $0.id == host.id }) {
            update(host)
        } else {
            add(host)
        }
        #endif
    }

    #if DEBUG
    /// Headless-verification hook: the deck's Enable/Disable action can't be
    /// tapped from the CLI, so
    /// `xcrun simctl spawn <udid> notifyutil -p app.multiplexterm.multiplex.debug.hostenable`
    /// flips the first host through the exact store mutation the menu and the
    /// tile use — proving that switching off drops the probe and that
    /// switching on brings the wall back.
    private func installDebugHostEnableHook() {
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.hostenable", &token, .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let host = self.hosts.first else { return }
                self.setEnabled(!host.isEnabled, for: host.id)
            }
        }
    }

    private struct SeedHost: Decodable {
        var name: String
        var hostname: String
        var port: Int?
        var username: String
        var password: String?
        var privateKey: String?
        var enabled: Bool?
        var useMosh: Bool?
        var moshServerPath: String?
        var moshPorts: String?
        var workingDirs: [String]?
        var sessionScripts: [SessionScript]?
        var newSessionTmuxConf: String?
        var agentLaunchModels: [String: [String]]?
    }
    #endif
}
