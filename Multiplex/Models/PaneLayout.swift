import CoreGraphics

/// One pane of a tab that draws its backend's panes itself, named by the
/// backend's own id for it: a Rex block id today; a tmux `%7` or a herdr
/// pane id for a backend that hands its panes out one stream each.
struct PaneID: Hashable, Sendable, CustomStringConvertible {
    var rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

/// How a tab's panes divide its space: a binary tree of splits with a pane
/// at every leaf.
///
/// This is the app's own shape, not any backend's. Rex's layout is this
/// tree already. A backend whose splits hold more than two children (a tmux
/// row of three panes) nests them — `a | (b | c)` — and states each ratio
/// from its cell counts; nothing here assumes the ratios came from a
/// person.
///
/// Pure: the geometry below turns a tree and a rectangle into frames, and a
/// drag back into a ratio. Who may change a ratio, and how, is the
/// transport's business (`PaneCommand`).
indirect enum PaneLayout: Equatable, Sendable {
    case pane(PaneID)
    case split(Split)

    /// Which way a split divides its space. Named for what is on screen:
    /// the backends disagree about which of these is "horizontal" (Rex and
    /// tmux say it of panes side by side; herdr of panes stacked).
    enum Axis: Equatable, Sendable {
        /// `before` on the left, `after` on the right.
        case sideBySide
        /// `before` above `after`.
        case stacked
    }

    struct Split: Equatable, Sendable {
        /// The backend's name for this split; the same split keeps it from
        /// one layout to the next, which is what lets a drag in progress
        /// survive a layout that arrives meanwhile.
        var id: String
        var axis: Axis
        /// The fraction of the split's space `before` gets.
        var ratio: Double
        var before: PaneLayout
        var after: PaneLayout
    }

    /// A ratio is kept this far from either end, whatever a backend or a
    /// drag says: a pane of no width cannot be dragged back open.
    static let ratioBounds: ClosedRange<Double> = 0.05...0.95

    /// Every pane, in reading order: `before` ahead of `after`.
    var panes: [PaneID] {
        switch self {
        case .pane(let id): [id]
        case .split(let split): split.before.panes + split.after.panes
        }
    }

    func contains(_ pane: PaneID) -> Bool {
        switch self {
        case .pane(let id): id == pane
        case .split(let split): split.before.contains(pane) || split.after.contains(pane)
        }
    }

    var firstPane: PaneID {
        switch self {
        case .pane(let id): id
        case .split(let split): split.before.firstPane
        }
    }

    func split(withID id: String) -> Split? {
        guard case .split(let split) = self else { return nil }
        if split.id == id { return split }
        return split.before.split(withID: id) ?? split.after.split(withID: id)
    }

    /// This layout with one split's ratio replaced; unchanged when no split
    /// has that id.
    func settingRatio(_ ratio: Double, ofSplit id: String) -> PaneLayout {
        guard case .split(var split) = self else { return self }
        if split.id == id {
            split.ratio = min(max(ratio, Self.ratioBounds.lowerBound), Self.ratioBounds.upperBound)
        } else {
            split.before = split.before.settingRatio(ratio, ofSplit: id)
            split.after = split.after.settingRatio(ratio, ofSplit: id)
        }
        return .split(split)
    }

    /// The pane focus goes to when `pane` closes: its nearest neighbour in
    /// the tree, the way a closed split hands its space to its sibling. nil
    /// when `pane` is the only one, or is not in the layout.
    func neighbor(ofClosing pane: PaneID) -> PaneID? {
        guard case .split(let split) = self else { return nil }
        if split.before == .pane(pane) { return split.after.firstPane }
        if split.after == .pane(pane) { return split.before.panes.last }
        return split.before.neighbor(ofClosing: pane) ?? split.after.neighbor(ofClosing: pane)
    }
}

// MARK: - Geometry

/// Where a layout's panes and the lines between them sit in a rectangle.
struct PaneLayoutFrames: Equatable {
    /// The line between a split's two sides.
    struct Divider: Equatable {
        var splitID: String
        var axis: PaneLayout.Axis
        /// The line as drawn.
        var frame: CGRect
        /// The whole of the split it divides: what a drag's position is a
        /// fraction of.
        var extent: CGRect
    }

    var panes: [PaneID: CGRect] = [:]
    var dividers: [Divider] = []
}

extension PaneLayout {
    /// The narrowest a drag may leave a pane, along the split's axis. A
    /// terminal a few cells wide is not one anybody can read, and its
    /// program is told that size.
    static let minimumPaneLength: CGFloat = 72

    /// Lays the tree out in `bounds`, a divider `dividerThickness` wide
    /// between the two sides of every split. Edges land on physical pixels:
    /// a pane's frame is what its emulator measures its grid from, and a
    /// fractional edge blurs the line drawn beside it.
    func frames(
        in bounds: CGRect, dividerThickness: CGFloat, displayScale: CGFloat
    ) -> PaneLayoutFrames {
        var frames = PaneLayoutFrames()
        place(
            in: bounds, thickness: dividerThickness,
            scale: max(displayScale, 1), into: &frames)
        return frames
    }

    private func place(
        in bounds: CGRect, thickness: CGFloat, scale: CGFloat,
        into frames: inout PaneLayoutFrames
    ) {
        switch self {
        case .pane(let id):
            frames.panes[id] = bounds
        case .split(let split):
            let length = split.axis == .sideBySide ? bounds.width : bounds.height
            let usable = max(0, length - thickness)
            let before = ((usable * CGFloat(split.ratio)) * scale).rounded() / scale
            let first: CGRect
            let line: CGRect
            let second: CGRect
            switch split.axis {
            case .sideBySide:
                first = CGRect(
                    x: bounds.minX, y: bounds.minY, width: before, height: bounds.height)
                line = CGRect(
                    x: first.maxX, y: bounds.minY, width: min(thickness, length),
                    height: bounds.height)
                second = CGRect(
                    x: line.maxX, y: bounds.minY, width: max(0, bounds.maxX - line.maxX),
                    height: bounds.height)
            case .stacked:
                first = CGRect(
                    x: bounds.minX, y: bounds.minY, width: bounds.width, height: before)
                line = CGRect(
                    x: bounds.minX, y: first.maxY, width: bounds.width,
                    height: min(thickness, length))
                second = CGRect(
                    x: bounds.minX, y: line.maxY, width: bounds.width,
                    height: max(0, bounds.maxY - line.maxY))
            }
            split.before.place(in: first, thickness: thickness, scale: scale, into: &frames)
            frames.dividers.append(PaneLayoutFrames.Divider(
                splitID: split.id, axis: split.axis, frame: line, extent: bounds))
            split.after.place(in: second, thickness: thickness, scale: scale, into: &frames)
        }
    }

    /// The ratio that puts a divider's centre at `position` along its
    /// split's axis. Both sides keep `minimumPaneLength` while the split is
    /// large enough to give it to them, and `ratioBounds` always.
    static func ratio(
        forDividerAt position: CGFloat, in extent: CGRect, axis: Axis,
        dividerThickness: CGFloat
    ) -> Double {
        let start = axis == .sideBySide ? extent.minX : extent.minY
        let length = axis == .sideBySide ? extent.width : extent.height
        let usable = length - dividerThickness
        guard usable > 0 else { return 0.5 }
        var before = position - start - dividerThickness / 2
        if usable >= minimumPaneLength * 2 {
            before = min(max(before, minimumPaneLength), usable - minimumPaneLength)
        }
        let ratio = Double(before / usable)
        return min(max(ratio, ratioBounds.lowerBound), ratioBounds.upperBound)
    }
}

// MARK: - What a transport says, and is asked

/// How a paned transport says its tab's panes are arranged.
struct PaneArrangement: Equatable, Sendable {
    var layout: PaneLayout
    /// Where the tab's focus should go, when the backend has a reason to
    /// move it: the pane an attach lands on, a pane this tab just made, the
    /// one that takes over from a pane that closed. nil leaves the tab's
    /// focus where the person put it.
    var focus: PaneID?
}

/// What a tab can ask of a transport that draws its panes natively. The
/// transport answers by changing the backend; the tab hears the result as
/// the next `PaneArrangement`, like a change made anywhere else.
enum PaneCommand: Equatable, Sendable {
    /// A new pane beside `pane`: to its right, or below it.
    case split(PaneID, PaneLayout.Axis)
    /// End the pane and whatever runs in it.
    case close(PaneID)
    /// Move the line between a split's two sides.
    case setRatio(Double, splitID: String)
    /// The person is on this pane now. What a backend makes of that is its
    /// own: one with a shared focus moves it, one without only remembers.
    case focus(PaneID)
    /// Another window of the session — a tab draws one at a time — holding
    /// one new pane that starts where `from`'s program is. The tab moves to
    /// it: the next arrangement is the new window's.
    case newWindow(from: PaneID)
}

/// The rows of a native-pane tab's shortcut panel — what `TmuxShortcut`
/// and `HerdrShortcut` are for a tab whose multiplexer draws its own panes,
/// minus the key bindings: these act on the pane that has the tab's focus,
/// through `PaneCommand` — except the zoom, which no backend is asked for.
enum PaneShortcut: String, CaseIterable, Identifiable, Sendable {
    case splitRight
    case splitDown
    case zoomPane
    case closePane
    case newWindow

    var id: Self { self }

    /// The row's name where a backend has no word of its own for it. A
    /// backend that does (Rex calls a window a tab) names the row itself
    /// (`ShortcutPanelItem.init(_:title:reference:)`).
    var title: String {
        switch self {
        case .splitRight: String(localized: "Split Right")
        case .splitDown: String(localized: "Split Down")
        case .zoomPane: String(localized: "Toggle Pane Zoom")
        case .closePane: String(localized: "Close Pane")
        case .newWindow: String(localized: "New Window")
        }
    }

    /// Closing ends a program, so the panel asks twice — the confirmed
    /// closes' rule on every backend.
    var requiresDoubleActivation: Bool { self == .closePane }

    var bindingLabel: String { requiresDoubleActivation ? "2×" : "" }

    /// What the row asks the backend to do with `pane`. nil for the zoom:
    /// drawing one pane over the others is the tab's own doing
    /// (`TerminalSessionController.togglePaneZoom`).
    func command(on pane: PaneID) -> PaneCommand? {
        switch self {
        case .splitRight: .split(pane, .sideBySide)
        case .splitDown: .split(pane, .stacked)
        case .zoomPane: nil
        case .closePane: .close(pane)
        case .newWindow: .newWindow(from: pane)
        }
    }
}
