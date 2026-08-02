import XCTest
import UIKit
@testable import Multiplex

final class FleetTileGridSizingTests: XCTestCase {
    @MainActor
    func testVisionWindowBoundaryDoesNotExposeOverlayIdealSize() {
        #if os(visionOS)
        let proposal = CGSize(width: 500, height: 300)
        let content = OversizedContentViewController()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let themes = ThemeStore(
            defaults: defaults,
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
        let root = UIKitSceneRootViewController(
            content: content,
            themes: themes,
            appLock: AppLockStore(
                defaults: UserDefaults(suiteName: UUID().uuidString)!,
                authenticate: { _ in false }
            ),
            externalActions: ExternalActionRouter(),
            bind: BindController(),
            sceneWindows: SceneWindowRouting(
                supportsMultipleWindows: false,
                perform: { _ in }
            )
        )
        let window = UIWindow(frame: CGRect(origin: .zero, size: proposal))
        window.rootViewController = root
        root.loadViewIfNeeded()
        root.view.frame = window.bounds
        root.view.layoutIfNeeded()

        XCTAssertEqual(content.oversizedIntrinsicSize, CGSize(width: 900, height: 700))
        XCTAssertEqual(content.view.frame.size.width, proposal.width, accuracy: 1)
        XCTAssertEqual(content.view.frame.size.height, proposal.height, accuracy: 1)
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

@MainActor
private final class OversizedContentViewController: UIViewController {
    let oversizedIntrinsicSize = CGSize(width: 900, height: 700)

    override func loadView() {
        view = OversizedIntrinsicView(size: oversizedIntrinsicSize)
    }
}

private final class OversizedIntrinsicView: UIView {
    private let size: CGSize

    init(size: CGSize) {
        self.size = size
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var intrinsicContentSize: CGSize { size }
}
