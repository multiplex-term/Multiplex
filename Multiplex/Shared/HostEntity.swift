import AppIntents
import Foundation

/// One host-scoped setup-script choice exposed to the Shortcuts process.
/// Only stable identity + display name cross this boundary; the script body
/// stays in the app's synced Host model and is resolved immediately before
/// session creation.
struct ShortcutSessionScript: Identifiable, Hashable, Sendable {
    var id: UUID
    var displayName: String
}

/// The host as Shortcuts and widget configuration see it: id + labels, no
/// secrets. The app-side query also carries configured working directories
/// and setup-script labels so dependent Shortcut parameters can offer them;
/// the widget fallback does not need or publish either. Launch-model lists
/// ride BOTH sides — the widget's own Model setting needs a picker in the
/// widget process, and model names are ordinary labels, not secrets. Both
/// processes share this type and query.
struct HostEntity: AppEntity, Identifiable, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Multiplex Host"
    static let defaultQuery = HostEntityQuery()

    var id: UUID
    var name: String
    var address: String
    var workingDirs: [String] = []
    var sessionScripts: [ShortcutSessionScript] = []
    /// Pre-configured launch models per agent, keyed by the agent raw value
    /// (`AgentChoice`/`AgentKind` mirror one-to-one, unit-tested).
    var agentModels: [String: [String]] = [:]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(address)")
    }
}

/// App process: `live` reads the in-memory `HostStore` (registered at
/// launch), so the picker is fresh even before the first App Group publish.
/// Widget process: never sets `live` and falls back to the published
/// snapshot. Empty until the app has run once with the group entitlement.
enum HostEntityProvider {
    @MainActor static var live: (() -> [HostEntity])?

    static func all() async -> [HostEntity] {
        if let entities = await liveEntities() { return entities }
        return (SharedStateStore.load()?.hosts ?? []).map {
            HostEntity(
                id: $0.id, name: $0.name, address: $0.address,
                agentModels: $0.agentModels ?? [:]
            )
        }
    }

    @MainActor private static func liveEntities() -> [HostEntity]? {
        live?()
    }
}

struct HostEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [HostEntity] {
        let all = await HostEntityProvider.all()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [HostEntity] {
        await HostEntityProvider.all()
    }

    func defaultResult() async -> HostEntity? {
        await HostEntityProvider.all().first
    }
}
