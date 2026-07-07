import SwiftUI
import SwiftTerm

/// SwiftUI wrapper around SwiftTerm's UIKit `TerminalView`, themed for Multiplex
/// and bound to a `TerminalSessionController` for SSH I/O.
struct SwiftTermView: UIViewRepresentable {
    let controller: TerminalSessionController
    var fontSize: CGFloat

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(
            frame: .zero,
            font: .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        )
        applyTheme(to: view)
        view.changeScrollback(5000)
        view.keyboardAppearance = .dark
        view.terminalDelegate = context.coordinator

        // Tapping the terminal always reclaims keyboard focus — without
        // cancelling SwiftTerm's own selection/scroll gestures.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.reclaimFocus(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        // Multi-window: hardware keys go to the KEY window's first responder,
        // and on visionOS every visible window stays scene-active — so grab
        // first responder whenever this terminal's own window becomes key.
        context.coordinator.observeKeyWindow(for: view)

        controller.bind(view)
        DispatchQueue.main.async {
            view.window?.makeKey()
            view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        if view.font.pointSize != fontSize {
            view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    private func applyTheme(to view: TerminalView) {
        view.nativeBackgroundColor = UIColor(rgb: Theme.terminalBackground)
        view.nativeForegroundColor = UIColor(rgb: Theme.terminalForeground)
        view.caretColor = UIColor(rgb: Theme.terminalCursor)
        view.installColors(Theme.ansiPalette.map { hex in
            SwiftTerm.Color(
                red: UInt16((hex >> 16) & 0xFF) * 257,
                green: UInt16((hex >> 8) & 0xFF) * 257,
                blue: UInt16(hex & 0xFF) * 257
            )
        })
        view.backgroundColor = UIColor(rgb: Theme.terminalBackground)
    }

    /// Forwards SwiftTerm delegate events to the session controller.
    /// SwiftTerm calls these on the main thread; `assumeIsolated` bridges
    /// into the controller's MainActor isolation.
    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        let controller: TerminalSessionController

        init(controller: TerminalSessionController) {
            self.controller = controller
        }

        private var keyWindowObserver: NSObjectProtocol?

        deinit {
            if let keyWindowObserver {
                NotificationCenter.default.removeObserver(keyWindowObserver)
            }
        }

        @objc func reclaimFocus(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            view.window?.makeKey()
            view.becomeFirstResponder()
        }

        func observeKeyWindow(for view: TerminalView) {
            keyWindowObserver = NotificationCenter.default.addObserver(
                forName: UIWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak view] notification in
                MainActor.assumeIsolated {
                    guard let view,
                          let window = notification.object as? UIWindow,
                          view.window === window,
                          !view.isFirstResponder
                    else { return }
                    view.becomeFirstResponder()
                }
            }
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
        func bell(source: TerminalView) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

extension UIColor {
    convenience init(rgb: (red: UInt8, green: UInt8, blue: UInt8)) {
        self.init(
            red: CGFloat(rgb.red) / 255,
            green: CGFloat(rgb.green) / 255,
            blue: CGFloat(rgb.blue) / 255,
            alpha: 1
        )
    }
}
