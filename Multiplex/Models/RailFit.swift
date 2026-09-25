import CoreGraphics

/// The direct chips a shell UMD rail offers, whether it lies as a row (the
/// iPhone / iPhone Duo shell row) or stands as a column (iPhone Duo's side
/// bar). Order is the rail's own; DECK, the title and the lamp are not items.
enum RailItem: Equatable, Hashable {
    case deck
    case fontDown
    case fontUp
    case newTab
    case file
    case shortcut
    case merge
    case guide
    case overflow
    case detach
}

/// Pure fitting rule for a shell rail: which direct chips stay when the
/// rail cannot hold every one offered. Dropped chips move into the ⋯ menu,
/// which appears (above DETACH) only once something dropped and then never
/// drops itself. DECK never drops either.
enum RailFit {
    static let chipHeight: CGFloat = 44
    static let gap: CGFloat = 4
    /// Room at the column's ends: inner display glyphs to ~120 pt; closed
    /// portrait glyphs under the camera to ~152; closed landscape has only
    /// the camera, 30…66 pt from the corner end (top when leading, bottom
    /// when trailing).
    static let innerTopInset: CGFloat = 120
    static let closedPortraitTopInset: CGFloat = 160
    static let closedCameraInset: CGFloat = 80
    static let closedCornerInset: CGFloat = 12

    /// The room kept at each end. The chips gather at the camera's end,
    /// which is the end with the larger inset.
    struct ColumnPlacement: Equatable {
        var top: CGFloat
        var bottom: CGFloat
        var anchoredToBottom: Bool { bottom > top }
    }

    /// The closed display is the compact-width one.
    static func columnPlacement(
        compactWidth: Bool,
        landscape: Bool,
        trailingEdge: Bool
    ) -> ColumnPlacement {
        guard compactWidth else { return ColumnPlacement(top: innerTopInset, bottom: 0) }
        guard landscape else { return ColumnPlacement(top: closedPortraitTopInset, bottom: 0) }
        return trailingEdge
            ? ColumnPlacement(top: closedCornerInset, bottom: closedCameraInset)
            : ColumnPlacement(top: closedCameraInset, bottom: closedCornerInset)
    }

    /// Drop order: the row-only MERGE and GUIDE first, the shortcut last.
    static let dropOrder: [RailItem] = [
        .merge, .guide, .fontDown, .fontUp, .newTab, .file, .detach, .shortcut,
    ]

    /// `offered` keeps its order; `fits` judges a candidate set. The result
    /// is `offered` minus dropped chips, plus ⋯ whenever something dropped.
    static func visibleItems(offered: [RailItem], fits: ([RailItem]) -> Bool) -> [RailItem] {
        var kept = offered
        guard !fits(kept) else { return kept }
        if !kept.contains(.overflow) {
            let index = kept.firstIndex(of: .detach) ?? kept.endIndex
            kept.insert(.overflow, at: index)
        }
        for item in dropOrder where !fits(kept) {
            kept.removeAll { $0 == item }
        }
        // A− and A+ are one control: never leave one of them behind.
        if kept.contains(.fontUp) != kept.contains(.fontDown) {
            kept.removeAll { $0 == .fontUp || $0 == .fontDown }
        }
        return kept
    }

    /// The horizontal row: `widths` gives each offered chip's measured width
    /// (the ⋯ chip's under `.overflow`, whether offered or not), `spacing`
    /// the inter-chip gap, `available` the room after the title cluster.
    static func rowItems(
        offered: [RailItem],
        widths: [RailItem: CGFloat],
        spacing: CGFloat,
        available: CGFloat
    ) -> [RailItem] {
        visibleItems(offered: offered) { items in
            guard !items.isEmpty else { return true }
            let width = items.reduce(0) { $0 + (widths[$1] ?? 0) }
                + CGFloat(items.count - 1) * spacing
            return width <= available
        }
    }

    static func capacity(
        availableHeight: CGFloat,
        chipHeight: CGFloat = chipHeight,
        gap: CGFloat = gap
    ) -> Int {
        guard availableHeight >= chipHeight, chipHeight > 0 else { return 0 }
        return Int((availableHeight + gap) / (chipHeight + gap))
    }

    /// The vertical column: `capacity` whole chips.
    static func columnItems(offered: [RailItem], capacity: Int) -> [RailItem] {
        visibleItems(offered: offered) { $0.count <= capacity }
    }

    /// The chips that left the rail and belong in the ⋯ menu.
    static func overflowing(offered: [RailItem], visible: [RailItem]) -> Set<RailItem> {
        Set(offered).subtracting(visible).subtracting([.overflow])
    }
}
