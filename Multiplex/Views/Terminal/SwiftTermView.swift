import SwiftUI
import SwiftTerm
#if DEBUG
import os
#endif

/// SwiftUI wrapper around SwiftTerm's UIKit `TerminalView`, themed for Multiplex
/// and bound to a `TerminalSessionController` for SSH I/O.
struct SwiftTermView: UIViewRepresentable {
    let controller: TerminalSessionController
    var fontSize: CGFloat
    var theme: TerminalTheme
    /// Space between terminal content and the iPad key rail for app chrome
    /// such as the agent helper strip. The rail itself remains bottommost.
    var bottomChromeHeight: CGFloat = 0
    /// Side safe areas this pane spans. The pane's screen and the rail's
    /// bezel paint through them; the grid and the keys keep clear, because a
    /// landscape Dynamic Island sits mid-edge — squarely over text rows.
    var contentSafeArea = EdgeInsets()
    /// Whether this pane runs to the window's bottom edge, which makes the
    /// rail rest there instead of on the safe-area boundary. Nothing else
    /// derives that resting edge from the container's live frame: the helper
    /// strip's clearance is measured from it, and would feed back.
    var railOwnsBottomSafeArea = false
    /// Only the window's active tab claims keyboard focus when it appears.
    var isActive: Bool = true

    private static let focusTapName = "multiplex.focus-tap"
    // Keep breathing room around the terminal chassis, but let tmux's status
    // line meet the helper/key rail directly—any bottom inset reads as an
    // accidental black seam between the two surfaces.
    private static let terminalInsets = UIEdgeInsets(top: 8, left: 10, bottom: 0, right: 10)

    func makeUIView(context: Context) -> UIView {
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
                font: .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            )
            view.changeScrollback(5000)
            view.keyboardType = .asciiCapable
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
        apply(theme, to: view, coordinator: context.coordinator)
        if view.font.pointSize != fontSize {
            view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        view.terminalDelegate = context.coordinator
        context.coordinator.terminalView = view

        // Tapping the terminal claims app-wide keyboard focus (and re-summons
        // a dismissed keyboard) — without cancelling SwiftTerm's own
        // selection/scroll gestures. An adopted view still carries the tap
        // wired to its previous window's coordinator — replace, don't stack.
        view.gestureRecognizers?
            .filter { $0.name == Self.focusTapName }
            .forEach(view.removeGestureRecognizer)
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.reclaimFocus(_:))
        )
        tap.name = Self.focusTapName
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        // On iPad, the app-owned rail is a normal sibling below the terminal.
        // Moving its bottom constraint above a genuinely docked keyboard
        // reflows the PTY once, while floating keyboards reserve nothing and
        // never enter TextInputUI's custom-accessory path. On visionOS the
        // keyboard floats in its own panel and never overlaps the window.
        #if os(visionOS)
        let container = UIView()
        container.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.terminalInsets.top),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.terminalInsets.left),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.terminalInsets.right),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.terminalInsets.bottom),
        ])
        #else
        let container = KeyboardAvoidingContainer()
        let keyBar = TerminalKeyBar(
            terminal: view,
            performTmuxShortcut: { [weak controller] shortcut in
                controller?.performTmuxShortcut(shortcut)
            },
            finishTmuxCopyMode: { [weak controller] in
                controller?.finishTmuxCopyMode()
            }
        )
        keyBar.contentSafeArea = contentSafeArea
        context.coordinator.keyBar = keyBar
        container.addSubview(view)
        container.addSubview(keyBar)
        view.translatesAutoresizingMaskIntoConstraints = false
        keyBar.translatesAutoresizingMaskIntoConstraints = false
        let terminalTop = view.topAnchor.constraint(
            equalTo: container.topAnchor,
            constant: Self.terminalInsets.top
        )
        let keyBarBottom = keyBar.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        let terminalBottom = view.bottomAnchor.constraint(
            equalTo: keyBar.topAnchor,
            constant: -(Self.terminalInsets.bottom + bottomChromeHeight)
        )
        // The container spans whatever side safe areas the shell handed it,
        // and the pane's screen paints across them. The grid does not: it
        // rides these constants back inside the readable region.
        let terminalLeading = view.leadingAnchor.constraint(
            equalTo: container.leadingAnchor,
            constant: Self.terminalInsets.left + contentSafeArea.leading
        )
        let terminalTrailing = view.trailingAnchor.constraint(
            equalTo: container.trailingAnchor,
            constant: -(Self.terminalInsets.right + contentSafeArea.trailing)
        )
        NSLayoutConstraint.activate([
            terminalTop,
            terminalLeading,
            terminalTrailing,
            terminalBottom,
            keyBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            keyBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            keyBar.heightAnchor.constraint(equalToConstant: TerminalKeyBar.barHeight),
            keyBarBottom,
        ])
        context.coordinator.installKeyboardAvoidance(
            container: container,
            constraint: keyBarBottom,
            terminalTopConstraint: terminalTop,
            terminalBottomConstraint: terminalBottom,
            terminalLeadingConstraint: terminalLeading,
            terminalTrailingConstraint: terminalTrailing
        )
        container.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.containerDidLayout()
        }
        #endif

        controller.bind(view)
        if isActive {
            DispatchQueue.main.async {
                TerminalFocusArbiter.claim(view)
            }
        }
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        // A moved tab's view may already belong to another window while this
        // (about to be torn down) representable gets one last update.
        guard let view = context.coordinator.terminalView,
              view.isDescendant(of: container) else { return }
        let fontChanged = view.font.pointSize != fontSize
        if fontChanged {
            view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        if context.coordinator.appliedTheme != theme {
            apply(theme, to: view, coordinator: context.coordinator)
        }
        #if !os(visionOS)
        context.coordinator.updateBottomChromeHeight(
            Self.terminalInsets.bottom + bottomChromeHeight
        )
        context.coordinator.updateContentSafeArea(
            leading: contentSafeArea.leading,
            trailing: contentSafeArea.trailing
        )
        context.coordinator.railOwnsBottomSafeArea = railOwnsBottomSafeArea
        if fontChanged {
            context.coordinator.terminalMetricsDidChange()
        }
        #endif
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    /// Colors change live — SwiftTerm's setters queue a full redraw, so an
    /// open session re-skins in place when the user switches themes.
    private func apply(_ theme: TerminalTheme, to view: TerminalView, coordinator: Coordinator) {
        view.nativeBackgroundColor = UIColor(theme.background)
        view.nativeForegroundColor = UIColor(theme.foreground)
        view.caretColor = UIColor(theme.cursor)
        view.selectedTextBackgroundColor = UIColor(theme.cursor).withAlphaComponent(0.3)
        if theme.isValid {
            view.installColors(theme.ansi.map { color in
                SwiftTerm.Color(
                    red: UInt16(color.red) * 257,
                    green: UInt16(color.green) * 257,
                    blue: UInt16(color.blue) * 257
                )
            })
        }
        view.backgroundColor = UIColor(theme.background)
        view.keyboardAppearance = theme.isDark ? .dark : .light
        coordinator.appliedTheme = theme
    }

    /// Forwards SwiftTerm delegate events to the session controller.
    /// SwiftTerm calls these on the main thread; `assumeIsolated` bridges
    /// into the controller's MainActor isolation.
    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        let controller: TerminalSessionController
        weak var terminalView: TerminalView?
        var appliedTheme: TerminalTheme?

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
        func updateContentSafeArea(leading: CGFloat, trailing: CGFloat) {
            keyBar?.contentSafeArea = EdgeInsets(
                top: 0, leading: leading, bottom: 0, trailing: trailing
            )
            guard let leadingConstraint = terminalLeadingConstraint,
                  let trailingConstraint = terminalTrailingConstraint
            else { return }
            let leadingConstant = SwiftTermView.terminalInsets.left + leading
            let trailingConstant = -(SwiftTermView.terminalInsets.right + trailing)
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
            guard controller.route.sessionName != nil,
                  let view = terminalView,
                  let topConstraint = terminalTopConstraint,
                  view.bounds.height > 0
            else { return }

            let baseTop = SwiftTermView.terminalInsets.top
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
        /// is measured against the window so its SwiftUI padding cannot feed
        /// back into the measurement.
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
        /// SwiftUI put the container — read with
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
                controller.remoteTitle = title
            }
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }

        func clipboardRead(source: TerminalView) -> Data? {
            UIPasteboard.general.string.map { Data($0.utf8) }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}

        func bell(source: TerminalView) {
            MainActor.assumeIsolated {
                controller.bellRang()
            }
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

#if !os(visionOS)
/// Terminal wrapper that offers every layout pass to the coordinator. It
/// aligns SwiftTerm's fractional grid remainder and re-measures docked
/// keyboard geometry because Stage Manager, Split View, and rotation can move
/// the terminal without a notification; unchanged/floating passes do no
/// constraint work.
private final class KeyboardAvoidingContainer: UIView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
#endif
