import XCTest
@testable import Multiplex

final class PaneTitleDisplayTests: XCTestCase {
    private func window(
        name: String, paneTitle: String, panes: Int = 1
    ) -> TmuxWindow {
        TmuxWindow(
            index: 0, name: name, isActive: true,
            hasBell: false, hasActivity: false, paneTitle: paneTitle,
            panes: (0..<panes).map {
                TmuxPane(
                    index: $0, isActive: $0 == 0, tmuxID: "%\($0)",
                    pid: 100 + $0, tty: "/dev/pts/\($0)", command: "zsh",
                    title: paneTitle
                )
            }
        )
    }

    func testRealTitleSurvives() {
        XCTAssertEqual(
            PaneTitleDisplay.title(
                paneTitle: "✳ Claude Code",
                windowName: "cc",
                serverHost: "Demo-MBPr14.local"
            ),
            "✳ Claude Code"
        )
    }

    func testTmuxSeededHostnameIsSuppressed() {
        // The exact string the dev harness reports on six of thirteen panes.
        XCTAssertNil(PaneTitleDisplay.title(
            paneTitle: "Demo-MBPr14.local",
            windowName: "editor",
            serverHost: "Demo-MBPr14.local"
        ))
    }

    func testShortAndFQDNFormsCountAsTheSameHost() {
        // gethostname() reports either depending on network state, so a pane
        // seeded under one form must stay suppressed under the other.
        XCTAssertNil(PaneTitleDisplay.title(
            paneTitle: "Demo-MBPr14",
            windowName: "editor",
            serverHost: "Demo-MBPr14.local"
        ))
        XCTAssertNil(PaneTitleDisplay.title(
            paneTitle: "Demo-MBPr14.local",
            windowName: "editor",
            serverHost: "Demo-MBPr14"
        ))
    }

    func testHostnamePrefixInsideARealTitleIsNotSuppressed() {
        // A shell that titles the pane `host: cwd` is saying something; only
        // a bare hostname is tmux's seed.
        XCTAssertEqual(
            PaneTitleDisplay.title(
                paneTitle: "Demo-MBPr14: ~/workspace",
                windowName: "editor",
                serverHost: "Demo-MBPr14.local"
            ),
            "Demo-MBPr14: ~/workspace"
        )
    }

    func testTitleRepeatingTheWindowNameIsRedundant() {
        XCTAssertNil(PaneTitleDisplay.title(
            paneTitle: "Editor",
            windowName: "editor",
            serverHost: "devbox"
        ))
    }

    func testEmptyAndWhitespaceTitlesSayNothing() {
        XCTAssertNil(PaneTitleDisplay.title(
            paneTitle: "", windowName: "editor", serverHost: "devbox"))
        XCTAssertNil(PaneTitleDisplay.title(
            paneTitle: "   ", windowName: "editor", serverHost: "devbox"))
    }

    func testUnknownServerHostSuppressesNothing() {
        // Legacy snapshots and hosts whose tmux declined to answer `#{host}`
        // fail open: showing the hostname beats hiding a real title.
        XCTAssertEqual(
            PaneTitleDisplay.title(
                paneTitle: "Demo-MBPr14.local",
                windowName: "editor",
                serverHost: ""
            ),
            "Demo-MBPr14.local"
        )
    }

    func testWindowConvenienceUsesTheActivePaneTitle() {
        XCTAssertEqual(
            window(name: "cc", paneTitle: "π - harness")
                .displayPaneTitle(serverHost: "devbox"),
            "π - harness"
        )
        XCTAssertNil(
            window(name: "shell", paneTitle: "devbox")
                .displayPaneTitle(serverHost: "devbox")
        )
    }

    func testSplitWindowOffersNoTitle() {
        // The title is the ACTIVE pane's. Beside a window name it would read
        // as the whole window's business; the spine shows the pane count.
        XCTAssertNil(
            window(name: "cc", paneTitle: "π - harness", panes: 2)
                .displayPaneTitle(serverHost: "devbox")
        )
    }

    func testWindowFromASnapshotWithoutPaneInventoryStillOffersItsTitle() {
        let legacy = TmuxWindow(
            index: 0, name: "cc", isActive: true,
            hasBell: false, hasActivity: false, paneTitle: "✳ Claude Code"
        )
        XCTAssertEqual(legacy.paneCount, 1)
        XCTAssertEqual(legacy.displayPaneTitle(serverHost: "devbox"), "✳ Claude Code")
    }
}
