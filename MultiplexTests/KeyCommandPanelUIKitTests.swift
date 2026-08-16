import SwiftTerm
import UIKit
import XCTest
@testable import Multiplex

/// The dispatcher: chords and text rows go through `TerminalView.send`, a
/// repeat is a guarded burst, and a submitting text row's Enter is its own
/// later write.
@MainActor
final class KeyCommandDispatcherTests: XCTestCase {
    private func makeTerminal() -> (TerminalView, CapturingTerminalDelegate) {
        CapturingTerminalDelegate.makeTerminal()
    }

    func testChordSendsOnceThroughTheDelegate() async {
        let (terminal, delegate) = makeTerminal()
        let command = KeyCommand(kind: .chord(KeyChord(modifiers: [.shift], key: .enter)))
        let task = KeyCommandDispatcher.perform(command, on: terminal)
        XCTAssertNotNil(task)
        await task?.value
        XCTAssertEqual(delegate.sent, [[0x0A]])
    }

    func testRepeatSendsCountTimesWithTheGap() async {
        let (terminal, delegate) = makeTerminal()
        let command = KeyCommand(
            kind: .chord(KeyChord(modifiers: [.control], key: .character("c"))),
            repeatCount: 2,
            repeatGapMilliseconds: 50
        )
        let started = ContinuousClock.now
        await KeyCommandDispatcher.perform(command, on: terminal)?.value
        let elapsed = ContinuousClock.now - started
        XCTAssertEqual(delegate.sent, [[0x03], [0x03]])
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(45), "The second send waits out the gap")
    }

    func testTextRowTypesThenSubmitsAsASeparateWrite() async {
        let (terminal, delegate) = makeTerminal()
        let command = KeyCommand(kind: .text(KeyTextSnippet(text: "git status", submits: true)))
        await KeyCommandDispatcher.perform(command, on: terminal)?.value
        XCTAssertEqual(delegate.sent, [Array("git status".utf8), [0x0D]])

        delegate.sent = []
        let quiet = KeyCommand(kind: .text(KeyTextSnippet(text: "ls", submits: false)))
        await KeyCommandDispatcher.perform(quiet, on: terminal)?.value
        XCTAssertEqual(delegate.sent, [Array("ls".utf8)])
    }

    func testBlankTextRowSendsNothing() {
        let (terminal, delegate) = makeTerminal()
        let command = KeyCommand(kind: .text(KeyTextSnippet(text: "   ")))
        XCTAssertNil(KeyCommandDispatcher.perform(command, on: terminal))
        XCTAssertTrue(delegate.sent.isEmpty)
    }

    func testDescribeSpellsTheBytesInPlainWords() {
        let (terminal, _) = makeTerminal()
        XCTAssertEqual(
            KeyCommandDispatcher.describe(KeyCommandSet.shipped[0], on: terminal),
            "LF"
        )
        XCTAssertEqual(
            KeyCommandDispatcher.describe(KeyCommandSet.shipped[1], on: terminal),
            "^C"
        )
        XCTAssertEqual(
            KeyCommandDispatcher.describe(
                KeyCommand(kind: .text(KeyTextSnippet(text: "x"))),
                on: terminal
            ),
            "TEXT · THEN CR 160 MS LATER"
        )
        XCTAssertEqual(
            KeyCommandDispatcher.describe(KeyCommandSet.shipped[0], on: nil),
            "NO ENCODING"
        )
    }
}

/// The panel: two tabs over one store, presses that send and close (or
/// stay), a hold that opens the row's setup, and a draft transaction that
/// commits only on DONE.
@MainActor
final class KeyCommandPanelUIKitTests: XCTestCase {
    private var performed: [KeyCommand] = []
    private var dismissals = 0

    private func makePanel(
        store providedStore: KeyCommandStore? = nil,
        plan: KeyCommandPlan = .unrestricted
    ) -> (KeyCommandPanelViewController, KeyCommandStore) {
        let store = providedStore ?? KeyCommandStore(directory: nil)
        performed = []
        dismissals = 0
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let panel = KeyCommandPanelViewController(
            store: store,
            terminal: terminal,
            plan: plan,
            perform: { [weak self] command in self?.performed.append(command) },
            dismiss: { [weak self] in self?.dismissals += 1 }
        )
        panel.loadViewIfNeeded()
        panel.view.frame = CGRect(origin: .zero, size: panel.fittingContentSize())
        panel.view.layoutIfNeeded()
        return (panel, store)
    }

    private func descendants(in root: UIView) -> [UIView] {
        root.subviews + root.subviews.flatMap(descendants(in:))
    }

    private func view(_ identifier: String, in panel: UIViewController) -> UIView? {
        descendants(in: panel.view).first { $0.accessibilityIdentifier == identifier }
    }

    func testCommandsTabShowsEveryStoredRowAsACell() {
        let (panel, store) = makePanel()
        XCTAssertEqual(panel.selectedTab, .commands)
        XCTAssertEqual(
            panel.preferredContentSize,
            panel.fittingContentSize(),
            "Loading the view sizes the popover; the presenter measures nothing twice"
        )
        XCTAssertNotNil(view("keyCommands.title", in: panel))
        XCTAssertNotNil(view("keyCommands.tab.commands", in: panel))
        XCTAssertNotNil(view("keyCommands.tab.setup", in: panel))
        let cells = descendants(in: panel.view).compactMap { $0 as? KeyCommandCell }
        XCTAssertEqual(cells.count, store.commands.count)
        XCTAssertEqual(
            cells.map(\.accessibilityLabel),
            [
                "Shift Enter, closes the panel",
                "Control C, 2 times, closes the panel",
                "Option Delete, panel stays open",
            ]
        )
        XCTAssertLessThanOrEqual(
            panel.fittingContentSize().width,
            KeyCommandPanelViewController.commandsWidth
        )
    }

    func testPressSendsAndClosesOnlyWhenTheRowSaysSo() {
        let (panel, store) = makePanel()
        panel.press(store.commands[0])
        XCTAssertEqual(performed.map(\.id), [store.commands[0].id])
        XCTAssertEqual(dismissals, 1)

        panel.press(store.commands[2])
        XCTAssertEqual(performed.count, 2)
        XCTAssertEqual(dismissals, 1, "The pinned Delete row keeps the panel up")

        let cell = descendants(in: panel.view)
            .compactMap { $0 as? KeyCommandCell }
            .first { $0.accessibilityIdentifier == "keyCommands.cell.\(store.commands[2].id.uuidString)" }
        XCTAssertNotNil(cell)
        XCTAssertTrue(cell?.accessibilityActivate() ?? false)
        XCTAssertEqual(performed.count, 3, "Accessibility activation is a press")
    }

    func testHoldOpensThatRowsSetup() {
        let (panel, store) = makePanel()
        panel.hold(store.commands[1])
        XCTAssertEqual(panel.selectedTab, .setup)
        XCTAssertEqual(panel.expandedID, store.commands[1].id)
        XCTAssertEqual(panel.drafts, store.commands)
        XCTAssertNotNil(view("keyCommands.composer", in: panel))
        XCTAssertNotNil(view("keyCommands.rowHeader.\(store.commands[1].id.uuidString)", in: panel))
        XCTAssertNotNil(view("keyCommands.done", in: panel))
        XCTAssertNotNil(view("keyCommands.cancel", in: panel))
        XCTAssertNotNil(view("keyCommands.add", in: panel))
        XCTAssertGreaterThan(
            panel.fittingContentSize().width,
            KeyCommandPanelViewController.commandsWidth,
            "Setup asks for the wider popover"
        )
    }

    func testDraftsCommitOnDoneAndDiscardOnCancel() {
        let (panel, store) = makePanel()
        panel.selectTab(.setup)
        let added = panel.addCommand()
        XCTAssertNotNil(added)
        XCTAssertEqual(panel.drafts.count, 4)
        XCTAssertEqual(panel.expandedID, added?.id)
        XCTAssertEqual(store.commands.count, 3, "Nothing reaches the store before DONE")

        var edited = added!
        edited.kind = .chord(KeyChord(modifiers: [.option], key: .enter))
        edited.repeatCount = 3
        panel.updateDraft(edited)
        panel.moveCommand(id: edited.id, offset: -1)
        XCTAssertEqual(panel.drafts.map(\.name), ["SHIFT ENTER", "CTRL C", "OPTION ENTER", "OPTION DELETE"])

        panel.saveDrafts()
        XCTAssertEqual(store.commands.map(\.name), ["SHIFT ENTER", "CTRL C", "OPTION ENTER", "OPTION DELETE"])
        XCTAssertEqual(store.commands[2].repeatCount, 3)
        XCTAssertFalse(store.commands[2].isShipped)
        XCTAssertEqual(panel.selectedTab, .commands, "DONE lands back on the grid")
        XCTAssertEqual(
            descendants(in: panel.view).compactMap { $0 as? KeyCommandCell }.count,
            4
        )

        panel.selectTab(.setup)
        panel.deleteCommand(id: store.commands[0].id)
        XCTAssertEqual(panel.drafts.count, 3)
        panel.cancelDrafts()
        XCTAssertEqual(store.commands.count, 4, "CANCEL discards the draft")
        XCTAssertEqual(panel.selectedTab, .commands)
    }

    func testNarrowPanelWrapsTheComposerInsteadOfClipping() {
        let store = KeyCommandStore(directory: nil)
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let panel = KeyCommandPanelViewController(
            store: store,
            terminal: terminal,
            maximumWidth: 366,
            perform: { _ in },
            dismiss: {}
        )
        panel.loadViewIfNeeded()
        XCTAssertEqual(panel.fittingContentSize().width, 366)
        panel.hold(store.commands[0])
        let size = panel.fittingContentSize()
        XCTAssertEqual(size.width, 366, "A phone popover never widens past the scene")
        panel.view.frame = CGRect(origin: .zero, size: size)
        panel.view.layoutIfNeeded()
        let composer = descendants(in: panel.view).compactMap { $0 as? KeyCommandComposerView }.first
        XCTAssertNotNil(composer)
        // Every keycap in the composer stays inside the panel's bounds.
        for cap in descendants(in: panel.view).compactMap({ $0 as? KeyCapControl }) {
            let frame = cap.convert(cap.bounds, to: panel.view)
            XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "\(cap.accessibilityLabel ?? "") clips")
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
        }
        // The direction keys and the letter field take the second line.
        let enter = view("keyCommands.composer.key.enter", in: panel)
        let up = view("keyCommands.composer.key.up", in: panel)
        let field = view("keyCommands.composer.character", in: panel)
        let enterY = enter.map { $0.convert($0.bounds, to: panel.view).minY } ?? 0
        let upY = up.map { $0.convert($0.bounds, to: panel.view).minY } ?? 0
        let fieldY = field.map { $0.convert($0.bounds, to: panel.view).minY } ?? 0
        XCTAssertGreaterThan(upY, enterY + 10, "Arrows drop to the second line on a phone")
        XCTAssertEqual(fieldY, upY, accuracy: 6, "The letter field sits with the arrows")
        // The second line hangs flush with the editing keys' right edge.
        let space = view("keyCommands.composer.key.space", in: panel)
        let spaceMaxX = space.map { $0.convert($0.bounds, to: panel.view).maxX } ?? 0
        let fieldMaxX = field.map { $0.convert($0.bounds, to: panel.view).maxX } ?? 0
        XCTAssertGreaterThan(spaceMaxX, 0)
        XCTAssertEqual(fieldMaxX, spaceMaxX, accuracy: 0.5, "The second line aligns right, under the editing keys")
    }

    func testMacScaleGrowsTheControlsAndWrapsTheComposer() {
        KeyCommandMetrics.scaleOverride = 1.3
        defer { KeyCommandMetrics.scaleOverride = nil }
        let store = KeyCommandStore(directory: nil)
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let panel = KeyCommandPanelViewController(
            store: store,
            terminal: terminal,
            perform: { _ in },
            dismiss: {}
        )
        panel.loadViewIfNeeded()
        panel.hold(store.commands[0])
        let size = panel.fittingContentSize()
        XCTAssertEqual(size.width, KeyCommandPanelViewController.setupWidth)
        panel.view.frame = CGRect(origin: .zero, size: size)
        panel.view.layoutIfNeeded()
        let caps = descendants(in: panel.view).compactMap { $0 as? KeyCapControl }
        XCTAssertFalse(caps.isEmpty)
        for cap in caps {
            let frame = cap.convert(cap.bounds, to: panel.view)
            XCTAssertEqual(frame.height, ceil(26 * 1.3), accuracy: 0.5, "Composer keycaps grow with the scale")
            XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "\(cap.accessibilityLabel ?? "") clips at Mac scale")
        }
        let switches = descendants(in: panel.view).compactMap { $0 as? TallyEditorSwitchTrack }
        XCTAssertFalse(switches.isEmpty)
        for track in switches {
            XCTAssertEqual(track.bounds.height, ceil(14 * 1.3), accuracy: 0.5)
        }
    }

    private func filledStore(count: Int) -> KeyCommandStore {
        let store = KeyCommandStore(directory: nil)
        store.replace((0..<count).map { index in
            KeyCommand(kind: .chord(KeyChord(key: .character(String(index % 10)))))
        })
        return store
    }

    func testAddStopsAtTheCap() throws {
        let (panel, _) = makePanel(store: filledStore(count: KeyCommandSet.maximumCount))
        panel.selectTab(.setup)
        XCTAssertFalse(panel.canAddCommand)
        XCTAssertFalse(panel.addNeedsPro, "The model's cap is a wall, not a Pro route")
        XCTAssertNil(panel.addCommand())
        XCTAssertEqual(panel.drafts.count, KeyCommandSet.maximumCount)
        let add = try XCTUnwrap(view("keyCommands.add", in: panel))
        XCTAssertFalse(add.isUserInteractionEnabled)
        XCTAssertNil(view("keyCommands.legend.tier", in: panel), "An unrestricted plan shows no tier line")
    }

    func testFreePlanAddTurnsIntoTheProRouteAtItsCap() throws {
        var upgrades = 0
        let plan = KeyCommandPlan(limit: 5, upgrade: { upgrades += 1 })
        let (panel, store) = makePanel(store: filledStore(count: 4), plan: plan)
        panel.selectTab(.setup)
        XCTAssertEqual(panel.limit, 5)
        XCTAssertTrue(panel.canAddCommand)
        XCTAssertNotNil(view("keyCommands.legend.tier", in: panel), "The free tier says why the cap is 5")
        let readout = try XCTUnwrap(view("keyCommands.readout", in: panel) as? UILabel)
        XCTAssertEqual(readout.text, "ALL HOSTS · 4 OF 5")

        // The fifth is free; ADD then becomes the Pro route.
        panel.addOrUpgrade()
        XCTAssertEqual(panel.drafts.count, 5)
        XCTAssertEqual(upgrades, 0)
        XCTAssertFalse(panel.canAddCommand)
        XCTAssertTrue(panel.addNeedsPro)
        XCTAssertEqual((view("keyCommands.readout", in: panel) as? UILabel)?.text, "ALL HOSTS · 5 OF 5")
        let add = try XCTUnwrap(view("keyCommands.add", in: panel) as? UIKitChassisChip)
        XCTAssertTrue(add.isUserInteractionEnabled, "The route stays live at the tier's cap")
        XCTAssertTrue(add.isProminent)
        XCTAssertEqual(add.accessibilityLabel, "Add command with Multiplex Pro")
        panel.addOrUpgrade()
        XCTAssertEqual(upgrades, 1)
        XCTAssertEqual(panel.drafts.count, 5, "The route adds nothing")
        XCTAssertNil(panel.addCommand(), "Nor does a direct add past the tier's cap")

        // DONE keeps the five; the plan never trims a set.
        panel.saveDrafts()
        XCTAssertEqual(store.commands.count, 5)
    }

    func testFreePlanKeepsASyncedSetAboveItsCap() {
        var upgrades = 0
        let plan = KeyCommandPlan(limit: 5, upgrade: { upgrades += 1 })
        let (panel, store) = makePanel(store: filledStore(count: 8), plan: plan)
        XCTAssertEqual(
            descendants(in: panel.view).compactMap { $0 as? KeyCommandCell }.count,
            8,
            "Every synced row stays pressable"
        )
        panel.selectTab(.setup)
        XCTAssertEqual(panel.drafts.count, 8)
        XCTAssertFalse(panel.canAddCommand)
        XCTAssertTrue(panel.addNeedsPro)
        panel.addOrUpgrade()
        XCTAssertEqual(upgrades, 1)
        panel.saveDrafts()
        XCTAssertEqual(store.commands.count, 8, "Saving never trims to the tier")
    }

    func testComposerWritesTheDraftAndClampsRepeats() throws {
        let (panel, store) = makePanel()
        panel.hold(store.commands[0])
        let composerView = try XCTUnwrap(
            descendants(in: panel.view).compactMap { $0 as? KeyCommandComposerView }.first
        )

        composerView.toggleModifier(.control)
        composerView.selectKey(.left)
        composerView.setRepeatCount(5)
        composerView.setRepeatGap(500)
        composerView.setClosesPanel(false)
        let draft = panel.drafts[0]
        XCTAssertEqual(draft.chord, KeyChord(modifiers: [.control, .shift], key: .left))
        XCTAssertEqual(draft.repeatCount, 5)
        XCTAssertEqual(draft.repeatGapMilliseconds, 500)
        XCTAssertFalse(draft.closesPanel)
        XCTAssertEqual(draft.readout, "×5 · 500 MS · STAYS")

        composerView.setKind(isText: true)
        composerView.setText("git status")
        composerView.setSubmits(false)
        let text = panel.drafts[0]
        XCTAssertEqual(text.textSnippet, KeyTextSnippet(text: "git status", submits: false))
        XCTAssertEqual(text.name, "git status")

        composerView.setKind(isText: false)
        XCTAssertEqual(panel.drafts[0].chord, KeyChord(key: .enter), "Back to KEYS starts from a plain Enter")
        XCTAssertNotNil(view("keyCommands.composer.modifier.ctrl", in: panel))
        XCTAssertNotNil(view("keyCommands.composer.key.enter", in: panel))
        XCTAssertNotNil(view("keyCommands.composer.character", in: panel))
        XCTAssertNotNil(view("keyCommands.switch.close on press", in: panel))
    }
}
