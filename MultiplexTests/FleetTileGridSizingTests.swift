import XCTest
import SwiftUI
@testable import Multiplex

final class FleetTileGridSizingTests: XCTestCase {
    @MainActor
    func testVisionWindowBoundaryDoesNotExposeOverlayIdealSize() {
        #if os(visionOS)
        let proposal = CGSize(width: 500, height: 300)
        let oversizedContent = Color.clear.frame(width: 900, height: 700)
        let rawHost = UIHostingController(rootView: oversizedContent)
        let boundedHost = UIHostingController(
            rootView: oversizedContent.modifier(DeckWindowSizingBoundary())
        )

        let rawSize = rawHost.sizeThatFits(in: proposal)
        let boundedSize = boundedHost.sizeThatFits(in: proposal)

        XCTAssertGreaterThan(rawSize.width, proposal.width)
        XCTAssertGreaterThan(rawSize.height, proposal.height)
        XCTAssertEqual(boundedSize.width, proposal.width, accuracy: 1)
        XCTAssertEqual(boundedSize.height, proposal.height, accuracy: 1)
        #endif
    }

    func testDefaultDeckWidthStartsWithTwoPreferredWidthColumns() {
        let width = FleetTileGridSizing.requiredWidth(
            columnCount: 2,
            tileWidth: FleetTileGridSizing.preferredTileWidth
        )

        let count = FleetTileGridSizing.initialColumnCount(availableWidth: width)

        XCTAssertEqual(count, 2)
    }

    func testIPadMiniPortraitRecoversTwoColumnsAfterNarrowGeometryPass() {
        // iPad mini portrait is 744pt wide. The standard wall leaves 26pt on
        // each side, so its 692pt grid comfortably fits two minimum-width
        // tiles even if an earlier presentation pass recorded one column.
        let availableWidth: CGFloat = 744 - 26 * 2
        let narrowPass = FleetTileGridSizing.columnCount(
            current: nil,
            availableWidth: 0
        )

        let recovered = FleetTileGridSizing.columnCount(
            current: narrowPass,
            availableWidth: availableWidth
        )

        XCTAssertEqual(narrowPass, 1)
        XCTAssertEqual(recovered, 2)
    }

    func testIPadMiniLandscapeFitsThreeCompactColumns() {
        // Rotating the same device leaves 1,081pt after standard wall
        // padding. Three tiles fit at 351pt each and should stay on one row.
        let availableWidth: CGFloat = 1_133 - 26 * 2

        let count = FleetTileGridSizing.columnCount(
            current: 2,
            availableWidth: availableWidth
        )

        XCTAssertEqual(count, 3)
    }

    func testGrowingAddsACompactColumnWhenMinimumWidthFits() {
        let twoPreferred = FleetTileGridSizing.requiredWidth(
            columnCount: 2,
            tileWidth: FleetTileGridSizing.preferredTileWidth
        )
        let threeMinimum = FleetTileGridSizing.requiredWidth(
            columnCount: 3,
            tileWidth: FleetTileGridSizing.minimumTileWidth
        )
        let initial = FleetTileGridSizing.initialColumnCount(availableWidth: twoPreferred)

        let count = FleetTileGridSizing.columnCount(
            current: initial,
            availableWidth: threeMinimum
        )

        XCTAssertEqual(count, 3)
    }

    func testInitialLargerWindowUsesCompactColumnWhenMinimumWidthFits() {
        let threeMinimum = FleetTileGridSizing.requiredWidth(
            columnCount: 3,
            tileWidth: FleetTileGridSizing.minimumTileWidth
        )

        let count = FleetTileGridSizing.initialColumnCount(availableWidth: threeMinimum)

        XCTAssertEqual(count, 3)
    }

    func testGrowingAddsColumnWhenEveryTileFitsAtPreferredWidth() {
        let twoPreferred = FleetTileGridSizing.requiredWidth(
            columnCount: 2,
            tileWidth: FleetTileGridSizing.preferredTileWidth
        )
        let threePreferred = FleetTileGridSizing.requiredWidth(
            columnCount: 3,
            tileWidth: FleetTileGridSizing.preferredTileWidth
        )
        let initial = FleetTileGridSizing.initialColumnCount(availableWidth: twoPreferred)

        let count = FleetTileGridSizing.columnCount(
            current: initial,
            availableWidth: threePreferred
        )

        XCTAssertEqual(count, 3)
    }

    func testShrinkingKeepsColumnsWhileTilesRemainAboveMinimumWidth() {
        let threePreferred = FleetTileGridSizing.requiredWidth(
            columnCount: 3,
            tileWidth: FleetTileGridSizing.preferredTileWidth
        )
        let threeMinimum = FleetTileGridSizing.requiredWidth(
            columnCount: 3,
            tileWidth: FleetTileGridSizing.minimumTileWidth
        )
        let initial = FleetTileGridSizing.initialColumnCount(availableWidth: threePreferred)

        let count = FleetTileGridSizing.columnCount(
            current: initial,
            availableWidth: threeMinimum
        )

        XCTAssertEqual(count, 3)
    }

    func testShrinkingWrapsColumnAfterTilesReachMinimumWidth() {
        let threePreferred = FleetTileGridSizing.requiredWidth(
            columnCount: 3,
            tileWidth: FleetTileGridSizing.preferredTileWidth
        )
        let belowThreeMinimum = FleetTileGridSizing.requiredWidth(
            columnCount: 3,
            tileWidth: FleetTileGridSizing.minimumTileWidth
        ) - 1
        let initial = FleetTileGridSizing.initialColumnCount(availableWidth: threePreferred)

        let count = FleetTileGridSizing.columnCount(
            current: initial,
            availableWidth: belowThreeMinimum
        )

        XCTAssertEqual(count, 2)
    }

    func testLargeShrinkDropsEveryColumnThatCannotFit() {
        let threePreferred = FleetTileGridSizing.requiredWidth(
            columnCount: 3,
            tileWidth: FleetTileGridSizing.preferredTileWidth
        )
        let belowTwoMinimum = FleetTileGridSizing.requiredWidth(
            columnCount: 2,
            tileWidth: FleetTileGridSizing.minimumTileWidth
        ) - 1
        let initial = FleetTileGridSizing.initialColumnCount(availableWidth: threePreferred)

        let count = FleetTileGridSizing.columnCount(
            current: initial,
            availableWidth: belowTwoMinimum
        )

        XCTAssertEqual(count, 1)
    }

    func testLargerRowsUseTheSameCompactThreshold() {
        let threePreferred = FleetTileGridSizing.requiredWidth(
            columnCount: 3,
            tileWidth: FleetTileGridSizing.preferredTileWidth
        )
        let fourMinimum = FleetTileGridSizing.requiredWidth(
            columnCount: 4,
            tileWidth: FleetTileGridSizing.minimumTileWidth
        )
        let fourPreferred = FleetTileGridSizing.requiredWidth(
            columnCount: 4,
            tileWidth: FleetTileGridSizing.preferredTileWidth
        )
        let initial = FleetTileGridSizing.initialColumnCount(availableWidth: threePreferred)

        let compactCount = FleetTileGridSizing.columnCount(
            current: initial,
            availableWidth: fourMinimum
        )
        XCTAssertEqual(compactCount, 4)

        let fullWidthCount = FleetTileGridSizing.columnCount(
            current: compactCount,
            availableWidth: fourPreferred
        )
        XCTAssertEqual(fullWidthCount, 4)
    }
}
