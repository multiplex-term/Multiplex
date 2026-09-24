import XCTest
@testable import Multiplex

final class FileViewerHistoryTests: XCTestCase {
    func testVisitBuildsATrailAndBackForwardWalkIt() {
        var history = FileViewerHistory()
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
        XCTAssertNil(history.goBack())
        XCTAssertNil(history.goForward())

        history.visit(.document(path: "/srv/app/README.md"))
        XCTAssertFalse(history.canGoBack, "The first screen has nowhere to go back to")

        history.visit(.document(path: "/srv/app/App.swift"))
        history.visit(.fileDiff(path: "/srv/app/App.swift"))
        history.visit(.repoDiff)
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        XCTAssertEqual(history.goBack(), .fileDiff(path: "/srv/app/App.swift"))
        XCTAssertEqual(history.goBack(), .document(path: "/srv/app/App.swift"))
        XCTAssertTrue(history.canGoForward)
        XCTAssertEqual(history.goForward(), .fileDiff(path: "/srv/app/App.swift"))
        XCTAssertEqual(history.goForward(), .repoDiff)
        XCTAssertFalse(history.canGoForward)
    }

    func testRevisitingTheCurrentEntryIsFree() {
        var history = FileViewerHistory()
        history.visit(.document(path: "/srv/app/App.swift"))
        // Refresh and quiet watch swaps land the same entry again.
        history.visit(.document(path: "/srv/app/App.swift"))
        XCTAssertFalse(history.canGoBack)
        XCTAssertEqual(history.current, .document(path: "/srv/app/App.swift"))
    }

    func testANewDestinationDropsTheForwardTrail() {
        var history = FileViewerHistory()
        history.visit(.document(path: "/a"))
        history.visit(.document(path: "/b"))
        history.visit(.document(path: "/c"))
        XCTAssertEqual(history.goBack(), .document(path: "/b"))
        XCTAssertEqual(history.goBack(), .document(path: "/a"))

        history.visit(.document(path: "/d"))
        XCTAssertFalse(history.canGoForward, "Branching cuts the forward trail")
        XCTAssertEqual(history.goBack(), .document(path: "/a"))
    }

    func testBackNavigationLandingDoesNotDuplicateTheTrail() {
        var history = FileViewerHistory()
        history.visit(.document(path: "/a"))
        history.visit(.document(path: "/b"))
        XCTAssertEqual(history.goBack(), .document(path: "/a"))
        // The controller re-opens /a, whose landing records the visit — the
        // equality gate must keep that from pushing /b onto the back stack.
        history.visit(.document(path: "/a"))
        XCTAssertFalse(history.canGoBack)
        XCTAssertTrue(history.canGoForward)
    }

    func testTrailIsBounded() {
        var history = FileViewerHistory()
        for index in 0...(FileViewerHistory.capacity + 20) {
            history.visit(.document(path: "/file-\(index)"))
        }
        XCTAssertEqual(history.backStack.count, FileViewerHistory.capacity)
        XCTAssertEqual(history.backStack.first, .document(path: "/file-20"))
    }
}
