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
    var accessibilityIdentifier: String

    var id: String { accessibilityIdentifier }

    init(_ shortcut: TmuxShortcut) {
        payload = .tmux(shortcut)
        title = shortcut.title
        command = shortcut.command
        bindingLabel = shortcut.bindingLabel
        requiresDoubleActivation = shortcut.requiresDoubleActivation
        accessibilityIdentifier = "tmuxShortcut.\(shortcut.rawValue)"
    }

    init(_ shortcut: HerdrShortcut) {
        payload = .herdr(shortcut)
        title = shortcut.title
        command = shortcut.command
        bindingLabel = shortcut.bindingLabel
        requiresDoubleActivation = shortcut.requiresDoubleActivation
        accessibilityIdentifier = "herdrShortcut.\(shortcut.rawValue)"
    }
}

struct ShortcutPanelSection: Equatable, Sendable {
    var title: String
    var accessibilityIdentifier: String
    var items: [ShortcutPanelItem]
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
                title: group.rawValue,
                accessibilityIdentifier: "tmuxGroup.\(group.rawValue)",
                items: TmuxShortcut.shortcuts(in: group).map(ShortcutPanelItem.init)
            )
        },
        switchSectionTitle: "Switch Window",
        switchSectionAccessibilityIdentifier: "tmuxWindowSection",
        switchChoiceAccessibilityPrefix: "tmuxWindow.",
        switchNoun: "window"
    )

    /// herdr's default prefix is also Control-B (`herdr --default-config`,
    /// 0.7.5) — the header states the same truth for both backends.
    static let herdr = ShortcutPanelContent(
        headerTitle: "HERDR SHORTCUTS",
        prefixLabel: "DEFAULT PREFIX  ⌃B",
        sections: HerdrShortcut.Group.allCases.map { group in
            ShortcutPanelSection(
                title: group.rawValue,
                accessibilityIdentifier: "herdrGroup.\(group.rawValue)",
                items: HerdrShortcut.shortcuts(in: group).map(ShortcutPanelItem.init)
            )
        },
        switchSectionTitle: "Switch Workspace",
        switchSectionAccessibilityIdentifier: "herdrWorkspaceSection",
        switchChoiceAccessibilityPrefix: "herdrWorkspace.",
        switchNoun: "workspace"
    )

    /// The panel for one terminal tab's backend; nil hides the chrome
    /// entirely (plain shells, viewports, the file viewer).
    static func content(for backend: Host.SessionBackend?) -> ShortcutPanelContent? {
        switch backend {
        case .tmux: .tmux
        case .herdr: .herdr
        case nil: nil
        }
    }
}
