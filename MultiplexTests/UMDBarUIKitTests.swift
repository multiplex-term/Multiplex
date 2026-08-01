import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class UMDBarUIKitTests: XCTestCase {
    func testRegularBarKeepsControlOrderMenusTallyChromeAndAccessibility() throws {
        let sources = [window("STUDIO"), window("DEPLOY")]
        let terminal = terminalController(useMosh: false)
        let controller = UMDBarViewController(configuration: configuration(
            controller: terminal,
            title: "agent · devbox",
            mergeSources: sources,
            closeSession: {}
        ))
        controller.loadViewIfNeeded()
        controller.applyObservedState(UMDBarObservedState(
            status: .live,
            contactLost: false,
            needsYou: false,
            keyboardLocked: false
        ))

        XCTAssertNotNil(view("umd.regular", in: controller.view))
        XCTAssertEqual(controller.view.layer.cornerRadius, 12)
        XCTAssertEqual(controller.view.layer.borderWidth, 1)
        XCTAssertEqual(
            controlIdentifiers(in: controller.view),
            [
                "umd.deck",
                "umd.fontDown",
                "umd.fontUp",
                "umd.newTab",
                "terminal.fileAttach",
                "umd.tmux",
                "umd.merge",
                "umd.detach",
            ]
        )
        XCTAssertEqual(view("umd.title", in: controller.view)?.accessibilityLabel, "agent · devbox")
        XCTAssertEqual(view("umd.status.live", in: controller.view)?.accessibilityLabel, "live")
        XCTAssertEqual(control("umd.tmux", in: controller.view)?.accessibilityLabel, "Show tmux shortcuts")
        XCTAssertEqual(
            control("umd.merge", in: controller.view)?.accessibilityLabel,
            "Merge another window into this one"
        )
        XCTAssertEqual(control("umd.detach", in: controller.view)?.accessibilityLabel, "Detach or close the session")
        XCTAssertFalse(try XCTUnwrap(control("terminal.fileAttach", in: controller.view)).isHidden)

        let newTab = try XCTUnwrap(control("umd.newTab", in: controller.view) as? UIButton)
        XCTAssertEqual(
            actions(in: try XCTUnwrap(newTab.menu)).map(\.title),
            ["New Session", "Claude Code", "Codex", "Pi", "File Viewer"]
        )

        let merge = try XCTUnwrap(control("umd.merge", in: controller.view) as? UIButton)
        XCTAssertEqual(
            actions(in: try XCTUnwrap(merge.menu)).map(\.title),
            ["STUDIO", "DEPLOY", "Merge All Windows"]
        )

        let detach = try XCTUnwrap(control("umd.detach", in: controller.view) as? UIButton)
        let detachActions = actions(in: try XCTUnwrap(detach.menu))
        XCTAssertEqual(detachActions.map(\.title), ["Detach", "Close Session"])
        XCTAssertTrue(detachActions[1].attributes.contains(.destructive))
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
            availableWidth: 375
        ))
        compactController.loadViewIfNeeded()
        XCTAssertNotNil(view("umd.shell.compact", in: compactController.view))
        XCTAssertNil(control("umd.fontDown", in: compactController.view))
        XCTAssertNil(control("umd.detach", in: compactController.view))
        XCTAssertNotNil(control("umd.overflow", in: compactController.view))
        XCTAssertNotNil(control("umd.tmux", in: compactController.view))
        XCTAssertEqual(compactController.fittingContentSize(for: 375).width, 375)
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

        let overflow = try XCTUnwrap(control("umd.overflow", in: controller.view) as? UIButton)
        let menu = try XCTUnwrap(overflow.menu)
        let allActions = actions(in: menu)
        XCTAssertEqual(menu.children.compactMap { ($0 as? UIMenu)?.title }, [
            "Text Size", "New Tab", "Send File…", "Merge Window", "",
        ])
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
            keyboardLocked: false
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
            keyboardLocked: false
        ))
        XCTAssertEqual(view("umd.status.noLink", in: controller.view)?.accessibilityLabel, "no link")
        XCTAssertNil(view("umd.status.needsYou", in: controller.view))

        controller.applyObservedState(UMDBarObservedState(
            status: .ended("closed"),
            contactLost: false,
            needsYou: false,
            keyboardLocked: false
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
            keyboardLocked: false
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
            keyboardLocked: false
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

    func testChassisButtonsReportTheirExactContentSizeInsteadOfNativeMetrics() {
        let button = UMDBarButton(
            caption: "‹ DECK",
            systemImage: nil,
            prominent: false,
            accessibilityLabel: "Deck"
        )

        XCTAssertGreaterThan(button.intrinsicContentSize.width, 18)
        XCTAssertGreaterThan(button.intrinsicContentSize.height, 10)
        XCTAssertLessThan(button.intrinsicContentSize.height, 34)
        XCTAssertEqual(
            button.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize),
            button.intrinsicContentSize
        )
    }

    private func configuration(
        controller: TerminalSessionController? = nil,
        title: String = "agent · devbox",
        mergeSources: [TerminalWorkspace.WindowEntry] = [],
        showDeck: @escaping () -> Void = {},
        fontDown: @escaping () -> Void = {},
        fontUp: @escaping () -> Void = {},
        newSession: @escaping (AgentKind?) -> Void = { _ in },
        openFileViewer: @escaping () -> Void = {},
        merge: @escaping (UUID) -> Void = { _ in },
        detach: @escaping () -> Void = {},
        closeSession: (() -> Void)? = nil,
        keychainTip: (() -> Void)? = nil,
        style: UMDBarStyle = .regular,
        deckControlLabel: String = "DECK",
        availableWidth: CGFloat? = nil,
        contentSafeArea: UIEdgeInsets = .zero
    ) -> UMDBarConfiguration {
        UMDBarConfiguration(
            controller: controller,
            title: title,
            mergeSources: mergeSources,
            showDeck: showDeck,
            fontDown: fontDown,
            fontUp: fontUp,
            newSession: newSession,
            openFileViewer: openFileViewer,
            merge: merge,
            detach: detach,
            closeSession: closeSession,
            keychainTip: keychainTip,
            showsTmuxShortcuts: true,
            style: style,
            deckControlLabel: deckControlLabel,
            availableWidth: availableWidth,
            contentSafeArea: contentSafeArea
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

    private func controlIdentifiers(in root: UIView) -> [String] {
        descendants(of: UIControl.self, in: root).compactMap(\.accessibilityIdentifier)
            .filter { $0.hasPrefix("umd.") || $0 == "terminal.fileAttach" }
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
