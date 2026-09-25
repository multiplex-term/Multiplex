import CoreGraphics

/// Pure, UIKit-free policy for choosing Multiplex's single-window shell.
/// UIKit supplies the scene idiom and the connected scene's full-screen bit;
/// tests can cover the complete matrix without constructing a UIWindowScene.
enum ShellModeDecision {
    enum Platform: Equatable {
        case iOS
        case visionOS
    }

    enum Idiom: Equatable {
        case phone
        case pad
        case other
    }

    static func usesSingleWindowShell(
        platform: Platform,
        idiom: Idiom,
        isFullScreen: Bool,
        environmentOverride: String?
    ) -> Bool {
        if environmentOverride == "1" { return true }
        if environmentOverride == "0" { return false }

        guard platform == .iOS else { return false }
        switch idiom {
        case .phone:
            return true
        case .pad:
            return isFullScreen
        case .other:
            return false
        }
    }
}

/// Pure layout constants shared by the real shell and its unit tests.
enum SingleWindowShellLayout {
    static let expandedThreshold: CGFloat = 620
    static let deckRailWidth: CGFloat = 316
    /// An unlocked compact key rail retains TMUX at 390 points. Keyboard lock
    /// adds RET on iPhone; its slightly tighter Air tier keeps both controls at
    /// 420 points, while narrower locked phones move TMUX to the top bar.
    /// "TMUX" names the shortcut-key slot — herdr tabs fill it with HRDR at
    /// the same four-character width, so both cutoffs hold for both backends.
    static let keyBarTmuxMinimumWidth: CGFloat = 390
    static let keyBarTmuxWithReturnMinimumWidth: CGFloat = 420

    /// The phone shell expands only while the terminal beside the rail keeps
    /// the key rail's full unlocked tier (TMUX stays on the rail). Measured on
    /// the terminal's available width, after its own safe areas.
    static let phoneTerminalMinimumWidth: CGFloat = keyBarTmuxMinimumWidth

    /// The key rail spends the home-indicator strip instead of parking a
    /// backfill band under itself: every compact-height phone, iPad, and a
    /// foldable in every pose (the rail floats above the edge otherwise).
    /// A shipped iPhone in portrait keeps its strip.
    static func railAlwaysTakesBottomStrip(idiom: ShellModeDecision.Idiom, foldable: Bool) -> Bool {
        idiom == .pad || (idiom == .phone && foldable)
    }

    /// A foldable phone, every display: the source strip and key rail drop
    /// the bezel slab and rule (they read as grey bars on the Duo's ground).
    static func chromeIsBare(idiom: ShellModeDecision.Idiom, foldable: Bool) -> Bool {
        idiom == .phone && foldable
    }

    /// While the deck spans the display its header chips stand in the side
    /// column; beside a terminal the terminal's column owns the strip.
    static func deckActionColumn(sideColumn: ShellSideColumn, deckSpansShell: Bool) -> ShellSideColumn {
        deckSpansShell ? sideColumn : .none
    }

    /// The Duo's inner display: regular × regular on the phone idiom.
    static func isInnerDisplay(
        idiom: ShellModeDecision.Idiom,
        horizontalSizeClass: ShellSizeClass,
        verticalSizeClass: ShellSizeClass
    ) -> Bool {
        idiom == .phone && horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

    /// The iPad rule: the shell runs full-screen there, so the window's own
    /// usable width is the measure.
    static func isExpanded(width: CGFloat) -> Bool {
        width >= expandedThreshold
    }

    /// The phone measures the terminal, the iPad the window. Shipped sizes:
    /// 16e (410) and Pro Max (440) landscape stay expanded, an SE-class 667
    /// landscape (351) goes single-pane. A vertical division overrides this.
    static func isExpanded(
        usableWidth: CGFloat,
        terminalAvailableWidthIfExpanded: CGFloat,
        idiom: ShellModeDecision.Idiom
    ) -> Bool {
        switch idiom {
        case .phone:
            terminalAvailableWidthIfExpanded >= phoneTerminalMinimumWidth
        case .pad, .other:
            isExpanded(width: usableWidth)
        }
    }

    /// The inner display's 55 pt corners have no system inset in landscape,
    /// so the pane owning the corner insets its header row (only the row:
    /// the content below starts under the curve's reach).
    static let bareCornerLeadingInset: CGFloat = 24

    /// The inner display with no top inset: rows flush with the edge lose
    /// their top points to the edge grab, so content starts this far down.
    /// Compact layouts keep their flush chrome.
    static let bareTopPadding: CGFloat = 8

    static func bareTopPadding(
        topSafeArea: CGFloat,
        idiom: ShellModeDecision.Idiom,
        horizontalSizeClass: ShellSizeClass,
        verticalSizeClass: ShellSizeClass
    ) -> CGFloat {
        guard isInnerDisplay(
            idiom: idiom, horizontalSizeClass: horizontalSizeClass, verticalSizeClass: verticalSizeClass
        ), topSafeArea == 0
        else { return 0 }
        return bareTopPadding
    }

    /// Inner portrait (and the laptop top region): the 82 pt status band
    /// holds only the trailing clock cluster, so the rail and deck header
    /// live inside it, `topBandTrailingClearance` clear of the cluster.
    static let topBandMinimumHeight: CGFloat = 60
    static let topBandTrailingClearance: CGFloat = 128
    /// The system's status glyphs centre 48 pt in from the display edge;
    /// our rows and columns in those regions centre on the same line.
    static let systemGlyphLine: CGFloat = 48

    /// Centre line for a row inside the top band.
    static func topBandRowCenter(bandHeight: CGFloat) -> CGFloat {
        bandHeight >= systemGlyphLine ? systemGlyphLine : bandHeight / 2
    }

    /// Centre x for the side column's chips, in the strip's own coordinates.
    static func sideColumnCenterX(stripWidth: CGFloat, trailingEdge: Bool) -> CGFloat {
        trailingEdge ? stripWidth - systemGlyphLine : systemGlyphLine
    }

    static func topBandHeight(
        topSafeArea: CGFloat,
        idiom: ShellModeDecision.Idiom,
        horizontalSizeClass: ShellSizeClass,
        verticalSizeClass: ShellSizeClass
    ) -> CGFloat {
        guard isInnerDisplay(
            idiom: idiom, horizontalSizeClass: horizontalSizeClass, verticalSizeClass: verticalSizeClass
        ), topSafeArea >= topBandMinimumHeight
        else { return 0 }
        return topSafeArea
    }

    /// Regular width only: the closed display's corner is 6 pt.
    static func cornerLeadingInset(
        topSafeArea: CGFloat,
        leadingSafeArea: CGFloat,
        idiom: ShellModeDecision.Idiom,
        horizontalSizeClass: ShellSizeClass
    ) -> CGFloat {
        idiom == .phone && horizontalSizeClass == .regular
            && topSafeArea == 0 && leadingSafeArea == 0
            ? bareCornerLeadingInset
            : 0
    }

    static func showsTopBarTmuxShortcut(
        availableWidth: CGFloat,
        supportsTmuxShortcuts: Bool,
        keyBarIncludesReturnKey: Bool = false
    ) -> Bool {
        let minimumWidth = keyBarIncludesReturnKey
            ? keyBarTmuxWithReturnMinimumWidth
            : keyBarTmuxMinimumWidth
        return supportsTmuxShortcuts && availableWidth < minimumWidth
    }
}

/// Pure completion policy for the iPhone shell's left-edge back swipe.
/// Translation is in points and velocity is in points per second.
enum SingleWindowShellBackSwipe {
    private static let completionFraction: CGFloat = 0.5
    private static let projectionDuration: CGFloat = 0.2
    private static let minimumFlickDistance: CGFloat = 16
    private static let decisiveReverseVelocity: CGFloat = -100

    /// The compact phone keeps edge-back as a navigation shortcut even when
    /// Reduce Motion is enabled. Motion preference changes the interactive
    /// travel, not whether the route back to the deck exists.
    static func isAvailable(
        idiom: ShellModeDecision.Idiom,
        expanded: Bool,
        compactShowsTerminal: Bool
    ) -> Bool {
        idiom == .phone && !expanded && compactShowsTerminal
    }

    /// Local text-selection drags always stay with the terminal. Otherwise,
    /// only unambiguously rightward horizontal intent starts navigation.
    static func shouldBegin(
        horizontalVelocity: CGFloat,
        verticalVelocity: CGFloat,
        hasActiveTextSelection: Bool
    ) -> Bool {
        guard !hasActiveTextSelection else { return false }
        return horizontalVelocity > 0
            && abs(horizontalVelocity) > abs(verticalVelocity)
    }

    static func constrainedTranslation(_ translation: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(max(translation, 0), width)
    }

    /// A deliberate half-width drag always completes. A shorter flick can
    /// complete when its forward velocity projects beyond the same midpoint;
    /// a clear reversal always cancels so the interface follows intent.
    static func shouldReturnToDeck(
        translation: CGFloat,
        velocity: CGFloat,
        width: CGFloat
    ) -> Bool {
        guard width > 0 else { return false }
        let distance = constrainedTranslation(translation, width: width)
        guard distance >= minimumFlickDistance,
              velocity > decisiveReverseVelocity
        else { return false }

        if distance >= width * completionFraction { return true }
        let projectedDistance = distance + max(velocity, 0) * projectionDuration
        return projectedDistance >= width * completionFraction
    }
}

/// UIKit-free mirror of `UIUserInterfaceSizeClass` so the placement rules
/// below stay assertable without a trait collection.
enum ShellSizeClass: Equatable {
    case compact
    case regular
    case unspecified
}

/// What a pane's header row (the deck header, the terminal's UMD rail, a
/// column panel's header) must clear beyond its safe area: a bare display
/// corner on the leading side, and iPhone Duo's inner-portrait status band,
/// whose clock cluster the row stops before. One value travels from
/// `SingleWindowShellNativeLayout.resolve` to every header.
struct ShellHeaderChrome: Equatable {
    /// `SingleWindowShellLayout.cornerLeadingInset`; zero elsewhere.
    var cornerInset: CGFloat = 0
    /// `SingleWindowShellLayout.topBandHeight`; zero elsewhere.
    var bandHeight: CGFloat = 0
    /// The row hugs the pane's top edge (the console deck under the fold).
    var flushTop = false

    static let none = ShellHeaderChrome()

    var bandTrailingClearance: CGFloat {
        bandHeight > 0 ? SingleWindowShellLayout.topBandTrailingClearance : 0
    }

    /// The row's centre line inside the band; nil without one.
    var bandRowCenterY: CGFloat? {
        bandHeight > 0 ? SingleWindowShellLayout.topBandRowCenter(bandHeight: bandHeight) : nil
    }
}

/// What the shell's DECK chip does: return to the wall (single pane, or a
/// column panel that ‹ DECK sends into a tab), or toggle the deck rail.
enum ShellDeckControl: Equatable {
    case back
    case hide
    case show

    var label: String {
        switch self {
        case .back: "‹ DECK"
        case .hide: "◧ HIDE"
        case .show: "◧ DECK"
        }
    }
}

enum ShellRailEdge: Equatable {
    case top
    case leading
    case trailing
}

/// The system's side strip as the shell's panes use it: the column's edge
/// (`.top` = no column) and the chips' placement inside the strip.
struct ShellSideColumn: Equatable {
    var edge: ShellRailEdge
    var placement: RailFit.ColumnPlacement

    static let none = ShellSideColumn(edge: .top, placement: RailFit.ColumnPlacement(top: 0, bottom: 0))

    var isPresent: Bool { edge != .top }

    /// The column's frame in a pane spanning the strip: `strip` is the
    /// pane's safe inset on the column's edge, `obstruction` the keyboard's
    /// height from the bottom.
    func frame(in bounds: CGRect, strip: CGFloat, obstruction: CGFloat = 0) -> CGRect {
        let width = max(strip, RailFit.chipHeight + RailFit.gap)
        let bottom = bounds.maxY - max(obstruction, placement.bottom)
        return CGRect(
            x: edge == .trailing ? bounds.width - width : 0,
            y: placement.top,
            width: width,
            height: max(0, bottom - placement.top)
        )
    }

    /// The chips' centre x inside the strip: the system glyph line.
    func centerX(stripWidth: CGFloat) -> CGFloat {
        SingleWindowShellLayout.sideColumnCenterX(stripWidth: stripWidth, trailingEdge: edge == .trailing)
    }
}

/// iPhone Duo stacks the system's bars in a side column; the shell's rail is
/// app-owned, so it follows the same edge by its own rule.
enum ShellRailPlacement {
    /// A system-reported edge wins. Else regular × regular landscape on the
    /// phone idiom is the inner display (leading); a foldable's compact
    /// landscape is the closed display, whose column takes the camera's
    /// safe strip. Nothing moves on a shipped phone.
    static func edge(
        systemVerticalBarEdge: ShellRailEdge?,
        idiom: ShellModeDecision.Idiom,
        horizontalSizeClass: ShellSizeClass,
        verticalSizeClass: ShellSizeClass,
        isLandscape: Bool,
        foldable: Bool = false,
        leadingSafeArea: CGFloat = 0,
        trailingSafeArea: CGFloat = 0
    ) -> ShellRailEdge {
        if let systemVerticalBarEdge { return systemVerticalBarEdge }
        guard idiom == .phone, isLandscape else { return .top }
        if SingleWindowShellLayout.isInnerDisplay(
            idiom: idiom, horizontalSizeClass: horizontalSizeClass, verticalSizeClass: verticalSizeClass
        ) { return .leading }
        guard foldable else { return .top }
        return leadingSafeArea >= trailingSafeArea ? .leading : .trailing
    }
}

/// Default terminal point size: 12 on a phone, 13 on the Duo's inner
/// display, 14 elsewhere. Per-tab A− / A+ override.
enum TerminalFontDefaults {
    static func pointSize(
        idiom: ShellModeDecision.Idiom,
        horizontalSizeClass: ShellSizeClass,
        verticalSizeClass: ShellSizeClass
    ) -> CGFloat {
        switch idiom {
        case .phone:
            SingleWindowShellLayout.isInnerDisplay(
                idiom: idiom, horizontalSizeClass: horizontalSizeClass, verticalSizeClass: verticalSizeClass
            ) ? 13 : 12
        case .pad, .other:
            14
        }
    }
}

/// The fold band when `reservedRegions(kind: .division)` is empty (the 27.1
/// simulator) but the hinge is `partiallyOpen`: 40 pt centred on the long
/// axis, vertical in the book pose, horizontal in the laptop pose.
enum DuoFoldGeometry {
    static let bandWidth: CGFloat = 40

    static func syntheticDivision(in size: CGSize) -> CGRect {
        if size.width >= size.height {
            return CGRect(
                x: (size.width - bandWidth) / 2,
                y: 0,
                width: bandWidth,
                height: size.height
            )
        }
        return CGRect(
            x: 0,
            y: (size.height - bandWidth) / 2,
            width: size.width,
            height: bandWidth
        )
    }
}
