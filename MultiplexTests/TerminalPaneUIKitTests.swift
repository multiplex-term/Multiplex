import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class TerminalPaneUIKitTests: XCTestCase {
    func testConnectingCaptionsDistinguishFirstConnectShellResumeAndTmuxResume() {
        XCTAssertEqual(
            TerminalPaneViewController.connectingCaption(
                hostName: "devbox",
                sessionName: "main",
                isResuming: false
            ),
            "Connecting to devbox…"
        )
        XCTAssertEqual(
            TerminalPaneViewController.connectingCaption(
                hostName: "devbox",
                sessionName: nil,
                isResuming: true
            ),
            "Reconnecting to devbox…"
        )
        XCTAssertEqual(
            TerminalPaneViewController.connectingCaption(
                hostName: "devbox",
                sessionName: "main",
                isResuming: true
            ),
            "Reattaching to devbox…"
        )
    }

    func testRemovedHostUsesNativeVerdictAndCloseAction() throws {
        var closes = 0
        let pane = TerminalPaneViewController(configuration: configuration(
            controller: nil,
            hostExists: false,
            close: { closes += 1 }
        ))
        pane.loadViewIfNeeded()

        XCTAssertNil(pane.terminalSurface)
        XCTAssertNotNil(view("terminalPane.missingHost", in: pane.view))
        XCTAssertTrue(renderedText(in: pane.view).contains("This host was removed"))
        let close = try XCTUnwrap(chip("Close tab", in: pane.view))
        XCTAssertTrue(close.isProminent)
        XCTAssertTrue(close.accessibilityActivate())
        XCTAssertEqual(closes, 1)
    }

    func testConnectingAndEndedStatesOverlayOnePersistentNativeTerminalSurface() throws {
        let terminal = terminalController(mode: .attach(sessionName: "main"))
        var closes = 0
        let pane = TerminalPaneViewController(configuration: configuration(
            controller: terminal,
            close: { closes += 1 }
        ))
        pane.loadViewIfNeeded()

        let surface = try XCTUnwrap(pane.terminalSurface)
        XCTAssertNotNil(view("terminalPane.status.connecting", in: pane.view))
        XCTAssertEqual(
            view("terminalPane.status.connecting", in: pane.view)?.accessibilityLabel,
            "Connecting to devbox…"
        )

        var state = TerminalPaneObservedState(controller: terminal)
        state.status = .ended("Connection lost")
        pane.applyObservedState(state)

        XCTAssertTrue(pane.terminalSurface === surface)
        XCTAssertNil(view("terminalPane.status.connecting", in: pane.view))
        XCTAssertNotNil(view("terminalPane.status.ended", in: pane.view))
        XCTAssertTrue(renderedText(in: pane.view).contains("Connection lost"))
        XCTAssertNotNil(chip("Reconnect", in: pane.view))
        let close = try XCTUnwrap(chip("Close tab", in: pane.view))
        XCTAssertTrue(close.accessibilityActivate())
        XCTAssertEqual(closes, 1)
    }

    func testTerminalGutterAndSurfaceUseSelectedThemeWithoutBezelFrame() throws {
        let terminal = terminalController(mode: .attach(sessionName: "main"))
        var configuration = configuration(controller: terminal)
        configuration.theme = .solarizedDark
        let pane = TerminalPaneViewController(configuration: configuration)
        pane.loadViewIfNeeded()

        let expected = UIColor(configuration.theme.background)
            .resolvedColor(with: pane.traitCollection)
        XCTAssertEqual(
            pane.view.backgroundColor?.resolvedColor(with: pane.traitCollection),
            expected
        )
        let surface = try XCTUnwrap(pane.terminalSurface)
        // PROTOTYPE(GLASS): the surface stays non-opaque wherever the glass
        // prototype is compiled in, so the pane can go translucent live.
        XCTAssertEqual(surface.isOpaque, !GlassPrototype.enabled)
        XCTAssertEqual(
            surface.backgroundColor?.resolvedColor(with: surface.traitCollection),
            expected
        )
    }

    func testCopyHistoryFindingNoticeAndDropChromeRemainNativeAndLayered() {
        let terminal = terminalController(mode: .attach(sessionName: "agent"))
        let pane = TerminalPaneViewController(configuration: configuration(
            controller: terminal
        ))
        pane.loadViewIfNeeded()
        var state = TerminalPaneObservedState(controller: terminal)
        state.status = .live
        state.tmuxCopyModeUIActive = true
        state.historyJump = .finding(preview: "Fix the probe parser")
        state.historyNotice = "AGENT IS BUSY"
        state.dropState = .uploading(name: "notes.md", fraction: 0.62)

        pane.applyObservedState(state)

        XCTAssertNotNil(view("terminalPane.context.copyMode", in: pane.view))
        XCTAssertNotNil(view("terminalPane.history.findingVeil", in: pane.view))
        XCTAssertNotNil(view("terminalPane.history.notice", in: pane.view))
        XCTAssertNotNil(view("terminalPane.drop.status", in: pane.view))
        XCTAssertNil(view("terminalPane.context.historyJump", in: pane.view))
        XCTAssertTrue(renderedText(in: pane.view).contains("COPY MODE"))
        XCTAssertTrue(renderedText(in: pane.view).contains("AGENT IS BUSY"))
        XCTAssertTrue(renderedText(in: pane.view).contains("notes.md · 62%"))
    }

    func testSharedSelectionMenuEntryPointOpensAppOwnedBlock() throws {
        let terminal = terminalController(mode: .attach(sessionName: "main"))
        let pane = TerminalPaneViewController(configuration: configuration(
            controller: terminal
        ))
        pane.loadViewIfNeeded()
        pane.view.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        pane.view.layoutIfNeeded()
        var state = TerminalPaneObservedState(controller: terminal)
        state.status = .live

        pane.applyObservedState(state)

        let terminalView = try XCTUnwrap(terminal.terminalView)
        let menu = try XCTUnwrap(view("terminalPane.longPress.menu", in: pane.view))
        XCTAssertTrue(menu.isHidden)
        XCTAssertTrue(terminalView.presentSelectionMenu(at: CGPoint(x: 20, y: 20)))
        XCTAssertFalse(menu.isHidden)
    }

    func testHistoryBarMovesToTrailingSlotWhenCopyModeEnds() {
        let terminal = terminalController(mode: .attach(sessionName: "agent"))
        let pane = TerminalPaneViewController(configuration: configuration(
            controller: terminal
        ))
        pane.loadViewIfNeeded()
        var state = TerminalPaneObservedState(controller: terminal)
        state.status = .live
        state.historyJump = .jumped(preview: "Ship UIKit", pages: 7)

        pane.applyObservedState(state)

        XCTAssertNil(view("terminalPane.context.copyMode", in: pane.view))
        XCTAssertNotNil(view("terminalPane.context.historyJump", in: pane.view))
        XCTAssertTrue(renderedText(in: pane.view).contains("JUMPED"))
        XCTAssertNotNil(chip("Back to live", in: pane.view))
    }

    private func terminalController(
        mode: TerminalRoute.Mode
    ) -> TerminalSessionController {
        let host = Host(
            name: "devbox",
            hostname: "127.0.0.1",
            username: "tester"
        )
        return TerminalSessionController(
            route: TerminalRoute(hostID: host.id, mode: mode),
            host: host
        )
    }

    private func configuration(
        controller: TerminalSessionController?,
        hostExists: Bool = true,
        close: @escaping () -> Void = {}
    ) -> TerminalPaneConfiguration {
        TerminalPaneConfiguration(
            controller: controller,
            hostExists: hostExists,
            fontSize: 14,
            theme: .tally,
            bottomChromeHeight: 0,
            contentSafeArea: .zero,
            railOwnsBottomSafeArea: false,
            isActive: true,
            focusAllowed: true,
            close: close
        )
    }

    private func view(_ identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for child in root.subviews {
            if let match = view(identifier, in: child) { return match }
        }
        return nil
    }

    private func chip(_ label: String, in root: UIView) -> UIKitChassisChip? {
        if let root = root as? UIKitChassisChip,
           root.accessibilityLabel == label {
            return root
        }
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
}
