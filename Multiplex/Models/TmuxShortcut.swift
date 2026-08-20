import Foundation

/// Familiar tmux commands exposed by the terminal chrome. Most use the stock
/// binding: Control-B (the default prefix) followed by one key. Destructive
/// commands are confirmed by our UI, then run over the SSH control connection
/// so they neither enter tmux's command prompt nor ask for another confirmation.
/// Keep the binding bytes pure so both platform surfaces use the same input.
/// Pane cycling is intentionally omitted because every pane is directly
/// tappable. Last Window is omitted too: the panel's live window list targets
/// the destination directly instead of making the user remember history.
enum TmuxShortcut: String, CaseIterable, Identifiable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case panes = "Panes"
        case resize = "Resize Pane"
        case windows = "Windows"

        /// Section header shown in the panel; the raw value stays English
        /// because it also names accessibility identifiers.
        var title: String {
            switch self {
            case .panes: String(localized: "Panes")
            case .resize: String(localized: "Resize Pane")
            case .windows: String(localized: "Windows")
            }
        }
    }

    case splitLeftRight
    case splitTopBottom
    case togglePaneZoom
    case copyMode
    case closePane
    case resizeLeft
    case resizeDown
    case resizeUp
    case resizeRight
    case newWindow
    case chooseWindow
    case nextWindow
    case previousWindow
    case renameWindow
    case closeWindow

    var id: Self { self }

    var group: Group {
        switch self {
        case .splitLeftRight, .splitTopBottom, .togglePaneZoom,
             .copyMode, .closePane:
            .panes
        case .resizeLeft, .resizeDown, .resizeUp, .resizeRight:
            .resize
        case .newWindow, .chooseWindow, .nextWindow, .previousWindow,
             .renameWindow, .closeWindow:
            .windows
        }
    }

    var title: String {
        switch self {
        case .splitLeftRight: String(localized: "Split Left / Right")
        case .splitTopBottom: String(localized: "Split Top / Bottom")
        case .togglePaneZoom: String(localized: "Toggle Pane Zoom")
        case .copyMode: String(localized: "Copy Mode")
        case .closePane: String(localized: "Close Pane")
        case .resizeLeft: String(localized: "Resize Left")
        case .resizeDown: String(localized: "Resize Down")
        case .resizeUp: String(localized: "Resize Up")
        case .resizeRight: String(localized: "Resize Right")
        case .newWindow: String(localized: "New Window")
        case .chooseWindow: String(localized: "Choose Window")
        case .nextWindow: String(localized: "Next Window")
        case .previousWindow: String(localized: "Previous Window")
        case .renameWindow: String(localized: "Rename Window")
        case .closeWindow: String(localized: "Close Window")
        }
    }

    /// The tmux command behind the stock binding, shown as supporting text
    /// so the dropdown doubles as a compact command reference.
    var command: String {
        switch self {
        case .splitLeftRight: "split-window -h"
        case .splitTopBottom: "split-window"
        case .togglePaneZoom: "resize-pane -Z"
        case .copyMode: "copy-mode"
        case .closePane: "kill-pane"
        // No count: resize-pane's default adjustment is one cell, exactly
        // the stock ⌃-arrow binding's step.
        case .resizeLeft: "resize-pane -L"
        case .resizeDown: "resize-pane -D"
        case .resizeUp: "resize-pane -U"
        case .resizeRight: "resize-pane -R"
        case .newWindow: "new-window"
        case .chooseWindow: "choose-tree"
        case .nextWindow: "next-window"
        case .previousWindow: "previous-window"
        case .renameWindow: "rename-window"
        case .closeWindow: "kill-window"
        }
    }

    /// The single key after the prefix; nil for the resize rows, whose stock
    /// bindings are the ⌃-arrow chords `bindingLabel` documents instead.
    var binding: Character? {
        switch self {
        case .splitLeftRight: "%"
        case .splitTopBottom: "\""
        case .togglePaneZoom: "z"
        case .copyMode: "["
        case .closePane: "x"
        case .resizeLeft, .resizeDown, .resizeUp, .resizeRight: nil
        case .newWindow: "c"
        case .chooseWindow: "w"
        case .nextWindow: "n"
        case .previousWindow: "p"
        case .renameWindow: ","
        case .closeWindow: "&"
        }
    }

    /// The one direction fact behind a resize row; nil for every ordinary
    /// row. The command flag, the stock ⌃-arrow chord, and the panel's
    /// button face all derive from it, so the four directions cannot drift.
    enum ResizeDirection: String {
        case left, down, up, right

        var arrow: String {
            switch self {
            case .left: "←"
            case .down: "↓"
            case .up: "↑"
            case .right: "→"
            }
        }
    }

    /// The held resize row's step, matching tmux's own coarse default (the
    /// stock M-arrow binding resizes five cells where ⌃-arrow resizes one).
    static let coarseResizeCells = 5

    var resizeDirection: ResizeDirection? {
        switch self {
        case .resizeLeft: .left
        case .resizeDown: .down
        case .resizeUp: .up
        case .resizeRight: .right
        case .splitLeftRight, .splitTopBottom, .togglePaneZoom, .copyMode,
             .closePane, .newWindow, .chooseWindow, .nextWindow, .previousWindow,
             .renameWindow, .closeWindow:
            nil
        }
    }

    var requiresDoubleActivation: Bool {
        self == .closePane || self == .closeWindow
    }

    /// Moving between panes and windows is a switchboard action: the panel
    /// stays up so a hop can be repeated, exactly like its window list.
    /// Rename stays up too — the panel hosts its name field and then shows
    /// the renamed list. Rows that create, close, or enter a mode dismiss
    /// it — what they leave behind is the terminal, and it must not be
    /// covered.
    var keepsPanelOpen: Bool {
        switch self {
        case .togglePaneZoom, .nextWindow, .previousWindow, .resizeLeft,
             .resizeDown, .resizeUp, .resizeRight, .renameWindow:
            true
        case .splitLeftRight, .splitTopBottom, .copyMode, .closePane,
             .newWindow, .chooseWindow, .closeWindow:
            false
        }
    }

    /// Rename collects its window name in the panel's own field: the stock
    /// `,` prompt is client-side tmux UI the control plane cannot drive.
    var promptsForWindowName: Bool { self == .renameWindow }

    /// Whether the row can land the session on a different window — the only
    /// rows whose success invalidates the panel's switch list.
    var movesActiveWindow: Bool {
        switch self {
        case .nextWindow, .previousWindow:
            true
        case .splitLeftRight, .splitTopBottom, .togglePaneZoom, .copyMode,
             .closePane, .resizeLeft, .resizeDown, .resizeUp, .resizeRight,
             .newWindow, .chooseWindow, .renameWindow, .closeWindow:
            false
        }
    }

    var bindingLabel: String {
        if requiresDoubleActivation { return "2×" }
        if let direction = resizeDirection { return "⌃B ⌃\(direction.arrow)" }
        // Every non-resize row has a post-prefix key.
        return "⌃B \(binding!.uppercased())"
    }

    /// Non-destructive actions use the stock binding through SwiftTerm.
    /// Close actions deliberately have no terminal input: after the panel's
    /// second press they execute through `TmuxProbe.directShortcutCommand`,
    /// avoiding both the timing-sensitive `:` prompt and tmux's own prompt.
    /// Resize rows have none either — their stock chord is prefix plus a
    /// multi-byte ⌃-arrow sequence, even more burst-fragile than the splits'
    /// shifted `%`, so they only run through the control plane.
    var bindingInput: [UInt8]? {
        guard !requiresDoubleActivation, let binding else { return nil }
        return [0x02, binding.asciiValue!]
    }

    static func shortcuts(in group: Group) -> [Self] {
        allCases.filter { $0.group == group }
    }
}

/// One row of the shortcut panel's window list — the attached session's
/// windows, tappable to switch. Carries tmux's own window id so the switch
/// can target it directly: `-t` name matching is prefix-based and pane/window
/// name targets misbehave on 3.6a, ids never do.
struct TmuxWindowChoice: Identifiable, Equatable, Sendable {
    var tmuxID: String
    var index: Int
    var isActive: Bool
    var name: String

    var id: String { tmuxID }
}
