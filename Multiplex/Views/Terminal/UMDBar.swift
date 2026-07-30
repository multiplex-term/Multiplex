import SwiftUI

/// The under-monitor display: every broadcast monitor wears one. Source
/// label, captioned status lamp, and the window's controls as chassis
/// chips. Deliberately opaque — the UMD is hardware, not glass.
struct UMDBar: View {
    enum Style {
        /// The visionOS classic window's title row: DECK, source label,
        /// text size, and the session controls. The key cluster flanks it
        /// on the same console row (every key stays TerminalKeyCluster's;
        /// this row never grows its own).
        case regular
        /// The single-window shell's slim full-width row — it keeps DECK
        /// and the font chips because the shell has no other chrome; the
        /// keyboard toggle lives on the key rail/cluster below.
        case shell
    }

    var controller: TerminalSessionController?
    var title: String
    var mergeSources: [TerminalWorkspace.WindowEntry]
    var showDeck: () -> Void
    var fontDown: () -> Void
    var fontUp: () -> Void
    /// New tab: a fresh session on the active tab's host, in its pane's
    /// directory — nil for a plain shell session, or an agent to launch.
    var newSession: (AgentKind?) -> Void
    /// New tab: the file viewer, rooted at the active pane's directory.
    var openFileViewer: () -> Void
    var merge: (UUID) -> Void
    var detach: () -> Void
    /// Kill the active tab's tmux session, then close the tab — the detach
    /// dropdown's destructive alternative. nil when there's no session to
    /// kill (plain shell tab, or the host record is gone).
    var closeSession: (() -> Void)?
    /// Opens the KEYCHAIN LOCKED tip when this tab's session shows Claude
    /// Code signed out behind a locked Mac keychain (`KeychainLockCheck`);
    /// nil hides the status. The deck rail carries the host-level view —
    /// this keeps it in sight after attach, where the user actually is.
    var keychainTip: (() -> Void)?
    /// Plain login shells have no tmux server or bindings to expose.
    var showsTmuxShortcuts = true
    var style: Style = .regular
    var deckControlLabel = "DECK"
    var availableWidth: CGFloat?
    /// Shell panes may span a landscape screen's side safe areas. The bar's
    /// bezel fills them; its chips keep clear of the rounded corners.
    var contentSafeArea = EdgeInsets()

    @State private var showingTmuxShortcuts = false
    /// A top-anchored phone popover cannot fit between the UMD and a docked
    /// software keyboard. Remember whether this presentation temporarily
    /// resigned the terminal so input can resume when the panel closes.
    @State private var resumesFocusAfterTmuxShortcuts = false

    @ViewBuilder
    var body: some View {
        switch style {
        case .regular:
            regularBar
        case .shell:
            shellBar
        }
    }

    private var regularBar: some View {
        HStack(spacing: 14) {
            ChassisChip("DECK", action: showDeck)
            divider
            ChassisLabel(title, size: 12)
            statusCluster
            divider
            ChassisChip("A−", action: fontDown)
            ChassisChip("A+", action: fontUp)
            newTabMenu
            FileAttachMenu(controller: controller)
            // Custom TALLY dropdown, immediately right of FILE. Each choice
            // sends the stock tmux prefix binding through the ordered pump.
            if showsTmuxShortcuts {
                tmuxShortcutButton
            }
            if !mergeSources.isEmpty {
                Menu {
                    ForEach(mergeSources) { entry in
                        Button {
                            merge(entry.id)
                        } label: {
                            Label(entry.label, systemImage: "macwindow")
                        }
                    }
                    if mergeSources.count > 1 {
                        Divider()
                        Button {
                            for entry in mergeSources { merge(entry.id) }
                        } label: {
                            Label("Merge All Windows", systemImage: "rectangle.stack")
                        }
                    }
                } label: {
                    ChassisBadge("MERGE")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .chassisHover(2)
                .accessibilityLabel("Merge another window into this one")
            }
            divider
            // Dropdown: detach (tmux keeps the session) or the destructive
            // alternative — kill the session, then close the tab. A plain
            // shell tab has no session to kill, so it keeps the direct chip.
            if let closeSession {
                Menu {
                    Button("Detach") { detach() }
                    Button("Close Session", role: .destructive, action: closeSession)
                } label: {
                    ChassisBadge("DETACH", prominent: true)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .chassisHover(2)
                .accessibilityLabel("Detach or close the session")
            } else {
                ChassisChip("DETACH", prominent: true, action: detach)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Theme.bezel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.bezelHi, lineWidth: 1))
    }

    /// Slim in-scene UMD. The common path stays visible at phone width;
    /// secondary actions move into one neutral overflow menu. At a genuinely
    /// wide terminal pane ViewThatFits restores the direct chips.
    private var shellBar: some View {
        ViewThatFits(in: .horizontal) {
            shellRow(showsDirectActions: true)
            shellRow(showsDirectActions: false)
        }
        .padding(.leading, 10 + contentSafeArea.leading)
        .padding(.trailing, 10 + contentSafeArea.trailing)
        .padding(.vertical, 8)
        .background(Theme.bezel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.bezelHi).frame(height: 1)
        }
    }

    private func shellRow(showsDirectActions: Bool) -> some View {
        HStack(spacing: 9) {
            ChassisChip(deckControlLabel, action: showDeck)
                .fixedSize()
            ChassisLabel(title, size: 11)
                .layoutPriority(1)
            statusCluster
                .fixedSize()
            Spacer(minLength: 4)
            if showsDirectActions {
                ChassisChip("A−", action: fontDown).fixedSize()
                ChassisChip("A+", action: fontUp).fixedSize()
                newTabMenu.fixedSize()
                FileAttachMenu(controller: controller).fixedSize()
                if showsTmuxShortcuts {
                    tmuxShortcutButton.fixedSize()
                }
                detachControl.fixedSize()
            } else {
                overflowMenu.fixedSize()
                // The sub-390-point phone rail drops TMUX to preserve every
                // terminal lifeline key. Keep the shortcut as its own trailing
                // top-bar control rather than burying it in the action menu.
                if showsCompactTopBarTmuxShortcut {
                    tmuxShortcutButton.fixedSize()
                }
            }
        }
    }

    private var showsCompactTopBarTmuxShortcut: Bool {
        guard let availableWidth else { return false }
        return SingleWindowShellLayout.showsTopBarTmuxShortcut(
            availableWidth: availableWidth,
            supportsTmuxShortcuts: showsTmuxShortcuts
        )
    }

    private var newTabMenu: some View {
        Menu {
            NewTabMenuItems(newSession: newSession, openFileViewer: openFileViewer)
        } label: {
            ChassisBadge("TAB", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .chassisHover(2)
        .accessibilityLabel("New tab: another session or the file viewer")
    }

    private var tmuxShortcutButton: some View {
        tmuxPopover(
            Button {
                showTmuxShortcuts()
            } label: {
                ChassisBadge("TMUX", systemImage: "command")
            }
            .buttonStyle(.plain)
            .chassisHover(2)
            .disabled(controller?.status != .live)
            .accessibilityLabel("Show tmux shortcuts")
        )
    }

    private func showTmuxShortcuts() {
        // In shell style this control sits at the top. Free the keyboard's
        // region before UIKit sizes the downward-opening popover; otherwise
        // the fixed command grid is clipped at both ends on a 375-point phone.
        if case .shell = style {
            resumesFocusAfterTmuxShortcuts =
                controller?.suspendFocusForPresentation() == true
        }
        showingTmuxShortcuts = true
    }

    private func tmuxShortcutsDidDisappear() {
        guard resumesFocusAfterTmuxShortcuts else { return }
        resumesFocusAfterTmuxShortcuts = false
        controller?.resumeFocusAfterPresentation()
    }

    private var overflowMenu: some View {
        TerminalOverflowMenu(
            controller: controller,
            mergeSources: mergeSources,
            fontDown: fontDown,
            fontUp: fontUp,
            newSession: newSession,
            openFileViewer: openFileViewer,
            merge: merge,
            detach: detach,
            closeSession: closeSession
        )
    }

    @ViewBuilder
    private var detachControl: some View {
        if let closeSession {
            Menu {
                Button("Detach", action: detach)
                Button("Close Session", role: .destructive, action: closeSession)
            } label: {
                ChassisBadge("DETACH", prominent: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .chassisHover(2)
            .accessibilityLabel("Detach or close the session")
        } else {
            ChassisChip("DETACH", prominent: true, action: detach)
        }
    }

    private func tmuxPopover<Control: View>(_ control: Control) -> some View {
        control.popover(
            isPresented: $showingTmuxShortcuts,
            attachmentAnchor: .rect(.bounds),
            // The regular UMD hangs below a visionOS window, so its panel
            // opens upward. The shell UMD sits at the top of the iPhone/iPad
            // stage and must open downward into the terminal instead.
            arrowEdge: tmuxPopoverArrowEdge
        ) {
            TmuxShortcutPanel(
                width: shortcutPanelWidth,
                select: { shortcut in
                    showingTmuxShortcuts = false
                    controller?.performTmuxShortcut(shortcut)
                },
                loadWindows: { [weak controller] in
                    await controller?.loadTmuxWindowList()
                },
                selectWindow: { window in
                    showingTmuxShortcuts = false
                    controller?.selectTmuxWindow(window)
                }
            )
            .presentationCompactAdaptation(.popover)
            .tmuxShortcutPresentationSizing()
            .followsAppAppearance()
            .onDisappear(perform: tmuxShortcutsDidDisappear)
        }
    }

    private var tmuxPopoverArrowEdge: Edge {
        switch style {
        case .regular: .bottom
        case .shell: .top
        }
    }

    private var shortcutPanelWidth: CGFloat {
        min(
            TmuxShortcutPanel.preferredWidth,
            max(280, (availableWidth ?? TmuxShortcutPanel.preferredWidth + 24) - 24)
        )
    }

    private var divider: some View {
        Rectangle().fill(Theme.bezelHi).frame(width: 1, height: 18)
    }

    /// The cluster starts with a persistent MOSH transport plate when in use;
    /// SSH is deliberately unmarked. Its lamp reads LIVE, LINK while
    /// connecting, and ENDED when the channel closed. A mosh tab that's live
    /// but out of contact reads NO LINK — the session is intact and self-heals,
    /// so it's caution, not a fault. A direct shell has no wall tile, so its
    /// app-owned UMD also carries the same captioned NEEDS YOU state that a
    /// tmux session would show on the wall.
    private var statusCluster: some View {
        HStack(spacing: 8) {
            if controller?.host.useMosh == true {
                ChassisBadge("MOSH")
                    .accessibilityLabel("Connects over mosh")
            }
            connectionStatus
            if let keychainTip {
                Button(action: keychainTip) {
                    TallyLamp(caption: "KEYCHAIN LOCKED", color: Theme.caution)
                }
                .buttonStyle(.plain)
                .chassisHover(2)
                .accessibilityLabel(
                    "The Mac's keychain is locked, so Claude Code shows signed out"
                )
                .accessibilityHint("Shows how to unlock the keychain")
            }
            if case .needsYou = controller?.directShellAttention {
                TallyLamp(caption: "NEEDS YOU", color: Theme.caution)
            }
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch controller?.status {
        case .live:
            if controller?.contactLost == true {
                TallyLamp(caption: "NO LINK", color: Theme.caution)
            } else {
                TallyLamp()
            }
        case .connecting:
            TallyLamp(caption: "LINK", color: Theme.caution)
        case .ended:
            TallyLamp(caption: "ENDED", color: Theme.signal3)
        case nil:
            EmptyView()
        }
    }
}

/// The + TAB dropdown's content — a fresh session in the active tab's
/// directory, plain or launching an agent (the deck's New Session grammar),
/// plus the file viewer. ONE spelling for its three homes — the classic
/// toolbar, the UMD bar, and the compact overflow's New Tab submenu — so a
/// new entry lands on every surface or none.
struct NewTabMenuItems: View {
    var newSession: (AgentKind?) -> Void
    var openFileViewer: () -> Void

    var body: some View {
        Button("New Session") { newSession(nil) }
        ForEach(AgentKind.allCases, id: \.self) { agent in
            Button(agent.displayName) { newSession(agent) }
        }
        Divider()
        Button("File Viewer") { openFileViewer() }
    }
}

/// Shared compact action menu for the iPhone shell and narrow classic iPad
/// windows. Keeping one menu definition prevents either compact surface from
/// silently losing actions as the regular terminal chrome evolves.
struct TerminalOverflowMenu: View {
    var controller: TerminalSessionController?
    var mergeSources: [TerminalWorkspace.WindowEntry]
    var fontDown: () -> Void
    var fontUp: () -> Void
    var newSession: (AgentKind?) -> Void
    var openFileViewer: () -> Void
    var merge: (UUID) -> Void
    var detach: () -> Void
    var closeSession: (() -> Void)?

    /// The picker presenter must belong to this outer menu, not to its nested
    /// Send File submenu. iPhone destroys submenu presentation state while
    /// dismissing the menu selection.
    @State private var requestedFileAttachPicker: FileAttachPicker?

    var body: some View {
        Menu {
            Section("Text Size") {
                Button("Smaller Text", action: fontDown)
                Button("Larger Text", action: fontUp)
            }
            Menu("New Tab") {
                NewTabMenuItems(newSession: newSession, openFileViewer: openFileViewer)
            }
            FileAttachSubmenu(controller: controller) {
                requestedFileAttachPicker = $0
            }
            if !mergeSources.isEmpty {
                Menu("Merge Window") {
                    ForEach(mergeSources) { entry in
                        Button {
                            merge(entry.id)
                        } label: {
                            Label(entry.label, systemImage: "macwindow")
                        }
                    }
                    if mergeSources.count > 1 {
                        Divider()
                        Button {
                            for entry in mergeSources { merge(entry.id) }
                        } label: {
                            Label("Merge All Windows", systemImage: "rectangle.stack")
                        }
                    }
                }
            }
            Divider()
            Button("Detach", action: detach)
            if let closeSession {
                Button("Close Session", role: .destructive, action: closeSession)
            }
        } label: {
            ChassisBadge("", systemImage: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .chassisHover(2)
        .accessibilityLabel("Terminal actions")
        .fileAttachPickers(
            controller: controller,
            request: $requestedFileAttachPicker
        )
    }
}

#if DEBUG
#Preview("UMD bar") {
    UMDBar(
        controller: nil,
        title: "agent · devbox",
        mergeSources: [],
        showDeck: {},
        fontDown: {},
        fontUp: {},
        newSession: { _ in },
        openFileViewer: {},
        merge: { _ in },
        detach: {},
        closeSession: {}
    )
    .padding()
    .background(Theme.chassis)
}

#Preview("Shell UMD bar") {
    UMDBar(
        controller: nil,
        title: "agent",
        mergeSources: [],
        showDeck: {},
        fontDown: {},
        fontUp: {},
        newSession: { _ in },
        openFileViewer: {},
        merge: { _ in },
        detach: {},
        closeSession: {},
        style: .shell,
        deckControlLabel: "WALL",
        availableWidth: 540
    )
    .frame(width: 540)
    .background(Theme.chassis)
}
#endif
