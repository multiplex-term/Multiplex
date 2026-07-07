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
        view.keyboardType = .asciiCapable
        view.terminalDelegate = context.coordinator

        // Tapping the terminal claims app-wide keyboard focus (and re-summons
        // a dismissed keyboard) — without cancelling SwiftTerm's own
        // selection/scroll gestures.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.reclaimFocus(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        controller.bind(view)
        DispatchQueue.main.async {
            TerminalFocusArbiter.claim(view)
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
