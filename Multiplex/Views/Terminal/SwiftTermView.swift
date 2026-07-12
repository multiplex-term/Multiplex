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
    /// Only the window's active tab claims keyboard focus when it appears.
    var isActive: Bool = true

    private static let focusTapName = "multiplex.focus-tap"

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
            // The TALLY key rail replaces SwiftTerm's stock accessory. Tied
            // to the view, so it survives tab moves across windows.
            view.inputAccessoryView = TerminalKeyBar(terminal: view)
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

        // The terminal shrinks above the keyboard — including the
        // accessory-only presentation (hardware keyboard mode), which
        // keyboardLayoutGuide misses in windowed iPadOS — so the bottom
        // rows are never covered: the PTY reflows and tmux redraws its
        // status line above the keyboard. This constraint is the *single*
        // owner of keyboard clearance: the window opts the terminal out of
        // SwiftUI's automatic avoidance (TerminalWindow), which mishandles
        // floating keyboards. On visionOS the keyboard floats in its own
        // panel and never overlaps the window.
        #if os(visionOS)
        let container = UIView()
        #else
        let container = KeyboardAvoidingContainer()
        #endif
        container.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        let bottomConstraint = view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomConstraint,
        ])
        #if !os(visionOS)
        context.coordinator.installKeyboardAvoidance(container: container, constraint: bottomConstraint)
        container.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.reapplyKeyboardOverlap()
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
        if view.font.pointSize != fontSize {
            view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        if context.coordinator.appliedTheme != theme {
            apply(theme, to: view, coordinator: context.coordinator)
        }
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
        private weak var avoidingContainer: UIView?
        private var bottomConstraint: NSLayoutConstraint?
        private var keyboardObservers: [NSObjectProtocol] = []
        /// Last keyboard end-frame (screen coords); nil once hidden. Kept so
        /// overlap can be re-measured when geometry — not the keyboard —
        /// changes: Stage Manager shifts the whole window after the
        /// keyboard notification, and an overlap computed mid-shift leaves
        /// the input row behind the key rail.
        private var lastKeyboardFrame: CGRect?

        deinit {
            for observer in keyboardObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        /// Raise the terminal's bottom edge by however much of the keyboard
        /// (including the accessory row alone) overlaps the container.
        /// Floating/split keyboards hover over content by design and reserve
        /// nothing — `KeyboardAvoidance` makes the docked call.
        func installKeyboardAvoidance(container: UIView, constraint: NSLayoutConstraint) {
            avoidingContainer = container
            bottomConstraint = constraint
            // didChangeFrame too: some presentations deliver their final
            // geometry (accessory attach, dock/float transitions) only in
            // the did- pass — reacting to will- alone under-insets and the
            // input row ends up behind the key rail. The handler is
            // idempotent, so re-measuring is free.
            for name in [UIResponder.keyboardWillChangeFrameNotification,
                         UIResponder.keyboardDidChangeFrameNotification,
                         UIResponder.keyboardWillHideNotification] {
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

        private func applyKeyboardFrame(_ notification: Notification) {
            if notification.name == UIResponder.keyboardWillHideNotification {
                lastKeyboardFrame = nil
            } else if let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                lastKeyboardFrame = endFrame
            }
            #if DEBUG
            if let container = avoidingContainer, let window = container.window {
                logKeyboardDiagnostics(notification, container: container, window: window)
            }
            #endif
            reapplyKeyboardOverlap()
            // Stage Manager keeps moving the window after the keyboard
            // animation; re-measure until the geometry has settled.
            for delay: TimeInterval in [0.35, 0.8] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.reapplyKeyboardOverlap()
                }
            }
        }

        /// Recomputes the inset from the last-seen keyboard frame against
        /// the container's *current* on-screen position. Idempotent — safe
        /// to call from layout passes (the constraint guard stops recursion).
        func reapplyKeyboardOverlap() {
            guard let container = avoidingContainer,
                  let constraint = bottomConstraint,
                  let window = container.window
            else { return }
            let screenSpace = window.screen.coordinateSpace
            let containerOnScreen = container.convert(container.bounds, to: screenSpace)
            var overlap: CGFloat = 0
            if let endFrame = lastKeyboardFrame {
                if KeyboardAvoidance.isDocked(
                    keyboard: endFrame,
                    screen: screenSpace.bounds,
                    containerWidth: containerOnScreen.width
                ) {
                    let inContainer = container.convert(endFrame, from: screenSpace)
                    overlap = max(0, container.bounds.maxY - inContainer.minY)
                }
            }
            // The accessory-only presentation (hardware-keyboard mode) can
            // report a zero-height end frame pinned to the *window* bottom —
            // useless geometry — while still rendering the key rail over the
            // terminal's last rows. The rendered accessory knows its real
            // frame, so measure it directly — but only when that frame is
            // itself docked (`accessoryIsDocked`): a floating keyboard drags
            // the rail around mid-screen, and insetting by a moving pill
            // resizes the PTY every frame — tmux reflow churn. The docked-
            // keyboard path above still wins when a taller keyboard is up
            // (max), and a hidden accessory has no window and adds 0.
            if let accessory = terminalView?.inputAccessoryView, accessory.window != nil {
                let onScreen = accessory.convert(accessory.bounds, to: screenSpace)
                if KeyboardAvoidance.accessoryIsDocked(
                    accessory: onScreen,
                    container: containerOnScreen,
                    screen: screenSpace.bounds
                ) {
                    let inContainer = container.convert(onScreen, from: screenSpace)
                    overlap = max(overlap, container.bounds.maxY - inContainer.minY)
                }
            }
            overlap = min(overlap, container.bounds.height * 0.8)
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
                var accessoryDescription = "none"
                if let accessory = self?.terminalView?.inputAccessoryView, accessory.window != nil {
                    let accessoryOnScreen = accessory.convert(accessory.bounds, to: screenSpace)
                    accessoryDescription = String(describing: accessoryOnScreen)
                }
                Logger(subsystem: "app.multiplexterm.multiplex", category: "kbd").debug(
                    "\(tag, privacy: .public): \(notification.name.rawValue, privacy: .public) end=\(String(describing: endFrame), privacy: .public) docked=\(docked, privacy: .public) container=\(String(describing: onScreen), privacy: .public) accessory=\(accessoryDescription, privacy: .public) constraint=\(self?.bottomConstraint?.constant ?? 0, privacy: .public) safeBottom=\(container.safeAreaInsets.bottom, privacy: .public)"
                )
            }
            logLine("kbd-event")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { logLine("kbd-settled") }
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
/// Terminal wrapper that re-measures keyboard overlap on every layout pass:
/// window resizes (Stage Manager, Split View, rotation) move the terminal
/// relative to a keyboard that posts no new notification of its own.
private final class KeyboardAvoidingContainer: UIView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
#endif
