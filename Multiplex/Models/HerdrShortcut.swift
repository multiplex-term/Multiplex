import Foundation

/// Familiar herdr commands exposed by the terminal chrome — the herdr-backend
/// sibling of `TmuxShortcut`. herdr's default prefix is Control-B like tmux's,
/// and non-destructive rows send the stock prefix binding through SwiftTerm.
/// Defaults were read from `herdr --default-config` and the split/detach
/// bindings exercised against a real 0.7.5 TUI attach (2026-08-02); a
/// same-burst prefix+key registers once the client is interactive.
/// Deliberately curated small (user-trimmed 2026-08-02 and 2026-08-14): zoom,
/// scrollback, rename-tab, pane/tab cycling, the workspace picker, and the
/// sidebar toggle are herdr UI the TUI already surfaces — the panel carries
/// only the commands touch actually needs.
/// Destructive commands are confirmed by our UI, then resolved and executed
/// over the SSH control connection (`HerdrProbe.closeShortcutCommand`), so
/// they follow herdr's server truth instead of a rebindable key and never
/// meet herdr's own confirmation dialog twice.
enum HerdrShortcut: String, CaseIterable, Identifiable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case panes = "Panes"
        case tabs = "Tabs"
        case workspaces = "Workspaces"

        /// Section header shown in the panel; the raw value stays English
        /// because it also names accessibility identifiers.
        var title: String {
            switch self {
            case .panes: String(localized: "Panes")
            case .tabs: String(localized: "Tabs")
            case .workspaces: String(localized: "Workspaces")
            }
        }
    }

    /// What a confirmed destructive row closes. The raw value is herdr's own
    /// CLI noun (`herdr pane|tab|workspace close <id>`), spliced verbatim by
    /// `HerdrProbe.closeShortcutCommand`.
    enum CloseScope: String, Sendable {
        case pane, tab, workspace
    }

    case splitLeftRight
    case splitTopBottom
    case closePane
    case newTab
    case closeTab
    case newWorkspace
    case renameWorkspace
    case closeWorkspace

    var id: Self { self }

    var group: Group {
        switch self {
        case .splitLeftRight, .splitTopBottom, .closePane:
            .panes
        case .newTab, .closeTab:
            .tabs
        case .newWorkspace, .renameWorkspace, .closeWorkspace:
            .workspaces
        }
    }

    var title: String {
        switch self {
        case .splitLeftRight: String(localized: "Split Left / Right")
        case .splitTopBottom: String(localized: "Split Top / Bottom")
        case .closePane: String(localized: "Close Pane")
        case .newTab: String(localized: "New Tab")
        case .closeTab: String(localized: "Close Tab")
        case .newWorkspace: String(localized: "New Workspace")
        case .renameWorkspace: String(localized: "Rename Workspace")
        case .closeWorkspace: String(localized: "Close Workspace")
        }
    }

    /// herdr's config action name (`[keys]` in config.toml), shown as
    /// supporting text: it names the action for both execution paths and is
    /// exactly the key a user would rebind.
    var command: String {
        switch self {
        case .splitLeftRight: "split_vertical"
        case .splitTopBottom: "split_horizontal"
        case .closePane: "close_pane"
        case .newTab: "new_tab"
        case .closeTab: "close_tab"
        case .newWorkspace: "new_workspace"
        case .renameWorkspace: "rename_workspace"
        case .closeWorkspace: "close_workspace"
        }
    }

    /// The key pressed after the prefix. Uppercase letters are herdr's
    /// `prefix+shift+…` defaults — the terminal byte for Shift+letter IS the
    /// uppercase letter; `\t` is `prefix+tab`.
    var binding: Character? {
        switch self {
        case .splitLeftRight: "v"
        case .splitTopBottom: "-"
        case .newTab: "c"
        case .newWorkspace: "N"
        case .renameWorkspace: "W"
        case .closePane, .closeTab, .closeWorkspace: nil
        }
    }

    var closeScope: CloseScope? {
        switch self {
        case .closePane: .pane
        case .closeTab: .tab
        case .closeWorkspace: .workspace
        default: nil
        }
    }

    var requiresDoubleActivation: Bool { closeScope != nil }

    /// Every curated action reveals a resulting pane, prompt, or close, so it
    /// dismisses the panel. Live workspace switch rows have their own stay-open
    /// behavior in `ShortcutPanelViewController`.
    var keepsPanelOpen: Bool { false }

    var bindingLabel: String {
        guard !requiresDoubleActivation else { return "2×" }
        switch self {
        case .newWorkspace: return "⌃B ⇧N"
        case .renameWorkspace: return "⌃B ⇧W"
        default: return "⌃B \(binding.map { String($0).uppercased() } ?? "")"
        }
    }

    /// Non-destructive actions ride the stock binding through SwiftTerm's
    /// ordered input path. The confirmed closes deliberately have none: after
    /// the panel's second press they resolve the focused target and close it
    /// through `HerdrProbe`, never a keybinding.
    var bindingInput: [UInt8]? {
        guard closeScope == nil, let binding else { return nil }
        return [0x02, binding.asciiValue!]
    }

    static func shortcuts(in group: Group) -> [Self] {
        allCases.filter { $0.group == group }
    }
}
