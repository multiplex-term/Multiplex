import SwiftTerm
import UIKit
#if DEBUG
import os
#endif

/// The real terminal pane surface. UIKit callers can construct and update it
/// directly. It owns the adopted `TerminalView`'s delegate, focus gesture,
/// platform chrome, constraints, keyboard avoidance, and visionOS link
/// overlay.
@MainActor
final class TerminalSurfaceView: UIView {
    struct Configuration {
        var fontSize: CGFloat
        var theme: TerminalTheme
        var bottomChromeHeight: CGFloat = 0
        var contentSafeArea: UIEdgeInsets = .zero
        var railOwnsBottomSafeArea = false
        var isActive = true
        /// Which multiplexer owns the rail's shortcut key (TMUX/HRDR); nil
        /// drops the key — plain shells and auxiliary panes have no panel.
        var shortcutBackend: Host.SessionBackend?
    }

    private static let focusTapName = "multiplex.focus-tap"
    // Keep a compact gutter around the terminal grid, but let tmux's status
    // line meet the helper/key rail directly—any bottom inset reads as an
    // accidental black seam between the two surfaces.
    private static let terminalInsets = UIEdgeInsets(
        top: 4,
        left: 6,
        bottom: 0,
        right: 6
    )

    let controller: TerminalSessionController
    private let coordinator: Coordinator
    private var configuration: Configuration

    init(
        controller: TerminalSessionController,
        configuration: Configuration
    ) {
        self.controller = controller
        self.configuration = configuration
        coordinator = Coordinator(controller: controller)
        super.init(frame: .zero)
        // PROTOTYPE(GLASS): THIS wrapper carries the glass pane (theme
        // background at `screenAlpha`) — it spans the whole silhouette, so
        // the tint fills the compact gutter to the window border instead of
        // leaving a bare-smoke band around the inset grid (user report
        // 2026-08-02: "different border"). The grid's own layer goes clear.
        backgroundColor = GlassPrototype.terminalGround(
            themeBackground: UIColor(configuration.theme.background)
        )
        isOpaque = !GlassPrototype.enabled
        installTerminal()
        // PROTOTYPE(GLASS): a live GLASS⇄DARK switch re-applies the theme so
        // the fork's model ground follows the selection, not just the layer.
        registerForTraitChanges(
            [GlassAppearanceTrait.self]
        ) { (surface: TerminalSurfaceView, _: UITraitCollection) in
            guard let view = surface.coordinator.terminalView,
                  view.isDescendant(of: surface) else { return }
            surface.apply(surface.configuration.theme, to: view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func installTerminal() {
        let view: TerminalView
        if let existing = controller.terminalView {
            // This tab moved here from another window (merge/split): adopt
            // the live view so buffer, scrollback, and connection survive.
            // removeFromSuperview also drops constraints tied to the old
            // container before we pin it to the new one.
            existing.removeFromSuperview()
            view = existing
        } else {
            view = TerminalView(
                frame: .zero,
                font: .monospacedSystemFont(
                    ofSize: configuration.fontSize,
                    weight: .regular
                )
            )
            view.changeScrollback(5000)
            // Use the standard keyboard so the user's selected language and
            // multistage IMEs remain available instead of forcing ASCII input.
            view.keyboardType = .default
            #if os(visionOS)
            // SwiftTerm still builds its stock accessory here even though
            // the floating visionOS keyboard never shows one — and that
            // invisible accessory's controlModifier shadows the view-level
            // latch the ornament key cluster sets (`terminalAccessory?.
            // controlModifier ?? controlModifier`). Drop it.
            view.inputAccessoryView = nil
            #else
            // Never attach Multiplex chrome as `inputAccessoryView` on iPad.
            // TextInputUI rehosts custom accessories while a Stage Manager
            // window moves, reactivating a floating keyboard every frame.
            // The UIKit container below renders the same TALLY controls as a
            // normal sibling view instead.
            view.inputAccessoryView = nil
            #endif
        }
        view.renderUpdatesEnabled = configuration.isActive
        apply(configuration.theme, to: view)
        if view.font.pointSize != configuration.fontSize {
            view.font = .monospacedSystemFont(
                ofSize: configuration.fontSize,
                weight: .regular
            )
        }
        view.terminalDelegate = coordinator
        coordinator.terminalView = view

        // Tapping the terminal claims app-wide keyboard focus (and re-summons
        // a dismissed keyboard) — without cancelling SwiftTerm's own
        // selection/scroll gestures. An adopted view still carries the tap
        // wired to its previous window's coordinator — replace, don't stack.
        view.gestureRecognizers?
            .filter { $0.name == Self.focusTapName }
            .forEach(view.removeGestureRecognizer)
        let tap = UITapGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.reclaimFocus(_:))
        )
        tap.name = Self.focusTapName
        tap.cancelsTouchesInView = false
        tap.delegate = coordinator
        view.addGestureRecognizer(tap)

        // On iPad, the app-owned rail is a normal sibling below the terminal.
        // Moving its bottom constraint above a genuinely docked keyboard
        // reflows the PTY once, while floating keyboards reserve nothing and
        // never enter TextInputUI's custom-accessory path. On visionOS the
        // keyboard floats in its own panel and never overlaps the window.
        #if os(visionOS)
        addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(
                equalTo: topAnchor,
                constant: Self.terminalInsets.top
            ),
            view.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Self.terminalInsets.left
            ),
            view.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Self.terminalInsets.right
            ),
            view.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -Self.terminalInsets.bottom
            ),
        ])
        // Gaze hover for links: the overlay is a subview of the terminal
        // (its touches keep feeding the terminal's own pan recognizers) and
        // survives merge/split with it — reuse the one already riding an
        // adopted view rather than stacking another.
        let overlay = view.subviews.compactMap { $0 as? TerminalLinkHoverOverlay }.first
            ?? {
                let created = TerminalLinkHoverOverlay(terminalView: view)
                view.addSubview(created)
                return created
            }()
        overlay.activate = { [weak controller] target in
            _ = controller?.activateLink(target)
        }
        coordinator.linkHoverOverlay = overlay
        controller.onOutputFlushed = { [weak overlay] in
            overlay?.scheduleRefresh()
        }
        overlay.scheduleRefresh()
        #else
        let keyBar = TerminalKeyBar(
            terminal: view,
            controller: controller,
            performShortcut: { [weak controller] item in
                controller?.performPanelShortcut(item)
            },
            finishTmuxCopyMode: { [weak controller] in
                controller?.finishTmuxCopyMode()
            },
            shortcutBackend: configuration.shortcutBackend
        )
        keyBar.contentSafeArea = configuration.contentSafeArea
        coordinator.keyBar = keyBar
        addSubview(view)
        addSubview(keyBar)
        view.translatesAutoresizingMaskIntoConstraints = false
        keyBar.translatesAutoresizingMaskIntoConstraints = false
        let terminalTop = view.topAnchor.constraint(
            equalTo: topAnchor,
            constant: Self.terminalInsets.top
        )
        let keyBarBottom = keyBar.bottomAnchor.constraint(equalTo: bottomAnchor)
        let terminalBottom = view.bottomAnchor.constraint(
            equalTo: keyBar.topAnchor,
            constant: -(
                Self.terminalInsets.bottom + configuration.bottomChromeHeight
            )
        )
        // The container spans whatever side safe areas the shell handed it,
        // and the pane's screen paints across them. The grid does not: it
        // rides these constants back inside the readable region.
        let terminalLeading = view.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: Self.terminalInsets.left + configuration.contentSafeArea.left
        )
        let terminalTrailing = view.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -(Self.terminalInsets.right + configuration.contentSafeArea.right)
        )
        // A docked keyboard lifts the rail by the measured overlap, and the
        // strip it vacates otherwise shows the terminal theme — under a light
        // theme the translucent system keyboard samples that near-white and
        // reads washed-out on dark chrome (user-reported). Continue the
        // rail's chassis down to the container edge instead, so the keyboard
        // always sits over appearance-correct hardware; its top rides the
        // rail's bottom anchor, so it is exactly the keyboard-covered band
        // and collapses to nothing when no keyboard docks.
        let keyboardBackfill = UIView()
        keyboardBackfill.backgroundColor = TallyPalette.bezel
        keyboardBackfill.isUserInteractionEnabled = false
        insertSubview(keyboardBackfill, belowSubview: keyBar)
        keyboardBackfill.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminalTop,
            terminalLeading,
            terminalTrailing,
            terminalBottom,
            keyBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            keyBar.heightAnchor.constraint(equalToConstant: TerminalKeyBar.barHeight),
            keyBarBottom,
            keyboardBackfill.topAnchor.constraint(equalTo: keyBar.bottomAnchor),
            keyboardBackfill.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyboardBackfill.trailingAnchor.constraint(equalTo: trailingAnchor),
            keyboardBackfill.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        coordinator.installKeyboardAvoidance(
            container: self,
            constraint: keyBarBottom,
            terminalTopConstraint: terminalTop,
            terminalBottomConstraint: terminalBottom,
            terminalLeadingConstraint: terminalLeading,
            terminalTrailingConstraint: terminalTrailing
        )
        coordinator.railOwnsBottomSafeArea = configuration.railOwnsBottomSafeArea
        #endif

        controller.bind(view)
        if configuration.isActive {
            DispatchQueue.main.async {
                TerminalFocusArbiter.claim(view)
            }
        }
    }

    func update(configuration: Configuration) {
        self.configuration = configuration
        backgroundColor = GlassPrototype.terminalGround(
            themeBackground: UIColor(configuration.theme.background)
        )
        // A moved tab's view may already belong to another window while this
        // (about to be torn down) surface gets one last update.
        guard let view = coordinator.terminalView,
              view.isDescendant(of: self) else { return }
        if view.renderUpdatesEnabled != configuration.isActive {
            view.renderUpdatesEnabled = configuration.isActive
        }
        #if os(visionOS)
        // An obscured tab's links must not glow through the tab on screen.
        if let overlay = coordinator.linkHoverOverlay {
            if overlay.isHidden == configuration.isActive {
                overlay.isHidden = !configuration.isActive
                if configuration.isActive {
                    overlay.scheduleRefresh()
                } else {
                    overlay.clearRegions()
                }
            }
        }
        #endif
        let fontChanged = view.font.pointSize != configuration.fontSize
        if fontChanged {
            view.font = .monospacedSystemFont(
                ofSize: configuration.fontSize,
                weight: .regular
            )
        }
        if coordinator.appliedTheme != configuration.theme {
            apply(configuration.theme, to: view)
        } else if coordinator.appliedCaretVisible != (controller.status == .live) {
            // The pane re-runs this update on every observed status change,
            // which is where a connecting tab earns its caret back.
            applyCaretColor(theme: configuration.theme, to: view)
        }
        #if !os(visionOS)
        coordinator.updateBottomChromeHeight(
            Self.terminalInsets.bottom + configuration.bottomChromeHeight
        )
        coordinator.updateContentSafeArea(configuration.contentSafeArea)
        coordinator.railOwnsBottomSafeArea = configuration.railOwnsBottomSafeArea
        if fontChanged {
            coordinator.terminalMetricsDidChange()
        }
        #endif
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        #if !os(visionOS)
        coordinator.containerDidLayout()
        #endif
    }

    /// Colors change live — SwiftTerm's setters queue a full redraw, so an
    /// open session re-skins in place when the user switches themes.
    private func apply(_ theme: TerminalTheme, to view: TerminalView) {
        // PROTOTYPE(GLASS): keep the fork's own non-opaque invariant — cells
        // stay transparent (`nativeBackgroundColor = .clear` is exactly what
        // its setupOptions chose) and the pane ground lives on the view's
        // layer below, at `screenAlpha`, tinted by the selected theme.
        view.nativeBackgroundColor = GlassPrototype.terminalNativeGround(
            themeBackground: UIColor(theme.background)
        )
        view.nativeForegroundColor = UIColor(theme.foreground)
        applyCaretColor(theme: theme, to: view)
        view.selectedTextBackgroundColor = UIColor(theme.cursor).withAlphaComponent(0.3)
        // SwiftTerm 1.15 adds an explicit selected-text foreground whose
        // upstream default is black. Preserve the theme's former text color,
        // especially for dark terminal surfaces.
        view.selectedTextForegroundColor = UIColor(theme.foreground)
        if theme.isValid {
            view.installColors(theme.ansi.map { color in
                SwiftTerm.Color(
                    red: UInt16(color.red) * 257,
                    green: UInt16(color.green) * 257,
                    blue: UInt16(color.blue) * 257
                )
            })
        }
        // PROTOTYPE(GLASS): the surface wrapper above carries the pane
        // tint edge-to-edge; the grid's own layer stays clear over it.
        view.backgroundColor = GlassPrototype.terminalWrapperGround(
            themeBackground: UIColor(theme.background)
        )
        // The keyboard belongs to the chassis, not the terminal surface:
        // `.default` follows the window's appearance (the Settings choice via
        // `overrideUserInterfaceStyle`), so a light terminal theme under dark
        // chrome keeps a dark keyboard — and vice versa (user-reported).
        view.keyboardAppearance = .default
        coordinator.appliedTheme = theme
    }

    /// The caret carries the theme's cursor color — tally red in the house
    /// themes — and SwiftTerm parks it at row 0 / column 0 while the screen is
    /// still empty. Over the CONNECTING panel that lone red glyph reads as a
    /// rendering fault, so the caret stays invisible until the tab's transport
    /// is actually live.
    private func applyCaretColor(theme: TerminalTheme, to view: TerminalView) {
        let visible = controller.status == .live
        view.caretColor = visible ? UIColor(theme.cursor) : .clear
        coordinator.appliedCaretVisible = visible
    }

    /// Forwards SwiftTerm delegate events to the session controller.
    /// SwiftTerm calls these on the main thread; `assumeIsolated` bridges
    /// into the controller's MainActor isolation.
    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        let controller: TerminalSessionController
        weak var terminalView: TerminalView?
        #if os(visionOS)
        /// Gaze link regions — owned by the terminal view it floats over,
        /// referenced here for visibility gating and scroll refreshes.
        weak var linkHoverOverlay: TerminalLinkHoverOverlay?
        #endif
        var appliedTheme: TerminalTheme?
        /// Whether the last applied caret color was the theme's cursor (live)
        /// or clear. `nil` until the first application.
        var appliedCaretVisible: Bool?

        init(controller: TerminalSessionController) {
            self.controller = controller
        }

        #if !os(visionOS)
        weak var keyBar: TerminalKeyBar?
        var railOwnsBottomSafeArea = false
        private weak var avoidingContainer: UIView?
        private var bottomConstraint: NSLayoutConstraint?
        private var terminalTopConstraint: NSLayoutConstraint?
        private var terminalBottomConstraint: NSLayoutConstraint?
        private var terminalLeadingConstraint: NSLayoutConstraint?
        private var terminalTrailingConstraint: NSLayoutConstraint?
        private var keyboardObservers: [NSObjectProtocol] = []
        private var keyboardPresentation: KeyboardAvoidance.Presentation = .hidden
        private var keyboardSettleWorkItems: [DispatchWorkItem] = []
        #if DEBUG
        private var keyboardLogSettleWorkItem: DispatchWorkItem?
        #endif
        /// Last *docked* keyboard end-frame (screen coords); floating frames
        /// are deliberately discarded. Kept so overlap can be re-measured
        /// when geometry — not the keyboard — changes after a docked event.
        private var lastKeyboardFrame: CGRect?

        deinit {
            for observer in keyboardObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            cancelKeyboardSettleRemeasures()
            #if DEBUG
            keyboardLogSettleWorkItem?.cancel()
            #endif
        }

        /// Move the app-owned rail and terminal above a docked keyboard, and
        /// publish the same obstruction for the helper strip. Floating/split
        /// keyboards reserve nothing.
        func installKeyboardAvoidance(
            container: UIView,
            constraint: NSLayoutConstraint,
            terminalTopConstraint: NSLayoutConstraint,
            terminalBottomConstraint: NSLayoutConstraint,
            terminalLeadingConstraint: NSLayoutConstraint,
            terminalTrailingConstraint: NSLayoutConstraint
        ) {
            avoidingContainer = container
            bottomConstraint = constraint
            self.terminalTopConstraint = terminalTopConstraint
            self.terminalBottomConstraint = terminalBottomConstraint
            self.terminalLeadingConstraint = terminalLeadingConstraint
            self.terminalTrailingConstraint = terminalTrailingConstraint
            // didChangeFrame too: some presentations deliver their final
            // geometry (accessory attach, dock/float transitions) only in
            // the did- pass — reacting to will- alone under-insets and the
            // input row ends up behind the key rail. Repeated floating-frame
            // events are filtered by presentation state before they reach
            // layout, and docked settle work is coalesced.
            for name in [UIResponder.keyboardWillChangeFrameNotification,
                         UIResponder.keyboardDidChangeFrameNotification,
                         UIResponder.keyboardWillHideNotification,
                         UIResponder.keyboardDidHideNotification] {
                keyboardObservers.append(NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    MainActor.assumeIsolated {
                        self?.applyKeyboardFrame(notification)
                    }
                })
            }
        }

        func updateBottomChromeHeight(_ height: CGFloat) {
            guard let constraint = terminalBottomConstraint,
                  constraint.constant != -height
            else { return }
            constraint.constant = -height
            avoidingContainer?.layoutIfNeeded()
        }

        /// Rotating a phone moves the Island's band from one long edge to the
        /// other, and hiding the deck rail hands the leading band to this
        /// pane. Both change the grid's clearance without rebuilding it.
        func updateContentSafeArea(_ safeArea: UIEdgeInsets) {
            keyBar?.contentSafeArea = safeArea
            guard let leadingConstraint = terminalLeadingConstraint,
                  let trailingConstraint = terminalTrailingConstraint
            else { return }
            let leadingConstant = TerminalSurfaceView.terminalInsets.left
                + safeArea.left
            let trailingConstant = -(TerminalSurfaceView.terminalInsets.right
                + safeArea.right)
            guard leadingConstraint.constant != leadingConstant
                    || trailingConstraint.constant != trailingConstant
            else { return }
            leadingConstraint.constant = leadingConstant
            trailingConstraint.constant = trailingConstant
            avoidingContainer?.layoutIfNeeded()
        }

        func terminalMetricsDidChange() {
            avoidingContainer?.setNeedsLayout()
            avoidingContainer?.layoutIfNeeded()
        }

        /// SwiftTerm renders only whole rows from the top of its bounds. Move
        /// its measured fractional remainder into the existing top gutter so
        /// a tmux status line hugs the lower chrome. One physical pixel stays
        /// below the grid to keep the PTY safely in the same row-count bucket.
        private func alignTerminalGridTowardBottom() {
            guard controller.route.usesTmux,
                  let view = terminalView,
                  let topConstraint = terminalTopConstraint,
                  view.bounds.height > 0
            else { return }

            let baseTop = TerminalSurfaceView.terminalInsets.top
            let appliedNudge = max(0, topConstraint.constant - baseTop)
            let rawHeight = view.bounds.height + appliedNudge
            let rows = view.getTerminal().rows
            guard rows > 0 else { return }
            let cellHeight = view.getOptimalFrameSize().height / CGFloat(rows)
            guard cellHeight > 0 else { return }

            let scale = max(view.window?.screen.scale ?? UIScreen.main.scale, 1)
            let epsilon = 0.5 / scale
            let nudge = TerminalGridAlignment.bottomNudge(
                rawHeight: rawHeight,
                cellHeight: cellHeight,
                displayScale: scale
            )
            let targetTop = baseTop + nudge
            guard abs(topConstraint.constant - targetTop) > epsilon else { return }
            topConstraint.constant = targetTop
            // This method runs after `super.layoutSubviews()`. Ensure UIKit
            // resolves the new constraint even if the keyboard/window stops
            // moving immediately after the layout pass that changed it.
            avoidingContainer?.setNeedsLayout()
        }

        private func applyKeyboardFrame(_ notification: Notification) {
            guard notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool != false
            else { return }
            guard let container = avoidingContainer,
                  let window = container.window
            else { return }
            // Keyboard notifications are process-global. Only the terminal
            // that owns the app-wide input session may convert geometry or
            // touch constraints; hidden Stage Manager scenes otherwise do
            // the same work (and can race a transient UIScreen replacement).
            guard terminalView === TerminalFocusArbiter.current,
                  terminalView?.window === window
            else { return }

            let previousPresentation = keyboardPresentation
            let endFrame: CGRect?
            if notification.name == UIResponder.keyboardDidHideNotification {
                endFrame = nil
                keyboardPresentation = .hidden
            } else if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                endFrame = frame
                let screenSpace = window.screen.coordinateSpace
                keyboardPresentation = KeyboardAvoidance.presentation(
                    keyboard: frame,
                    screen: screenSpace.bounds
                )
            } else if notification.name == UIResponder.keyboardWillHideNotification {
                endFrame = nil
                keyboardPresentation = .hidden
            } else {
                return
            }

            lastKeyboardFrame = keyboardPresentation == .docked ? endFrame : nil

            // Stage Manager reports the floating keyboard as a zero-height
            // shortcut frame and can emit will-change, will-hide, then
            // did-change with that same geometry during one window move.
            // Classify the frame rather than treating will-hide as definitive;
            // repeated shortcut/floating events do no layout or timer work.
            guard KeyboardAvoidance.shouldReapplyFrameChange(
                from: previousPresentation,
                to: keyboardPresentation
            ) else {
                return
            }

            #if DEBUG
            logKeyboardDiagnostics(notification, container: container, window: window)
            #endif
            reapplyKeyboardLayout()

            // Stage Manager can keep moving the window after a real keyboard
            // transition. Keep the two proven settle points, but replace any
            // pending pair so a notification burst never fans out unbounded
            // main-thread layout work.
            if keyboardPresentation == .docked {
                scheduleKeyboardSettleRemeasures()
            } else {
                cancelKeyboardSettleRemeasures()
            }
        }

        private func scheduleKeyboardSettleRemeasures() {
            cancelKeyboardSettleRemeasures()
            for delay: TimeInterval in [0.35, 0.8] {
                let item = DispatchWorkItem { [weak self] in
                    self?.reapplyKeyboardLayout()
                }
                keyboardSettleWorkItems.append(item)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            }
        }

        private func cancelKeyboardSettleRemeasures() {
            for item in keyboardSettleWorkItems { item.cancel() }
            keyboardSettleWorkItems.removeAll()
        }

        /// Window movement causes layout passes even though a floating
        /// or short/flat keyboard frame has no effect on terminal geometry.
        /// Only a docked keyboard needs remeasurement as the window moves.
        func containerDidLayout() {
            alignTerminalGridTowardBottom()
            guard terminalView === TerminalFocusArbiter.current else { return }
            guard keyboardPresentation == .docked else { return }
            reapplyKeyboardLayout()
        }

        /// Recomputes rail clearance and `keyboardObstruction` from the last
        /// docked frame against the current window position. The helper value
        /// is measured against the window so its own content insets cannot
        /// feed back into the measurement.
        func reapplyKeyboardLayout() {
            guard let container = avoidingContainer,
                  let constraint = bottomConstraint,
                  let window = container.window,
                  terminalView === TerminalFocusArbiter.current,
                  terminalView?.window === window
            else { return }
            let screenSpace = window.screen.coordinateSpace
            let containerOnScreen = container.convert(container.bounds, to: screenSpace)
            let windowOnScreen = window.convert(window.bounds, to: screenSpace)
            // The helper's interactive content rests directly on the rail,
            // which rests on the window's bottom safe-area edge — or on the
            // window's edge itself where the shell hands its pane the home
            // indicator's strip. Either way the reference comes from the
            // window and a static fact about this pane, never from the
            // container's live frame: the strip's own padding would feed back.
            let restingBottom = windowOnScreen.maxY
                - (railOwnsBottomSafeArea ? 0 : window.safeAreaInsets.bottom)
            var overlap: CGFloat = 0
            var obstruction: CGFloat = 0
            if let endFrame = lastKeyboardFrame {
                if KeyboardAvoidance.isDocked(
                    keyboard: endFrame,
                    screen: screenSpace.bounds,
                    containerWidth: containerOnScreen.width
                ) {
                    let inContainer = container.convert(endFrame, from: screenSpace)
                    overlap = max(0, container.bounds.maxY - inContainer.minY)
                    obstruction = max(0, restingBottom - endFrame.minY)
                }
            }
            overlap = min(overlap, container.bounds.height * 0.8)
            obstruction = min(obstruction, window.bounds.height * 0.8)
            MainActor.assumeIsolated {
                controller.reportKeyboardObstruction(max(0, obstruction))
            }
            guard constraint.constant != -overlap else { return }
            constraint.constant = -overlap
            container.layoutIfNeeded()
        }

        #if DEBUG
        /// Diagnosis aid for keyboard-geometry bugs: dumps what the
        /// notification reported, what the classifier decided, and where
        /// UIKit put the container — read with
        /// `log show --predicate 'subsystem == "app.multiplexterm.multiplex"'`.
        private func logKeyboardDiagnostics(_ notification: Notification, container: UIView, window: UIWindow) {
            let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .null
            let screenSpace = window.screen.coordinateSpace
            let containerOnScreen = container.convert(container.bounds, to: screenSpace)
            let docked = KeyboardAvoidance.isDocked(
                keyboard: endFrame, screen: screenSpace.bounds, containerWidth: containerOnScreen.width
            )
            let logLine = { [weak self] (tag: String) in
                let onScreen = container.convert(container.bounds, to: screenSpace)
                Logger(subsystem: "app.multiplexterm.multiplex", category: "kbd").debug(
                    "\(tag, privacy: .public): \(notification.name.rawValue, privacy: .public) end=\(String(describing: endFrame), privacy: .public) docked=\(docked, privacy: .public) container=\(String(describing: onScreen), privacy: .public) obstruction=\(self?.controller.keyboardObstruction ?? 0, privacy: .public) safeBottom=\(container.safeAreaInsets.bottom, privacy: .public)"
                )
            }
            logLine("kbd-event")
            keyboardLogSettleWorkItem?.cancel()
            let item = DispatchWorkItem { logLine("kbd-settled") }
            keyboardLogSettleWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
        }
        #endif
        #endif

        @objc func reclaimFocus(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? TerminalView else { return }
            TerminalFocusArbiter.summon(view)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            MainActor.assumeIsolated {
                controller.sendInput(bytes)
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                controller.terminalResized(cols: newCols, rows: newRows)
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            MainActor.assumeIsolated {
                controller.terminalTitleChanged(title)
            }
        }

        /// OSC 52 write. The remote naming the device clipboard is the
        /// mechanism `mpx bind --copy` rides (and tmux's own `set-clipboard`),
        /// so it stays — bounded, because the payload is remote bytes and a
        /// clipboard entry nobody can read back is not worth a megabyte.
        func clipboardCopy(source: TerminalView, content: Data) {
            guard content.count <= Coordinator.maxClipboardWriteBytes,
                  let text = String(data: content, encoding: .utf8)
            else { return }
            UIPasteboard.general.string = text
        }

        /// OSC 52 read is deliberately unanswered. The query is pane output —
        /// any remote process that can print can send it — and answering it
        /// hands the device pasteboard (passwords, tokens, whatever was last
        /// copied) back over the wire with nothing on screen to show for it.
        /// Paste stays a user action: the key bar, the selection menu, and the
        /// system paste control all still work.
        func clipboardRead(source: TerminalView) -> Data? {
            nil
        }

        static let maxClipboardWriteBytes = 256 * 1024

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {
            #if os(visionOS)
            // Scrollback browsing moves links under fixed regions — re-place
            // them for the rows now visible.
            linkHoverOverlay?.scheduleRefresh()
            #endif
        }
        /// Only reached if the view's `linkActivationHandler` is ever absent —
        /// `bind` installs one. Kept wired so the two routes can't disagree.
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            MainActor.assumeIsolated {
                _ = controller.activateLink(link)
            }
        }

        func bell(source: TerminalView) {
            MainActor.assumeIsolated {
                controller.bellRang()
            }
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

extension TerminalView {
    /// True while the user is actively typing into this terminal — read from
    /// the same send-path stamp the fork's immediate-display window uses, so
    /// every input road (IME commits, the key rail, kitty-encoded hardware
    /// keys, dictation chunks) counts, and none has to report separately.
    /// Chrome uses it to defer work that has no business running between
    /// keystrokes: the focused-pane agent probe and the gaze hover-region
    /// rebuild both wait for a quiet gap instead.
    func hasRecentUserInput(within window: Duration) -> Bool {
        let last = lastUserInputUptimeNanoseconds
        guard last > 0 else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= last else { return false }
        let windowNs = UInt64(window / .nanoseconds(1))
        return now - last <= windowNs
    }
}
