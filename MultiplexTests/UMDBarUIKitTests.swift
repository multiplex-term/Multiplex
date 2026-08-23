import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class UMDBarUIKitTests: XCTestCase {
    func testHerdrTabKeepsNewSessionLeadingAndAddsTheWorkspaceTabRow() throws {
        let controller = UMDBarViewController(configuration: configuration(
            extraNewTabTarget: .herdrWorkspaceTab
        ))
        controller.loadViewIfNeeded()

        let newTab = try XCTUnwrap(control("umd.newTab", in: controller.view) as? UIButton)
        XCTAssertEqual(
            actions(in: try XCTUnwrap(newTab.menu)).map(\.title),
            ["New Session", "Claude Code", "Codex", "Pi", "Grok Build", "Antigravity",
             "Hermes", "New Tab in Workspace", "File Viewer"],
            "every backend leads with a session mint — the workspace tab is an extra row"
        )
        XCTAssertEqual(
            newTab.accessibilityLabel,
            "New tab: another session, a tab in this herdr workspace, or the file viewer"
        )

        let tmux = UMDBarViewController(configuration: configuration())
        tmux.loadViewIfNeeded()
        let plain = try XCTUnwrap(control("umd.newTab", in: tmux.view) as? UIButton)
        XCTAssertEqual(
            actions(in: try XCTUnwrap(plain.menu)).map(\.title),
            ["New Session", "Claude Code", "Codex", "Pi", "Grok Build", "Antigravity",
             "Hermes", "File Viewer"],
            "tmux windows belong to the prefix key and the shortcut panel, not app chrome"
        )
        XCTAssertEqual(
            plain.accessibilityLabel,
            "New tab: another session or the file viewer"
        )
    }

    func testHerdrBackendRelabelsTheShortcutChipAtTheSameSlot() throws {
        let controller = UMDBarViewController(configuration: configuration(
            extraNewTabTarget: .herdrWorkspaceTab,
            shortcutBackend: .herdr
        ))
        controller.loadViewIfNeeded()

        let chip = try XCTUnwrap(control("umd.tmux", in: controller.view))
        XCTAssertEqual(chip.accessibilityLabel, "Show herdr shortcuts")
        XCTAssertTrue(
            descendants(of: UILabel.self, in: chip).contains {
                ($0.text ?? $0.attributedText?.string)?.contains("HRDR") == true
            },
            "the chip face reads HRDR — four mono characters, TMUX's width"
        )

        let none = UMDBarViewController(configuration: configuration(
            shortcutBackend: nil
        ))
        none.loadViewIfNeeded()
        XCTAssertNil(control("umd.tmux", in: none.view))
    }

    func testRegularActionRouterAndDirectButtonsPreserveEveryCallback() throws {
        let first = UUID()
        let second = UUID()
        let sources = [window("ONE", id: first), window("TWO", id: second)]
        var events: [String] = []
        let controller = UMDBarViewController(configuration: configuration(
            mergeSources: sources,
            showDeck: { events.append("deck") },
            fontDown: { events.append("down") },
            fontUp: { events.append("up") },
            newSession: { events.append($0?.rawValue ?? "session") },
            newHerdrWorkspaceTab: { events.append("workspaceTab") },
            openFileViewer: { events.append("files") },
            merge: { events.append("merge:\($0.uuidString)") },
            detach: { events.append("detach") },
            closeSession: { events.append("close") }
        ))
        controller.loadViewIfNeeded()

        try XCTUnwrap(control("umd.deck", in: controller.view)).sendActions(for: .touchUpInside)
        try XCTUnwrap(control("umd.fontDown", in: controller.view)).sendActions(for: .touchUpInside)
        try XCTUnwrap(control("umd.fontUp", in: controller.view)).sendActions(for: .touchUpInside)
        controller.perform(.newSession(nil))
        controller.perform(.newSession(.codex))
        controller.perform(.newHerdrWorkspaceTab)
        controller.perform(.openFileViewer)
        controller.perform(.merge(first))
        controller.perform(.mergeAll)
        controller.perform(.detach)
        controller.perform(.closeSession)

        XCTAssertEqual(events, [
            "deck",
            "down",
            "up",
            "session",
            "codex",
            "workspaceTab",
            "files",
            "merge:\(first.uuidString)",
            "merge:\(first.uuidString)",
            "merge:\(second.uuidString)",
            "detach",
            "close",
        ])
    }

    func testShellSwitchesBetweenWideAndCompactRowsAndHonorsSafeAreas() throws {
        let wideController = UMDBarViewController(configuration: configuration(
            style: .shell,
            deckControlLabel: "WALL",
            availableWidth: 700,
            contentSafeArea: UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 12)
        ))
        wideController.loadViewIfNeeded()
        XCTAssertNotNil(view("umd.shell.wide", in: wideController.view))
        XCTAssertNil(view("umd.shell.compact", in: wideController.view))
        XCTAssertEqual(wideController.fittingContentSize(for: 700).width, 700)
        XCTAssertEqual(wideController.view.layer.cornerRadius, 0)
        XCTAssertEqual(wideController.view.layer.borderWidth, 0)
        XCTAssertEqual(control("umd.deck", in: wideController.view)?.accessibilityLabel, "Wall")
        XCTAssertNotNil(control("umd.fontDown", in: wideController.view))
        XCTAssertNotNil(control("umd.detach", in: wideController.view))

        let compactController = UMDBarViewController(configuration: configuration(
            style: .shell,
            deckControlLabel: "WALL",
            availableWidth: 375,
            keyRailContentWidth: 375
        ))
        compactController.loadViewIfNeeded()
        XCTAssertNotNil(view("umd.shell.compact", in: compactController.view))
        XCTAssertNil(control("umd.fontDown", in: compactController.view))
        XCTAssertNil(control("umd.detach", in: compactController.view))
        XCTAssertNotNil(control("umd.overflow", in: compactController.view))
        XCTAssertNotNil(control("umd.tmux", in: compactController.view))
        XCTAssertEqual(compactController.fittingContentSize(for: 375).width, 375)
    }

    /// One road, one rail: the pane's key rail carries TMUX/HRDR wherever it
    /// fits, so a rail wide enough for the wide row must not draw a second
    /// chip above it (iPhone landscape, reported 2026-08-06).
    func testOnlyOneRailDrawsTheShortcutChipAtAnyWidth() throws {
        let wide = UMDBarViewController(configuration: configuration(
            style: .shell,
            availableWidth: 734,
            keyRailContentWidth: 734
        ))
        wide.loadViewIfNeeded()
        XCTAssertNotNil(view("umd.shell.wide", in: wide.view))
        XCTAssertNil(
            control("umd.tmux", in: wide.view),
            "the key rail below still carries TMUX at this width"
        )

        let narrow = UMDBarViewController(configuration: configuration(
            style: .shell,
            availableWidth: 375,
            keyRailContentWidth: 375
        ))
        narrow.loadViewIfNeeded()
        XCTAssertNotNil(
            control("umd.tmux", in: narrow.view),
            "the key rail drops TMUX here, so the top bar takes it over"
        )

        // No key rail at all (visionOS) — the rail is the only road.
        let ornament = UMDBarViewController(configuration: configuration(
            style: .shell,
            availableWidth: 734,
            keyRailContentWidth: nil
        ))
        ornament.loadViewIfNeeded()
        XCTAssertNotNil(control("umd.tmux", in: ornament.view))
    }

    func testWideRailsCarryGuideAsItsOwnChipNeverInTheOverflow() throws {
        let terminal = terminalController(useMosh: false)
        let controller = UMDBarViewController(configuration: configuration(
            controller: terminal,
            style: .shell,
            availableWidth: 1_200
        ))
        controller.loadViewIfNeeded()

        controller.applyObservedState(UMDBarObservedState(
            status: .live,
            contactLost: false,
            needsYou: false,
            keyboardLocked: false,
            hardwareKeyboardConnected: true
        ))
        XCTAssertNotNil(view("umd.shell.wide", in: controller.view))
        let guide = try XCTUnwrap(control("umd.guide", in: controller.view))
        XCTAssertEqual(guide.accessibilityLabel, "Guide")
        // With GUIDE out of the menu the keyboard lock is its only other
        // resident — hidden here (a hardware keyboard is connected, and on
        // visionOS the row is compiled out), so the ⋯ has nothing to carry.
        XCTAssertNil(control("umd.overflow", in: controller.view))

        #if !os(visionOS)
        controller.applyObservedState(UMDBarObservedState(
            status: .live,
            contactLost: false,
            needsYou: false,
            keyboardLocked: false,
            hardwareKeyboardConnected: false
        ))
        let lock = try XCTUnwrap(
            control("umd.overflow", in: controller.view) as? UIButton
        )
        XCTAssertEqual(
            actions(in: try XCTUnwrap(lock.menu)).map(\.title),
            ["Lock Keyboard Closed"]
        )
        XCTAssertNotNil(control("umd.guide", in: controller.view))
        #endif

        let regular = UMDBarViewController(configuration: configuration(
            controller: terminal
        ))
        regular.loadViewIfNeeded()
        XCTAssertNotNil(
            control("umd.guide", in: regular.view),
            "the classic window rail carries the chip too"
        )
    }

    func testCompactOverflowContainsDisplacedActionsMergeDestructionAndFileSources() throws {
        let terminal = terminalController(useMosh: false)
        let source = window("OTHER")
        let controller = UMDBarViewController(configuration: configuration(
            controller: terminal,
            mergeSources: [source],
            closeSession: {},
            style: .shell,
            availableWidth: 375
        ))
        controller.loadViewIfNeeded()
        controller.applyObservedState(UMDBarObservedState(
            status: .connecting,
            contactLost: false,
            needsYou: false,
            keyboardLocked: false,
            hardwareKeyboardConnected: false
        ))

        let overflow = try XCTUnwrap(control("umd.overflow", in: controller.view) as? UIButton)
        let menu = try XCTUnwrap(overflow.menu)
        let allActions = actions(in: menu)
        XCTAssertEqual(menu.children.compactMap { ($0 as? UIMenu)?.title }, [
            "Text Size", "New Tab", "Send File…", "Merge Window", "",
        ])
        XCTAssertNil(
            control("umd.guide", in: controller.view),
            "the compact row displaces every direct action, GUIDE included"
        )
        XCTAssertTrue(allActions.map(\.title).contains("Guide"))
        XCTAssertEqual(
            allActions.first { $0.title == "Guide" }?.identifier,
            UIAction.Identifier("umd.guide.action")
        )
        #if os(visionOS)
        // Keyboard lock is an iPad software-keyboard affordance. The
        // production controller and the SwiftUI surface it replaced both
        // compile this action out on visionOS, where there is no key rail.
        XCTAssertFalse(allActions.map(\.title).contains("Lock Keyboard Closed"))
        #else
        XCTAssertTrue(allActions.map(\.title).contains("Lock Keyboard Closed"))
        #endif
        XCTAssertTrue(allActions.map(\.title).contains("Smaller Text"))
        XCTAssertTrue(allActions.map(\.title).contains("Larger Text"))
        XCTAssertTrue(allActions.map(\.title).contains("New Session"))
        XCTAssertTrue(allActions.map(\.title).contains("File Viewer"))
        XCTAssertTrue(allActions.map(\.title).contains("Files…"))
        XCTAssertTrue(allActions.map(\.title).contains("OTHER"))
        XCTAssertTrue(allActions.map(\.title).contains("Detach"))
        let close = try XCTUnwrap(allActions.first { $0.title == "Close Session" })
        XCTAssertTrue(close.attributes.contains(.destructive))
        let files = try XCTUnwrap(allActions.first { $0.title == "Files…" })
        XCTAssertTrue(files.attributes.contains(.disabled))

        #if !os(visionOS)
        controller.applyObservedState(UMDBarObservedState(
            status: .connecting,
            contactLost: false,
            needsYou: false,
            keyboardLocked: false,
            hardwareKeyboardConnected: true
        ))
        let connectedOverflow = try XCTUnwrap(
            control("umd.overflow", in: controller.view) as? UIButton
        )
        XCTAssertFalse(
            actions(in: try XCTUnwrap(connectedOverflow.menu))
                .map(\.title)
                .contains("Lock Keyboard Closed")
        )

        controller.applyObservedState(UMDBarObservedState(
            status: .connecting,
            contactLost: false,
            needsYou: false,
            keyboardLocked: true,
            hardwareKeyboardConnected: true
        ))
        let lockedOverflow = try XCTUnwrap(
            control("umd.overflow", in: controller.view) as? UIButton
        )
        XCTAssertTrue(
            actions(in: try XCTUnwrap(lockedOverflow.menu))
                .map(\.title)
                .contains("Unlock Keyboard")
        )
        #endif
    }

    func testStatusClusterPreservesMoshConnectionAttentionAndKeychainSemantics() throws {
        let terminal = terminalController(useMosh: true)
        var openedTip = false
        let controller = UMDBarViewController(configuration: configuration(
            controller: terminal,
            keychainTip: { openedTip = true }
        ))
        controller.loadViewIfNeeded()

        controller.applyObservedState(UMDBarObservedState(
            status: .connecting,
            contactLost: false,
            needsYou: true,
            keyboardLocked: false,
            hardwareKeyboardConnected: false
        ))
        XCTAssertEqual(view("umd.status.mosh", in: controller.view)?.accessibilityLabel, "Connects over mosh")
        XCTAssertEqual(view("umd.status.link", in: controller.view)?.accessibilityLabel, "link")
        XCTAssertEqual(view("umd.status.needsYou", in: controller.view)?.accessibilityLabel, "needs you")
        let keychain = try XCTUnwrap(control("umd.status.keychain", in: controller.view))
        XCTAssertEqual(
            keychain.accessibilityLabel,
            "The Mac's keychain is locked, so Claude Code shows signed out"
        )
        XCTAssertEqual(keychain.accessibilityHint, "Shows how to unlock the keychain")
        XCTAssertTrue(keychain.accessibilityActivate())
        XCTAssertTrue(openedTip)

        controller.applyObservedState(UMDBarObservedState(
            status: .live,
            contactLost: true,
            needsYou: false,
            keyboardLocked: false,
            hardwareKeyboardConnected: false
        ))
        XCTAssertEqual(view("umd.status.noLink", in: controller.view)?.accessibilityLabel, "no link")
        XCTAssertNil(view("umd.status.needsYou", in: controller.view))

        controller.applyObservedState(UMDBarObservedState(
            status: .ended("closed"),
            contactLost: false,
            needsYou: false,
            keyboardLocked: false,
            hardwareKeyboardConnected: false
        ))
        XCTAssertEqual(view("umd.status.ended", in: controller.view)?.accessibilityLabel, "ended")
    }

    func testFileAttachmentPresenterSurvivesNativeChromeReconfiguration() {
        let terminal = terminalController(useMosh: false)
        let controller = UMDBarViewController(configuration: configuration(
            controller: terminal
        ))
        controller.loadViewIfNeeded()
        let presenter = controller.fileAttachController
        let button = presenter.attachButton

        controller.applyObservedState(UMDBarObservedState(
            status: .live,
            contactLost: false,
            needsYou: false,
            keyboardLocked: false,
            hardwareKeyboardConnected: false
        ))
        controller.update(configuration: configuration(
            controller: terminal,
            title: "renamed",
            style: .shell,
            availableWidth: 375
        ))

        XCTAssertTrue(controller.fileAttachController === presenter)
        XCTAssertTrue(controller.fileAttachController.attachButton === button)
        XCTAssertNotNil(button.window ?? button.superview)
        XCTAssertEqual(button.accessibilityIdentifier, "terminal.fileAttach")
    }

    func testEquivalentUpdatesKeepExactMenuAnchorAndUseFreshCallbacks() throws {
        var events: [String] = []
        let state = UMDBarObservedState(
            status: .live,
            contactLost: false,
            needsYou: false,
            keyboardLocked: false,
            hardwareKeyboardConnected: false
        )
        let controller = UMDBarViewController(configuration: configuration(
            showDeck: { events.append("old") },
            style: .shell,
            availableWidth: 375
        ))
        controller.loadViewIfNeeded()
        controller.applyObservedState(state)

        let deck = try XCTUnwrap(control("umd.deck", in: controller.view))
        let overflow = try XCTUnwrap(control("umd.overflow", in: controller.view))
        let menu = try XCTUnwrap((overflow as? UIButton)?.menu)

        controller.update(configuration: configuration(
            showDeck: { events.append("fresh") },
            style: .shell,
            availableWidth: 375
        ))
        controller.applyObservedState(state)

        XCTAssertTrue(control("umd.deck", in: controller.view) === deck)
        XCTAssertTrue(control("umd.overflow", in: controller.view) === overflow)
        XCTAssertTrue((overflow as? UIButton)?.menu === menu)
        deck.sendActions(for: .touchUpInside)
        XCTAssertEqual(events, ["fresh"])
    }

    func testTogglingConnectionStatsRebuildsOverflowMenu() throws {
        let state = UMDBarObservedState(
            status: .live,
            contactLost: false,
            needsYou: false,
            keyboardLocked: false,
            hardwareKeyboardConnected: false
        )
        let controller = UMDBarViewController(configuration: configuration(
            showConnectionStats: {},
            style: .shell,
            availableWidth: 375
        ))
        controller.loadViewIfNeeded()
        controller.applyObservedState(state)

        func statsRow() throws -> UIAction? {
            let overflow = try XCTUnwrap(
                control("umd.overflow", in: controller.view) as? UIButton
            )
            return actions(in: try XCTUnwrap(overflow.menu))
                .first { $0.identifier == UIAction.Identifier("umd.connectionStats") }
        }
        XCTAssertNotNil(try statsRow())

        // Turning the stats setting off must drop the row from an already
        // built menu — the presence of the callback is part of the key.
        controller.update(configuration: configuration(
            showConnectionStats: nil,
            style: .shell,
            availableWidth: 375
        ))
        controller.applyObservedState(state)
        XCTAssertNil(try statsRow())

        controller.update(configuration: configuration(
            showConnectionStats: {},
            style: .shell,
            availableWidth: 375
        ))
        controller.applyObservedState(state)
        XCTAssertNotNil(try statsRow())
    }

    private func configuration(
        controller: TerminalSessionController? = nil,
        title: String = "agent · devbox",
        mergeSources: [TerminalWorkspace.WindowEntry] = [],
        showDeck: @escaping () -> Void = {},
        fontDown: @escaping () -> Void = {},
        fontUp: @escaping () -> Void = {},
        newSession: @escaping (AgentKind?) -> Void = { _ in },
        newHerdrWorkspaceTab: @escaping () -> Void = {},
        openFileViewer: @escaping () -> Void = {},
        merge: @escaping (UUID) -> Void = { _ in },
        detach: @escaping () -> Void = {},
        closeSession: (() -> Void)? = nil,
        keychainTip: (() -> Void)? = nil,
        showConnectionStats: (() -> Void)? = nil,
        extraNewTabTarget: TerminalRoute.NewTabTarget? = nil,
        shortcutBackend: Host.SessionBackend? = .tmux,
        style: UMDBarStyle = .regular,
        deckControlLabel: String = "DECK",
        availableWidth: CGFloat? = nil,
        contentSafeArea: UIEdgeInsets = .zero,
        keyRailContentWidth: CGFloat? = nil
    ) -> UMDBarConfiguration {
        UMDBarConfiguration(
            controller: controller,
            title: title,
            mergeSources: mergeSources,
            showDeck: showDeck,
            fontDown: fontDown,
            fontUp: fontUp,
            newSession: newSession,
            newHerdrWorkspaceTab: newHerdrWorkspaceTab,
            openFileViewer: openFileViewer,
            merge: merge,
            detach: detach,
            closeSession: closeSession,
            keychainTip: keychainTip,
            showConnectionStats: showConnectionStats,
            extraNewTabTarget: extraNewTabTarget,
            shortcutBackend: shortcutBackend,
            style: style,
            deckControlLabel: deckControlLabel,
            availableWidth: availableWidth,
            contentSafeArea: contentSafeArea,
            keyRailContentWidth: keyRailContentWidth
        )
    }

    private func terminalController(useMosh: Bool) -> TerminalSessionController {
        var host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        host.useMosh = useMosh
        return TerminalSessionController(
            route: TerminalRoute(hostID: host.id, mode: .attach(sessionName: "main")),
            host: host
        )
    }

    private func window(
        _ label: String,
        id: UUID = UUID()
    ) -> TerminalWorkspace.WindowEntry {
        TerminalWorkspace.WindowEntry(
            id: id,
            tabs: [],
            label: label,
            reveal: { _ in },
            surrender: { [] },
            adopt: { _ in }
        )
    }

    private func view(_ identifier: String, in root: UIView) -> UIView? {
        descendants(of: UIView.self, in: root).first {
            $0.accessibilityIdentifier == identifier
        }
    }

    private func control(_ identifier: String, in root: UIView) -> UIControl? {
        descendants(of: UIControl.self, in: root).first {
            $0.accessibilityIdentifier == identifier
        }
    }

    private func actions(in menu: UIMenu) -> [UIAction] {
        menu.children.flatMap { element in
            if let action = element as? UIAction { return [action] }
            if let submenu = element as? UIMenu { return actions(in: submenu) }
            return []
        }
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        var matches: [T] = (root as? T).map { [$0] } ?? []
        for child in root.subviews {
            matches.append(contentsOf: descendants(of: type, in: child))
        }
        return matches
    }
}
