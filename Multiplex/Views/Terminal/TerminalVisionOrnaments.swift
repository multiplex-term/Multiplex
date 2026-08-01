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

    var bottomCenterGuide: CGFloat {
        switch bottom {
        case .terminal(showsHelper: true): 40
        case .terminal, .auxiliary, .hidden: 24
        }
    }

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
            maximumConsoleWidth: max(1, windowWidth - 24)
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
    /// The width the console row reserves for the mounted UMD. Held here
    /// rather than measured inside the ornament body: the bar re-renders on
    /// its own observations (a mosh contact loss swaps LIVE for the wider
    /// NO LINK lamp) that the window's render pass never sees, and a stale
    /// reservation squeezes the bar the UMD must never compress.
    private(set) var umdContentSize: CGSize = .zero

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
        windowWidth: CGFloat,
        forceRevision: Bool
    ) {
        let nextHelper = isAuxiliary ? nil : helperController
        let nextPresentation = TerminalVisionOrnamentPresentation.resolve(
            tabCount: tabCount,
            isAuxiliary: isAuxiliary,
            hasUMD: umdController != nil,
            hasHelper: nextHelper != nil,
            windowWidth: windowWidth
        )
        let changed = presentation != nextPresentation
            || self.activeTerminalController !== activeTerminalController
            || self.umdController !== umdController
            || self.helperController !== nextHelper
        self.activeTerminalController = activeTerminalController
        self.umdController = umdController
        self.helperController = nextHelper
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
                .modifier(GlassPrototypeOrnamentGround())
        }
        let bottom = UIHostingOrnament(
            sceneAnchor: UnitPoint.bottom,
            contentAlignment: SwiftUI.Alignment.center
        ) {
            TerminalVisionBottomOrnament(state: state)
                .modifier(GlassPrototypeOrnamentGround())
        }
        owner.ornaments = [top, bottom]
        installed = true
    }

    func update(
        tabCount: Int,
        isAuxiliary: Bool,
        activeTerminalController: TerminalSessionController?,
        umdController: UIViewController?,
        helperController: AgentHelperStripViewController?,
        windowWidth: CGFloat,
        forceRevision: Bool = false
    ) {
        state.update(
            tabCount: tabCount,
            isAuxiliary: isAuxiliary,
            activeTerminalController: activeTerminalController,
            umdController: umdController,
            helperController: helperController,
            windowWidth: windowWidth,
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
                revision: state.revision
            )
            .fixedSize()
        }
    }
}

private struct TerminalVisionBottomOrnament: View {
    @Bindable var state: TerminalVisionOrnamentState

    @ViewBuilder
    var body: some View {
        switch state.presentation.bottom {
        case .hidden:
            EmptyView()

        case .auxiliary:
            if let umd = state.umdController {
                TerminalVisionControllerMount(
                    controller: umd,
                    sizing: .auxiliaryUMD,
                    revision: state.revision
                )
                .fixedSize()
                .alignmentGuide(VerticalAlignment.center) { _ in
                    state.presentation.bottomCenterGuide
                }
            }

        case .terminal(let showsHelper):
            VStack(spacing: 10) {
                if showsHelper, let helper = state.helperController {
                    TerminalVisionControllerMount(
                        controller: helper,
                        sizing: .helper,
                        revision: state.revision
                    )
                    .fixedSize()
                }

                TerminalVisionOrnamentWidthClamp(
                    maxWidth: state.presentation.maximumConsoleWidth
                ) {
                    // Observed, not measured here: the bar's own re-renders
                    // move this width without a window render behind them.
                    TerminalKeyCluster(
                        controller: state.activeTerminalController,
                        centerSize: state.umdContentSize,
                        context: state.keyClusterContext
                    ) {
                        if let umd = state.umdController {
                            TerminalVisionControllerMount(
                                controller: umd,
                                sizing: .terminalUMD,
                                revision: state.revision,
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
                        }
                    }
                }
            }
            .alignmentGuide(VerticalAlignment.center) { _ in
                state.presentation.bottomCenterGuide
            }
        }
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

    func makeUIView(context _: Context) -> TerminalKeyClusterGroupView {
        TerminalKeyClusterGroupView(role: role, metric: metric, context: context)
    }

    func updateUIView(_ view: TerminalKeyClusterGroupView, context _: Context) {
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

    init(
        controller: TerminalSessionController?,
        centerSize: CGSize,
        context: TerminalKeyClusterContext? = nil,
        @ViewBuilder center: () -> Center
    ) {
        self.controller = controller
        self.centerSize = centerSize
        self.context = context ?? TerminalKeyClusterContext()
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
                controller: controller
            )
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
                controller: controller
            )
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
                controller: controller
            )
        }
    }
}

extension TerminalKeyCluster where Center == EmptyView {
    init(
        controller: TerminalSessionController?,
        context: TerminalKeyClusterContext? = nil
    ) {
        self.controller = controller
        self.context = context ?? TerminalKeyClusterContext()
        centerSize = .zero
        center = nil
    }
}

/// PROTOTYPE(GLASS): ornament chrome sits on real system glass carrying the
/// smoke tint — matching the window ground — instead of floating opaque
/// slabs (ornaments get no platter of their own; the app must supply one).
private struct GlassPrototypeOrnamentGround: ViewModifier {
    func body(content: Content) -> some View {
        if GlassPrototype.active {
            content
                .background(Color(uiColor: GlassPrototype.smokeTint))
                .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 16))
        } else {
            content
        }
    }
}

// MARK: - UIKit mounts

@MainActor
final class TerminalVisionTabOrnamentHostView: UIView {
    let tabStrip: TerminalTabStripView

    init(tabStrip: TerminalTabStripView) {
        self.tabStrip = tabStrip
        super.init(frame: .zero)
        // PROTOTYPE(GLASS): the ornament's glass ground provides the slab.
        backgroundColor = GlassPrototype.active ? .clear : UIKitChassis.chassis
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        accessibilityIdentifier = "terminal.vision.topOrnament"
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

    func makeUIView(context: Context) -> TerminalVisionTabOrnamentHostView {
        hostView.removeFromSuperview()
        return hostView
    }

    func updateUIView(
        _ view: TerminalVisionTabOrnamentHostView,
        context: Context
    ) {
        _ = revision
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
}

private struct TerminalVisionControllerMount: UIViewControllerRepresentable {
    let controller: UIViewController
    let sizing: TerminalVisionControllerSizing
    let revision: Int
    var onContentSizeChange: (() -> Void)?

    func makeUIViewController(context: Context) -> TerminalVisionControllerHost {
        let host = TerminalVisionControllerHost()
        host.onContentSizeChange = onContentSizeChange
        host.update(content: controller, sizing: sizing)
        return host
    }

    func updateUIViewController(
        _ host: TerminalVisionControllerHost,
        context: Context
    ) {
        _ = revision
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
