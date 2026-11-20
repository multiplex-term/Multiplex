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
    /// carries no shortcut rows at all. What it carries is the one thing a
    /// Rex tab cannot otherwise do from inside itself: a tab shows ONE
    /// terminal of its session, and this lists the others and switches the
    /// tab to one in place (`RexSession.switchBlock`). The header's trailing
    /// slot says so where the others state their prefix.
    static let rex = ShortcutPanelContent(
        headerTitle: "REX TERMINALS",
        prefixLabel: "SWITCHES THIS TAB",
        sections: [],
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
        case .rex: String(localized: "Show Rex terminals")
        }
    }
}
