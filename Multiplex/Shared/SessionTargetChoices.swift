import Foundation

/// Picker rows for an external agent launch's session target and in-session
/// placement — shared by the Open Agent Shortcut's providers (app process)
/// and the Host widget's configuration providers (widget process), the
/// `AgentModelChoices` pattern. String-only on purpose: the widget target
/// compiles no app model, so the placement grammar stays with the app-side
/// URL parser and these rows just spell the tokens it accepts (lockstep
/// unit-tested app-side).
enum SessionTargetChoices {
    struct Choice: Equatable {
        var value: String
        var title: String
    }

    /// The empty value is the "fresh session" sentinel, like
    /// `AgentModelChoices.agentDefaultValue`: link builders skip it and the
    /// Shortcut's perform normalizes it to a new-session launch.
    static let newSessionValue = ""

    /// `Host.SessionBackend.herdr.rawValue`, spelled here so the widget
    /// process can compare a published backend without compiling the Host
    /// model.
    static let herdrBackendRaw = "herdr"

    /// Session rows: New Session leads (never empty — a zero-item options
    /// query flash-dismisses the picker) and the published snapshot's
    /// session names follow, deduped in the snapshot's own order.
    static func sessionChoices(names: [String]) -> [Choice] {
        var choices = [Choice(value: newSessionValue, title: "New Session")]
        var seen = Set<String>()
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            choices.append(Choice(value: name, title: name))
        }
        return choices
    }

    /// Placement rows for an existing-session launch, in the backend's own
    /// vocabulary: tmux has one granularity below a session — the single
    /// honest row — while herdr splits a tab in the focused workspace from
    /// a whole new workspace. Values are `ExternalSessionPlacement` tokens;
    /// "window" is the tmux-natural spelling of the workspace branch, and
    /// an unset parameter means the tab default. nil `backendRaw` (a
    /// pre-backend snapshot) reads as tmux, the app's own default.
    static func placementChoices(backendRaw: String?) -> [Choice] {
        if backendRaw == herdrBackendRaw {
            return [
                Choice(value: "tab", title: "New Tab (Focused Workspace)"),
                Choice(value: "workspace", title: "New Workspace"),
            ]
        }
        return [Choice(value: "window", title: "New Window")]
    }
}
