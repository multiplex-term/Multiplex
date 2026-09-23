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

    /// The terminal's key rail spends the home-indicator strip instead of
    /// parking a backfill band under itself: every compact-height phone (the
    /// row is too precious to give away), and always on iPad and on a
    /// foldable — the rail reads as floating above the display edge
    /// otherwise, in every pose of the Duo (Jhen, 2026-09-25). A shipped
    /// iPhone in portrait keeps its strip.
    static func railAlwaysTakesBottomStrip(idiom: ShellModeDecision.Idiom, foldable: Bool) -> Bool {
        idiom == .pad || (idiom == .phone && foldable)
    }

    /// iPhone Duo (a foldable phone), every display: the terminal's source
    /// strip and key rail drop the bezel slab and the 1 pt rule — on the
    /// Duo's dark ground they read as grey bars around the pane (Jhen,
    /// 2026-09-25, closed then inner). Shipped iPhones and iPad keep the slab.
    static func chromeIsBare(idiom: ShellModeDecision.Idiom, foldable: Bool) -> Bool {
        idiom == .phone && foldable
    }

    /// The iPad rule: the shell runs full-screen there, so the window's own
    /// usable width is the measure.
    static func isExpanded(width: CGFloat) -> Bool {
        width >= expandedThreshold
    }

    /// The phone measures the terminal, the iPad the window. Consequences on
    /// shipped sizes: iPhone 16e landscape (410 pt available beside the rail)
    /// and Pro Max (440) stay expanded; an SE-class 667-wide landscape (351)
    /// becomes single-pane; iPhone Duo closed landscape (~292) and open
    /// portrait (310) stay single-pane while its open landscape (~504)
    /// expands. A vertical division region overrides this (`resolve`).
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

    /// iPhone Duo's inner display has 55 pt corners (measured), and its
    /// landscape poses give the leading top corner no system inset at all:
    /// the status column sits on the trailing edge and there is no top
    /// inset. A 44 pt header row with a 12 pt top inset loses ~21 pt of its
    /// first line to the curve, so the pane that owns that corner (the deck's
    /// title, or the terminal's ‹ DECK chip once ◧ HIDE hands it the corner)
    /// insets its header row by this much. Only the header row: the pane
    /// below it starts under the curve's reach. Every other phone carries a
    /// notch or status-bar inset there; the iPad shell always has a status
    /// bar; the outer display's corners are 6 pt.
    static let bareCornerLeadingInset: CGFloat = 24

    /// A phone display edge with no system inset above it (iPhone Duo's
    /// landscape poses and its closed display): header rows flush with the
    /// top edge lose their top few points to the display's own edge grab,
    /// so the shell's content starts this far down. Only the inner display
    /// (regular × regular): a compact layout — every shipped iPhone in
    /// landscape, the Duo's closed display — keeps its flush chrome.
    static let bareTopPadding: CGFloat = 8

    static func bareTopPadding(
        topSafeArea: CGFloat,
        idiom: ShellModeDecision.Idiom,
        horizontalSizeClass: ShellSizeClass,
        verticalSizeClass: ShellSizeClass
    ) -> CGFloat {
        guard idiom == .phone,
              horizontalSizeClass == .regular,
              verticalSizeClass == .regular,
              topSafeArea == 0
        else { return 0 }
        return bareTopPadding
    }

    /// iPhone Duo's flat inner portrait (and the laptop pose's top region):
    /// the 82 pt status band holds only the clock and radio cluster at the
    /// trailing side, so the shell hands the band to the terminal's rail and
    /// the deck's header. `topBandTrailingClearance` keeps them clear of the
    /// cluster (measured 120 pt on the 27.1 simulator, plus air).
    static let topBandMinimumHeight: CGFloat = 60
    static let topBandTrailingClearance: CGFloat = 128
    /// The system draws its status glyphs 48 pt in from the display edge:
    /// the clock's centre is y = 48 in the top band and x = edge − 48 in the
    /// side strip. Every row or column of ours in those regions centres on
    /// that same line.
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
        guard idiom == .phone,
              horizontalSizeClass == .regular,
              verticalSizeClass == .regular,
              topSafeArea >= topBandMinimumHeight
        else { return 0 }
        return topSafeArea
    }

    /// Regular width only: the inner display's corner measures 55 pt, the
    /// closed display's 6 — its title sits flush with the pane.
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

/// Where the shell's app-owned top rail (the UMD strip) sits.
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

/// iPhone Duo stacks the system's bars in a side column; the shell's rail is
/// app-owned, so it follows the same edge by its own rule.
enum ShellRailPlacement {
    /// A system-reported edge (the iOS 27.1 vertical-bar trait) wins
    /// outright, `.top` included. Without one, the size-class pair no other
    /// iPhone has — regular width AND regular height on the phone idiom, in
    /// landscape — is the Duo's inner display. Its closed display in
    /// landscape is compact × compact like a shipped iPhone, so only a
    /// `foldable` device (one that reports a hinge) moves the rail there:
    /// the system draws no bar, and the column takes the camera's safe
    /// strip, whichever side holds it. Nothing moves on a shipped phone.
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
        if horizontalSizeClass == .regular, verticalSizeClass == .regular { return .leading }
        guard foldable else { return .top }
        return leadingSafeArea >= trailingSafeArea ? .leading : .trailing
    }
}

/// The terminal's default point size per device class. The phone keeps 12;
/// the Duo's inner display (regular × regular on the phone idiom) takes 13
/// so a 626 pt pane reads ~86 columns and a 445 pt book page ~61; the iPad
/// and Vision Pro keep 14. Per-tab A− / A+ still override.
enum TerminalFontDefaults {
    static func pointSize(
        idiom: ShellModeDecision.Idiom,
        horizontalSizeClass: ShellSizeClass,
        verticalSizeClass: ShellSizeClass
    ) -> CGFloat {
        switch idiom {
        case .phone:
            horizontalSizeClass == .regular && verticalSizeClass == .regular ? 13 : 12
        case .pad, .other:
            14
        }
    }
}

/// iPhone Duo's fold as the shell reads it. iOS 27.1 reports the fold as a
/// division reserved region, but the 27.1 simulator returns none in any
/// pose while its hinge still reports `partiallyOpen`, so the shell
/// synthesises the band from the measured geometry when the query is empty:
/// a 40 pt band centred on the display's long axis (inner display 951 × 669,
/// band 455.5…495.5). Vertical when the display is wider than tall (book
/// pose), horizontal otherwise (laptop / propped pose).
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
