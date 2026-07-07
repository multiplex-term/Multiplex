import Foundation
import Observation

/// Hosts persisted as JSON in Application Support. Secrets go to the Keychain.
@MainActor
@Observable
final class HostStore {
    private(set) var hosts: [Host] = []

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Multiplex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("hosts.json")
        load()
        seedFromEnvironmentIfNeeded()
    }

    func add(_ host: Host) {
        hosts.append(host)
        save()
    }

    func update(_ host: Host) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index] = host
        save()
    }

    func remove(_ host: Host) {
        hosts.removeAll { $0.id == host.id }
        KeychainStore.delete(for: host.id)
        save()
    }

    func host(id: UUID) -> Host? {
        hosts.first { $0.id == id }
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

    /// Dev/verification hook: `MULTIPLEX_SEED_HOST` points at a JSON file
    /// (host fields + inline secrets) that is imported once at launch.
    /// Simulator-only convenience; ignored in release builds.
    private func seedFromEnvironmentIfNeeded() {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["MULTIPLEX_SEED_HOST"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let seed = try? JSONDecoder().decode(SeedHost.self, from: data)
        else { return }

        if let existing = hosts.first(where: { $0.name == seed.name }) {
            KeychainStore.delete(for: existing.id)
            hosts.removeAll { $0.id == existing.id }
        }
        let host = Host(
            name: seed.name,
            hostname: seed.hostname,
            port: seed.port ?? 22,
            username: seed.username,
            authMethod: seed.privateKey != nil ? .privateKey : .password
        )
        if let key = seed.privateKey { KeychainStore.set(key, for: host.id, kind: .privateKey) }
        if let password = seed.password { KeychainStore.set(password, for: host.id, kind: .password) }
        hosts.append(host)
        save()
        #endif
    }

    #if DEBUG
    private struct SeedHost: Decodable {
        var name: String
        var hostname: String
        var port: Int?
        var username: String
        var password: String?
        var privateKey: String?
    }
    #endif
}
