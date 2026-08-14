/// Familiar tmux commands exposed by the terminal chrome. Most use the stock
/// binding: Control-B (the default prefix) followed by one key. Destructive
/// commands are confirmed by our UI, then run over the SSH control connection
/// so they neither enter tmux's command prompt nor ask for another confirmation.
/// Keep the binding bytes pure so both platform surfaces use the same input.
enum TmuxShortcut: String, CaseIterable, Identifiable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case panes = "Panes"
        case resize = "Resize Pane"
        case windows = "Windows"
    }

    case splitLeftRight
    case splitTopBottom
    case nextPane
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
    case lastWindow
    case renameWindow
    case closeWindow

    var id: Self { self }

    var group: Group {
        switch self {
        case .splitLeftRight, .splitTopBottom, .nextPane, .togglePaneZoom,
             .copyMode, .closePane:
            .panes
        case .resizeLeft, .resizeDown, .resizeUp, .resizeRight:
            .resize
        case .newWindow, .chooseWindow, .nextWindow, .previousWindow,
             .lastWindow, .renameWindow, .closeWindow:
            .windows
        }
    }

    var title: String {
        switch self {
        case .splitLeftRight: "Split Left / Right"
        case .splitTopBottom: "Split Top / Bottom"
        case .nextPane: "Next Pane"
        case .togglePaneZoom: "Toggle Pane Zoom"
        case .copyMode: "Copy Mode"
        case .closePane: "Close Pane"
        case .resizeLeft: "Resize Left"
        case .resizeDown: "Resize Down"
        case .resizeUp: "Resize Up"
        case .resizeRight: "Resize Right"
        case .newWindow: "New Window"
        case .chooseWindow: "Choose Window"
        case .nextWindow: "Next Window"
        case .previousWindow: "Previous Window"
        case .lastWindow: "Last Window"
        case .renameWindow: "Rename Window"
        case .closeWindow: "Close Window"
        }
    }

    /// The tmux command behind the stock binding, shown as supporting text
    /// so the dropdown doubles as a compact command reference.
    var command: String {
        switch self {
        case .splitLeftRight: "split-window -h"
        case .splitTopBottom: "split-window"
        case .nextPane: "select-pane -t :.+"
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
        case .lastWindow: "last-window"
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
        case .nextPane: "o"
        case .togglePaneZoom: "z"
        case .copyMode: "["
        case .closePane: "x"
        case .resizeLeft, .resizeDown, .resizeUp, .resizeRight: nil
        case .newWindow: "c"
        case .chooseWindow: "w"
        case .nextWindow: "n"
        case .previousWindow: "p"
        case .lastWindow: "l"
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
        case .splitLeftRight, .splitTopBottom, .nextPane, .togglePaneZoom,
             .copyMode, .closePane, .newWindow, .chooseWindow, .nextWindow,
             .previousWindow, .lastWindow, .renameWindow, .closeWindow:
            nil
        }
    }

    var requiresDoubleActivation: Bool {
        self == .closePane || self == .closeWindow
    }

    /// Moving between panes and windows is a switchboard action: the panel
    /// stays up so a hop can be repeated, exactly like its window list. Rows
    /// that create, rename, close, or enter a mode dismiss it — what they
    /// leave behind is the terminal, and it must not be covered.
    var keepsPanelOpen: Bool {
        switch self {
        case .nextPane, .togglePaneZoom, .nextWindow, .previousWindow, .lastWindow,
             .resizeLeft, .resizeDown, .resizeUp, .resizeRight:
            true
        case .splitLeftRight, .splitTopBottom, .copyMode, .closePane,
             .newWindow, .chooseWindow, .renameWindow, .closeWindow:
            false
        }
    }

    /// Whether the row can land the session on a different window — the only
    /// rows whose success invalidates the panel's switch list.
    var movesActiveWindow: Bool {
        switch self {
        case .nextWindow, .previousWindow, .lastWindow:
            true
        case .splitLeftRight, .splitTopBottom, .nextPane, .togglePaneZoom,
             .copyMode, .closePane, .resizeLeft, .resizeDown, .resizeUp,
             .resizeRight, .newWindow, .chooseWindow, .renameWindow, .closeWindow:
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
