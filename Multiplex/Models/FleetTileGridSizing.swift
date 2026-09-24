import CoreGraphics

/// Breakpoint sizing for the wall's session-tile grid, in two stages: how many
/// columns the width allows, then how many the wall has tiles to fill.
///
/// Tiles expand toward the preferred width, but a new column enters as soon
/// as every tile can retain the compact minimum. The final count stops at the
/// number of tiles that actually exist, preventing wider viewports from
/// compressing populated columns merely to reserve empty slots.
///
/// This policy is UI-framework-independent so the UIKit fleet collection and
/// its tests share the exact breakpoint behavior used by the existing wall.
enum FleetTileGridSizing {
    static let minimumTileWidth: CGFloat = 290
    static let preferredTileWidth: CGFloat = 360
    static let gutter: CGFloat = 14

    /// The wall's final column count: never more columns than there are tiles
    /// to put in them.
    static func columnCount(availableColumns: Int, tileCount: Int) -> Int {
        max(1, min(availableColumns, tileCount))
    }

    static func initialColumnCount(availableWidth rawWidth: CGFloat) -> Int {
        let width = normalized(rawWidth)
        return maximumColumnCount(
            tileWidth: minimumTileWidth,
            availableWidth: width
        )
    }

    static func columnCount(current: Int?, availableWidth rawWidth: CGFloat) -> Int {
        let width = normalized(rawWidth)
        var count = max(1, current ?? initialColumnCount(availableWidth: width))

        while requiredWidth(
            columnCount: count + 1,
            tileWidth: minimumTileWidth
        ) <= width {
            count += 1
        }

        while count > 1,
              requiredWidth(
                columnCount: count,
                tileWidth: minimumTileWidth
              ) > width {
            count -= 1
        }

        return count
    }

    static func requiredWidth(columnCount: Int, tileWidth: CGFloat) -> CGFloat {
        guard columnCount > 0 else { return 0 }
        return CGFloat(columnCount) * tileWidth
            + CGFloat(columnCount - 1) * gutter
    }

    private static func maximumColumnCount(
        tileWidth: CGFloat,
        availableWidth: CGFloat
    ) -> Int {
        max(1, Int((availableWidth + gutter) / (tileWidth + gutter)))
    }

    private static func normalized(_ width: CGFloat) -> CGFloat {
        width.isFinite ? max(0, width) : 0
    }
}
