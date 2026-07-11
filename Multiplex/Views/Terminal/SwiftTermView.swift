import SwiftUI
import SwiftTerm

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
            #if !os(visionOS)
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
        // status line above the keyboard. On visionOS the keyboard floats
        // in its own panel and never overlaps the window.
        let container = UIView()
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
            for name in [UIResponder.keyboardWillChangeFrameNotification,
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
            guard let container = avoidingContainer,
                  let constraint = bottomConstraint,
                  let window = container.window
            else { return }

            var overlap: CGFloat = 0
            if notification.name != UIResponder.keyboardWillHideNotification,
               let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                let screenSpace = window.screen.coordinateSpace
                let containerOnScreen = container.convert(container.bounds, to: screenSpace)
                if KeyboardAvoidance.isDocked(
                    keyboard: endFrame,
                    screen: screenSpace.bounds,
                    containerWidth: containerOnScreen.width
                ) {
                    let inContainer = container.convert(endFrame, from: screenSpace)
                    overlap = max(0, container.bounds.maxY - inContainer.minY)
                    overlap = min(overlap, container.bounds.height * 0.8)
                }
            }
            guard constraint.constant != -overlap else { return }
            constraint.constant = -overlap
            container.layoutIfNeeded()
        }
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
