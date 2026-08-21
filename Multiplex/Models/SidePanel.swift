import CoreGraphics

/// The platforms that can present an auxiliary viewer beside a terminal —
/// each remembers its own panel width.
enum SidePanelPlatform: CaseIterable, Equatable {
    case iPad
    case visionOS
}

/// How a window presents the panel: the visionOS classic window hangs it
/// from a trailing ornament; iPad and the visionOS Shell lay a card over the
/// pane inside the window.
enum SidePanelPresentationStyle: Equatable {
    case iPadOverlay
    case visionOrnament
}

/// Pure side-panel geometry shared by the in-window iPad overlay and the
/// visionOS ornament.
enum SidePanelWidth {
    static let minimumPanelWidth: CGFloat = 320
    static let minimumTerminalWidth: CGFloat = 320
    /// visionOS widths; the live limit is geometric (`clampedVisionGeometry`),
    /// this range only sanity-caps stored values.
    static let visionWidthRange: ClosedRange<CGFloat> = 360...2_400
    /// visionOS: the card's right edge starts this far past the glass's
    /// trailing edge — the default card overlaps the glass by 80 pt.
    static let defaultVisionOverhang: CGFloat = 440
    /// visionOS: the right handle's outer stop — 360 pt of travel from the
    /// default, so both handles move both ways.
    static let maxVisionOverhang: CGFloat = 800
    /// Reference widths `debug.sidepanelwidth` cycles through — not a grid.
    static let visionWidthCycle: [CGFloat] = [400, 520, 680]
    /// One VoiceOver increment / decrement of the handle.
    static let accessibilityStep: CGFloat = 40

    static func defaultWidth(for platform: SidePanelPlatform) -> CGFloat {
        switch platform {
        case .iPad:
            440
        case .visionOS:
            520
        }
    }

    /// Keeps the overlay panel usable while reserving the terminal's minimum
    /// width. A pane too small to satisfy both sides falls back to the panel
    /// minimum; admission prevents that degenerate geometry from mounting.
    static func clamped(_ width: CGFloat, paneWidth: CGFloat) -> CGFloat {
        let maximum = max(minimumPanelWidth, paneWidth - minimumTerminalWidth)
        guard width.isFinite else { return minimumPanelWidth }
        return min(maximum, max(minimumPanelWidth, width))
    }

    /// A width as the store keeps it, pane-free: iPad only needs the floor
    /// (the pane clamps at use), visionOS the sanity range.
    static func clampedStored(_ width: CGFloat, for platform: SidePanelPlatform) -> CGFloat {
        switch platform {
        case .iPad:
            return width.isFinite ? max(minimumPanelWidth, width) : defaultWidth(for: .iPad)
        case .visionOS:
            return clampedVision(width)
        }
    }

    /// The overlay card's container inside the pane — `overlayInset` from
    /// the pane's top, bottom and trailing edge; the seam's overhang rides
    /// along past the card's leading edge so its outside half is hittable.
    static let overlayInset: CGFloat = 8

    static func overlayContainerFrame(
        pane: CGRect,
        bottom: CGFloat,
        width: CGFloat,
        leadingOverhang: CGFloat
    ) -> CGRect {
        let top = pane.minY + overlayInset
        return CGRect(
            x: pane.maxX - overlayInset - width - leadingOverhang,
            y: top,
            width: width + leadingOverhang,
            height: max(0, bottom - overlayInset - top)
        )
    }

    /// A released visionOS drag lands anywhere inside `visionWidthRange`; a
    /// non-finite value falls back to the platform default.
    static func clampedVision(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultWidth(for: .visionOS) }
        return min(visionWidthRange.upperBound, max(visionWidthRange.lowerBound, width))
    }

    /// visionOS: the ornament hosts a fixed transparent strip twice the
    /// window's width, centred on the glass edge, so the card can reach across
    /// the terminal or hang `maxVisionOverhang` outside. A drag moves a frame
    /// inside it; only a window resize changes it.
    static func visionStripWidth(windowWidth: CGFloat) -> CGFloat {
        windowWidth.isFinite ? max(0, windowWidth * 2) : 0
    }

    /// ⚠ Stored GLASS-relative (right edge past the glass), never relative to
    /// the strip's end: a strip-relative inset outlived a strip-width change
    /// and pinned the card at the far end on device. The inner bound depends
    /// on the live window (`clampedVisionRightEdge`).
    static func clampedVisionOverhang(_ overhang: CGFloat) -> CGFloat {
        guard overhang.isFinite else { return defaultVisionOverhang }
        return min(maxVisionOverhang, overhang)
    }

    /// The right edge in strip coordinates: at most `maxVisionOverhang` past
    /// the glass and inside the strip, at least reserve + minimum width in
    /// from the strip's start.
    static func clampedVisionRightEdge(_ rightEdge: CGFloat, stripWidth: CGFloat) -> CGFloat {
        let strip = stripWidth.isFinite ? max(0, stripWidth) : 0
        let glassEdge = strip / 2
        let outermost = min(strip, glassEdge + maxVisionOverhang)
        let innermost = min(outermost, minimumTerminalWidth + visionWidthRange.lowerBound)
        let wanted = rightEdge.isFinite ? rightEdge : glassEdge + defaultVisionOverhang
        return min(outermost, max(innermost, wanted))
    }

    /// The card inside a strip: right edge as above, then a width inside the
    /// range that leaves `minimumTerminalWidth` uncovered (the minimum wins
    /// in a window too narrow for both). Stored values stay; a shrunken
    /// window clamps live.
    static func clampedVisionGeometry(
        width: CGFloat,
        overhang: CGFloat,
        stripWidth: CGFloat
    ) -> (width: CGFloat, overhang: CGFloat) {
        let strip = stripWidth.isFinite ? max(0, stripWidth) : 0
        let glassEdge = strip / 2
        let rightEdge = clampedVisionRightEdge(glassEdge + overhang, stripWidth: strip)
        let room = max(visionWidthRange.lowerBound, rightEdge - minimumTerminalWidth)
        let fitted = max(0, min(clampedVision(width), room, rightEdge))
        return (fitted, rightEdge - glassEdge)
    }

    /// The left handle: the right edge stays, the left edge follows the
    /// finger (`translation` positive = rightward) out to the terminal
    /// reserve or in to the minimum width.
    static func visionGeometry(
        draggingLeadingEdgeBy translation: CGFloat,
        from start: (width: CGFloat, overhang: CGFloat),
        stripWidth: CGFloat
    ) -> (width: CGFloat, overhang: CGFloat) {
        clampedVisionGeometry(
            width: start.width - translation,
            overhang: start.overhang,
            stripWidth: stripWidth
        )
    }

    /// The right handle: the left edge stays, the right edge follows the
    /// finger out to its limit past the glass or in to the minimum width.
    static func visionGeometry(
        draggingTrailingEdgeBy translation: CGFloat,
        from start: (width: CGFloat, overhang: CGFloat),
        stripWidth: CGFloat
    ) -> (width: CGFloat, overhang: CGFloat) {
        let glassEdge = stripWidth / 2
        let leftEdge = glassEdge + start.overhang - start.width
        let rightEdge = clampedVisionRightEdge(
            max(leftEdge + visionWidthRange.lowerBound, glassEdge + start.overhang + translation),
            stripWidth: stripWidth
        )
        return clampedVisionGeometry(
            width: rightEdge - leftEdge,
            overhang: rightEdge - glassEdge,
            stripWidth: stripWidth
        )
    }
}

/// Pure admission policy. UIKit supplies the presentation, the active tab
/// kind, pane width, size class, and DEBUG process override.
enum SidePanelPolicy {
    static let minimumPaneWidth: CGFloat = 660

    static func admitsPanel(
        style: SidePanelPresentationStyle,
        paneWidth: CGFloat,
        isCompactWidth: Bool,
        anchorIsTerminal: Bool,
        environmentOverride: String?
    ) -> Bool {
        guard environmentOverride != "0", anchorIsTerminal else { return false }

        switch style {
        case .iPadOverlay:
            // An overlay needs a pane wide enough for card + terminal.
            return paneWidth.isFinite
                && paneWidth >= minimumPaneWidth
                && !isCompactWidth
        case .visionOrnament:
            return true
        }
    }
}
