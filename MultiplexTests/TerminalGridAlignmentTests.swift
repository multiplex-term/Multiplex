import XCTest
@testable import Multiplex

final class TerminalGridAlignmentTests: XCTestCase {
    func testNudgeUsesRemainderBeyondFourPoints() {
        let nudge = TerminalGridAlignment.bottomNudge(
            rawHeight: 507,
            cellHeight: 20,
            displayScale: 2
        )

        XCTAssertEqual(nudge, 6.5, accuracy: 0.0001)
        XCTAssertGreaterThan(nudge, 4)
    }

    func testNudgePreservesRowCountAndLeavesAtMostOnePhysicalPixel() {
        for scale: CGFloat in [1, 2, 3] {
            for rawHeight: CGFloat in [500, 500.1, 507, 519.9, 520, 538.75] {
                let cellHeight: CGFloat = 20
                let before = Int(rawHeight / cellHeight)
                let nudge = TerminalGridAlignment.bottomNudge(
                    rawHeight: rawHeight,
                    cellHeight: cellHeight,
                    displayScale: scale
                )
                let adjustedHeight = rawHeight - nudge
                let after = Int(adjustedHeight / cellHeight)
                let remainder = adjustedHeight - CGFloat(after) * cellHeight

                XCTAssertEqual(after, before, "height=\(rawHeight), scale=\(scale)")
                XCTAssertLessThanOrEqual(
                    remainder,
                    1 / scale + 0.0001,
                    "height=\(rawHeight), scale=\(scale)"
                )
            }
        }
    }

    func testInvalidGeometryDoesNotNudge() {
        XCTAssertEqual(TerminalGridAlignment.bottomNudge(
            rawHeight: 0,
            cellHeight: 20,
            displayScale: 2
        ), 0)
        XCTAssertEqual(TerminalGridAlignment.bottomNudge(
            rawHeight: 500,
            cellHeight: 0,
            displayScale: 2
        ), 0)
    }
}
