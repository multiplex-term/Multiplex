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
/// stay), a hold that opens the row's setup, a draft transaction that
/// commits only on DONE, the tier's cap, and the composer's layouts.
@MainActor
final class KeyCommandPanelUIKitTests: XCTestCase {
    private var performed: [KeyCommand] = []
    private var dismissals = 0

    private func makePanel(
        store providedStore: KeyCommandStore? = nil,
        maximumWidth: CGFloat = KeyCommandPanelViewController.setupWidth,
        plan: KeyCommandPlan = .unrestricted
    ) -> (KeyCommandPanelViewController, KeyCommandStore) {
        let store = providedStore ?? KeyCommandStore(directory: nil)
        performed = []
        dismissals = 0
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let panel = KeyCommandPanelViewController(
            store: store,
            terminal: terminal,
            maximumWidth: maximumWidth,
            plan: plan,
            perform: { [weak self] command in self?.performed.append(command) },
            dismiss: { [weak self] in self?.dismissals += 1 }
        )
        panel.loadViewIfNeeded()
        layout(panel)
        return (panel, store)
    }

    private func layout(_ panel: KeyCommandPanelViewController) {
        panel.view.frame = CGRect(origin: .zero, size: panel.fittingContentSize())
        panel.view.layoutIfNeeded()
    }

    private func filledStore(count: Int) -> KeyCommandStore {
        let store = KeyCommandStore(directory: nil)
        store.replace((0..<count).map { index in
            KeyCommand(kind: .chord(KeyChord(key: .character(String(index % 10)))))
        })
        return store
    }

    private func descendants(in root: UIView) -> [UIView] {
        root.subviews + root.subviews.flatMap(descendants(in:))
    }

    private func view(_ identifier: String, in panel: UIViewController) -> UIView? {
        descendants(in: panel.view).first { $0.accessibilityIdentifier == identifier }
    }

    private func frame(_ identifier: String, in panel: UIViewController) -> CGRect {
        view(identifier, in: panel).map { $0.convert($0.bounds, to: panel.view) } ?? .null
    }

    /// Every keycap in the composer stays inside the panel's bounds.
    private func assertNoKeycapClips(
        in panel: KeyCommandPanelViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let caps = descendants(in: panel.view).compactMap { $0 as? KeyCapControl }
        XCTAssertFalse(caps.isEmpty, file: file, line: line)
        for cap in caps {
            let frame = cap.convert(cap.bounds, to: panel.view)
            XCTAssertLessThanOrEqual(
                frame.maxX,
                panel.view.bounds.width + 0.5,
                "\(cap.accessibilityLabel ?? "") clips",
                file: file,
                line: line
            )
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, file: file, line: line)
        }
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
        XCTAssertLessThanOrEqual(panel.fittingContentSize().width, KeyCommandPanelViewController.commandsWidth)
    }

    func testPressSendsAndClosesAsTheRowSaysAndHoldOpensItsSetup() {
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
        XCTAssertTrue(cell?.accessibilityActivate() ?? false)
        XCTAssertEqual(performed.count, 3, "Accessibility activation is a press")

        panel.hold(store.commands[1])
        XCTAssertEqual(panel.selectedTab, .setup)
        XCTAssertEqual(panel.expandedID, store.commands[1].id)
        XCTAssertEqual(panel.drafts, store.commands)
        XCTAssertNotNil(view("keyCommands.composer", in: panel))
        XCTAssertNotNil(view("keyCommands.rowHeader.\(store.commands[1].id.uuidString)", in: panel))
        XCTAssertNotNil(view("keyCommands.done", in: panel))
        XCTAssertNotNil(view("keyCommands.cancel", in: panel))
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
        XCTAssertEqual(descendants(in: panel.view).compactMap { $0 as? KeyCommandCell }.count, 4)

        panel.selectTab(.setup)
        panel.deleteCommand(id: store.commands[0].id)
        XCTAssertEqual(panel.drafts.count, 3)
        panel.cancelDrafts()
        XCTAssertEqual(store.commands.count, 4, "CANCEL discards the draft")
        XCTAssertEqual(panel.selectedTab, .commands)
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

    /// The tier's cap turns ADD COMMAND into the Pro route; the model's cap
    /// is a wall; a set that already holds more than the tier allows is kept.
    func testAddIsCappedByTheTierThenTheModel() throws {
        var upgrades = 0
        let free = KeyCommandPlan(limit: 5, upgrade: { upgrades += 1 })
        let (panel, store) = makePanel(store: filledStore(count: 4), plan: free)
        panel.selectTab(.setup)
        XCTAssertEqual(panel.limit, 5)
        XCTAssertNotNil(view("keyCommands.legend.tier", in: panel), "The free tier says why the cap is 5")
        XCTAssertEqual((view("keyCommands.readout", in: panel) as? UILabel)?.text, "ALL HOSTS · 4 OF 5")

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
        XCTAssertNil(panel.addCommand(), "Neither route adds past the tier's cap")
        XCTAssertEqual(panel.drafts.count, 5)
        panel.saveDrafts()
        XCTAssertEqual(store.commands.count, 5)

        // A synced set above the tier keeps every row; only adding is gated.
        let (synced, syncedStore) = makePanel(store: filledStore(count: 8), plan: free)
        XCTAssertEqual(descendants(in: synced.view).compactMap { $0 as? KeyCommandCell }.count, 8)
        synced.selectTab(.setup)
        XCTAssertTrue(synced.addNeedsPro)
        synced.saveDrafts()
        XCTAssertEqual(syncedStore.commands.count, 8, "Saving never trims to the tier")

        // The model's cap dims the chip instead — no route, no tier line.
        let (full, _) = makePanel(store: filledStore(count: KeyCommandSet.maximumCount))
        full.selectTab(.setup)
        XCTAssertFalse(full.canAddCommand)
        XCTAssertFalse(full.addNeedsPro)
        XCTAssertNil(full.addCommand())
        XCTAssertFalse(try XCTUnwrap(view("keyCommands.add", in: full)).isUserInteractionEnabled)
        XCTAssertNil(view("keyCommands.legend.tier", in: full))
    }

    /// A phone popover wraps the composer's keys onto two lines (the second
    /// hanging flush-right under the editing keys); the Mac's larger scale
    /// grows the controls; neither clips a keycap.
    func testCompactAndScaledComposersStayInsideThePanel() {
        let (phone, phoneStore) = makePanel(maximumWidth: 366)
        XCTAssertEqual(phone.fittingContentSize().width, 366)
        phone.hold(phoneStore.commands[0])
        layout(phone)
        XCTAssertEqual(phone.view.bounds.width, 366, "A phone popover never widens past the scene")
        assertNoKeycapClips(in: phone)
        let enter = frame("keyCommands.composer.key.enter", in: phone)
        let up = frame("keyCommands.composer.key.up", in: phone)
        let field = frame("keyCommands.composer.character", in: phone)
        let space = frame("keyCommands.composer.key.space", in: phone)
        XCTAssertGreaterThan(up.minY, enter.minY + 10, "Arrows drop to the second line on a phone")
        XCTAssertEqual(field.minY, up.minY, accuracy: 6, "The letter field sits with the arrows")
        XCTAssertGreaterThan(space.maxX, 0)
        XCTAssertEqual(field.maxX, space.maxX, accuracy: 0.5, "The second line aligns right, under the editing keys")

        KeyCommandMetrics.scaleOverride = 1.3
        defer { KeyCommandMetrics.scaleOverride = nil }
        let (mac, macStore) = makePanel()
        mac.hold(macStore.commands[0])
        layout(mac)
        XCTAssertEqual(mac.view.bounds.width, KeyCommandPanelViewController.setupWidth)
        assertNoKeycapClips(in: mac)
        for cap in descendants(in: mac.view).compactMap({ $0 as? KeyCapControl }) {
            XCTAssertEqual(cap.bounds.height, ceil(26 * 1.3), accuracy: 0.5, "Composer keycaps grow with the scale")
        }
        let switches = descendants(in: mac.view).compactMap { $0 as? TallyEditorSwitchTrack }
        XCTAssertFalse(switches.isEmpty)
        for track in switches {
            XCTAssertEqual(track.bounds.height, ceil(14 * 1.3), accuracy: 0.5)
        }
    }
}
