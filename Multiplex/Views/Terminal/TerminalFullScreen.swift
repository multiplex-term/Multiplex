import UIKit

/// Where a full-screen pane sits: inside the scene's safe area, read through
/// the classic rail's corrections (`TerminalClassicRailInsets`). iPadOS
/// reports the display's status bar as a floating window's top inset, so only
/// the band actually under it counts; a floating window's close/minimize pill
/// sits over the first row's leading cells, so the pane starts below it. The
/// Mac's scene already sits under a real title bar. Wherever the windowed key
/// rail spends the home strip, the pane spends it too, keeping the rail's own
/// daylight (`spentBottomStrip`). A phone's safe area is the truth otherwise
/// (sensor housing), except on the iPhone Duo's inner display: it reports
/// nothing beside its 55 pt corners once the status bar hides, so the pane
/// clears them vertically — a band at each end, never along its long sides
/// (24 pt a side costs ~6 columns).
enum TerminalFullScreenInsets {
    /// The pill's bottom edge under `.minimal` window controls (measured
    /// 6–27.5 pt from the window's top), rounded up.
    static let windowControlsBand: CGFloat = 28
    /// From this far down, a cell 6 pt in (the grid's gutter) clears a 55 pt
    /// corner whole: (55 − 6)² + (55 − (26 + 4))² ≤ 55², the 4 being the
    /// grid's top gutter.
    static let bareCornerClearance: CGFloat = 26

    /// Full screen keeps the side column where it is the strip around a
    /// camera — the iPhone Duo's outer display (compact width, a vertical
    /// system bar): no terminal cells belong beside the lens, so the column
    /// keeps its system glyphs and the UMD chips instead of standing empty.
    static func keepsSideColumn(
        isPhone: Bool,
        compactWidth: Bool,
        systemBarEdge: ShellRailEdge?
    ) -> Bool {
        isPhone && compactWidth && (systemBarEdge == .leading || systemBarEdge == .trailing)
    }

    static func resolve(
        sceneSafeArea: UIEdgeInsets,
        isPad: Bool,
        bareCorners: Bool = false,
        spentBottomStrip: CGFloat? = nil,
        hostsWindowControls: Bool,
        systemTopChromeOverlap: CGFloat,
        spansDisplay: Bool
    ) -> UIEdgeInsets {
        var insets = sceneSafeArea
        if let spentBottomStrip {
            insets.bottom = min(insets.bottom, spentBottomStrip)
        }
        guard isPad else {
            if bareCorners {
                insets.top = max(insets.top, bareCornerClearance)
                insets.bottom = max(insets.bottom, bareCornerClearance)
            }
            return insets
        }
        insets.top = TerminalClassicRailInsets.topStrip(
            sceneTopSafeArea: sceneSafeArea.top,
            hostsWindowControls: hostsWindowControls,
            systemTopChromeOverlap: systemTopChromeOverlap
        )
        if TerminalClassicRailInsets.floatsWithPill(
            hostsWindowControls: hostsWindowControls,
            spansDisplay: spansDisplay
        ) {
            insets.top = max(insets.top, windowControlsBand)
        }
        return insets
    }
}

/// Full screen's one control. iPad/iPhone: a square ⤡ over the pane's
/// top-trailing corner that dims while idle, so it covers as little of the
/// screen as it can, and wakes on a touch or a pointer hover. visionOS: `⤡
/// EXIT` on a larger face over the bottom-trailing corner, always at full
/// strength — the app never sees gaze, so a dimmed chip could never wake.
@MainActor
final class TerminalFullScreenExitButton: UMDChipBase {
    /// visionOS: bottom-trailing, captioned, never dimmed.
    static var isVisionFace: Bool {
        #if os(visionOS)
        true
        #else
        false
        #endif
    }
    /// Clear of a rounded display corner, or the visionOS window's 24 pt one.
    static let margin: CGFloat = isVisionFace ? 14 : 12
    static let idleAlpha: CGFloat = 0.45
    static let idleDelay: TimeInterval = 2.5
    private static let faceHeight: CGFloat = isVisionFace ? 36 : 30
    /// The visionOS face's caption.
    private static let captionSize: CGFloat = 12
    /// The face keeps a 44 pt press target.
    private static let touchOutset: CGFloat = 7

    private let symbolView = UIImageView()
    private let captionLabel = UILabel()
    private let contentStack = UIStackView()
    private var dimWork: DispatchWorkItem?

    init() {
        super.init(
            prominent: Self.isVisionFace,
            accessibilityLabel: String(localized: "Exit Full Screen")
        )
        accessibilityIdentifier = "terminalWindow.fullScreenExit"
        // It floats over live terminal content, like the Select Text block:
        // the strata step chips wear elsewhere let the screen read through.
        backgroundColor = GlassPrototype.floatingChrome
        symbolView.image = UIImage(
            systemName: "arrow.down.right.and.arrow.up.left",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: (Self.isVisionFace ? 13 : 12) * Theme.typeScale,
                weight: .semibold
            )
        )
        symbolView.contentMode = .scaleAspectFit
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 6
        contentStack.isUserInteractionEnabled = false
        contentStack.addArrangedSubview(symbolView)
        if Self.isVisionFace { contentStack.addArrangedSubview(captionLabel) }
        addSubview(contentStack)
        if !Self.isVisionFace {
            addAction(UIAction { [weak self] _ in self?.holdAwake() }, for: .touchDown)
            addAction(
                UIAction { [weak self] _ in self?.wake() },
                for: [.touchUpOutside, .touchCancel]
            )
            addGestureRecognizer(UIHoverGestureRecognizer(
                target: self,
                action: #selector(hovered(_:))
            ))
        }
        refreshColors()
    }

    override var intrinsicContentSize: CGSize {
        // The glyph-only face is square.
        guard Self.isVisionFace else {
            return CGSize(width: Self.faceHeight, height: Self.faceHeight)
        }
        let content = contentStack.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize
        )
        return CGSize(width: ceil(content.width + 22), height: Self.faceHeight)
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? UIKitChassis.bezelHi : GlassPrototype.floatingChrome
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let content = contentStack.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize
        )
        contentStack.frame = CGRect(
            x: (bounds.width - content.width) / 2,
            y: (bounds.height - content.height) / 2,
            width: content.width,
            height: content.height
        )
    }

    override func refreshColors() {
        super.refreshColors()
        symbolView.tintColor = ink
        captionLabel.attributedText = NSAttributedString(
            string: "EXIT",
            attributes: [
                .font: UIKitChassis.monoFont(Self.captionSize, weight: .semibold),
                .kern: 1.1,
                .foregroundColor: ink.resolvedColor(with: traitCollection),
            ]
        )
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -Self.touchOutset, dy: -Self.touchOutset).contains(point)
    }

    /// Full strength now, back to idle after `idleDelay` where it dims.
    func wake() {
        holdAwake()
        guard !Self.isVisionFace else { return }
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(
                withDuration: 0.6,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                self?.alpha = Self.idleAlpha
            }
        }
        dimWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleDelay, execute: work)
    }

    /// Full strength for as long as a finger or pointer is on it.
    private func holdAwake() {
        dimWork?.cancel()
        dimWork = nil
        layer.removeAllAnimations()
        alpha = 1
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began: holdAwake()
        case .ended, .cancelled: wake()
        default: break
        }
    }
}
