import CoreImage
import UIKit

@MainActor
enum SidePanelResizePhase {
    case began
    case changed
    case ended
}

/// One native mount around an existing auxiliary pane. It owns panel chrome,
/// never the viewer's lifetime: `TerminalWorkspace` remains the only owner
/// that may shut down the SSH connection or web page.
///
/// Resizing is UIKit-live with the card FROZEN while the finger moves: the
/// first movement renders it into one blurred bitmap, each tick stretches
/// that picture and moves the handles, the release reflows once. Frozen
/// until release on purpose — gaze-and-pinch delivers drag events with gaps,
/// so a mid-drag settle thaw flickered; per-tick reflow and a per-tick
/// system glass were both unusable on device. On visionOS the view is the
/// whole strip the ornament hosts, so a drag never touches the ornament.
@MainActor
final class SidePanelViewController: UIViewController {
    static let headerHeight: CGFloat = 30
    /// iPad: the seam's hit strip straddles the card's leading edge — this
    /// much outside the card (the window widens the container by it) and
    /// `seamInside` over the card.
    static let seamOverhang: CGFloat = 12
    static let seamInside: CGFloat = 24
    /// visionOS: each handle reaches this far to both sides of its edge, the
    /// card's height above the action row (sharing the row's corner fired ✕).
    static let visionHandleReach: CGFloat = 28
    /// visionOS: the header and content sit this far inside the slab, the
    /// glass's own silhouette.
    static let visionContentInset: CGFloat = 10

    /// How far the hosting container must extend past the card's leading
    /// edge so the seam's outside half is hit-testable (iPad only).
    var leadingOverhang: CGFloat {
        presentationStyle == .iPadOverlay ? Self.seamOverhang : 0
    }

    let controller: any AuxiliaryPaneController
    let paneController: UIViewController
    let presentationStyle: SidePanelPresentationStyle

    /// `(width, overhang, phase)`. iPad reports the wanted width (overhang 0)
    /// and the window lays the container out; visionOS lays itself out live
    /// and reports the geometry to persist on `.ended`.
    private let resizeAction: (CGFloat, CGFloat, SidePanelResizePhase) -> Void
    private(set) var panelWidth: CGFloat
    /// visionOS: the card's right edge past the glass's trailing edge
    /// (`SidePanelWidth.clampedVisionGeometry`).
    private(set) var overhang: CGFloat
    private var dragStart: (width: CGFloat, overhang: CGFloat)?
    private var isDragging: Bool { dragStart != nil }
    /// The card's picture while the finger moves; nil while the live views
    /// are showing (idle, released).
    private var dragSnapshot: UIView?
    /// Under GLASS the SwiftUI host paints the system glass platter behind
    /// the card; it hears the card's frame on the content cadence.
    var onCardFrameChange: ((CGRect) -> Void)?

    private let cardView = UIKitTallyBorderedView()
    private let headerView: SidePanelHeaderView
    private let leadingSeam = SidePanelSeamView()
    private let trailingSeam = SidePanelSeamView()
    private let widthReadout = ViewportBadgeView("")
    private var preparedForRemoval = false

    init(
        controller: any AuxiliaryPaneController,
        paneController: UIViewController,
        presentationStyle: SidePanelPresentationStyle,
        width: CGFloat,
        overhang: CGFloat = SidePanelWidth.defaultVisionOverhang,
        split: @escaping () -> Void,
        close: @escaping () -> Void,
        resize: @escaping (CGFloat, CGFloat, SidePanelResizePhase) -> Void = { _, _, _ in }
    ) {
        self.controller = controller
        self.paneController = paneController
        self.presentationStyle = presentationStyle
        headerView = SidePanelHeaderView(
            edge: presentationStyle == .visionOrnament ? .bottom : .top,
            split: split,
            close: close
        )
        panelWidth = width
        self.overhang = overhang
        resizeAction = resize
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        let root: UIView = presentationStyle == .visionOrnament
            ? SidePanelStripView()
            : UIView()
        root.backgroundColor = .clear
        root.clipsToBounds = false
        root.accessibilityIdentifier = "terminal.sidePanel"
        view = root

        configureCard()
        root.addSubview(cardView)
        cardView.addSubview(headerView)

        addChild(paneController)
        cardView.addSubview(paneController.view)
        paneController.didMove(toParent: self)

        leadingSeam.onResize = { [weak self] translation, phase in
            self?.leadingSeamMoved(translation, phase: phase)
        }
        switch presentationStyle {
        case .iPadOverlay:
            leadingSeam.pillCenterX = Self.seamOverhang
            // On the root, not the card: the strip reaches past the card's edge.
            root.addSubview(leadingSeam)
            configureWidthReadout()
            cardView.addSubview(widthReadout)
        case .visionOrnament:
            leadingSeam.pillCenterX = Self.visionHandleReach
            trailingSeam.pillCenterX = Self.visionHandleReach
            trailingSeam.accessibilityIdentifier = "sidePanel.resizeSeam.trailing"
            trailingSeam.onResize = { [weak self] translation, phase in
                self?.trailingSeamMoved(translation, phase: phase)
            }
            root.addSubview(leadingSeam)
            root.addSubview(trailingSeam)
        }

        refreshHeader()
    }

    private func configureWidthReadout() {
        widthReadout.setText(Self.widthLabel(panelWidth))
        widthReadout.isHidden = true
        widthReadout.accessibilityIdentifier = "sidePanel.widthReadout"
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        UIView.performWithoutAnimation {
            let bounds = view.bounds
            let contentInset: CGFloat
            switch presentationStyle {
            case .iPadOverlay:
                contentInset = 0
                cardView.frame = CGRect(
                    x: Self.seamOverhang,
                    y: 0,
                    width: max(0, bounds.width - Self.seamOverhang),
                    height: bounds.height
                )
                leadingSeam.frame = CGRect(
                    x: 0,
                    y: 0,
                    width: Self.seamOverhang + Self.seamInside,
                    height: bounds.height
                )
            case .visionOrnament:
                contentInset = Self.visionContentInset
                // The strip starts at the window's leading edge and its
                // middle is the glass's trailing edge. A window that shrank
                // under the stored geometry clamps here; the values stay.
                let geometry = effectiveVisionGeometry
                let width = geometry.width
                let x = bounds.width / 2 + geometry.overhang - width
                cardView.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
                let reach = Self.visionHandleReach
                let handleHeight = max(
                    0,
                    bounds.height - Self.headerHeight - Self.visionContentInset
                )
                leadingSeam.frame = CGRect(x: x - reach, y: 0, width: reach * 2, height: handleHeight)
                trailingSeam.frame = CGRect(
                    x: x + width - reach,
                    y: 0,
                    width: reach * 2,
                    height: handleHeight
                )
            }
            if presentationStyle == .iPadOverlay {
                widthReadout.frame = CGRect(
                    origin: CGPoint(x: Self.seamInside + 4, y: Self.headerHeight + 12),
                    size: widthReadout.intrinsicContentSize
                )
            }
            // Frozen: the blurred picture stretches with the card, so no
            // edge leaves a stale band behind. Nothing below runs per tick.
            if let dragSnapshot {
                dragSnapshot.frame = cardView.bounds
                return
            }
            let card = cardView.bounds.insetBy(dx: contentInset, dy: contentInset)
            let contentHeight = max(0, card.height - Self.headerHeight)
            switch headerView.edge {
            case .top:
                headerView.frame = CGRect(
                    x: card.minX, y: card.minY, width: card.width, height: Self.headerHeight
                )
                paneController.view.frame = CGRect(
                    x: card.minX, y: card.minY + Self.headerHeight, width: card.width, height: contentHeight
                )
            case .bottom:
                paneController.view.frame = CGRect(
                    x: card.minX, y: card.minY, width: card.width, height: contentHeight
                )
                headerView.frame = CGRect(
                    x: card.minX,
                    y: card.maxY - Self.headerHeight,
                    width: card.width,
                    height: Self.headerHeight
                )
            }
            headerView.applyPanelWidth(card.width)
            reportCardFrame()
        }
    }

    func updateWidth(_ width: CGFloat) {
        guard panelWidth != width else { return }
        panelWidth = width
        widthReadout.setText(Self.widthLabel(width))
        if isDragging {
            // The window drives iPad ticks: freeze on the first.
            freezeIfNeeded()
        } else {
            headerView.applyPanelWidth(width)
        }
        viewIfLoaded?.setNeedsLayout()
    }

    func updateOverhang(_ overhang: CGFloat) {
        guard self.overhang != overhang else { return }
        self.overhang = overhang
        viewIfLoaded?.setNeedsLayout()
    }

    func setPresented(_ presented: Bool) {
        (paneController as? FileViewerPaneViewController)?.setActive(presented)
    }

    func refreshHeader() {
        guard isViewLoaded else { return }
        if let pane = paneController as? FileViewerPaneViewController,
           let configuration = pane.ornamentConfiguration {
            headerView.apply(fileViewer: configuration, title: controller.tabLabel, width: panelWidth)
        } else if let pane = paneController as? ViewportPaneViewController,
                  let configuration = pane.ornamentConfiguration {
            headerView.apply(viewport: configuration, width: panelWidth)
        }
    }

    /// Unmounts pane-owned presentation/observation state but deliberately
    /// does not call the auxiliary controller's `shutdown()`. The workspace
    /// decides whether this was a close, replacement, or ↗ TAB re-key.
    func prepareForRemoval() {
        guard !preparedForRemoval else { return }
        preparedForRemoval = true
        dragSnapshot?.removeFromSuperview()
        dragSnapshot = nil
        (paneController as? ViewportPaneViewController)?.prepareForRemoval()
        (paneController as? FileViewerPaneViewController)?.prepareForRemoval()
    }

    // MARK: Live resize

    private func leadingSeamMoved(_ translation: CGFloat, phase: SidePanelResizePhase) {
        if phase == .began { beginDrag() }
        guard let start = dragStart else { return }
        switch presentationStyle {
        case .iPadOverlay:
            // The window owns the container: report the wanted width, it
            // clamps and lays out, and `updateWidth` brings the card along.
            if phase != .began { resizeAction(start.width - translation, 0, phase) }
            if phase == .ended { endDrag() }
        case .visionOrnament:
            applyLiveGeometry(
                SidePanelWidth.visionGeometry(
                    draggingLeadingEdgeBy: translation,
                    from: start,
                    stripWidth: view.bounds.width
                ),
                phase: phase
            )
        }
    }

    private func trailingSeamMoved(_ translation: CGFloat, phase: SidePanelResizePhase) {
        if phase == .began { beginDrag() }
        guard let start = dragStart, presentationStyle == .visionOrnament else { return }
        applyLiveGeometry(
            SidePanelWidth.visionGeometry(
                draggingTrailingEdgeBy: translation,
                from: start,
                stripWidth: view.bounds.width
            ),
            phase: phase
        )
    }

    /// The card as the live strip can hold it: the stored geometry clamped
    /// to the current bounds (a window narrower than the stored reach).
    private var effectiveVisionGeometry: (width: CGFloat, overhang: CGFloat) {
        SidePanelWidth.clampedVisionGeometry(
            width: panelWidth,
            overhang: overhang,
            stripWidth: view.bounds.width
        )
    }

    /// A clamped geometry from the model, straight onto the card.
    private func applyLiveGeometry(
        _ geometry: (width: CGFloat, overhang: CGFloat),
        phase: SidePanelResizePhase
    ) {
        panelWidth = geometry.width
        overhang = geometry.overhang
        if phase == .ended {
            endDrag()
            resizeAction(panelWidth, overhang, .ended)
            return
        }
        freezeIfNeeded()
        // No synchronous layout per event: several gesture events inside one
        // frame coalesce into one layout pass.
        view.setNeedsLayout()
    }

    private func beginDrag() {
        // A drag starts from the card as shown, not from stored values a
        // narrower window could not hold — else the first tick jumps.
        let start = presentationStyle == .visionOrnament
            ? effectiveVisionGeometry
            : (width: panelWidth, overhang: 0)
        dragStart = start
        widthReadout.isHidden = presentationStyle != .iPadOverlay
        leadingSeam.setHoverEnabled(false)
        trailingSeam.setHoverEnabled(false)
        reportCardFrame()
        resizeAction(start.width, start.overhang, .began)
    }

    /// First movement: picture the card once (blurred), hide the live views
    /// and let the frame do the rest; a declined render gets a plain
    /// snapshot under a live blur.
    private func freezeIfNeeded() {
        guard isDragging, dragSnapshot == nil else { return }
        let picture: UIView
        if let image = Self.blurredPicture(of: cardView) {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleToFill
            picture = imageView
        } else if let snapshot = cardView.snapshotView(afterScreenUpdates: false)
            ?? cardView.snapshotView(afterScreenUpdates: true) {
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
            blur.frame = snapshot.bounds
            blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            snapshot.addSubview(blur)
            picture = snapshot
        } else {
            return
        }
        picture.frame = cardView.bounds
        picture.isUserInteractionEnabled = false
        cardView.addSubview(picture)
        headerView.isHidden = true
        paneController.view.isHidden = true
        dragSnapshot = picture
    }

    private static let blurContext = CIContext(options: [.useSoftwareRenderer: false])

    /// The card as one blurred bitmap at 1× — once per drag.
    private static func blurredPicture(of view: UIView) -> UIImage? {
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            view.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        guard let input = CIImage(image: rendered) else { return nil }
        let blurred = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 7)
            .cropped(to: input.extent)
        guard let cgImage = blurContext.createCGImage(blurred, from: input.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    /// Released: the live views return and reflow once at the new size; the
    /// picture leaves a turn later so the reflow has painted.
    private func thaw() {
        guard let snapshot = dragSnapshot else { return }
        dragSnapshot = nil
        headerView.isHidden = false
        paneController.view.isHidden = false
        view.setNeedsLayout()
        view.layoutIfNeeded()
        reportCardFrame()
        DispatchQueue.main.async { snapshot.removeFromSuperview() }
    }

    private func endDrag() {
        dragStart = nil
        widthReadout.isHidden = true
        leadingSeam.setHoverEnabled(true)
        trailingSeam.setHoverEnabled(true)
        thaw()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        reportCardFrame()
    }

    // MARK: Testing

    var isFrozenForTesting: Bool { dragSnapshot != nil }
    var cardFrameForTesting: CGRect { cardView.frame }

    func simulateLeadingDragForTesting(translation: CGFloat, phase: SidePanelResizePhase) {
        leadingSeamMoved(translation, phase: phase)
    }

    func simulateTrailingDragForTesting(translation: CGFloat, phase: SidePanelResizePhase) {
        trailingSeamMoved(translation, phase: phase)
    }

    private func reportCardFrame() {
        guard presentationStyle == .visionOrnament else { return }
        // While the finger moves the platter is down (an empty frame) — a
        // system glass resized per tick showed on device; back on release.
        onCardFrameChange?(isDragging ? .zero : cardView.frame)
    }

    private func configureCard() {
        cardView.accessibilityIdentifier = "terminal.sidePanel.card"
        switch presentationStyle {
        case .iPadOverlay:
            cardView.backgroundColor = UIKitChassis.bezel
            cardView.layer.cornerRadius = 3
            cardView.layer.cornerCurve = .continuous
            cardView.clipsToBounds = true
            view.layer.shadowColor = UIColor.black.cgColor
            view.layer.shadowOpacity = 0.45
            view.layer.shadowRadius = 24
            view.layer.shadowOffset = CGSize(width: -8, height: 6)
        case .visionOrnament:
            // The card IS the slab: smoke under GLASS (the SwiftUI host adds
            // the platter behind it), opaque chassis otherwise; the root is
            // the transparent strip.
            view.backgroundColor = .clear
            view.layer.shadowOpacity = 0
            cardView.backgroundColor = GlassPrototype.windowGround
            cardView.layer.borderWidth = 0
            cardView.layer.cornerRadius = 14
            cardView.layer.cornerCurve = .continuous
            cardView.clipsToBounds = true
        }
    }

    private static func widthLabel(_ width: CGFloat) -> String {
        "\(String(Int(width.rounded()))) pt"
    }
}

/// The visionOS strip: transparent and never the hit target itself, so a
/// pinch on its empty part falls through to the glass behind it.
@MainActor
final class SidePanelStripView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// Which edge of the card the row sits on: a header on iPad, the lower edge
/// on visionOS like every ornament row. Hairline and progress line face the
/// content.
enum SidePanelRowEdge {
    case top
    case bottom
}

/// The one 30-point action row. It consumes the same value snapshots as the
/// visionOS auxiliary ornaments; its controls expand by measured priority and
/// `⋯` exists only for what did not fit.
@MainActor
final class SidePanelHeaderView: UIView {
    /// ▤ groups in the order they earn a chip as the row widens.
    private enum FileGroup: Equatable, CaseIterable {
        case tree
        case refresh
        case sourceDiff
        case select
        case textScale
        case host
    }

    private struct FilePlan: Equatable {
        var surfaced: [FileGroup]
        var showsCrumb: Bool
        var showsMore: Bool
    }

    private enum RenderKey: Equatable {
        case none
        case file(
            FileViewerOrnamentConfiguration.RenderKey,
            title: String,
            plan: FilePlan,
            textScale: CGFloat
        )
        case viewport(ViewportOrnamentConfiguration.RenderKey, showsSystem: Bool)
    }

    private enum Content {
        case none
        case file(FileViewerOrnamentConfiguration, title: String)
        case viewport(ViewportOrnamentConfiguration)
    }

    private static let gap: CGFloat = 5
    private static let horizontalPadding: CGFloat = 15
    private static let minimumCrumbWidth: CGFloat = 48
    private static let minimumAddressWidth: CGFloat = 140
    /// Chip, label and badge widths depend on their text and the type scale
    /// alone, and the row measures the same handful of strings every plan.
    private static var measuredWidths: [String: CGFloat] = [:]

    let edge: SidePanelRowEdge
    /// The panel's own controls — the same two for the row's whole life.
    private let splitAction: () -> Void
    private let closeAction: () -> Void
    private var content = Content.none
    private var panelWidth: CGFloat = 0
    private var renderedKey = RenderKey.none
    private let row = UIStackView()
    private let progressLine = UIView()

    init(edge: SidePanelRowEdge, split: @escaping () -> Void, close: @escaping () -> Void) {
        self.edge = edge
        splitAction = split
        closeAction = close
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.bezel
        clipsToBounds = true

        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Self.gap
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let hairline = UIView()
        hairline.backgroundColor = UIKitChassis.bezelHi
        hairline.isUserInteractionEnabled = false
        addSubview(hairline)
        hairline.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            edge == .top
                ? hairline.bottomAnchor.constraint(equalTo: bottomAnchor)
                : hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
        ])

        progressLine.backgroundColor = TallyPalette.caution
        progressLine.isAccessibilityElement = false
        addSubview(progressLine)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let progress: CGFloat
        if case .viewport(let configuration) = content,
           configuration.key.isLoading {
            progress = CGFloat(min(max(configuration.key.progress, 0), 1))
        } else {
            progress = 0
        }
        progressLine.isHidden = progress == 0
        progressLine.frame = CGRect(
            x: 0,
            y: edge == .top ? max(0, bounds.height - 2) : 0,
            width: bounds.width * progress,
            height: 2
        )
    }

    func apply(fileViewer: FileViewerOrnamentConfiguration, title: String, width: CGFloat) {
        content = .file(fileViewer, title: title)
        panelWidth = width
        rebuild()
    }

    func apply(viewport: ViewportOrnamentConfiguration, width: CGFloat) {
        content = .viewport(viewport)
        panelWidth = width
        rebuild()
        // The progress line is drawn by layout, never by a rebuild.
        setNeedsLayout()
    }

    func applyPanelWidth(_ width: CGFloat) {
        guard abs(panelWidth - width) > 0.5 else { return }
        panelWidth = width
        rebuild()
    }

    // MARK: Measuring — what fits is decided by the chips themselves

    private static func measured(_ key: String, _ make: () -> UIView) -> CGFloat {
        if let cached = measuredWidths[key] { return cached }
        let width = make().intrinsicContentSize.width
        measuredWidths[key] = width
        return width
    }

    private static func chipWidth(_ caption: String, systemImage: String? = nil) -> CGFloat {
        measured("chip|" + caption + "|" + (systemImage ?? "")) {
            UIKitChassisChip(caption, systemImage: systemImage, accessibilityLabel: caption, action: {})
        }
    }

    private static func labelWidth(_ text: String) -> CGFloat {
        measured("label|" + text) { UIKitChassisLabel(text, size: 9) }
    }

    private static func badgeWidth(_ text: String) -> CGFloat {
        measured("badge|" + text) { FileViewerBadgeView(text) }
    }

    private func filePlan(_ state: FileViewerOrnamentConfiguration.RenderKey, title: String) -> FilePlan {
        let gap = Self.gap
        var fixed = Self.labelWidth(title) + gap
        if state.canGoBack || state.canGoForward {
            fixed += Self.chipWidth("◂") + 2 + Self.chipWidth("▸") + gap
        }
        fixed += Self.chipWidth("↗ TAB") + gap + Self.chipWidth("✕")

        var candidates: [(FileGroup, CGFloat)] = [
            (.tree, Self.chipWidth(state.treeCaption) + gap),
            (.refresh, Self.chipWidth("REFRESH") + gap),
        ]
        if state.showsSourceDiff {
            candidates.append((.sourceDiff, Self.chipWidth("SOURCE") + 4 + Self.chipWidth("DIFF") + gap))
        }
        if let caption = state.markdownSelectionCaption {
            candidates.append((.select, Self.chipWidth(caption) + gap))
        }
        candidates.append((.textScale, Self.chipWidth("A−") + 2 + Self.chipWidth("A+") + gap))
        candidates.append((.host, Self.badgeWidth(state.hostName.uppercased()) + gap))

        var room = panelWidth - Self.horizontalPadding - fixed
        let showsCrumb = room >= Self.minimumCrumbWidth
        if showsCrumb { room -= Self.minimumCrumbWidth }
        let everything = candidates.reduce(0) { $0 + $1.1 }
        if everything <= room {
            return FilePlan(surfaced: candidates.map(\.0), showsCrumb: showsCrumb, showsMore: false)
        }
        // Something folds, so `⋯` takes its place first; then the ladder
        // fills strictly in order — never A− A+ while REFRESH is folded.
        room -= Self.chipWidth("⋯") + gap
        var surfaced: [FileGroup] = []
        for (group, width) in candidates {
            guard width <= room else { break }
            surfaced.append(group)
            room -= width
        }
        return FilePlan(surfaced: surfaced, showsCrumb: showsCrumb, showsMore: true)
    }

    /// Whether SYSTEM fits beside the viewport's fixed controls.
    private func viewportShowsSystem(_ state: ViewportOrnamentConfiguration.RenderKey) -> Bool {
        let gap = Self.gap
        let fixed = Self.chipWidth("", systemImage: "chevron.left") + gap
            + Self.chipWidth("", systemImage: "arrow.clockwise") + gap
            + Self.minimumAddressWidth + gap
            + Self.badgeWidth(state.railTag) + gap
            + Self.chipWidth("↗ TAB") + gap
            + Self.chipWidth("✕")
        let room = panelWidth - Self.horizontalPadding - fixed
        return Self.chipWidth("SYSTEM") + gap <= room
    }

    // MARK: Building

    private func rebuild() {
        let nextKey: RenderKey
        let build: () -> Void
        switch content {
        case .none:
            nextKey = .none
            build = {}
        case .file(let configuration, let title):
            let plan = filePlan(configuration.key, title: title)
            nextKey = .file(
                configuration.key,
                title: title,
                plan: plan,
                textScale: FileViewerTextScaleStore.shared.scale
            )
            build = { self.buildFileRow(configuration, title: title, plan: plan) }
        case .viewport(let configuration):
            let showsSystem = viewportShowsSystem(configuration.key)
            // Loading progress moves tens of times a page; layout draws the
            // line from `content`, so it must not tear the row down.
            var key = configuration.key
            key.progress = 0
            nextKey = .viewport(key, showsSystem: showsSystem)
            build = { self.buildViewportRow(configuration, showsSystem: showsSystem) }
        }
        guard renderedKey != nextKey else { return }
        renderedKey = nextKey
        UIView.performWithoutAnimation {
            for arranged in row.arrangedSubviews {
                row.removeArrangedSubview(arranged)
                arranged.removeFromSuperview()
            }
            build()
            setNeedsLayout()
            layoutIfNeeded()
        }
    }

    private func buildFileRow(
        _ configuration: FileViewerOrnamentConfiguration,
        title: String,
        plan: FilePlan
    ) {
        let state = configuration.key
        // ✕ then ↗ TAB lead the row; the viewer's controls follow.
        row.addArrangedSubview(closeChip(String(localized: "Close file viewer panel")))
        row.addArrangedSubview(splitChip(String(localized: "Move file viewer to a tab")))
        let identity = UIKitChassisLabel(title, size: 9)
        identity.setContentHuggingPriority(.required, for: .horizontal)
        identity.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(identity)

        if plan.showsCrumb {
            let crumb = UIKitChassisMonoLabel(
                Self.directoryCrumb(state.path),
                font: UIKitChassis.monoFont(9),
                color: UIKitChassis.signal3
            )
            crumb.lineBreakMode = .byTruncatingMiddle
            crumb.setContentHuggingPriority(.defaultLow, for: .horizontal)
            crumb.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(crumb)
        } else {
            let spacer = UIView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)
        }

        if state.canGoBack || state.canGoForward {
            let back = UIKitChassisChip.rail(
                "◂",
                accessibilityLabel: String(localized: "Back"),
                action: configuration.goBack
            )
            back.isEnabled = state.canGoBack
            let forward = UIKitChassisChip.rail(
                "▸",
                accessibilityLabel: String(localized: "Forward"),
                action: configuration.goForward
            )
            forward.isEnabled = state.canGoForward
            row.addArrangedSubview(pair(back, forward, spacing: 2))
        }

        for group in plan.surfaced {
            switch group {
            case .tree:
                let tree = UIKitChassisChip.rail(
                    state.treeCaption,
                    accessibilityLabel: state.treeCaption == "HIDE"
                        ? String(localized: "Hide the file tree")
                        : String(localized: "Show the file tree"),
                    action: configuration.toggleTree
                )
                tree.accessibilityIdentifier = "sidePanel.file.tree"
                row.addArrangedSubview(tree)
            case .refresh:
                let refresh = UIKitChassisChip.rail(
                    "REFRESH",
                    accessibilityLabel: String(localized: "Refresh file viewer"),
                    action: configuration.refresh
                )
                refresh.accessibilityIdentifier = "sidePanel.file.refresh"
                refresh.isEnabled = !state.isBusy
                row.addArrangedSubview(refresh)
            case .sourceDiff:
                let source = UIKitChassisChip.rail(
                    "SOURCE",
                    prominent: state.sourceSelected,
                    accessibilityLabel: String(localized: "Show source"),
                    action: configuration.showSource
                )
                let diff = UIKitChassisChip.rail(
                    "DIFF",
                    prominent: !state.sourceSelected,
                    accessibilityLabel: String(localized: "Show diff"),
                    action: configuration.showDiff
                )
                let mode = pair(source, diff, spacing: 4)
                mode.accessibilityLabel = String(localized: "Source or diff")
                row.addArrangedSubview(mode)
            case .select:
                let caption = state.markdownSelectionCaption ?? "SELECT"
                let select = UIKitChassisChip.rail(
                    caption,
                    prominent: caption == "DONE",
                    accessibilityLabel: caption == "DONE"
                        ? String(localized: "Back to rendered markdown")
                        : String(localized: "Select source text to copy"),
                    action: configuration.toggleMarkdownSelection
                )
                select.accessibilityIdentifier = "sidePanel.file.select"
                row.addArrangedSubview(select)
            case .textScale:
                let store = FileViewerTextScaleStore.shared
                let smaller = UIKitChassisChip.rail(
                    "A−",
                    accessibilityLabel: String(localized: "Smaller text"),
                    action: { store.step(by: -1) }
                )
                smaller.isEnabled = store.canStep(by: -1)
                let larger = UIKitChassisChip.rail(
                    "A+",
                    accessibilityLabel: String(localized: "Larger text"),
                    action: { store.step(by: 1) }
                )
                larger.isEnabled = store.canStep(by: 1)
                row.addArrangedSubview(pair(smaller, larger, spacing: 2))
            case .host:
                let host = FileViewerBadgeView(state.hostName.uppercased())
                host.accessibilityLabel = String(localized: "Files on \(state.hostName)")
                host.setContentHuggingPriority(.required, for: .horizontal)
                row.addArrangedSubview(host)
            }
        }

        if plan.showsMore {
            let folded = FileGroup.allCases.filter { !plan.surfaced.contains($0) }
            let more = ViewportMenuButton(
                caption: "⋯",
                accessibilityLabel: String(localized: "More file viewer actions"),
                menu: fileMenu(configuration, folded: folded)
            )
            more.accessibilityIdentifier = "sidePanel.file.more"
            row.addArrangedSubview(more)
        }
    }

    /// Only what the row could not surface, in the same order.
    private func fileMenu(
        _ configuration: FileViewerOrnamentConfiguration,
        folded: [FileGroup]
    ) -> UIMenu {
        let state = configuration.key
        var actions: [UIMenuElement] = []
        for group in folded {
            switch group {
            case .tree:
                actions.append(UIAction(
                    title: state.treeCaption == "HIDE"
                        ? String(localized: "Hide File Tree")
                        : String(localized: "Show File Tree")
                ) { _ in configuration.toggleTree() })
            case .refresh:
                actions.append(UIAction(title: String(localized: "Refresh")) { _ in
                    configuration.refresh()
                })
            case .sourceDiff:
                guard state.showsSourceDiff else { continue }
                actions.append(UIAction(
                    title: String(localized: "Source"),
                    state: state.sourceSelected ? .on : .off
                ) { _ in configuration.showSource() })
                actions.append(UIAction(
                    title: String(localized: "Diff"),
                    state: state.sourceSelected ? .off : .on
                ) { _ in configuration.showDiff() })
            case .select:
                guard let caption = state.markdownSelectionCaption else { continue }
                actions.append(UIAction(
                    title: caption == "DONE"
                        ? String(localized: "Done Selecting")
                        : String(localized: "Select Source Text")
                ) { _ in configuration.toggleMarkdownSelection() })
            case .textScale:
                let scaleStore = FileViewerTextScaleStore.shared
                actions.append(UIAction(
                    title: "A− · " + String(localized: "Smaller Text"),
                    attributes: scaleStore.canStep(by: -1) ? [] : .disabled
                ) { _ in scaleStore.step(by: -1) })
                actions.append(UIAction(
                    title: "A+ · " + String(localized: "Larger Text"),
                    attributes: scaleStore.canStep(by: 1) ? [] : .disabled
                ) { _ in scaleStore.step(by: 1) })
            case .host:
                actions.append(UIAction(
                    title: state.hostName,
                    attributes: .disabled
                ) { _ in })
            }
        }
        return UIMenu(children: actions)
    }

    private func buildViewportRow(
        _ configuration: ViewportOrnamentConfiguration,
        showsSystem: Bool
    ) {
        let state = configuration.key
        row.addArrangedSubview(closeChip(String(localized: "Close viewport panel")))
        row.addArrangedSubview(splitChip(String(localized: "Move viewport to a tab")))
        let back = UIKitChassisChip.rail(
            "",
            systemImage: "chevron.left",
            accessibilityLabel: String(localized: "Back"),
            action: configuration.goBack
        )
        back.isEnabled = state.canGoBack
        row.addArrangedSubview(back)

        let reload = UIKitChassisChip.rail(
            "",
            systemImage: state.isLoading ? "xmark" : "arrow.clockwise",
            accessibilityLabel: state.isLoading
                ? String(localized: "Stop loading")
                : String(localized: "Reload"),
            action: configuration.reloadOrStop
        )
        row.addArrangedSubview(reload)

        let address = UIButton(type: .custom)
        address.contentHorizontalAlignment = .leading
        address.titleLabel?.numberOfLines = 1
        address.titleLabel?.lineBreakMode = .byTruncatingMiddle
        address.setAttributedTitle(
            ViewportPaneViewController.readoutText(state.displayURL),
            for: .normal
        )
        address.accessibilityLabel = state.displayURL.absoluteString
        address.accessibilityHint = String(localized: "Edits the address")
        address.accessibilityIdentifier = "sidePanel.viewport.address"
        address.hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        address.addAction(UIAction { _ in configuration.editAddress() }, for: .touchUpInside)
        address.menu = UIMenu(children: [
            UIAction(
                title: String(localized: "Copy Address"),
                image: UIImage(systemName: "doc.on.doc")
            ) { _ in configuration.copyAddress() },
            UIAction(
                title: String(localized: "Clear Browsing Data…"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { _ in configuration.clearBrowsingData() },
        ])
        address.showsMenuAsPrimaryAction = false
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(address)

        let reach = ViewportBadgeView(state.railTag)
        reach.accessibilityLabel = String(localized: "Reach: \(state.railTag)")
        reach.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(reach)

        if showsSystem {
            let system = UIKitChassisChip.rail(
                "SYSTEM",
                accessibilityLabel: String(localized: "Open in the system browser"),
                action: configuration.openInSystemBrowser
            )
            system.accessibilityIdentifier = "sidePanel.viewport.system"
            row.addArrangedSubview(system)
        } else {
            let more = ViewportMenuButton(
                caption: "⋯",
                accessibilityLabel: String(localized: "More viewport actions"),
                menu: UIMenu(children: [
                    UIAction(
                        title: String(localized: "Open in System Browser"),
                        image: UIImage(systemName: "safari")
                    ) { _ in configuration.openInSystemBrowser() },
                ])
            )
            more.accessibilityIdentifier = "sidePanel.viewport.more"
            row.addArrangedSubview(more)
        }
    }

    private func pair(_ first: UIView, _ second: UIView, spacing: CGFloat) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: [first, second])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = spacing
        stack.isAccessibilityElement = false
        return stack
    }

    private func splitChip(_ accessibility: String) -> UIKitChassisChip {
        let result = UIKitChassisChip.rail("↗ TAB", accessibilityLabel: accessibility, action: splitAction)
        result.accessibilityIdentifier = "sidePanel.split"
        return result
    }

    private func closeChip(_ accessibility: String) -> UIKitChassisChip {
        let result = UIKitChassisChip.rail(
            "✕",
            prominent: true,
            accessibilityLabel: accessibility,
            action: closeAction
        )
        result.accessibilityIdentifier = "sidePanel.close"
        return result
    }

    private static func directoryCrumb(_ path: String) -> String {
        FileTree.parent(of: path) ?? path
    }
}

/// A resize handle: a hit strip straddling one edge of the card, drawing
/// only the authored 3×36 pill (on the edge itself — `pillCenterX`). The
/// callback reports horizontal translation from gesture start; the owner
/// turns it into geometry, clamps, lays out and persists.
@MainActor
final class SidePanelSeamView: UIView {
    var onResize: (CGFloat, SidePanelResizePhase) -> Void = { _, _ in }
    /// Where the pill is drawn — the card's edge, not the strip's middle.
    var pillCenterX: CGFloat? {
        didSet { setNeedsLayout() }
    }

    private let pill = UIView()
    private var dragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        accessibilityIdentifier = "sidePanel.resizeSeam"
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Resize side panel")
        accessibilityTraits = [.adjustable]

        pill.backgroundColor = UIKitChassis.signal3
        pill.layer.cornerRadius = 1.5
        pill.isUserInteractionEnabled = false
        addSubview(pill)
        setHoverEnabled(true)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func layoutSubviews() {
        super.layoutSubviews()
        pill.frame = CGRect(
            x: (pillCenterX ?? bounds.midX) - 1.5,
            y: (bounds.height - 36) / 2,
            width: 3,
            height: 36
        )
    }

    /// Off while a drag moves this view every tick — a moving hover region is
    /// a system re-registration per frame.
    func setHoverEnabled(_ enabled: Bool) {
        hoverStyle = enabled
            ? UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 10))
            : nil
    }

    override func accessibilityIncrement() {
        onResize(-SidePanelWidth.accessibilityStep, .ended)
    }

    override func accessibilityDecrement() {
        onResize(SidePanelWidth.accessibilityStep, .ended)
    }

    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self).x
        switch recognizer.state {
        case .began:
            dragging = true
            pill.backgroundColor = UIKitChassis.signal2
            onResize(0, .began)
        case .changed:
            onResize(translation, .changed)
        case .ended, .cancelled, .failed:
            dragging = false
            pill.backgroundColor = UIKitChassis.signal3
            onResize(translation, .ended)
        default:
            break
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        pill.backgroundColor = dragging ? UIKitChassis.signal2 : UIKitChassis.signal3
    }
}
