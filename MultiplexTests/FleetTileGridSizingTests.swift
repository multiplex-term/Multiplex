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

    func testGrowingDoesNotAddACompressedColumn() {
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

        XCTAssertEqual(count, 2)
    }

    func testInitialLargerWindowDoesNotStartWithACompressedColumn() {
        let threeMinimum = FleetTileGridSizing.requiredWidth(
            columnCount: 3,
            tileWidth: FleetTileGridSizing.minimumTileWidth
        )

        let count = FleetTileGridSizing.initialColumnCount(availableWidth: threeMinimum)

        XCTAssertEqual(count, 2)
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

    func testLargerRowsUseTheSameNoCompressionThreshold() {
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

        let compressedCount = FleetTileGridSizing.columnCount(
            current: initial,
            availableWidth: fourMinimum
        )
        XCTAssertEqual(compressedCount, 3)

        let fullWidthCount = FleetTileGridSizing.columnCount(
            current: compressedCount,
            availableWidth: fourPreferred
        )
        XCTAssertEqual(fullWidthCount, 4)
    }
}
