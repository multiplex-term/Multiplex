import XCTest
@testable import Multiplex

@MainActor
final class TerminalDropViewTests: XCTestCase {
    func testProgressAndFailureStateUpdateTheAccessibilityAnnouncement() {
        let view = DropStatusPillView(
            state: .uploading(name: "release-notes.md", fraction: 0.62)
        )

        XCTAssertTrue(view.isAccessibilityElement)
        XCTAssertEqual(view.accessibilityLabel, "release-notes.md · 62%")
        XCTAssertGreaterThan(view.intrinsicContentSize.width, 0)
        XCTAssertGreaterThan(view.intrinsicContentSize.height, 0)

        view.apply(.failed("File upload requires tmux or herdr over SSH"))

        XCTAssertEqual(
            view.accessibilityLabel,
            "File upload requires tmux or herdr over SSH"
        )
    }

    func testTargetVeilIsNonInteractiveAndAccessible() {
        let view = DropTargetVeilView()

        XCTAssertFalse(view.isUserInteractionEnabled)
        XCTAssertTrue(view.isAccessibilityElement)
        XCTAssertEqual(view.accessibilityLabel, "Drop to upload")
        XCTAssertEqual(view.layer.borderWidth, 2)
    }
}
