import Foundation

/// Device-local persistence for the deck's last-known wall state, keyed by
/// host id (`deck-snapshots.json` next to hosts.json). A cold launch paints
/// every tile from here instantly while the control connections rebuild —
/// the rail's LINKING/CONNECTED phase stays the truth about liveness.
/// Presentation cache only: never secrets, never attention state, and losing
/// the file costs nothing but one acquiring flash.
@MainActor
final class DeckSnapshotStore {
    private var snapshots: [UUID: DeckSnapshot] = [:]
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Multiplex", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("deck-snapshots.json")
        }
        load()
    }

    func snapshot(for hostID: UUID) -> DeckSnapshot? {
        snapshots[hostID]
    }

    /// Record a host's latest probe result; nil clears it (no tmux server —
    /// ghost tiles at the next launch would outlive the sessions they show).
    /// Saves are debounced: busy sessions change every tick, and snapshot
    /// freshness beyond "recent" buys nothing at the next launch.
    func update(_ snapshot: DeckSnapshot?, for hostID: UUID) {
        guard snapshots[hostID] != snapshot else { return }
        snapshots[hostID] = snapshot
        scheduleSave()
    }

    func remove(for hostID: UUID) {
        guard snapshots.removeValue(forKey: hostID) != nil else { return }
        scheduleSave()
    }

    /// Write pending changes now — the debounce timer may never fire when
    /// the app is being suspended.
    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveTask = nil
            save()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONDecoder().decode([String: DeckSnapshot].self, from: data)
        else { return }
        snapshots = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    private func save() {
        let raw = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
