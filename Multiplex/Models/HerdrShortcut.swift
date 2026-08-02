/// Familiar herdr commands exposed by the terminal chrome — the herdr-backend
/// sibling of `TmuxShortcut`. herdr's default prefix is Control-B like tmux's,
/// and non-destructive rows send the stock prefix binding through SwiftTerm.
/// Defaults were read from `herdr --default-config` and the split/zoom/detach
/// bindings exercised against a real 0.7.5 TUI attach (2026-08-02); a
/// same-burst prefix+key registers once the client is interactive.
/// Destructive commands are confirmed by our UI, then resolved and executed
/// over the SSH control connection (`HerdrProbe.closeShortcutCommand`), so
/// they follow herdr's server truth instead of a rebindable key and never
/// meet herdr's own confirmation dialog twice.
enum HerdrShortcut: String, CaseIterable, Identifiable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case panes = "Panes"
        case tabs = "Tabs"
        case workspaces = "Workspaces"
    }

    /// What a confirmed destructive row closes. The raw value is herdr's own
    /// CLI noun (`herdr pane|tab|workspace close <id>`), spliced verbatim by
    /// `HerdrProbe.closeShortcutCommand`.
    enum CloseScope: String, Sendable {
        case pane, tab, workspace
    }

    case splitLeftRight
    case splitTopBottom
    case nextPane
    case togglePaneZoom
    case editScrollback
    case closePane
    case newTab
    case nextTab
    case previousTab
    case renameTab
    case closeTab
    case newWorkspace
    case workspacePicker
    case renameWorkspace
    case toggleSidebar
    case closeWorkspace

    var id: Self { self }

    var group: Group {
        switch self {
        case .splitLeftRight, .splitTopBottom, .nextPane, .togglePaneZoom,
             .editScrollback, .closePane:
            .panes
        case .newTab, .nextTab, .previousTab, .renameTab, .closeTab:
            .tabs
        case .newWorkspace, .workspacePicker, .renameWorkspace, .toggleSidebar,
             .closeWorkspace:
            .workspaces
        }
    }

    var title: String {
        switch self {
        case .splitLeftRight: "Split Left / Right"
        case .splitTopBottom: "Split Top / Bottom"
        case .nextPane: "Next Pane"
        case .togglePaneZoom: "Toggle Pane Zoom"
        case .editScrollback: "Edit Scrollback"
        case .closePane: "Close Pane"
        case .newTab: "New Tab"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .renameTab: "Rename Tab"
        case .closeTab: "Close Tab"
        case .newWorkspace: "New Workspace"
        case .workspacePicker: "Workspace Picker"
        case .renameWorkspace: "Rename Workspace"
        case .toggleSidebar: "Toggle Sidebar"
        case .closeWorkspace: "Close Workspace"
        }
    }

    /// herdr's config action name (`[keys]` in config.toml), shown as
    /// supporting text: it names the action for both execution paths and is
    /// exactly the key a user would rebind.
    var command: String {
        switch self {
        case .splitLeftRight: "split_vertical"
        case .splitTopBottom: "split_horizontal"
        case .nextPane: "cycle_pane_next"
        case .togglePaneZoom: "zoom"
        case .editScrollback: "edit_scrollback"
        case .closePane: "close_pane"
        case .newTab: "new_tab"
        case .nextTab: "next_tab"
        case .previousTab: "previous_tab"
        case .renameTab: "rename_tab"
        case .closeTab: "close_tab"
        case .newWorkspace: "new_workspace"
        case .workspacePicker: "workspace_picker"
        case .renameWorkspace: "rename_workspace"
        case .toggleSidebar: "toggle_sidebar"
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
        case .nextPane: "\t"
        case .togglePaneZoom: "z"
        case .editScrollback: "e"
        case .newTab: "c"
        case .nextTab: "n"
        case .previousTab: "p"
        case .renameTab: "T"
        case .newWorkspace: "N"
        case .workspacePicker: "w"
        case .renameWorkspace: "W"
        case .toggleSidebar: "b"
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

    var bindingLabel: String {
        guard !requiresDoubleActivation else { return "2×" }
        switch self {
        case .nextPane: return "⌃B ⇥"
        case .renameTab: return "⌃B ⇧T"
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
