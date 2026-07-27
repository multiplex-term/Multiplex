import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Debounced writer of the App Group widget snapshot — same cadence
/// discipline as `DeckSnapshotStore` (2 s debounce, explicit flush when the
/// deck leaves the foreground because suspension freezes the timer).
/// Timeline reloads are content-gated: `probedAt` churn alone (a fresh probe
/// with identical sessions) never spends WidgetKit's reload budget while the
/// app is frontmost; the background flush always reloads once so the Home
/// Screen is correct whenever the user can actually see it.
@MainActor
final class WidgetStatePublisher {
    private var pending: WidgetFleetState?
    private var saveTask: Task<Void, Never>?
    private var lastContentFingerprint: Int?

    func schedule(_ state: WidgetFleetState) {
        pending = state
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            self.flush(reloadAlways: false)
        }
    }

    func flush(reloadAlways: Bool) {
        saveTask?.cancel()
        saveTask = nil
        guard let state = pending else {
            if reloadAlways { reloadTimelines() }
            return
        }
        pending = nil
        SharedStateStore.save(state)
        let fingerprint = WidgetStateBuilder.contentFingerprint(of: state)
        if reloadAlways || fingerprint != lastContentFingerprint {
            reloadTimelines()
        }
        lastContentFingerprint = fingerprint
    }

    private func reloadTimelines() {
        #if canImport(WidgetKit)
        if #available(iOS 14.0, visionOS 26.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
    }
}

/// Pure projection from the app's probe state into the shared widget types —
/// kept static and model-typed so it is unit-testable without a hub.
enum WidgetStateBuilder {
    /// Lines the medium widget's held frame can actually show.
    static let miniatureLineLimit = 6

    static func hostState(
        host: Host,
        sessions: [TmuxSession],
        miniatures: [String: [String]],
        probedAt: Date?
    ) -> WidgetHostState {
        WidgetHostState(
            id: host.id,
            name: host.name,
            address: host.address,
            sessions: sessions.map {
                sessionState($0, miniatureLines: miniatures[$0.name] ?? [])
            },
            probedAt: probedAt,
            agentModels: host.agentLaunchModels.isEmpty ? nil : host.agentLaunchModels
        )
    }

    static func sessionState(
        _ session: TmuxSession, miniatureLines: [String]
    ) -> WidgetSessionState {
        WidgetSessionState(
            name: session.name,
            agentRaw: sessionAgent(session)?.rawValue,
            windowNames: session.windows.map(\.name),
            windowPaneTitles: session.windows.map {
                $0.displayPaneTitle(serverHost: session.serverHost) ?? ""
            },
            activeWindowIndex: session.windows.firstIndex(where: \.isActive) ?? 0,
            miniatureLines: Array(miniatureLines.suffix(miniatureLineLimit)),
            createdAt: session.created
        )
    }

    /// The badge agent: the active pane's agent (what helper chips would
    /// follow), else any agent detected in a background window/split.
    static func sessionAgent(_ session: TmuxSession) -> AgentKind? {
        session.activeWindow?.activeAgent
            ?? session.windows.lazy.compactMap(\.activeAgent).first
            ?? session.windows.lazy.flatMap(\.detectedAgents).first
    }

    /// Reload gate: everything except the recency stamps. A probe that
    /// changes only `probedAt` re-saves the file but must not reload
    /// timelines every wall tick.
    static func contentFingerprint(of state: WidgetFleetState) -> Int {
        var hasher = Hasher()
        for host in state.hosts {
            var stripped = host
            stripped.probedAt = nil
            hasher.combine(stripped)
        }
        return hasher.finalize()
    }
}
