import Foundation

/// One row of the Agent Gallery's rail — an agent pane on the host, with
/// its herdr lifecycle status. Pure derivation from the probe's records so
/// the rail can never disagree with the wall.
struct GalleryAgent: Identifiable, Equatable {
    var paneID: String
    var agent: AgentKind?
    /// herdr's raw kind id (`claude`, `codex`, `devin`…) — the label
    /// fallback for kinds Multiplex has no `AgentKind` for.
    var herdrKind: String
    var workspaceName: String
    var workspaceID: String
    var status: HerdrProbe.AgentStatus

    var id: String { paneID }

    var displayName: String {
        agent?.telemetryLabel ?? herdrKind.uppercased()
    }

    /// The rail's state word. BLOCKED wears NEEDS YOU in caution amber —
    /// the wall's own vocabulary; WORKING/DONE/IDLE are telemetry text,
    /// never lamps.
    var statusWord: String {
        switch status {
        case .working: "WORKING"
        case .blocked: "NEEDS YOU"
        case .done: "DONE"
        case .idle: "IDLE"
        case .unknown: "—"
        }
    }

    var needsYou: Bool { status == .blocked }
}

enum AgentGallery {
    /// Every agent pane in the probe's sessions, in workspace order. In
    /// herdr mode `TmuxPane.command` carries herdr's raw agent id (set by
    /// the adapter), so a pane belongs on the rail exactly when it is
    /// non-empty — foreign kinds included, with their honest status and no
    /// claimed `AgentKind`.
    static func agents(
        sessions: [TmuxSession],
        statuses: [String: HerdrProbe.AgentStatus]
    ) -> [GalleryAgent] {
        var rows: [GalleryAgent] = []
        for session in sessions {
            for window in session.windows {
                for pane in window.panes ?? [] where !pane.command.isEmpty {
                    rows.append(GalleryAgent(
                        paneID: pane.tmuxID,
                        agent: pane.agent,
                        herdrKind: pane.command,
                        workspaceName: session.name,
                        workspaceID: session.tmuxID,
                        status: statuses[pane.tmuxID] ?? .unknown
                    ))
                }
            }
        }
        return rows
    }

    /// Keep the selection on a live pane: the previous choice if it still
    /// exists, else the most attention-worthy row (blocked first, then
    /// working), else the first.
    static func resolvedSelection(
        previous: String?, agents: [GalleryAgent]
    ) -> String? {
        if let previous, agents.contains(where: { $0.paneID == previous }) {
            return previous
        }
        return (agents.first { $0.status == .blocked }
            ?? agents.first { $0.status == .working }
            ?? agents.first)?.paneID
    }
}
