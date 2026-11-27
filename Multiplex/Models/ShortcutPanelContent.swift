import Foundation

/// Pure presentation records for the shared multiplexer-shortcut panel: one
/// UIKit dropdown renders both the tmux and the herdr shortcut sets. Derived
/// entirely from `TmuxShortcut`/`HerdrShortcut` so the enums stay the single
/// source of bindings and the panel view never learns a backend.
struct ShortcutPanelItem: Equatable, Sendable, Identifiable {
    /// The backend action a row performs, carried typed so selection
    /// dispatches without string lookups. A payload mismatched to the tab's
    /// backend fails closed on the controller's own route guards.
    enum Payload: Equatable, Sendable {
        case tmux(TmuxShortcut)
        case herdr(HerdrShortcut)
        /// A row of a tab that draws its backend's panes itself: performed
        /// on the pane the tab's keyboard is on, through the transport.
        case pane(PaneShortcut)
    }

    var payload: Payload
    var title: String
    var command: String
    var bindingLabel: String
    var requiresDoubleActivation: Bool
    /// Whether performing this row leaves the panel on screen — see
    /// `TmuxShortcut.keepsPanelOpen`.
    var keepsPanelOpen: Bool
    /// Whether performing this row can move the switch section's ACTIVE
    /// choice, requiring the open panel to re-read the list.
    var invalidatesSwitchChoices: Bool
    /// Whether the row collects a name in the panel's own field before it
    /// performs (tmux Rename Window).
    var promptsForName: Bool
    /// SF Symbol name for a compact-row button's face (the tmux resize
    /// directions); nil for the ordinary grid rows. A symbol, not a text
    /// glyph: the Unicode arrow-to-bar characters come from different
    /// blocks and the horizontal pair draws visibly smaller.
    var symbolName: String?
    var accessibilityIdentifier: String

    var id: String { accessibilityIdentifier }

    init(_ shortcut: TmuxShortcut) {
        payload = .tmux(shortcut)
        title = shortcut.title
        command = shortcut.command
        bindingLabel = shortcut.bindingLabel
        requiresDoubleActivation = shortcut.requiresDoubleActivation
        keepsPanelOpen = shortcut.keepsPanelOpen
        invalidatesSwitchChoices = shortcut.movesActiveWindow
        promptsForName = shortcut.promptsForWindowName
        symbolName = shortcut.resizeDirection.map { "arrow.\($0.rawValue).to.line" }
        accessibilityIdentifier = "tmuxShortcut.\(shortcut.rawValue)"
    }

    init(_ shortcut: HerdrShortcut) {
        payload = .herdr(shortcut)
        title = shortcut.title
        command = shortcut.command
        bindingLabel = shortcut.bindingLabel
        requiresDoubleActivation = shortcut.requiresDoubleActivation
        keepsPanelOpen = shortcut.keepsPanelOpen
        // No herdr row moves the active workspace, so none invalidates the
        // switch list (cycling panes/tabs happens inside one workspace).
        invalidatesSwitchChoices = false
        promptsForName = false
        symbolName = nil
        accessibilityIdentifier = "herdrShortcut.\(shortcut.rawValue)"
    }

    /// `reference` is the backend's own name for what the row does, shown
    /// as the row's supporting text the way a tmux command or a herdr
    /// action name is; `title` is the backend's word for the row where it
    /// has one.
    init(_ shortcut: PaneShortcut, title: String? = nil, reference: String) {
        payload = .pane(shortcut)
        self.title = title ?? shortcut.title
        command = reference
        bindingLabel = shortcut.bindingLabel
        requiresDoubleActivation = shortcut.requiresDoubleActivation
        // Every row changes what the tab shows: a new pane, the neighbour
        // of a closed one, one pane alone, another window.
        keepsPanelOpen = false
        // The switch list marks the terminal the keyboard is on, and a
        // split, a close and a new window all move it.
        invalidatesSwitchChoices = shortcut != .zoomPane
        promptsForName = false
        symbolName = nil
        accessibilityIdentifier = "paneShortcut.\(shortcut.rawValue)"
    }
}

struct ShortcutPanelSection: Equatable, Sendable {
    var title: String
    var accessibilityIdentifier: String
    var items: [ShortcutPanelItem]

    /// A section whose every row carries a symbol face (the tmux resize
    /// directions) lays out as one compact row of square glyph buttons
    /// instead of the two-column grid of full rows.
    var usesCompactRow: Bool {
        !items.isEmpty && items.allSatisfy { $0.symbolName != nil }
    }
}

/// Everything one backend's panel shows. The switch section is the live list
/// loaded after presentation: tmux windows or herdr workspaces, both carried
/// as `TmuxWindowChoice` rows the way the probe reuses the tmux records.
struct ShortcutPanelContent: Equatable, Sendable {
    var headerTitle: String
    var prefixLabel: String
    var sections: [ShortcutPanelSection]
    var switchSectionTitle: String
    var switchSectionAccessibilityIdentifier: String
    var switchChoiceAccessibilityPrefix: String
    /// Spoken row noun ("window"/"workspace") for the switch rows.
    var switchNoun: String

    static let tmux = ShortcutPanelContent(
        headerTitle: "TMUX SHORTCUTS",
        prefixLabel: "DEFAULT PREFIX  ⌃B",
        sections: TmuxShortcut.Group.allCases.map { group in
            ShortcutPanelSection(
                title: group.title,
                accessibilityIdentifier: "tmuxGroup.\(group.rawValue)",
                items: TmuxShortcut.shortcuts(in: group).map(ShortcutPanelItem.init)
            )
        },
        switchSectionTitle: String(localized: "Switch Window"),
        switchSectionAccessibilityIdentifier: "tmuxWindowSection",
        switchChoiceAccessibilityPrefix: "tmuxWindow.",
        switchNoun: String(localized: "window")
    )

    /// herdr's default prefix is also Control-B (`herdr --default-config`,
    /// 0.7.5) — the header states the same truth for both backends.
    static let herdr = ShortcutPanelContent(
        headerTitle: "HERDR SHORTCUTS",
        prefixLabel: "DEFAULT PREFIX  ⌃B",
        sections: HerdrShortcut.Group.allCases.map { group in
            ShortcutPanelSection(
                title: group.title,
                accessibilityIdentifier: "herdrGroup.\(group.rawValue)",
                items: HerdrShortcut.shortcuts(in: group).map(ShortcutPanelItem.init)
            )
        },
        switchSectionTitle: String(localized: "Switch Workspace"),
        switchSectionAccessibilityIdentifier: "herdrWorkspaceSection",
        switchChoiceAccessibilityPrefix: "herdrWorkspace.",
        switchNoun: String(localized: "workspace")
    )

    /// Rex has no prefix-key client — Multiplex IS the client — so its panel
    /// has no bindings to list. Its rows act on the tab's own panes
    /// (`PaneShortcut`): split the pane the keyboard is on, zoom it, close
    /// it, or open a new Rex tab — a window, in the server's word and in
    /// every other part of this app — beside the one the tab is drawing.
    /// Below them, every terminal of the session: one among the panes on
    /// show takes the keyboard, one in another Rex window brings that
    /// window's panes into the tab (`RexSession.showTerminal`). The
    /// header's trailing slot says whose pane the rows act on, where the
    /// others state their prefix.
    static let rex = ShortcutPanelContent(
        headerTitle: "REX PANES",
        prefixLabel: "ACTS ON THE FOCUSED PANE",
        sections: [
            ShortcutPanelSection(
                title: String(localized: "Panes"),
                accessibilityIdentifier: "rexGroup.Panes",
                items: [
                    ShortcutPanelItem(.splitRight, reference: "new_split horizontal"),
                    ShortcutPanelItem(.splitDown, reference: "new_split vertical"),
                    ShortcutPanelItem(.zoomPane, reference: "in this tab only"),
                    ShortcutPanelItem(.closePane, reference: "block.close"),
                ]
            ),
            ShortcutPanelSection(
                title: String(localized: "Tabs"),
                accessibilityIdentifier: "rexGroup.Tabs",
                items: [
                    ShortcutPanelItem(
                        .newWindow, title: String(localized: "New Tab"),
                        reference: "session.new_window"),
                ]
            ),
        ],
        switchSectionTitle: String(localized: "Switch Terminal"),
        switchSectionAccessibilityIdentifier: "rexTerminalSection",
        switchChoiceAccessibilityPrefix: "rexTerminal.",
        switchNoun: String(localized: "terminal")
    )

    /// The panel for one terminal tab's backend; nil hides the chrome
    /// entirely (plain shells, viewports, the file viewer).
    static func content(for backend: Host.SessionBackend?) -> ShortcutPanelContent? {
        switch backend {
        case .tmux: .tmux
        case .herdr: .herdr
        case .rex: .rex
        case nil: nil
        }
    }
}

extension Host.SessionBackend {
    /// The face of the rail / bar key that opens this backend's panel. One
    /// source for the three places that draw it.
    var shortcutKeyCaption: String {
        switch self {
        case .tmux: "TMUX"
        case .herdr: "HRDR"
        case .rex: "REX"
        }
    }

    var shortcutKeyAccessibilityLabel: String {
        switch self {
        case .tmux: String(localized: "Show tmux shortcuts")
        case .herdr: String(localized: "Show herdr shortcuts")
        case .rex: String(localized: "Show Rex panes and terminals")
        }
    }
}
