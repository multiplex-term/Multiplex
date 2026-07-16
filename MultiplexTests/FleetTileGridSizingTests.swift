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

    // MARK: Columns the wall has tiles to fill

    /// A width allowing four columns for a host holding three tiles: the
    /// fourth has nothing to show, and taking it would compress all three to
    /// 302pt to clear a slot that stays empty.
    func testColumnsStopAtTheTilesThereAreToFillThem() {
        let fourMinimum = FleetTileGridSizing.requiredWidth(
            columnCount: 4,
            tileWidth: FleetTileGridSizing.minimumTileWidth
        )
        let availableColumns = FleetTileGridSizing.columnCount(
            current: nil,
            availableWidth: fourMinimum
        )
        XCTAssertEqual(availableColumns, 4)

        let count = FleetTileGridSizing.columnCount(
            availableColumns: availableColumns,
            tileCount: 3
        )

        XCTAssertEqual(count, 3)
    }

    /// The complaint this stage exists for: with the count pinned to the
    /// tiles, widening past what they need leaves their share growing, never
    /// shrinking, so it can only be clamped by the grid's preferred width.
    func testWideningAWallPastItsTilesNeverShrinksTheirShare() {
        let tileCount = 3
        var previousShare: CGFloat = 0

        for width in stride(from: 900.0, through: 3_000, by: 1) {
            let count = FleetTileGridSizing.columnCount(
                availableColumns: FleetTileGridSizing.columnCount(
                    current: nil,
                    availableWidth: width
                ),
                tileCount: tileCount
            )
            XCTAssertLessThanOrEqual(count, tileCount, "width \(width)")

            let share = (width - CGFloat(count - 1) * FleetTileGridSizing.gutter)
                / CGFloat(count)
            XCTAssertGreaterThanOrEqual(share, previousShare, "width \(width)")
            previousShare = share
        }
    }

    /// A row with tiles to spare keeps every column the width allows — the
    /// stage this change adds must not touch the full-row case.
    func testFullRowKeepsEveryColumnTheWidthAllows() {
        XCTAssertEqual(
            FleetTileGridSizing.columnCount(availableColumns: 3, tileCount: 3),
            3
        )
        XCTAssertEqual(
            FleetTileGridSizing.columnCount(availableColumns: 3, tileCount: 9),
            3
        )
    }

    /// A host still probing renders one tile, and a wall of empty hosts must
    /// not collapse to a zero-column grid.
    func testWallWithNoTilesYetKeepsASingleColumn() {
        XCTAssertEqual(
            FleetTileGridSizing.columnCount(availableColumns: 4, tileCount: 1),
            1
        )
        XCTAssertEqual(
            FleetTileGridSizing.columnCount(availableColumns: 4, tileCount: 0),
            1
        )
    }
}
