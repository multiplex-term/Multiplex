import SwiftTerm
import UIKit

/// The panes of a tab whose backend hands them out separately, drawn the
/// way that backend arranged them (`PaneLayout`): one emulator per pane, a
/// hairline between the two sides of every split, and a frame around the
/// pane the keyboard is on.
///
/// It sits exactly where a single-stream tab's one `TerminalView` sits in
/// `TerminalSurfaceView`, so the surface's keyboard avoidance, bottom
/// chrome and safe-area edges move it the same way and each pane's emulator
/// simply measures a new grid from its new frame.
///
/// - **Dragging a line resizes** the split it divides. The tab's own layout
///   follows the finger at once (`TerminalSessionController.setPaneRatio`);
///   the backend is asked in order behind it.
/// - **A touch puts the keyboard on a pane** — at touch DOWN, not on the
///   tap's release, so a long press already has the pane's own selection
///   menu under it (`TerminalSurfaceView.Coordinator`).
/// - A tab with ONE pane draws no line and no frame: it is the single
///   emulator it always was.
///
/// Colors come from the terminal theme, never the chassis: this is inside
/// the screen, and a light theme under dark chrome has to stay legible.
@MainActor
final class PaneSplitView: UIView {
    /// The room between two panes: a hairline with clear ground either
    /// side, so text never touches it.
    static let gap: CGFloat = 9
    /// The frame around the focused pane lies ON the lines beside it: this
    /// far outside the pane's own rectangle, which is the gap's centre.
    private static let frameOutset: CGFloat = 5
    /// What several panes give up of the surface's top and bottom edges so
    /// the frame around an outermost pane has somewhere to be drawn.
    private static let framedInsets = UIEdgeInsets(top: 2, left: 0, bottom: 6, right: 0)

    private weak var controller: TerminalSessionController?
    /// Makes one pane's cell around the emulator view the surface prepared
    /// for it (themed, sized, and adopted from another window if the tab
    /// just moved).
    private let makeCell: (TerminalScreen) -> PaneCellView

    private(set) var cells: [PaneCellView] = []
    private var dividerViews: [PaneDividerView] = []
    private let focusFrame = UIView()
    private var layout: PaneLayout?
    private var activePane: PaneID?
    private var zoomedPane: PaneID?
    private var ink = UIColor.label

    init(
        controller: TerminalSessionController,
        makeCell: @escaping (TerminalScreen) -> PaneCellView
    ) {
        self.controller = controller
        self.makeCell = makeCell
        super.init(frame: .zero)
        focusFrame.isUserInteractionEnabled = false
        focusFrame.isAccessibilityElement = false
        focusFrame.layer.borderWidth = 1
        focusFrame.isHidden = true
        focusFrame.accessibilityIdentifier = "terminalPane.focusFrame"
        addSubview(focusFrame)
        accessibilityIdentifier = "terminalPane.split"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    /// The cell showing `pane`, for the surface's per-emulator updates.
    func cell(for pane: PaneID?) -> PaneCellView? {
        guard let pane else { return nil }
        return cells.first { $0.screen.paneID == pane }
    }

    /// The pane under a point of this view — where a file was dropped. A
    /// pane hidden behind a zoomed one is under nothing.
    func pane(at point: CGPoint) -> PaneID? {
        cells.first { !$0.isHidden && $0.frame.contains(point) }?.screen.paneID
    }

    /// Brings the cells in line with the tab's screens and layout. Cells
    /// are kept by screen — a pane that stays keeps its emulator view, its
    /// scrollback and its selection — and only what changed is made or
    /// dropped.
    func apply(
        layout: PaneLayout?, screens: [TerminalScreen], activePane: PaneID?,
        zoomedPane: PaneID?, theme: TerminalTheme
    ) {
        var arranged: [PaneCellView] = []
        for screen in screens {
            if let cell = cells.first(where: { $0.screen === screen }) {
                arranged.append(cell)
            } else {
                let cell = makeCell(screen)
                insertSubview(cell, belowSubview: focusFrame)
                arranged.append(cell)
            }
        }
        for cell in cells where !arranged.contains(where: { $0 === cell }) {
            cell.removeFromSuperview()
        }
        cells = arranged
        self.layout = layout
        self.activePane = activePane
        self.zoomedPane = zoomedPane
        ink = UIColor(theme.foreground)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A surface not yet given a size has nothing to measure; laying an
        // emulator out at zero would have it report a grid of nothing.
        guard bounds.width >= 1, bounds.height >= 1, let layout else {
            syncDividers([])
            focusFrame.isHidden = true
            return
        }
        let isSplit = cells.count > 1
        let area = isSplit ? bounds.inset(by: Self.framedInsets) : bounds
        let frames = layout.frames(
            in: area, dividerThickness: Self.gap,
            displayScale: traitCollection.displayScale)
        // A zoomed pane takes the whole view. The others are hidden but
        // still laid out where the split has them: their terminals keep the
        // size they will be shown at again, so leaving the zoom redraws
        // nothing and resizes only the pane that was zoomed.
        let zoomed = isSplit ? cell(for: zoomedPane) : nil
        for cell in cells {
            guard let pane = cell.screen.paneID, let frame = frames.panes[pane] else { continue }
            let placed = cell === zoomed ? bounds : frame
            if cell.frame != placed { cell.frame = placed }
            let hidden = zoomed != nil && cell !== zoomed
            if cell.isHidden != hidden { cell.isHidden = hidden }
        }
        guard zoomed == nil else {
            syncDividers([])
            focusFrame.isHidden = true
            return
        }
        syncDividers(frames.dividers)
        if isSplit, let active = cell(for: activePane) {
            focusFrame.frame = active.frame.insetBy(dx: -Self.frameOutset, dy: -Self.frameOutset)
            focusFrame.layer.borderColor = ink.withAlphaComponent(0.6).cgColor
            focusFrame.isHidden = false
            bringSubviewToFront(focusFrame)
        } else {
            focusFrame.isHidden = true
        }
    }

    /// A line's view is kept by the split it divides, so one being dragged
    /// stays under the finger while the layout around it changes.
    private func syncDividers(_ dividers: [PaneLayoutFrames.Divider]) {
        var kept: [PaneDividerView] = []
        for divider in dividers {
            let view = dividerViews.first { $0.splitID == divider.splitID } ?? {
                let view = PaneDividerView()
                view.moved = { [weak self] divider, position in
                    self?.moveDivider(divider, to: position)
                }
                view.nudged = { [weak self] divider, step in
                    self?.nudgeDivider(divider, by: step)
                }
                addSubview(view)
                return view
            }()
            view.show(divider, ink: ink)
            // Over the panes: a line's strip reaches onto the edge of both.
            bringSubviewToFront(view)
            kept.append(view)
        }
        for view in dividerViews where !kept.contains(where: { $0 === view }) {
            view.removeFromSuperview()
        }
        dividerViews = kept
    }

    /// A drag moved a line to `position` along its split's axis, in this
    /// view's coordinates.
    private func moveDivider(_ divider: PaneLayoutFrames.Divider, to position: CGFloat) {
        let ratio = PaneLayout.ratio(
            forDividerAt: position, in: divider.extent, axis: divider.axis,
            dividerThickness: Self.gap)
        controller?.setPaneRatio(ratio, ofSplit: divider.splitID)
    }

    /// VoiceOver's adjust: a twentieth of the split either way.
    private func nudgeDivider(_ divider: PaneLayoutFrames.Divider, by step: Double) {
        guard let split = layout?.split(withID: divider.splitID) else { return }
        controller?.setPaneRatio(split.ratio + step, ofSplit: divider.splitID)
    }
}

/// One pane: its emulator view, held at the pane's frame — or, while the
/// far side dictates the grid, at exactly the frame that grid measures
/// (`TerminalSurfaceView.Coordinator.applyGridPin`), top-leading in the
/// pane.
@MainActor
final class PaneCellView: UIView {
    let screen: TerminalScreen
    let coordinator: TerminalSurfaceView.Coordinator
    let terminalView: TerminalView

    init(
        screen: TerminalScreen, coordinator: TerminalSurfaceView.Coordinator,
        terminalView: TerminalView
    ) {
        self.screen = screen
        self.coordinator = coordinator
        self.terminalView = terminalView
        super.init(frame: .zero)
        accessibilityIdentifier = "terminalPane.cell"
        addSubview(terminalView)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        let trailing = terminalView.trailingAnchor.constraint(equalTo: trailingAnchor)
        let bottom = terminalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailing,
            bottom,
        ])
        coordinator.installGridEdges(trailing: trailing, bottom: bottom)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The pane changed size under a grid that is not its own: fit again.
        coordinator.applyGridPin(synchronously: false)
    }
}

/// The line between a split's two sides, and the strip either side of it a
/// finger can take hold of.
@MainActor
final class PaneDividerView: UIView {
    /// How far past the gap, each side, a drag may start. The strip lies
    /// over the edge of both panes, where a terminal's own gestures would
    /// otherwise take the touch.
    private static let reach: CGFloat = 8

    var moved: ((PaneLayoutFrames.Divider, CGFloat) -> Void)?
    var nudged: ((PaneLayoutFrames.Divider, Double) -> Void)?

    private let line = UIView()
    private var divider: PaneLayoutFrames.Divider?
    var splitID: String? { divider?.splitID }
    /// Where on the strip the finger came down, so the line keeps its place
    /// under the finger instead of jumping to its centre.
    private var grabOffset: CGFloat = 0
    private var grabPosition: CGFloat = 0
    private var isDragging = false

    init() {
        super.init(frame: .zero)
        line.isUserInteractionEnabled = false
        addSubview(line)
        // A press with no delay, not a pan. A pan recognizer begins only
        // once the finger has travelled some way, and reports the travel
        // from THERE: with a real touch a 180 pt drag moved the line 158,
        // by position and by `translation` alike. The strip is the line's
        // alone — nothing else wants its touches — so the drag can start
        // where the finger lands.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(dragged(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        addGestureRecognizer(press)
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = String(localized: "Pane divider")
        accessibilityIdentifier = "terminalPane.divider"
        #if os(visionOS)
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        #else
        addInteraction(UIPointerInteraction(delegate: nil))
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func show(_ divider: PaneLayoutFrames.Divider, ink: UIColor) {
        self.divider = divider
        let sideways = divider.axis == .sideBySide
        let strip = divider.frame.insetBy(
            dx: sideways ? -Self.reach : 0, dy: sideways ? 0 : -Self.reach)
        if frame != strip { frame = strip }
        // One point, in the middle of the gap.
        line.frame = sideways
            ? CGRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
            : CGRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
        line.backgroundColor = ink.withAlphaComponent(0.2)
        accessibilityValue = sideways
            ? String(localized: "Between left and right panes")
            : String(localized: "Between top and bottom panes")
    }

    @objc private func dragged(_ gesture: UILongPressGestureRecognizer) {
        guard let divider, let container = superview else { return }
        let point = gesture.location(in: container)
        let position = divider.axis == .sideBySide ? point.x : point.y
        switch gesture.state {
        case .began:
            let centre = divider.axis == .sideBySide ? divider.frame.midX : divider.frame.midY
            grabOffset = position - centre
            grabPosition = position
            isDragging = false
        case .changed, .ended:
            // A touch that never moved is not a drag: a tap on the line
            // must not re-state the ratio it already has, rounded.
            if abs(position - grabPosition) >= 1 { isDragging = true }
            if isDragging { moved?(divider, position - grabOffset) }
        default:
            break
        }
    }

    override func accessibilityIncrement() {
        if let divider { nudged?(divider, 0.05) }
    }

    override func accessibilityDecrement() {
        if let divider { nudged?(divider, -0.05) }
    }
}
