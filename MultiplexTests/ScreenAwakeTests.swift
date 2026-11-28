import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class ScreenAwakeTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var applied: [Bool] = []

    private func makeCenter() -> ScreenAwakeCenter {
        suiteName = "screen-awake-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        return ScreenAwakeCenter(
            defaults: defaults,
            notificationCenter: NotificationCenter()
        ) { [weak self] in
            self?.applied.append($0)
        }
    }

    /// A view in a scene-less window: on screen as far as the center knows.
    private func windowedView() -> (UIWindow, UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let view = UIView()
        window.addSubview(view)
        return (window, view)
    }

    override func tearDown() {
        if let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        applied = []
        super.tearDown()
    }

    func testDefaultsOffAndNeverHolds() {
        let center = makeCenter()
        let (window, view) = windowedView()
        XCTAssertFalse(center.isEnabled)
        center.setShowing(true, owner: view, view: view)
        XCTAssertFalse(center.isHoldingAwake)
        XCTAssertEqual(applied, [])
        withExtendedLifetime(window) {}
    }

    func testHoldsOnlyWhileEnabledAndASurfaceShows() {
        let center = makeCenter()
        let (window, view) = windowedView()
        let owner = NSObject()

        center.setEnabled(true)
        XCTAssertTrue(KeepScreenOnSetting.isEnabled(defaults: defaults))
        XCTAssertFalse(center.isHoldingAwake)

        center.setShowing(true, owner: owner, view: view)
        XCTAssertTrue(center.isHoldingAwake)

        center.setEnabled(false)
        XCTAssertFalse(center.isHoldingAwake)
        center.setEnabled(true)
        XCTAssertTrue(center.isHoldingAwake)

        center.setShowing(false, owner: owner, view: view)
        XCTAssertFalse(center.isHoldingAwake)
        XCTAssertEqual(applied, [true, false, true, false])
        withExtendedLifetime(window) {}
    }

    func testAnyOneSurfaceKeepsTheHold() {
        let center = makeCenter()
        center.setEnabled(true)
        let (window, first) = windowedView()
        let second = UIView()
        window.addSubview(second)

        center.setShowing(true, owner: first, view: first)
        center.setShowing(true, owner: second, view: second)
        center.setShowing(false, owner: first, view: first)
        XCTAssertTrue(center.isHoldingAwake)
        center.setShowing(false, owner: second, view: second)
        XCTAssertFalse(center.isHoldingAwake)
        XCTAssertEqual(applied, [true, false])
    }

    func testAViewOutsideAnyWindowDoesNotHold() {
        let center = makeCenter()
        center.setEnabled(true)
        let view = UIView()
        center.setShowing(true, owner: view, view: view)
        XCTAssertFalse(center.isHoldingAwake)
    }

    func testAReleasedSurfaceStopsHoldingAtTheNextReconcile() {
        let center = makeCenter()
        center.setEnabled(true)
        let (window, keeper) = windowedView()
        let owner = NSObject()
        do {
            let transient = UIView()
            window.addSubview(transient)
            center.setShowing(true, owner: owner, view: transient)
            XCTAssertTrue(center.isHoldingAwake)
            transient.removeFromSuperview()
        }
        center.setShowing(false, owner: keeper, view: keeper)
        XCTAssertFalse(center.isHoldingAwake)
    }
}
