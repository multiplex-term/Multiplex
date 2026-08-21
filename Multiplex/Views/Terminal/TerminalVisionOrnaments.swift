#if os(visionOS)
import Observation
import SwiftUI
import UIKit

/// The value-only spatial layout contract for a classic visionOS terminal.
/// Keeping this separate from `UIHostingOrnament` lets focused tests pin the
/// visibility and anchor geometry without constructing a compositor scene.
struct TerminalVisionOrnamentPresentation: Equatable {
    enum Bottom: Equatable {
        case hidden
        case terminal(showsHelper: Bool)
        case auxiliary
    }

    var showsTopSourceLabels: Bool
    var bottom: Bottom
    var maximumConsoleWidth: CGFloat

    static func resolve(
        tabCount: Int,
        isAuxiliary: Bool,
        hasUMD: Bool,
        hasHelper: Bool,
        windowWidth: CGFloat
    ) -> Self {
        let bottom: Bottom
        if !hasUMD {
            bottom = .hidden
        } else if isAuxiliary {
            bottom = .auxiliary
        } else {
            bottom = .terminal(showsHelper: hasHelper)
        }
        return Self(
            showsTopSourceLabels: tabCount > 1,
            bottom: bottom,
            maximumConsoleWidth: consoleClamp(windowWidth: windowWidth)
        )
    }

    /// The width the console row (and every slab hung from it) is proposed
    /// at most — the scene less its resize-corner margins.
    static func consoleClamp(windowWidth: CGFloat) -> CGFloat {
        max(1, windowWidth - 24)
    }
}

/// Geometric contract for the scene-bottom console ornament. The console's
/// top is always the exact vertical midpoint of the reported bounds; that is
/// the point `UIHostingOrnament(contentAlignment: .center)` actually honors.
struct TerminalVisionConsoleGeometry: Equatable {
    var size: CGSize
    var helperOrigin: CGPoint?
    var consoleOrigin: CGPoint
    /// The Talkback slab hangs below the console row, `spacing` under it.
    /// It lengthens the lower half — and so, symmetrically, the reported
    /// bounds — while the console's top stays the exact midpoint.
    var talkbackOrigin: CGPoint?

    static func resolve(
        helperSize: CGSize?,
        consoleSize: CGSize,
        talkbackSize: CGSize? = nil,
        helperLeading: Bool,
        spacing: CGFloat
    ) -> Self {
        let helperSize = helperSize.map(Self.normalized)
        let consoleSize = Self.normalized(consoleSize)
        let talkbackSize = talkbackSize.map(Self.normalized)
        let spacing = spacing.isFinite ? max(0, spacing) : 0
        let upperExtent = helperSize.map { $0.height + spacing } ?? 0
        let lowerExtent = consoleSize.height + (talkbackSize.map { spacing + $0.height } ?? 0)
        let halfHeight = max(upperExtent, lowerExtent)
        let width = max(
            helperSize?.width ?? 0,
            consoleSize.width,
            talkbackSize?.width ?? 0
        )
        let helperOrigin = helperSize.map { helperSize in
            CGPoint(
                x: helperLeading ? 0 : (width - helperSize.width) / 2,
                y: halfHeight - spacing - helperSize.height
            )
        }
        let talkbackOrigin = talkbackSize.map { talkbackSize in
            CGPoint(
                x: (width - talkbackSize.width) / 2,
                y: halfHeight + consoleSize.height + spacing
            )
        }
        return Self(
            size: CGSize(width: width, height: halfHeight * 2),
            helperOrigin: helperOrigin,
            consoleOrigin: CGPoint(
                x: (width - consoleSize.width) / 2,
                y: halfHeight
            ),
            talkbackOrigin: talkbackOrigin
        )
    }

    private static func normalized(_ size: CGSize) -> CGSize {
        CGSize(
            width: size.width.isFinite ? max(0, size.width) : 0,
            height: size.height.isFinite ? max(0, size.height) : 0
        )
    }
}

/// Mutable handoff from the native terminal owner to the two hosting
/// ornaments. Controller and view identities are native; SwiftUI observes
/// only this placement snapshot and mounts those identities into space.
@MainActor
@Observable
final class TerminalVisionOrnamentState {
    private(set) var presentation = TerminalVisionOrnamentPresentation(
        showsTopSourceLabels: false,
        bottom: .hidden,
        maximumConsoleWidth: 1
    )
    private(set) var revision = 0
    private(set) var activeTerminalController: TerminalSessionController?
    private(set) var umdController: UIViewController?
    private(set) var helperController: AgentHelperStripViewController?
    /// The open Talkback composer for the active tab, mounted as its own
    /// slab under the console row; nil while the box is closed. Its growth
    /// (a line typed, a chip attached) reaches the ornament through the
    /// window: the composer reports, the window re-renders, `revision`
    /// bumps, and the mount re-asks the composer for its size.
    private(set) var talkbackController: TalkbackComposerViewController?
    /// Active terminal tab's SIDECAR mount. It is independent of the bottom
    /// console presentation: the active route remains a terminal while this
    /// controller hangs from the scene's trailing edge.
    private(set) var sidePanelController: SidePanelViewController?
    /// The strip the side-panel mount is hosted at — twice the window's
    /// width × its height; it follows a window resize, never a drag, so a
    /// drag never changes the ornament's own size.
    private(set) var sidePanelSize: CGSize = .zero
    /// Where the card sits inside the strip, in the strip's coordinates —
    /// reported by the controller on its content cadence (never per drag
    /// tick); under GLASS the system glass platter follows it.
    private(set) var sidePanelCardFrame: CGRect = .zero

    func setSidePanelCardFrame(_ frame: CGRect) {
        guard sidePanelCardFrame != frame else { return }
        sidePanelCardFrame = frame
    }
    /// The helper controller is native UIKit, so its app-wide collapse choice
    /// is not observable by SwiftUI on its own. Mirror it into ornament state:
    /// this value is the animation trigger for the full rail ↔ corner dot
    /// geometry instead of relying on an unrelated revision redraw.
    private(set) var helperCollapsed = false
    /// The width the console row reserves for the mounted UMD. Held here
    /// rather than measured inside the ornament body: the bar re-renders on
    /// its own observations (a mosh contact loss swaps LIVE for the wider
    /// NO LINK lamp) that the window's render pass never sees, and a stale
    /// reservation squeezes the bar the UMD must never compress.
    private(set) var umdContentSize: CGSize = .zero
    /// The applied appearance choice. Ornaments host in their own UIKit
    /// windows, so the scene window's `overrideUserInterfaceStyle` never
    /// reaches this content on its own — without re-applying it at every
    /// mount, a pinned LIGHT leaves the whole bottom bar dark.
    private(set) var interfaceStyle: UIUserInterfaceStyle = .unspecified

    let topHostView: TerminalVisionTabOrnamentHostView
    /// One key-cluster owner per ornament — the latch state and the DEBUG
    /// proof hook stay single-owner across every fitting candidate.
    let keyClusterContext = TerminalKeyClusterContext()

    init(tabStrip: TerminalTabStripView) {
        topHostView = TerminalVisionTabOrnamentHostView(tabStrip: tabStrip)
    }

    func update(
        tabCount: Int,
        isAuxiliary: Bool,
        activeTerminalController: TerminalSessionController?,
        umdController: UIViewController?,
        helperController: AgentHelperStripViewController?,
        talkbackController: TalkbackComposerViewController? = nil,
        sidePanelController: SidePanelViewController? = nil,
        windowWidth: CGFloat,
        windowHeight: CGFloat = 0,
        interfaceStyle: UIUserInterfaceStyle,
        forceRevision: Bool
    ) {
        self.interfaceStyle = interfaceStyle
        let nextHelper = isAuxiliary ? nil : helperController
        let nextTalkback = isAuxiliary ? nil : talkbackController
        // The ornament hosts the whole strip; the card's place inside it is
        // the controller's (and the store's) business, never the ornament's.
        let nextSidePanelSize = sidePanelController == nil
            ? CGSize.zero
            : CGSize(
                width: SidePanelWidth.visionStripWidth(windowWidth: windowWidth),
                height: max(0, windowHeight)
            )
        let nextPresentation = TerminalVisionOrnamentPresentation.resolve(
            tabCount: tabCount,
            isAuxiliary: isAuxiliary,
            hasUMD: umdController != nil,
            hasHelper: nextHelper != nil,
            windowWidth: windowWidth
        )
        let nextHelperCollapsed = nextHelper?.isCollapsed == true
        let changed = presentation != nextPresentation
            || self.activeTerminalController !== activeTerminalController
            || self.umdController !== umdController
            || self.helperController !== nextHelper
            || self.talkbackController !== nextTalkback
            || self.sidePanelController !== sidePanelController
            || sidePanelSize != nextSidePanelSize
            || helperCollapsed != nextHelperCollapsed
        self.activeTerminalController = activeTerminalController
        self.umdController = umdController
        self.helperController = nextHelper
        self.talkbackController = nextTalkback
        self.sidePanelController = sidePanelController
        sidePanelSize = nextSidePanelSize
        helperCollapsed = nextHelperCollapsed
        presentation = nextPresentation
        refreshUMDContentSize()
        guard changed || forceRevision else { return }
        revision &+= 1
        topHostView.refreshFittingSize()
    }

    /// Re-derives the console row's reserved UMD geometry. Called on every
    /// window render and whenever the mounted bar reports its own size change,
    /// so the ornament never frames new status content at the old width.
    func refreshUMDContentSize() {
        let size = (umdController as? UMDBarViewController)?
            .fittingContentSize(for: nil) ?? .zero
        guard umdContentSize != size else { return }
        umdContentSize = size
    }

    func clear() {
        activeTerminalController = nil
        umdController = nil
        helperController = nil
        talkbackController = nil
        sidePanelController = nil
        sidePanelSize = .zero
        sidePanelCardFrame = .zero
        helperCollapsed = false
        umdContentSize = .zero
        presentation = TerminalVisionOrnamentPresentation(
            showsTopSourceLabels: false,
            bottom: .hidden,
            maximumConsoleWidth: 1
        )
        revision &+= 1
        topHostView.refreshFittingSize()
    }
}

/// The sole main-app SwiftUI boundary left by WidgetKit-independent UIKit.
/// visionOS exposes ornaments through SwiftUI's `UIHostingOrnament` even when
/// a UIKit view controller owns the window. Every visible child supplied to
/// these ornaments is a native UIKit view/controller.
@MainActor
final class TerminalVisionOrnamentCoordinator {
    let state: TerminalVisionOrnamentState

    private weak var owner: UIViewController?
    private var installed = false

    init(tabStrip: TerminalTabStripView) {
        state = TerminalVisionOrnamentState(tabStrip: tabStrip)
    }

    func install(on owner: UIViewController) {
        guard !installed || self.owner !== owner else { return }
        remove()
        self.owner = owner

        let top = UIHostingOrnament(
            sceneAnchor: UnitPoint.top,
            contentAlignment: SwiftUI.Alignment.center
        ) {
            TerminalVisionTopOrnament(state: state)
        }
        let bottom = UIHostingOrnament(
            sceneAnchor: UnitPoint.bottom,
            contentAlignment: SwiftUI.Alignment.center
        ) {
            TerminalVisionBottomOrnament(state: state)
        }
        // Centred on the trailing edge: the side-panel strip is as wide as the
        // widest panel and straddles the glass, so the panel can hang outside
        // it or reach in over the terminal — see TerminalVisionSidePanelOrnament.
        let trailing = UIHostingOrnament(
            sceneAnchor: UnitPoint.trailing,
            contentAlignment: SwiftUI.Alignment.center
        ) {
            TerminalVisionSidePanelOrnament(state: state)
        }
        owner.ornaments = [top, bottom, trailing]
        installed = true
    }

    func update(
        tabCount: Int,
        isAuxiliary: Bool,
        activeTerminalController: TerminalSessionController?,
        umdController: UIViewController?,
        helperController: AgentHelperStripViewController?,
        talkbackController: TalkbackComposerViewController? = nil,
        sidePanelController: SidePanelViewController? = nil,
        windowWidth: CGFloat,
        windowHeight: CGFloat = 0,
        interfaceStyle: UIUserInterfaceStyle,
        forceRevision: Bool = false
    ) {
        state.update(
            tabCount: tabCount,
            isAuxiliary: isAuxiliary,
            activeTerminalController: activeTerminalController,
            umdController: umdController,
            helperController: helperController,
            talkbackController: talkbackController,
            sidePanelController: sidePanelController,
            windowWidth: windowWidth,
            windowHeight: windowHeight,
            interfaceStyle: interfaceStyle,
            forceRevision: forceRevision
        )
    }

    func remove() {
        state.clear()
        guard installed else {
            owner = nil
            return
        }
        owner?.ornaments = []
        owner = nil
        installed = false
    }
}

// MARK: - Spatial layout only

private struct TerminalVisionTopOrnament: View {
    @Bindable var state: TerminalVisionOrnamentState

    @ViewBuilder
    var body: some View {
        if state.presentation.showsTopSourceLabels {
            TerminalVisionTabOrnamentMount(
                hostView: state.topHostView,
                revision: state.revision,
                interfaceStyle: state.interfaceStyle
            )
            .fixedSize()
            .modifier(GlassPrototypeSlabGround(cornerRadius: 10))
        }
    }
}

/// ⚠ No SwiftUI animation or transition on this content, on purpose: an
/// animated removal of the slab (↗ TAB, ✕) left MRUIKit's coalescing
/// ornament updater holding the whole scene batch — the window kept
/// showing the old tab for ~6 s until an unrelated update flushed it
/// ("Animation settings for update are incompatible with pending changes",
/// visionOS 27 sim, 2026-08-21). Replacement still re-mounts through `.id`.
///
/// Static on purpose: the ornament hosts ONE fixed strip and everything that
/// moves during a drag moves inside `SidePanelViewController`, in UIKit;
/// under GLASS the platter follows `sidePanelCardFrame`.
private struct TerminalVisionSidePanelOrnament: View {
    @Bindable var state: TerminalVisionOrnamentState

    @ViewBuilder
    var body: some View {
        if let controller = state.sidePanelController {
            let size = state.sidePanelSize
            TerminalVisionControllerMount(
                controller: controller,
                sizing: .fixed(size),
                revision: state.revision,
                interfaceStyle: state.interfaceStyle
            )
            .frame(width: size.width, height: size.height)
            .id(ObjectIdentifier(controller))
            .background(alignment: .topLeading) {
                TerminalVisionSidePanelGlass(state: state)
            }
            .fixedSize()
        }
    }
}

/// PROTOTYPE(GLASS): the card paints its own smoke (UIKit, live); this is the
/// system glass platter under it, the one piece of the slab only SwiftUI can
/// draw. Empty in every other appearance, so nothing observes the card frame.
private struct TerminalVisionSidePanelGlass: View {
    @Bindable var state: TerminalVisionOrnamentState

    @ViewBuilder
    var body: some View {
        if GlassPrototype.enabled && GlassSelectionState.shared.isGlass {
            let frame = state.sidePanelCardFrame
            if !frame.isEmpty {
                Color.clear
                    .frame(width: frame.width, height: frame.height)
                    .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 14))
                    .offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct TerminalVisionBottomOrnament: View {
    @Bindable var state: TerminalVisionOrnamentState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    var body: some View {
        switch state.presentation.bottom {
        case .hidden:
            EmptyView()

        case .auxiliary:
            if let switchboard = state.umdController as? ViewportSwitchboardViewController {
                HStack(spacing: 10) {
                    ForEach(
                        Array(switchboard.slabControllers.enumerated()),
                        id: \.offset
                    ) { _, slab in
                        TerminalVisionControllerMount(
                            controller: slab,
                            sizing: .switchboardSlab,
                            revision: state.revision,
                            interfaceStyle: state.interfaceStyle
                        )
                        .fixedSize()
                        .modifier(GlassPrototypeSlabGround())
                    }
                }
            } else if let umd = state.umdController as? ViewportUMDViewController,
                      umd.stackedDeckAnchorOffset(for: nil) > 0 {
                // Content-sized on purpose: a slab that tracked the window
                // width would permanently cover the system window bar and
                // resize corners below the silhouette.
                TerminalVisionStackedDeckLayout(
                    anchorOffset: umd.stackedDeckAnchorOffset(for: nil)
                ) {
                    TerminalVisionControllerMount(
                        controller: umd,
                        sizing: .auxiliaryUMD,
                        revision: state.revision,
                        interfaceStyle: state.interfaceStyle
                    )
                    .fixedSize()
                    .modifier(GlassPrototypeSlabGround())
                }
            } else if let umd = state.umdController {
                TerminalVisionControllerMount(
                    controller: umd,
                    sizing: .auxiliaryUMD,
                    revision: state.revision,
                    interfaceStyle: state.interfaceStyle
                )
                .fixedSize()
                .modifier(GlassPrototypeSlabGround())
            }

        case .terminal(let showsHelper):
            // Collapsed, the helper is a small dot leaning on the console
            // row's leading edge — the ornament analog of the flat platforms'
            // bottom-left corner. Ornament state mirrors the app-wide choice
            // so every window follows it through its own animation transaction.
            let helperCollapsed = state.helperCollapsed
            // `UIHostingOrnament` centers the root's geometric bounds but
            // does not consume a descendant alignment guide. Make the console
            // top the root's actual midpoint instead: the row then starts at
            // the scene edge whether or not a helper exists above it.
            TerminalVisionConsoleLayout(
                helperLeading: helperCollapsed,
                spacing: 10
            ) {
                if showsHelper, let helper = state.helperController {
                    TerminalVisionControllerMount(
                        controller: helper,
                        sizing: .helper,
                        revision: state.revision,
                        interfaceStyle: state.interfaceStyle
                    )
                    .fixedSize()
                    .modifier(GlassPrototypeSlabGround(
                        cornerRadius: helperCollapsed
                            ? AgentHelperStripViewController.collapsedDotDiameter / 2
                            : 12
                    ))
                    .layoutValue(
                        key: TerminalVisionConsoleRoleKey.self,
                        value: .helper
                    )
                }

                TerminalVisionOrnamentWidthClamp(
                    maxWidth: state.presentation.maximumConsoleWidth
                ) {
                    // Observed, not measured here: the bar's own re-renders
                    // move this width without a window render behind them.
                    TerminalKeyCluster(
                        controller: state.activeTerminalController,
                        centerSize: state.umdContentSize,
                        context: state.keyClusterContext,
                        interfaceStyle: state.interfaceStyle
                    ) {
                        if let umd = state.umdController {
                            TerminalVisionControllerMount(
                                controller: umd,
                                sizing: .terminalUMD,
                                revision: state.revision,
                                interfaceStyle: state.interfaceStyle,
                                onContentSizeChange: { [state] in
                                    // The bar reports mid-layout; take the
                                    // new reservation on the next turn so
                                    // the ornament is never re-entered
                                    // during its own update.
                                    Task { @MainActor in
                                        state.refreshUMDContentSize()
                                    }
                                }
                            )
                            .fixedSize()
                            .modifier(GlassPrototypeSlabGround())
                        }
                    }
                }
                .layoutValue(
                    key: TerminalVisionConsoleRoleKey.self,
                    value: .console
                )

                if let talkback = state.talkbackController {
                    // Content-sized like every slab (never window-width),
                    // hung below the console row: the composer's arithmetic
                    // decides its height at the console clamp's width, and
                    // `revision` re-asks it after every window render.
                    TerminalVisionControllerMount(
                        controller: talkback,
                        sizing: .talkback,
                        revision: state.revision,
                        interfaceStyle: state.interfaceStyle
                    )
                    .fixedSize()
                    .modifier(GlassPrototypeSlabGround(cornerRadius: 22))
                    .layoutValue(
                        key: TerminalVisionConsoleRoleKey.self,
                        value: .talkback
                    )
                }
            }
            // The terminal owner previously wrapped this change in a UIKit
            // animator, but a classic ornament lives in a separate SwiftUI
            // host window: laying out the terminal scene cannot animate it.
            // Drive the spatial host's own transaction from the mirrored
            // collapse value. The native strip still cross-dissolves its
            // content while this folds its slab along the same path.
            .animation(
                reduceMotion
                    ? nil
                    : .spring(response: 0.35, dampingFraction: 0.85),
                value: helperCollapsed
            )
        }
    }
}

struct TerminalVisionStackedDeckGeometry: Equatable {
    var size: CGSize
    var contentOrigin: CGPoint

    static func resolve(contentSize: CGSize, anchorOffset: CGFloat) -> Self {
        let size = CGSize(
            width: contentSize.width.isFinite ? max(0, contentSize.width) : 0,
            height: contentSize.height.isFinite ? max(0, contentSize.height) : 0
        )
        let offset = anchorOffset.isFinite
            ? min(max(0, anchorOffset), size.height) : 0
        // Pad the host by the upper band's height and shift the content down
        // by the same amount: the slab's top edge then lands half a window
        // row above the anchor — exactly where a single-row slab's top sits —
        // and the extra file row extends BELOW the anchor instead of riding
        // up over the pane's last lines of content.
        return Self(
            size: CGSize(width: size.width, height: size.height + offset),
            contentOrigin: CGPoint(x: 0, y: offset)
        )
    }
}

/// Biases Stacked Deck's host bounds so the slab's top edge sits where a
/// single-row slab's top would — half a window row above the anchor — and the
/// extra file row hangs below the anchor. A plain VStack would center the
/// doubled slab on the anchor and push the file row up over the pane's last
/// lines of content.
private struct TerminalVisionStackedDeckLayout: Layout {
    var anchorOffset: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(proposal)
        return TerminalVisionStackedDeckGeometry.resolve(
            contentSize: size,
            anchorOffset: anchorOffset
        ).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let content = subviews.first else { return }
        let size = content.sizeThatFits(proposal)
        let geometry = TerminalVisionStackedDeckGeometry.resolve(
            contentSize: size,
            anchorOffset: anchorOffset
        )
        content.place(
            at: CGPoint(
                x: bounds.midX,
                y: bounds.minY + geometry.contentOrigin.y
            ),
            anchor: .top,
            proposal: ProposedViewSize(width: size.width, height: size.height)
        )
    }
}

private enum TerminalVisionConsoleRole: Equatable {
    case helper
    case console
    case talkback
}

private struct TerminalVisionConsoleRoleKey: LayoutValueKey {
    static let defaultValue = TerminalVisionConsoleRole.console
}

/// Gives the hosting ornament real, symmetric bounds around the console seam.
/// A descendant `.alignmentGuide` does not cross `UIHostingOrnament`'s root
/// boundary, which is why the helper-less row used to remain half in-window.
private struct TerminalVisionConsoleLayout: Layout {
    var helperLeading: Bool
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let console = subview(.console, in: subviews) else { return .zero }
        return TerminalVisionConsoleGeometry.resolve(
            helperSize: subview(.helper, in: subviews)?.sizeThatFits(proposal),
            consoleSize: console.sizeThatFits(proposal),
            talkbackSize: subview(.talkback, in: subviews)?.sizeThatFits(proposal),
            helperLeading: helperLeading,
            spacing: spacing
        ).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let console = subview(.console, in: subviews) else { return }
        let helper = subview(.helper, in: subviews)
        let helperSize = helper?.sizeThatFits(proposal)
        let consoleSize = console.sizeThatFits(proposal)
        let talkback = subview(.talkback, in: subviews)
        let talkbackSize = talkback?.sizeThatFits(proposal)
        let geometry = TerminalVisionConsoleGeometry.resolve(
            helperSize: helperSize,
            consoleSize: consoleSize,
            talkbackSize: talkbackSize,
            helperLeading: helperLeading,
            spacing: spacing
        )
        let origin = CGPoint(
            x: bounds.midX - geometry.size.width / 2,
            y: bounds.midY - geometry.size.height / 2
        )
        console.place(
            at: CGPoint(
                x: origin.x + geometry.consoleOrigin.x,
                y: origin.y + geometry.consoleOrigin.y
            ),
            anchor: .topLeading,
            proposal: ProposedViewSize(
                width: consoleSize.width,
                height: consoleSize.height
            )
        )
        if let helper,
           let helperSize,
           let helperOrigin = geometry.helperOrigin {
            helper.place(
                at: CGPoint(
                    x: origin.x + helperOrigin.x,
                    y: origin.y + helperOrigin.y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: helperSize.width,
                    height: helperSize.height
                )
            )
        }
        if let talkback,
           let talkbackSize,
           let talkbackOrigin = geometry.talkbackOrigin {
            talkback.place(
                at: CGPoint(
                    x: origin.x + talkbackOrigin.x,
                    y: origin.y + talkbackOrigin.y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: talkbackSize.width,
                    height: talkbackSize.height
                )
            )
        }
    }

    private func subview(_ role: TerminalVisionConsoleRole, in subviews: Subviews) -> LayoutSubview? {
        subviews.first { $0[TerminalVisionConsoleRoleKey.self] == role }
    }
}

/// Proposes at most the live scene width to the console row while reporting
/// the row's actual chosen size. Reporting a capped frame makes visionOS clip
/// the key slabs when `ViewThatFits` reaches its fixed-size compact tier.
private struct TerminalVisionOrnamentWidthClamp: Layout {
    var maxWidth: CGFloat

    private func clamped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(
            width: min(proposal.width ?? maxWidth, maxWidth),
            height: proposal.height
        )
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(clamped(proposal))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let content = subviews.first else { return }
        content.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: clamped(proposal)
        )
    }
}

private enum TerminalVisionConsoleCenterAlignment: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
        context[HorizontalAlignment.center]
    }
}

private extension HorizontalAlignment {
    static let terminalVisionConsoleCenter = HorizontalAlignment(
        TerminalVisionConsoleCenterAlignment.self
    )
}

/// Thin ornament adapter around native key slabs. The generic center remains
/// a SwiftUI value only because the native UMD is supplied by the ornament
/// builder; every key, state transition, popover, and action is UIKit.
@MainActor
private struct TerminalKeyClusterGroupRepresentable: UIViewRepresentable {
    var role: TerminalKeyClusterGroupView.Role
    var metric: TerminalKeyClusterMetric
    var context: TerminalKeyClusterContext
    var controller: TerminalSessionController?
    var interfaceStyle: UIUserInterfaceStyle = .unspecified

    func makeUIView(context _: Context) -> TerminalKeyClusterGroupView {
        let view = TerminalKeyClusterGroupView(
            role: role,
            metric: metric,
            context: context
        )
        view.overrideUserInterfaceStyle = interfaceStyle
        applyGlassTrait(to: view)
        return view
    }

    func updateUIView(_ view: TerminalKeyClusterGroupView, context _: Context) {
        view.overrideUserInterfaceStyle = interfaceStyle
        applyGlassTrait(to: view)
        view.update(controller: controller)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: TerminalKeyClusterGroupView,
        context _: Context
    ) -> CGSize? {
        uiView.fittingSize(maximumWidth: proposal.width)
    }
}

@MainActor
struct TerminalKeyCluster<Center: View>: View {
    var controller: TerminalSessionController?
    private let center: Center?
    private let centerSize: CGSize
    /// Supplied by the owner, never `@State`: the struct is rebuilt on every
    /// ornament revision, and a default-expression context would mint (and
    /// register) a throwaway owner each time. One instance per ornament keeps
    /// the CTRL latch and the DEBUG proof hook single-owner, as the shell
    /// layout's own long-lived context does.
    private let context: TerminalKeyClusterContext
    /// See `TerminalVisionOrnamentState.interfaceStyle` — the ornament window
    /// never inherits the scene's appearance override, so every UIKit mount
    /// carries it explicitly.
    private let interfaceStyle: UIUserInterfaceStyle

    init(
        controller: TerminalSessionController?,
        centerSize: CGSize,
        context: TerminalKeyClusterContext? = nil,
        interfaceStyle: UIUserInterfaceStyle = .unspecified,
        @ViewBuilder center: () -> Center
    ) {
        self.controller = controller
        self.centerSize = centerSize
        self.context = context ?? TerminalKeyClusterContext()
        self.interfaceStyle = interfaceStyle
        self.center = center()
    }

    var body: some View {
        if let center {
            // The three fitting candidates may coexist while SwiftUI measures
            // them. A native UMD controller can have only one parent, so each
            // candidate reserves its exact geometry and the real controller
            // mounts once above the selected row. Duplicating the controller
            // here let a discarded candidate steal it during the helper-strip
            // transition, leaving the visible bottom-center control empty.
            ZStack(alignment: Alignment(
                horizontal: .terminalVisionConsoleCenter,
                vertical: .center
            )) {
                ViewThatFits(in: .horizontal) {
                    consoleRowPlaceholder(metric: .regular)
                    consoleRowPlaceholder(metric: .compact)
                    consoleRowPlaceholder(metric: .compact)
                        .fixedSize(horizontal: true, vertical: false)
                }
                center
                    .frame(
                        width: normalizedCenterSize.width,
                        height: normalizedCenterSize.height
                    )
                    .alignmentGuide(.terminalVisionConsoleCenter) { dimensions in
                        dimensions.width / 2
                    }
            }
        } else {
            TerminalKeyClusterGroupRepresentable(
                role: .standalone,
                metric: .regular,
                context: context,
                controller: controller,
                interfaceStyle: interfaceStyle
            )
            .modifier(GlassPrototypeSlabGround())
        }
    }

    private var normalizedCenterSize: CGSize {
        CGSize(
            width: centerSize.width.isFinite ? max(0, centerSize.width) : 0,
            height: centerSize.height.isFinite ? max(0, centerSize.height) : 0
        )
    }

    private func consoleRowPlaceholder(
        metric: TerminalKeyClusterMetric
    ) -> some View {
        HStack(spacing: 10) {
            TerminalKeyClusterGroupRepresentable(
                role: .leading,
                metric: metric,
                context: context,
                controller: controller,
                interfaceStyle: interfaceStyle
            )
            .modifier(GlassPrototypeSlabGround())
            Color.clear
                .frame(
                    width: normalizedCenterSize.width,
                    height: normalizedCenterSize.height
                )
                .alignmentGuide(.terminalVisionConsoleCenter) { dimensions in
                    dimensions.width / 2
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            TerminalKeyClusterGroupRepresentable(
                role: .trailing,
                metric: metric,
                context: context,
                controller: controller,
                interfaceStyle: interfaceStyle
            )
            .modifier(GlassPrototypeSlabGround())
        }
    }
}

extension TerminalKeyCluster where Center == EmptyView {
    init(
        controller: TerminalSessionController?,
        context: TerminalKeyClusterContext? = nil,
        interfaceStyle: UIUserInterfaceStyle = .unspecified
    ) {
        self.controller = controller
        self.context = context ?? TerminalKeyClusterContext()
        self.interfaceStyle = interfaceStyle
        centerSize = .zero
        center = nil
    }
}

/// PROTOTYPE(GLASS): each ornament bar is its own smoked-glass slab — UMD
/// console, key clusters, the agent helper strip, and the tab strip — never
/// one platter behind the whole ornament (user feedback: an area-wide glass
/// background read as noise). Ornaments get no platter of their own; the
/// app supplies one per bar.
private struct GlassPrototypeSlabGround: ViewModifier {
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        if GlassPrototype.enabled && GlassSelectionState.shared.isGlass {
            content
                .background(
                    Color(uiColor: GlassPrototype.smokeMaterial),
                    in: RoundedRectangle(cornerRadius: cornerRadius)
                )
                .glassBackgroundEffect(
                    in: RoundedRectangle(cornerRadius: cornerRadius)
                )
        } else {
            content
        }
    }
}

/// PROTOTYPE(GLASS): custom traits do not cross `UIHostingOrnament` — the
/// mounted native chrome must be handed the glass trait explicitly, or its
/// materials resolve to the opaque baseline (the "dark theme" bars).
/// View-level on purpose, like the interface-style handoff beside it:
/// SwiftUI clobbers controller-level overrides.
@MainActor
private func applyGlassTrait(to view: UIView) {
    view.traitOverrides[GlassAppearanceTrait.self] =
        GlassPrototype.enabled && GlassSelectionState.shared.isGlass
}

// MARK: - UIKit mounts

@MainActor
final class TerminalVisionTabOrnamentHostView: UIView {
    let tabStrip: TerminalTabStripView

    init(tabStrip: TerminalTabStripView) {
        self.tabStrip = tabStrip
        super.init(frame: .zero)
        // PROTOTYPE(GLASS): the ornament's glass ground provides the slab.
        backgroundColor =
            GlassPrototype.enabled ? GlassPrototype.clearedChassis : UIKitChassis.chassis
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        accessibilityIdentifier = "terminal.vision.topOrnament"
        tabStrip.installDropTarget(on: self)
        adoptTabStripIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var intrinsicContentSize: CGSize { fittingSize() }

    override func layoutSubviews() {
        super.layoutSubviews()
        adoptTabStripIfNeeded()
        let content = tabStripSize()
        tabStrip.frame = CGRect(
            x: 12,
            y: 8,
            width: content.width,
            height: content.height
        )
    }

    func fittingSize() -> CGSize {
        let content = tabStripSize()
        return CGSize(width: ceil(content.width + 24), height: ceil(content.height + 16))
    }

    func refreshFittingSize() {
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func adoptTabStripIfNeeded() {
        guard tabStrip.superview !== self else { return }
        tabStrip.removeFromSuperview()
        addSubview(tabStrip)
    }

    private func tabStripSize() -> CGSize {
        // `TerminalTabStripView` owns an arithmetic fitting contract. Do not
        // feed its live, edge-pinned stack back through Auto Layout while a
        // pinch action may be updating the selected cell in place.
        let measured = tabStrip.fittingContentSize()
        return CGSize(width: max(1, ceil(measured.width)), height: 30)
    }
}

private struct TerminalVisionTabOrnamentMount: UIViewRepresentable {
    let hostView: TerminalVisionTabOrnamentHostView
    let revision: Int
    let interfaceStyle: UIUserInterfaceStyle

    func makeUIView(context: Context) -> TerminalVisionTabOrnamentHostView {
        hostView.removeFromSuperview()
        hostView.overrideUserInterfaceStyle = interfaceStyle
        applyGlassTrait(to: hostView)
        return hostView
    }

    func updateUIView(
        _ view: TerminalVisionTabOrnamentHostView,
        context: Context
    ) {
        _ = revision
        view.overrideUserInterfaceStyle = interfaceStyle
        applyGlassTrait(to: view)
        view.refreshFittingSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: TerminalVisionTabOrnamentHostView,
        context: Context
    ) -> CGSize? {
        uiView.fittingSize()
    }
}

private enum TerminalVisionControllerSizing: Equatable {
    case helper
    case terminalUMD
    case auxiliaryUMD
    case switchboardSlab
    /// Exact SIDECAR geometry. A trailing ornament is re-laid out only when
    /// the grip commits a rung; it never streams continuous proposals.
    case fixed(CGSize)
    /// The Talkback slab: the composer's own arithmetic at the width the
    /// window handed it.
    case talkback
}

private struct TerminalVisionControllerMount: UIViewControllerRepresentable {
    let controller: UIViewController
    let sizing: TerminalVisionControllerSizing
    let revision: Int
    var interfaceStyle: UIUserInterfaceStyle = .unspecified
    var onContentSizeChange: (() -> Void)?

    func makeUIViewController(context: Context) -> TerminalVisionControllerHost {
        let host = TerminalVisionControllerHost()
        host.onContentSizeChange = onContentSizeChange
        host.update(content: controller, sizing: sizing)
        host.apply(interfaceStyle: interfaceStyle)
        applyGlassTrait(to: host.view)
        return host
    }

    func updateUIViewController(
        _ host: TerminalVisionControllerHost,
        context: Context
    ) {
        _ = revision
        host.apply(interfaceStyle: interfaceStyle)
        applyGlassTrait(to: host.view)
        host.onContentSizeChange = onContentSizeChange
        host.update(content: controller, sizing: sizing)
    }

    static func dismantleUIViewController(
        _ host: TerminalVisionControllerHost,
        coordinator: Void
    ) {
        host.onContentSizeChange = nil
        host.update(content: nil, sizing: .terminalUMD)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiViewController host: TerminalVisionControllerHost,
        context: Context
    ) -> CGSize? {
        host.fittingSize(proposedWidth: proposal.width)
    }
}

@MainActor
private final class TerminalVisionControllerHost: UIViewController {
    /// The mounted child is the only witness to its own content changes; the
    /// ornament reserves its geometry and has to hear about them.
    var onContentSizeChange: (() -> Void)?

    private var content: UIViewController?
    private var sizing = TerminalVisionControllerSizing.terminalUMD

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        self.view = view
    }

    /// Both levels on purpose. SwiftUI re-asserts the traits it vends to an
    /// embedded controller, which can leave a controller-level override
    /// unapplied to the mounted subtree — the view-level write is the one the
    /// content reliably inherits (the key-cluster mounts flip through exactly
    /// this mechanism). The controller-level write stays because
    /// `inheritedInterfaceStyleOverride` walks the controller chain for
    /// popovers presented from this content.
    func apply(interfaceStyle: UIUserInterfaceStyle) {
        overrideUserInterfaceStyle = interfaceStyle
        viewIfLoaded?.overrideUserInterfaceStyle = interfaceStyle
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        content?.view.frame = view.bounds
    }

    override func preferredContentSizeDidChange(
        forChildContentContainer container: any UIContentContainer
    ) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        let size = fittingSize(proposedWidth: nil)
        if preferredContentSize != size { preferredContentSize = size }
        parent?.preferredContentSizeDidChange(forChildContentContainer: self)
        onContentSizeChange?()
    }

    func update(
        content replacement: UIViewController?,
        sizing: TerminalVisionControllerSizing
    ) {
        self.sizing = sizing
        guard content !== replacement else {
            refreshPreferredSize()
            return
        }
        if let content, content.parent === self {
            content.willMove(toParent: nil)
            content.view.removeFromSuperview()
            content.removeFromParent()
        }
        content = replacement
        guard let replacement else {
            refreshPreferredSize()
            return
        }
        if replacement.parent != nil {
            replacement.willMove(toParent: nil)
            replacement.view.removeFromSuperview()
            replacement.removeFromParent()
        }
        addChild(replacement)
        view.addSubview(replacement.view)
        replacement.view.frame = view.bounds
        replacement.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        replacement.didMove(toParent: self)
        refreshPreferredSize()
    }

    func fittingSize(proposedWidth: CGFloat?) -> CGSize {
        guard let content else { return .zero }
        switch sizing {
        case .helper:
            if let helper = content as? AgentHelperStripViewController {
                return helper.fittingContentSize(for: proposedWidth)
            }
        case .terminalUMD:
            if let umd = content as? UMDBarViewController {
                // A regular UMD keeps its intrinsic width; the surrounding
                // key-cluster layout decides which metric tier fits.
                return umd.fittingContentSize(for: nil)
            }
        case .auxiliaryUMD:
            if let umd = content as? ViewportUMDViewController {
                return umd.fittingContentSize(for: proposedWidth)
            }
        case .switchboardSlab:
            if let slab = content as? ViewportSwitchboardSlabViewController {
                return slab.fittingContentSize(for: proposedWidth)
            }
        case .fixed(let size):
            return size
        case .talkback:
            if let composer = content as? TalkbackComposerViewController {
                return composer.fittingContentSize()
            }
        }
        content.loadViewIfNeeded()
        return content.view.systemLayoutSizeFitting(
            CGSize(
                width: proposedWidth ?? UIView.layoutFittingCompressedSize.width,
                height: UIView.layoutFittingCompressedSize.height
            ),
            withHorizontalFittingPriority: proposedWidth == nil
                ? .fittingSizeLevel : .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }

    private func refreshPreferredSize() {
        guard isViewLoaded else { return }
        let size = fittingSize(proposedWidth: nil)
        if preferredContentSize != size { preferredContentSize = size }
        view.invalidateIntrinsicContentSize()
        view.setNeedsLayout()
    }
}
#endif
