import SwiftTerm
import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class TerminalTallyKeyControlTests: XCTestCase {
    func testNativeKeyRoutesActivationAndExposesLatchedAccessibility() {
        var activations = 0
        let key = TerminalTallyKeyControl(
            face: .text(
                "CTRL",
                font: UIKitChassis.monoFont(11, weight: .semibold),
                kerning: 1.1
            ),
            width: 46,
            height: 34,
            accessibilityLabel: "Control",
            accessibilityIdentifier: "test.control",
            action: { activations += 1 }
        )

        XCTAssertEqual(key.intrinsicContentSize, CGSize(width: 46, height: 34))
        XCTAssertEqual(key.accessibilityLabel, "Control")
        XCTAssertEqual(key.accessibilityIdentifier, "test.control")
        XCTAssertTrue(key.accessibilityTraits.contains(.button))
        XCTAssertFalse(key.accessibilityTraits.contains(.selected))

        key.sendActions(for: .touchUpInside)
        XCTAssertEqual(activations, 1)
        XCTAssertTrue(key.accessibilityActivate())
        XCTAssertEqual(activations, 2)

        key.isLatched = true
        XCTAssertTrue(key.accessibilityTraits.contains(.selected))

        // Arrange Keys: the key stays a live control (visionOS gaze targets
        // interactive elements) but sends nothing; the system drag source
        // arms in its place and disarms with the mode.
        key.isArranging = true
        XCTAssertTrue(key.isUserInteractionEnabled)
        XCTAssertTrue(key.isArrangeDragSourceForTesting)
        key.sendActions(for: .touchDown)
        key.sendActions(for: .touchUpInside)
        XCTAssertEqual(activations, 2, "A tap in the mode sends nothing")
        XCTAssertFalse(key.accessibilityActivate())
        XCTAssertEqual(key.accessibilityHint, "Drag to move this key")
        key.isArranging = false
        XCTAssertFalse(key.isArrangeDragSourceForTesting)
        XCTAssertNil(key.accessibilityHint)
        key.sendActions(for: .touchUpInside)
        XCTAssertEqual(activations, 3)
    }

    func testNativeControlComboKeepsOrderLabelsAndTypedLetters() {
        var letters: [String] = []
        let combo = TerminalCtrlComboView(
            faceHeight: 34,
            padding: 8,
            fontSize: 15,
            send: { letters.append($0) }
        )

        XCTAssertEqual(combo.intrinsicContentSize, CGSize(width: 114, height: 50))
        XCTAssertEqual(combo.accessibilityIdentifier, "terminal.ctrlCombos")
        XCTAssertEqual(combo.keys.map(\.accessibilityLabel), ["Control C", "Control B"])
        XCTAssertEqual(
            combo.keys.map(\.accessibilityIdentifier),
            ["terminal.ctrlCombos.c", "terminal.ctrlCombos.b"]
        )

        combo.keys[0].sendActions(for: .touchUpInside)
        combo.keys[1].sendActions(for: .touchUpInside)
        XCTAssertEqual(letters, ["c", "b"])
    }
}

#if !os(visionOS)
@MainActor
final class TerminalKeyBarUIKitTests: XCTestCase {
    func testWidthLadderPreservesEveryDocumentedFloor() {
        XCTAssertEqual(specification(width: 1024, returns: true).tier, .full)
        // The talk key (RET · talk · keyboard) costs a 768 pt window its page
        // keys — the ladder's first sacrifice — and nothing below.
        XCTAssertEqual(
            specification(width: 768, returns: true).tier,
            .twoSymbols
        )
        XCTAssertEqual(
            specification(width: 820, returns: true).tier,
            .twoSymbolsAndPages
        )
        XCTAssertEqual(
            specification(width: 420, returns: true).tier,
            .returnAndTmuxFloor
        )
        XCTAssertEqual(
            specification(width: 375, returns: true).tier,
            .essentialsFloor
        )
        XCTAssertEqual(specification(width: 390, returns: false).tier, .tightTmux)

        XCTAssertEqual(
            specification(
                width: 420,
                returns: true,
                safeArea: UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            ).tier,
            .essentialsFloor
        )
    }

    func testNativeRailBuildsTallyControlsWithoutAHostedView() throws {
        let terminal = TerminalView(
            frame: CGRect(x: 0, y: 0, width: 420, height: 200)
        )
        // An isolated store: the simulator's container may carry a custom
        // order from a headless proof, and this test speaks for the shipped one.
        let bar = TerminalKeyBar(
            terminal: terminal,
            controller: nil,
            performShortcut: { _ in },
            finishTmuxCopyMode: {},
            shortcutBackend: .tmux,
            orderStore: KeyBarOrderStore(defaults: try isolatedDefaults())
        )
        bar.frame = CGRect(x: 0, y: 0, width: 420, height: TerminalKeyBar.barHeight)
        bar.layoutIfNeeded()

        XCTAssertEqual(
            bar.intrinsicContentSize.height,
            TerminalKeyBar.keyTopInset + TerminalKeyBar.keyHeight
                + TerminalKeyBar.keyBottomInset
        )
        // Both branches are assertable from either host: the platform fact
        // is a parameter, and the shipped constants are the convenience.
        XCTAssertLessThan(
            TerminalKeyBar.keyBottomInset(isIOSAppOnMac: false),
            TerminalKeyBar.keyTopInset,
            "On iPad the rail is the window's bottom edge; its chassis is trimmed"
        )
        XCTAssertEqual(
            TerminalKeyBar.keyBottomInset(isIOSAppOnMac: true),
            TerminalKeyBar.keyTopInset,
            "The Mac's window bottom is the Mac's; the rail keeps its symmetry"
        )
        // A rail that spends the home-indicator strip reaches the display
        // edge, so it buys daylight back below the faces — and the bar it
        // reports must grow by exactly that, or the terminal covers the row.
        XCTAssertGreaterThan(
            TerminalKeyBar.keyBottomInset(
                isIOSAppOnMac: false,
                spendsBottomStrip: true
            ),
            TerminalKeyBar.keyBottomInset(
                isIOSAppOnMac: false,
                spendsBottomStrip: false
            ),
            "Keys parked over the home indicator owe it visible daylight"
        )
        XCTAssertEqual(
            TerminalKeyBar.keyBottomInset(
                isIOSAppOnMac: true,
                spendsBottomStrip: true
            ),
            TerminalKeyBar.keyTopInset,
            "The Mac has no indicator strip to spend"
        )
        bar.spendsBottomStrip = true
        XCTAssertEqual(
            bar.intrinsicContentSize.height,
            TerminalKeyBar.barHeight(spendsBottomStrip: true)
        )
        XCTAssertGreaterThan(
            TerminalKeyBar.barHeight(spendsBottomStrip: true),
            TerminalKeyBar.barHeight(spendsBottomStrip: false)
        )
        bar.spendsBottomStrip = false
        XCTAssertGreaterThan(
            TerminalKeyBarLayout.regularEdgeInset(isIOSAppOnMac: false),
            TerminalKeyBarLayout.regularEdgeInset(isIOSAppOnMac: true),
            "Only the iPad's rounded window corners buy extra edge daylight"
        )
        XCTAssertFalse(bar.renderedKeys.isEmpty)
        XCTAssertEqual(
            bar.renderedKeys.prefix(3).map(\.accessibilityIdentifier),
            [
                "terminal.keybar.escape",
                "terminal.keybar.control",
                "terminal.keybar.tab",
            ]
        )
        // Talkback sits between RET and the keyboard / mic slot on every tier.
        let identifiers = bar.renderedKeys.compactMap(\.accessibilityIdentifier)
        let talk = try XCTUnwrap(identifiers.firstIndex(of: "terminal.keybar.talkback"))
        XCTAssertEqual(identifiers[talk - 1], "terminal.keybar.return")
        XCTAssertTrue(
            ["terminal.keybar.keyboard", "terminal.keybar.dictation"]
                .contains(identifiers[talk + 1])
        )
        XCTAssertEqual(
            bar.renderedKeys[talk].accessibilityLabel,
            "Open the message box"
        )
        XCTAssertEqual(
            bar.renderedKeys.first {
                $0.accessibilityIdentifier == "terminal.keybar.control"
            }?.accessibilityLabel,
            "Control"
        )
        XCTAssertTrue(bar.subviews.contains { $0 is TerminalTallyKeyControl })
        XCTAssertFalse(descendants(in: bar).contains {
            String(describing: type(of: $0)).contains("Hosting")
        })
    }

    func testKeyFramesCountGroupsAndADropLandsOnTheNearestOtherKey() {
        let full = specification(width: 1024, returns: true)
        XCTAssertEqual(full.tier, .full)
        let frames = TerminalKeyBarLayout.keyFrames(
            specification: full,
            keyCount: 17,
            includesReturn: true,
            width: 1024,
            contentSafeArea: .zero,
            keyTop: TerminalKeyBar.keyTopInset,
            keyHeight: TerminalKeyBar.keyHeight
        )
        XCTAssertEqual(frames.count, 17)
        XCTAssertEqual(frames[0].minX, TerminalKeyBarLayout.regularEdgeInset)
        XCTAssertEqual(frames[16].maxX, 1024 - TerminalKeyBarLayout.regularEdgeInset, accuracy: 0.5)
        XCTAssertTrue(frames.allSatisfy { $0.minY == TerminalKeyBar.keyTopInset && $0.width == 46 })
        // Three · four symbols · the rest: spacing inside a group, and the
        // slack split evenly over the two group gaps.
        XCTAssertEqual(frames[1].minX - frames[0].maxX, 6)
        XCTAssertEqual(frames[4].minX - frames[3].maxX, 6)
        XCTAssertEqual(
            frames[3].minX - frames[2].maxX,
            frames[7].minX - frames[6].maxX,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(frames[3].minX - frames[2].maxX, 8)
        XCTAssertEqual(TerminalKeyBarLayout.keyFrames(
            specification: full, keyCount: 0, includesReturn: true, width: 1024,
            contentSafeArea: .zero, keyTop: 7, keyHeight: 34
        ), [])

        // A drop lands on the nearest OTHER key by centre; the dragged key's
        // own slot (three points of slack a side) is no target.
        func target(_ x: CGFloat, source: Int) -> Int? {
            RowDropGeometry.dropTargetIndex(x: x, restingFrames: frames, sourceIndex: source)
        }
        XCTAssertNil(target(frames[0].maxX + 3, source: 0))
        XCTAssertEqual(target(frames[0].maxX + 4, source: 0), 1)
        XCTAssertEqual(target(frames[2].midX, source: 3), 2)
        XCTAssertEqual(
            target((frames[2].maxX + frames[3].minX) / 2 - 1, source: 0), 2,
            "A group gap belongs to the nearer key"
        )
        XCTAssertEqual(target(5000, source: 3), 16)
        XCTAssertNil(RowDropGeometry.dropTargetIndex(x: 10, restingFrames: [frames[0]], sourceIndex: 0))
    }

    func testRailFollowsTheStoredOrderAndArrangeModeMovesKeysThroughIt() throws {
        let suite = "TerminalKeyBarUIKitTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KeyBarOrderStore(defaults: defaults)
        store.setOrder(KeyBarOrder(slots: [.shortcuts, .keyboard, .tab]))
        let host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        let controller = TerminalSessionController(
            route: TerminalRoute(hostID: host.id, mode: .attach(sessionName: "main")),
            host: host
        )
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 1024, height: 200))
        let bar = TerminalKeyBar(
            terminal: terminal,
            controller: controller,
            performShortcut: { _ in },
            finishTmuxCopyMode: {},
            shortcutBackend: .tmux,
            orderStore: store
        )
        // In a window: the ARRANGE KEYS bar mounts there, over the rail.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 300))
        window.addSubview(bar)
        bar.frame = CGRect(x: 0, y: 200, width: 1024, height: TerminalKeyBar.barHeight)
        func state(arranging: Bool) -> TerminalKeyBarObservedState {
            TerminalKeyBarObservedState(
                hardwareKeyboardConnected: false,
                keyboardLocked: false,
                isDictating: false,
                talkbackOpen: false,
                arranging: arranging,
                order: store.order
            )
        }
        // Painted, not observed: the simulator reports a hardware keyboard,
        // which would fill the keyboard slot with the mic.
        bar.applyObservedState(state(arranging: false))
        bar.layoutIfNeeded()

        // The order permutes keys across the tier's slots; the gaps stay.
        XCTAssertEqual(Array(bar.renderedSlots.prefix(4)), [.shortcuts, .keyboard, .tab, .escape])
        XCTAssertEqual(
            bar.renderedKeys.prefix(3).map(\.accessibilityIdentifier),
            ["terminal.keybar.tmux", "terminal.keybar.keyboard", "terminal.keybar.tab"]
        )
        XCTAssertEqual(bar.renderedKeys.count, 17)
        let frames = bar.renderedKeys.map(\.frame)
        XCTAssertEqual(frames[1].minX - frames[0].maxX, 6)
        XCTAssertGreaterThan(frames[3].minX - frames[2].maxX, 8, "The first group gap holds after slot 3")
        XCTAssertTrue(bar.renderedKeys.allSatisfy(\.isUserInteractionEnabled))
        XCTAssertNil(bar.renderedKeys[0].accessibilityCustomActions)
        XCTAssertFalse(bar.isArrangingForTesting)
        XCTAssertNil(bar.arrangeBarForTesting)

        // Arrange Keys flips in place: same controls, now inert to touch,
        // movable through VoiceOver's custom actions.
        let escapeBefore = bar.renderedKeys[3]
        bar.applyObservedState(state(arranging: true))
        bar.layoutIfNeeded()
        window.layoutIfNeeded()
        XCTAssertTrue(bar.isArrangingForTesting)
        XCTAssertTrue(bar.renderedKeys[3] === escapeBefore, "Entering the mode rebuilds nothing")
        // Still live controls — gaze on visionOS targets interactive
        // elements — but inert: no action, no hold, a drag source instead.
        XCTAssertTrue(bar.renderedKeys.allSatisfy(\.isUserInteractionEnabled))
        XCTAssertTrue(bar.renderedKeys.allSatisfy(\.isArranging))
        XCTAssertTrue(bar.renderedKeys.allSatisfy(\.isArrangeDragSourceForTesting))
        XCTAssertEqual(
            bar.renderedKeys[0].accessibilityCustomActions?.map(\.name),
            ["Move left", "Move right"]
        )
        XCTAssertFalse(bar.renderedKeys[0].accessibilityActivate(), "A press sends nothing in the mode")

        // The bar hangs over the rail — a window subview pinned 6 pt above
        // the rail's top and centred on it — with RESET (the order is
        // custom) and DONE.
        let arrangeBar = try XCTUnwrap(bar.arrangeBarForTesting)
        XCTAssertTrue(arrangeBar.superview === window)
        XCTAssertEqual(arrangeBar.frame.maxY, bar.frame.minY - 6, accuracy: 0.5)
        XCTAssertEqual(arrangeBar.frame.midX, bar.frame.midX, accuracy: 0.5)
        XCTAssertNotNil(chip("Restore the standard key order", in: arrangeBar))
        XCTAssertTrue(renderedText(in: arrangeBar).contains("ARRANGE KEYS"))

        XCTAssertFalse(bar.moveKey(.shortcuts, by: -1), "The leftmost key has nowhere to go")
        XCTAssertFalse(bar.moveKey(.tilde, by: 99))
        XCTAssertTrue(bar.moveKey(.tab, by: 1))
        XCTAssertEqual(Array(store.order.slots.prefix(4)), [.shortcuts, .keyboard, .escape, .tab])
        // Painted here (the observation's turn in production), the row
        // rebuilds in the new order, still arranging.
        bar.applyObservedState(state(arranging: true))
        bar.layoutIfNeeded()
        XCTAssertEqual(Array(bar.renderedSlots.prefix(4)), [.shortcuts, .keyboard, .escape, .tab])
        XCTAssertTrue(bar.renderedKeys.allSatisfy(\.isArranging))
        XCTAssertTrue(bar.arrangeBarForTesting === arrangeBar, "RESET's presence unchanged: the bar stays")

        // RESET restores the shipped order; the rebuilt bar drops the chip.
        let reset = try XCTUnwrap(chip("Restore the standard key order", in: arrangeBar))
        XCTAssertTrue(reset.accessibilityActivate())
        XCTAssertEqual(store.order, .standard)
        bar.applyObservedState(state(arranging: true))
        bar.layoutIfNeeded()
        XCTAssertEqual(Array(bar.renderedSlots.prefix(3)), [.escape, .control, .tab])
        let standardBar = try XCTUnwrap(bar.arrangeBarForTesting)
        XCTAssertFalse(standardBar === arrangeBar)
        XCTAssertNil(chip("Restore the standard key order", in: standardBar))

        // DONE ends the mode through the controller; painted back, the rail
        // is live again and the bar is gone.
        controller.setKeyBarArranging(true)
        let done = try XCTUnwrap(chip("Done arranging keys", in: standardBar))
        XCTAssertTrue(done.isProminent)
        XCTAssertTrue(done.accessibilityActivate())
        XCTAssertFalse(controller.keyBarArranging)
        bar.applyObservedState(state(arranging: false))
        bar.layoutIfNeeded()
        XCTAssertFalse(bar.isArrangingForTesting)
        XCTAssertNil(bar.arrangeBarForTesting)
        XCTAssertNil(standardBar.superview)
        XCTAssertTrue(bar.renderedKeys.allSatisfy(\.isUserInteractionEnabled))
        XCTAssertTrue(bar.renderedKeys.allSatisfy { !$0.isArranging })
        XCTAssertNil(bar.renderedKeys[0].accessibilityCustomActions)
        XCTAssertTrue(bar.renderedKeys[0].accessibilityActivate())

        // A rail leaving its window takes the mode (and the bar) with it.
        controller.setKeyBarArranging(true)
        bar.applyObservedState(state(arranging: true))
        bar.layoutIfNeeded()
        XCTAssertNotNil(bar.arrangeBarForTesting)
        bar.removeFromSuperview()
        XCTAssertNil(bar.arrangeBarForTesting)
        XCTAssertFalse(controller.keyBarArranging)
    }

    /// A fake drop session against the rail's own drop interaction: ESC
    /// dropped on TAB lands after it, in place, with the displaced keys
    /// parked on their old centres for the animator.
    func testADropSessionOnTheRailLandsThroughTheDelegate() throws {
        let store = KeyBarOrderStore(defaults: try isolatedDefaults())
        let host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        let controller = TerminalSessionController(
            route: TerminalRoute(hostID: host.id, mode: .attach(sessionName: "main")),
            host: host
        )
        let bar = TerminalKeyBar(
            terminal: TerminalView(frame: CGRect(x: 0, y: 0, width: 1024, height: 200)),
            controller: controller,
            performShortcut: { _ in },
            finishTmuxCopyMode: {},
            shortcutBackend: .tmux,
            orderStore: store
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 300))
        window.addSubview(bar)
        bar.frame = CGRect(x: 0, y: 200, width: 1024, height: TerminalKeyBar.barHeight)
        bar.applyObservedState(TerminalKeyBarObservedState(
            hardwareKeyboardConnected: false,
            keyboardLocked: false,
            isDictating: false,
            talkbackOpen: false,
            arranging: true,
            order: store.order
        ))
        bar.layoutIfNeeded()
        window.layoutIfNeeded()
        let (escape, control, tab) = (bar.renderedKeys[0], bar.renderedKeys[1], bar.renderedKeys[2])
        let frames = bar.renderedKeys.map(\.frame)
        func dropInteraction(on view: UIView) -> UIDropInteraction? {
            view.interactions.compactMap { $0 as? UIDropInteraction }
                .first { $0.delegate === bar.dropCoordinator }
        }
        let interaction = try XCTUnwrap(dropInteraction(on: bar))
        let coordinator = bar.dropCoordinator
        XCTAssertNotNil(dropInteraction(on: window), "The container is a host too")
        XCTAssertNotNil(dropInteraction(on: try XCTUnwrap(bar.arrangeBarForTesting)))

        let dragSession = FakeDragSession()
        let item = try XCTUnwrap(escape.arrangeDragItem?(dragSession))
        let session = FakeDropSession(
            items: [item],
            localDragSession: dragSession,
            windowPoint: CGPoint(x: frames[2].midX, y: 220)
        )
        XCTAssertTrue(coordinator.dropInteraction(interaction, canHandle: session))
        XCTAssertEqual(coordinator.dropInteraction(interaction, sessionDidUpdate: session).operation, .move)
        XCTAssertTrue(tab.isDropTarget)
        session.windowPoint = CGPoint(x: frames[0].midX, y: 220)
        XCTAssertEqual(coordinator.dropInteraction(interaction, sessionDidUpdate: session).operation, .forbidden)
        XCTAssertFalse(tab.isDropTarget)

        session.windowPoint = CGPoint(x: frames[2].midX, y: 220)
        coordinator.dropInteraction(interaction, performDrop: session)
        XCTAssertEqual(Array(bar.renderedSlots.prefix(3)), [.control, .tab, .escape])
        XCTAssertEqual(Array(store.order.slots.prefix(3)), [.control, .tab, .escape])
        XCTAssertTrue(bar.renderedKeys[2] === escape, "Same control, new slot")
        XCTAssertEqual(escape.center.x, frames[2].midX, accuracy: 0.5)
        XCTAssertEqual(control.transform.tx, frames[1].midX - frames[0].midX, accuracy: 0.5)
        XCTAssertEqual(tab.transform.tx, frames[2].midX - frames[1].midX, accuracy: 0.5)
        let preview = coordinator.dropInteraction(
            interaction, previewForDropping: item, withDefault: UITargetedDragPreview(view: escape)
        )
        XCTAssertEqual(preview?.target.center, escape.center)

        let animator = FakeDragAnimator()
        coordinator.dropInteraction(interaction, item: item, willAnimateDropWith: animator)
        animator.runAnimations()
        animator.runCompletions()
        coordinator.dropInteraction(interaction, concludeDrop: session)
        coordinator.dropInteraction(interaction, sessionDidEnd: session)
        XCTAssertEqual(control.transform, .identity)
        XCTAssertTrue(bar.renderedKeys.allSatisfy { !$0.isDropTarget && $0.isArranging })
    }

    private func chip(_ label: String, in root: UIView) -> UIKitChassisChip? {
        if let root = root as? UIKitChassisChip, root.accessibilityLabel == label { return root }
        for child in root.subviews {
            if let match = chip(label, in: child) { return match }
        }
        return nil
    }

    private func renderedText(in root: UIView) -> [String] {
        var values: [String] = []
        if let label = root as? UILabel {
            if let text = label.text { values.append(text) }
            if let text = label.attributedText?.string { values.append(text) }
        }
        for child in root.subviews { values.append(contentsOf: renderedText(in: child)) }
        return values
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "TerminalKeyBarUIKitTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func specification(
        width: CGFloat,
        returns: Bool,
        safeArea: UIEdgeInsets = .zero
    ) -> TerminalKeyBarLayout.Specification {
        TerminalKeyBarLayout.specification(
            width: width,
            contentSafeArea: safeArea,
            showsTmux: true,
            includesReturn: returns
        )
    }

    private func descendants(in root: UIView) -> [UIView] {
        root.subviews + root.subviews.flatMap(descendants(in:))
    }
}
#else
@MainActor
final class TerminalKeyClusterUIKitTests: XCTestCase {
    func testNativeSlabsPreserveRegularAndCompactGeometry() throws {
        let context = TerminalKeyClusterContext(orderStore: try isolatedStore())
        let leading = TerminalKeyClusterGroupView(
            role: .leading,
            metric: .regular,
            context: context
        )
        let trailing = TerminalKeyClusterGroupView(
            role: .trailing,
            metric: .regular,
            context: context
        )
        let standalone = TerminalKeyClusterGroupView(
            role: .standalone,
            metric: .regular,
            context: context
        )

        XCTAssertEqual(leading.intrinsicContentSize, CGSize(width: 174, height: 44))
        // arrows · RET · talk · keyboard: seven faces, three tail gaps.
        XCTAssertEqual(trailing.intrinsicContentSize, CGSize(width: 400, height: 44))
        XCTAssertEqual(
            standalone.fittingSize(maximumWidth: 600),
            CGSize(width: 562, height: 44)
        )
        // 420 no longer holds the compact run with its arrows (436): the
        // standalone slab drops to its minimal tier there.
        XCTAssertEqual(
            standalone.fittingSize(maximumWidth: 420),
            CGSize(width: 272, height: 44)
        )
        XCTAssertEqual(
            standalone.fittingSize(maximumWidth: 375),
            CGSize(width: 272, height: 44)
        )
    }

    func testNativeSlabsKeepKeyOrderRepeatSemanticsAndAccessibility() throws {
        // An isolated store: the simulator's container may carry a custom
        // order from a headless proof, and this test speaks for the shipped one.
        let context = TerminalKeyClusterContext(orderStore: try isolatedStore())
        let leading = TerminalKeyClusterGroupView(
            role: .leading,
            metric: .regular,
            context: context
        )
        let trailing = TerminalKeyClusterGroupView(
            role: .trailing,
            metric: .regular,
            context: context
        )

        XCTAssertEqual(
            leading.keys.map(\.accessibilityIdentifier),
            [
                "terminal.keyCluster.escape",
                "terminal.keyCluster.control",
                "terminal.keyCluster.tab",
            ]
        )
        XCTAssertEqual(
            trailing.keys.map(\.accessibilityIdentifier),
            [
                "terminal.keyCluster.left",
                "terminal.keyCluster.up",
                "terminal.keyCluster.down",
                "terminal.keyCluster.right",
                "terminal.keyCluster.return",
                "terminal.keyCluster.talkback",
                "terminal.keyCluster.keyboard",
            ]
        )
        XCTAssertTrue(trailing.keys.prefix(4).allSatisfy(\.repeats))
        XCTAssertFalse(trailing.keys.suffix(3).contains(where: \.repeats))
        XCTAssertEqual(leading.layer.cornerRadius, 12)
        XCTAssertEqual(leading.layer.borderWidth, 1)
        XCTAssertFalse((leading.subviews + trailing.subviews).contains {
            String(describing: type(of: $0)).contains("Hosting")
        })
    }

    func testClustersFollowTheStoredOrderAcrossSlabsAndArrangeMovesCrossTheUMD() throws {
        let suite = "TerminalKeyClusterUIKitTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KeyBarOrderStore(defaults: defaults)
        store.setOrder(KeyBarOrder(slots: [.keyboard, .escape]))
        let context = TerminalKeyClusterContext(orderStore: store)
        let leading = TerminalKeyClusterGroupView(role: .leading, metric: .regular, context: context)
        let trailing = TerminalKeyClusterGroupView(role: .trailing, metric: .regular, context: context)
        let standalone = TerminalKeyClusterGroupView(
            role: .standalone,
            metric: .regular,
            context: context
        )

        // The order permutes keys across the ornament's ten slots: the first
        // three lead, the other seven trail; the slabs keep their widths.
        XCTAssertEqual(leading.renderedSlots, [.keyboard, .escape, .control])
        XCTAssertEqual(
            trailing.renderedSlots,
            [.tab, .left, .up, .down, .right, .returnKey, .talkback]
        )
        XCTAssertEqual(
            leading.keys.map(\.accessibilityIdentifier),
            [
                "terminal.keyCluster.keyboard",
                "terminal.keyCluster.escape",
                "terminal.keyCluster.control",
            ]
        )
        XCTAssertEqual(leading.intrinsicContentSize, CGSize(width: 174, height: 44))
        XCTAssertEqual(trailing.intrinsicContentSize, CGSize(width: 400, height: 44))
        XCTAssertTrue(leading.carriesControlKey, "CTRL's slab follows the order")
        XCTAssertFalse(trailing.carriesControlKey)
        XCTAssertFalse(trailing.keys[0].repeats, "TAB took an arrow slot; repeat follows the key")
        XCTAssertTrue(trailing.keys[1].repeats)
        XCTAssertEqual(Array(standalone.renderedSlots.prefix(3)), [.keyboard, .escape, .control])
        XCTAssertEqual(standalone.renderedSlots.count, 10)

        // The minimal standalone tier drops the arrows and keeps the order.
        standalone.frame = CGRect(x: 0, y: 0, width: 300, height: 44)
        standalone.layoutIfNeeded()
        XCTAssertEqual(
            standalone.renderedSlots,
            [.keyboard, .escape, .control, .tab, .returnKey, .talkback]
        )

        // In a window, like the ornament: the context reads the live row
        // from the slabs on screen.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 900, height: 100))
        window.addSubview(leading)
        leading.frame = CGRect(x: 0, y: 0, width: 174, height: 44)
        window.addSubview(trailing)
        trailing.frame = CGRect(x: 480, y: 0, width: 400, height: 44)
        leading.layoutIfNeeded()
        trailing.layoutIfNeeded()

        // Arrange mode flows from the active tab through the context and
        // flips every slab in place.
        let host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        let controller = TerminalSessionController(
            route: TerminalRoute(hostID: host.id, mode: .attach(sessionName: "main")),
            host: host
        )
        context.update(controller: controller)
        XCTAssertTrue(leading.keys.allSatisfy(\.isUserInteractionEnabled))
        controller.setKeyBarArranging(true)
        leading.applyContextState()
        trailing.applyContextState()
        XCTAssertTrue(leading.keys.allSatisfy(\.isArranging))
        XCTAssertTrue(trailing.keys.allSatisfy(\.isArranging))
        XCTAssertTrue(trailing.keys.allSatisfy(\.isUserInteractionEnabled), "Gaze needs live targets")
        XCTAssertTrue(trailing.keys.allSatisfy(\.isArrangeDragSourceForTesting))
        XCTAssertEqual(
            leading.keys[0].accessibilityCustomActions?.map(\.name),
            ["Move left", "Move right"]
        )
        XCTAssertFalse(leading.keys[0].accessibilityActivate())

        // A move across the UMD: the keyboard key leaves the leading slab
        // for the trailing one and TAB comes the other way — one order
        // write, both slabs rebuilt, still arranging.
        XCTAssertFalse(context.moveKey(.keyboard, by: -1), "The leftmost key has nowhere to go")
        XCTAssertTrue(context.moveKey(.keyboard, by: 3))
        XCTAssertEqual(
            Array(store.order.slots.prefix(4)),
            [.escape, .control, .tab, .keyboard]
        )
        XCTAssertEqual(leading.renderedSlots, [.escape, .control, .tab])
        XCTAssertEqual(
            trailing.renderedSlots,
            [.keyboard, .left, .up, .down, .right, .returnKey, .talkback]
        )
        XCTAssertTrue(leading.keys.allSatisfy(\.isArranging))
        XCTAssertTrue(trailing.keys.allSatisfy(\.isArranging))
        XCTAssertFalse(leading.carriesControlKey == trailing.carriesControlKey)

        // Another tab taking the ornament ends the mode on the one leaving.
        let other = TerminalSessionController(
            route: TerminalRoute(hostID: host.id, mode: .attach(sessionName: "scratch")),
            host: host
        )
        context.update(controller: other)
        XCTAssertFalse(controller.keyBarArranging)
        leading.applyContextState()
        XCTAssertTrue(leading.keys.allSatisfy { !$0.isArranging })
        XCTAssertNil(leading.keys[0].accessibilityCustomActions)
    }

    /// A fake drop session against the trailing slab's drop interaction
    /// (the visionOS simulator cannot lift a drag): TAB dropped on ← lands
    /// after it across the UMD, ← comes over parked on its old centre for
    /// the animator, and a drop on CTRL brings TAB back.
    func testADropSessionOverTheOtherSlabLandsThroughTheDelegate() throws {
        let store = try isolatedStore()
        let context = TerminalKeyClusterContext(orderStore: store)
        let leading = TerminalKeyClusterGroupView(role: .leading, metric: .regular, context: context)
        let trailing = TerminalKeyClusterGroupView(role: .trailing, metric: .regular, context: context)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 900, height: 100))
        window.addSubview(leading)
        leading.frame = CGRect(x: 0, y: 0, width: 174, height: 44)
        window.addSubview(trailing)
        trailing.frame = CGRect(x: 480, y: 0, width: 400, height: 44)
        leading.layoutIfNeeded()
        trailing.layoutIfNeeded()
        let host = Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
        let controller = TerminalSessionController(
            route: TerminalRoute(hostID: host.id, mode: .attach(sessionName: "main")),
            host: host
        )
        context.update(controller: controller)
        let tab = try XCTUnwrap(leading.keys.last)
        let dragSession = FakeDragSession()
        XCTAssertNil(tab.arrangeDragItem?(dragSession), "Nothing lifts outside the mode")
        controller.setKeyBarArranging(true)
        leading.applyContextState()
        trailing.applyContextState()
        let ornament = TerminalKeyClusterContext.ornamentSlots

        // Leading keys at x 12 · 64 · 116 (46 wide), the trailing slab's
        // first at 492: the UMD between belongs to the nearer key.
        let row: CGFloat = 22
        let coordinator = context.dropCoordinator
        XCTAssertNil(coordinator.targetSlot(at: CGPoint(x: 139, y: row), in: window, source: .tab))
        XCTAssertEqual(coordinator.targetSlot(at: CGPoint(x: 300, y: row), in: window, source: .escape), .tab)
        XCTAssertEqual(coordinator.targetSlot(at: CGPoint(x: 400, y: row), in: window, source: .escape), .left)

        func dropInteraction(on view: UIView) -> UIDropInteraction? {
            view.interactions.compactMap { $0 as? UIDropInteraction }
                .first { $0.delegate === context.dropCoordinator }
        }
        let interaction = try XCTUnwrap(dropInteraction(on: trailing), "Every slab is a drop host")
        XCTAssertNotNil(dropInteraction(on: leading))
        let item = try XCTUnwrap(tab.arrangeDragItem?(dragSession))
        let session = FakeDropSession(
            items: [item],
            localDragSession: dragSession,
            windowPoint: CGPoint(x: 515, y: row)
        )
        XCTAssertTrue(coordinator.dropInteraction(interaction, canHandle: session))
        XCTAssertEqual(coordinator.dropInteraction(interaction, sessionDidUpdate: session).operation, .move)
        XCTAssertTrue(trailing.keys[0].isDropTarget, "← lights")
        coordinator.dropInteraction(interaction, performDrop: session)
        XCTAssertEqual(leading.renderedSlots, [.escape, .control, .left])
        XCTAssertEqual(trailing.renderedSlots.first, .tab)
        XCTAssertEqual(Array(store.order.arrange(ornament).prefix(4)), [.escape, .control, .left, .tab])
        let landed = try XCTUnwrap(trailing.keys.first)
        let left = try XCTUnwrap(leading.keys.last)
        XCTAssertEqual(left.transform.tx, 515 - 139, accuracy: 0.5, "← parked on its old centre")
        XCTAssertTrue(leading.keys.allSatisfy(\.isArranging) && trailing.keys.allSatisfy(\.isArranging))
        let preview = coordinator.dropInteraction(
            interaction, previewForDropping: item, withDefault: UITargetedDragPreview(view: landed)
        )
        XCTAssertTrue(preview?.target.container === trailing)
        XCTAssertEqual(preview?.target.center, landed.center)

        let animator = FakeDragAnimator()
        coordinator.dropInteraction(interaction, item: item, willAnimateDropWith: animator)
        animator.runAnimations()
        animator.runCompletions()
        coordinator.dropInteraction(interaction, concludeDrop: session)
        coordinator.dropInteraction(interaction, sessionDidEnd: session)
        XCTAssertEqual(left.transform, .identity)
        XCTAssertTrue(trailing.keys.allSatisfy { !$0.isDropTarget })

        // And back: TAB dropped on CTRL lands before it.
        XCTAssertTrue(context.dropKey(.tab, onto: .control))
        XCTAssertEqual(leading.renderedSlots, [.escape, .tab, .control])
        XCTAssertEqual(trailing.renderedSlots.first, .left)
        XCTAssertFalse(context.dropKey(.pipe, onto: .tab), "A rail-only slot is not on the ornament")
    }

    func testSlotFramesRunKeysAtSpacingAndRunsAGroupGapApart() {
        let frames = TerminalKeyClusterGroupView.slotFrames(
            widths: Array(repeating: 46, count: 5), runs: [3, 1, 1], spacing: 6, groupGap: 12
        )
        XCTAssertEqual(frames.map(\.minX), [12, 64, 116, 174, 232])
        XCTAssertTrue(frames.allSatisfy { $0.minY == 9 && $0.height == 26 })
        XCTAssertEqual(
            TerminalKeyClusterGroupView.slotFrames(widths: [46], runs: [3], spacing: 6, groupGap: 12).count,
            1,
            "Runs stop at the keys there are"
        )
    }

    private func isolatedStore() throws -> KeyBarOrderStore {
        let suite = "TerminalKeyClusterUIKitTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return KeyBarOrderStore(defaults: defaults)
    }
}
#endif

// MARK: - Drag and drop session fakes

/// A drag session for a key's item closure.
@MainActor
private final class FakeDragSession: NSObject, UIDragSession {
    var localContext: Any?
    var items: [UIDragItem] = []
    var allowsMoveOperation: Bool { true }
    var isRestrictedToDraggingApplication: Bool { true }
    func location(in view: UIView) -> CGPoint { .zero }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: NSItemProviderReading.Type) -> Bool { false }
}

/// A drop session at one window point carrying the lifted key's item.
@MainActor
private final class FakeDropSession: NSObject, UIDropSession {
    let items: [UIDragItem]
    let localDragSession: UIDragSession?
    let progress = Progress()
    var progressIndicatorStyle: UIDropSessionProgressIndicatorStyle = .none
    var windowPoint: CGPoint
    var allowsMoveOperation: Bool { true }
    var isRestrictedToDraggingApplication: Bool { true }

    init(items: [UIDragItem], localDragSession: UIDragSession?, windowPoint: CGPoint) {
        self.items = items
        self.localDragSession = localDragSession
        self.windowPoint = windowPoint
    }

    func location(in view: UIView) -> CGPoint { view.convert(windowPoint, from: nil) }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: NSItemProviderReading.Type) -> Bool { false }
    func loadObjects(
        ofClass aClass: NSItemProviderReading.Type,
        completion: @escaping ([NSItemProviderReading]) -> Void
    ) -> Progress {
        Progress()
    }
}

@MainActor
private final class FakeDragAnimator: NSObject, UIDragAnimating {
    private var animations: [() -> Void] = []
    private var completions: [(UIViewAnimatingPosition) -> Void] = []

    func addAnimations(_ animations: @escaping () -> Void) {
        self.animations.append(animations)
    }

    func addCompletion(_ completion: @escaping (UIViewAnimatingPosition) -> Void) {
        completions.append(completion)
    }

    func runAnimations() {
        animations.forEach { $0() }
    }

    func runCompletions() {
        completions.forEach { $0(.end) }
    }
}
