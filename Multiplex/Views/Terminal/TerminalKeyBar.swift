#if !os(visionOS)
import SwiftUI
import SwiftTerm
import UIKit
#if DEBUG
import notify
#endif

/// The iPad terminal's input accessory — a TALLY key rail above the software
/// keyboard (and the row that docks alone in hardware-keyboard mode),
/// replacing SwiftTerm's stock white accessory. Keys a remote tmux + CLI
/// agent session actually needs: ESC, a latching CTRL, TAB, the shell
/// symbols the iPad keyboard buries behind layer switches, and arrows.
///
/// Every key sends through `TerminalView.send` → the view delegate → the
/// controller's ordered input pump, so accessory bytes can never reorder
/// around keystrokes. CTRL rides SwiftTerm's `controlModifier`, which the
/// next software-keyboard character consumes (and auto-resets — the bar
/// listens for the reset to release the latch visual). On visionOS the
/// keyboard floats in its own panel and never shows an accessory.
@MainActor
final class TerminalKeyBar: UIInputView, UIInputViewAudioFeedback {
    @Observable @MainActor
    final class Model {
        var ctrlLatched = false
    }

    private static let barHeight: CGFloat = 48

    private weak var terminal: TerminalView?
    private let model = Model()
    /// The hosting controller must outlive its view; stored, not parented —
    /// an accessory has no view-controller hierarchy to join.
    private var host: UIHostingController<KeyBarRow>?

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: Self.barHeight),
            inputViewStyle: .keyboard
        )
        allowsSelfSizing = true

        let host = UIHostingController(rootView: KeyBarRow(
            model: model,
            press: { [weak self] key in self?.press(key) }
        ))
        // The keyboard region would otherwise pad the row inside its own bar.
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        self.host = host

        // SwiftTerm consumes the control modifier on the next typed
        // character; selector-based observation needs no deinit cleanup.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controlModifierDidReset),
            name: .terminalViewControlModifierReset,
            object: terminal
        )
        #if DEBUG
        KeyBarDebugHook.install()
        #endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // UIInputViewAudioFeedback — lets playInputClick() tick like a key.
    var enableInputClicksWhenVisible: Bool { true }

    @objc private func controlModifierDidReset() {
        model.ctrlLatched = false
    }

    fileprivate func press(_ key: TerminalKey) {
        guard let terminal else { return }
        switch key {
        case .esc:
            click()
            terminal.send(EscapeSequences.cmdEsc)
        case .ctrl:
            let latched = !terminal.controlModifier
            terminal.controlModifier = latched
            model.ctrlLatched = latched
        case .tab:
            click()
            terminal.send([0x09])
        case .text(let text):
            click()
            terminal.send(txt: text)
        case .up:
            click()
            terminal.send(arrow(EscapeSequences.moveUpApp, EscapeSequences.moveUpNormal))
        case .down:
            click()
            terminal.send(arrow(EscapeSequences.moveDownApp, EscapeSequences.moveDownNormal))
        case .left:
            click()
            terminal.send(arrow(EscapeSequences.moveLeftApp, EscapeSequences.moveLeftNormal))
        case .right:
            click()
            terminal.send(arrow(EscapeSequences.moveRightApp, EscapeSequences.moveRightNormal))
        case .dismiss:
            terminal.resignFirstResponder()
        }
    }

    /// Arrows honor DECCKM the same way SwiftTerm's own key handling does.
    private func arrow(_ app: [UInt8], _ normal: [UInt8]) -> [UInt8] {
        terminal?.getTerminal().applicationCursor == true ? app : normal
    }

    private func click() {
        UIDevice.current.playInputClick()
    }

    #if DEBUG
    /// Headless proof sequence: the four symbol keys through the bar's own
    /// send path, then a latched CTRL consumed by a software-keyboard 'c' —
    /// at a shell prompt `tmux capture-pane` shows `~|/-^C`.
    func debugExercise() {
        for symbol in ["~", "|", "/", "-"] { press(.text(symbol)) }
        press(.ctrl)
        terminal?.insertText("c")
    }
    #endif
}

private enum TerminalKey {
    case esc, ctrl, tab
    case text(String)
    case up, down, left, right
    case dismiss
}

/// The rail: modifiers left, shell symbols center, arrows + dismiss right.
/// Fixed-size keys so ViewThatFits can actually measure — when the bar is
/// narrow (accessory-only row in a small Stage Manager window) the symbol
/// cluster is the first thing to go.
private struct KeyBarRow: View {
    var model: TerminalKeyBar.Model
    var press: (TerminalKey) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(withSymbols: true)
            row(withSymbols: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Theme.bezel)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.bezelHi).frame(height: 1)
        }
    }

    private func row(withSymbols: Bool) -> some View {
        HStack(spacing: 6) {
            capsKey("ESC", .esc, "Escape")
            capsKey("CTRL", .ctrl, "Control", latched: model.ctrlLatched)
            capsKey("TAB", .tab, "Tab")
            Spacer(minLength: 12)
            if withSymbols {
                ForEach(["~", "|", "/", "-"], id: \.self) { symbol in
                    Key(action: { press(.text(symbol)) }, accessibilityText: symbol) {
                        Text(symbol).font(.mono(15))
                    }
                }
                Spacer(minLength: 12)
            }
            arrowKey("arrow.left", .left, "Arrow left")
            arrowKey("arrow.down", .down, "Arrow down")
            arrowKey("arrow.up", .up, "Arrow up")
            arrowKey("arrow.right", .right, "Arrow right")
            Key(action: { press(.dismiss) }, accessibilityText: "Hide keyboard") {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
    }

    private func capsKey(
        _ label: String, _ key: TerminalKey, _ accessibility: String, latched: Bool = false
    ) -> some View {
        Key(action: { press(key) }, latched: latched, accessibilityText: accessibility) {
            Text(label).font(.mono(11, weight: .semibold)).kerning(1.1)
        }
    }

    private func arrowKey(_ icon: String, _ key: TerminalKey, _ accessibility: String) -> some View {
        Key(action: { press(key) }, repeats: true, accessibilityText: accessibility) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
        }
    }
}

/// One key: a chassis chip scaled to a touch target. Latched (sticky CTRL)
/// inverts the face — prominence, not color, marks the held modifier.
private struct Key<Label: View>: View {
    var action: () -> Void
    var repeats = false
    var latched = false
    var accessibilityText: String
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: 46, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyFace(latched: latched))
        .buttonRepeatBehavior(repeats ? .enabled : .disabled)
        .chassisHover(2)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(latched ? .isSelected : [])
    }
}

private struct KeyFace: ButtonStyle {
    var latched: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(latched ? Theme.chassis : Theme.signal2)
            .background(latched ? Theme.signal2
                : configuration.isPressed ? Theme.bezelHi : Theme.chassis)
            .overlay(Rectangle().strokeBorder(
                latched ? Theme.signal2 : Theme.bezelHi, lineWidth: 1))
    }
}

#if DEBUG
/// Headless-verification hook, same shape as the agent-chip and new-tab
/// hooks: `xcrun simctl spawn <udid> notifyutil -p
/// tools.bricks.multiplex.debug.keybar` runs the focused terminal's key-bar
/// proof sequence without touching the screen.
@MainActor
enum KeyBarDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var token: Int32 = 0
        notify_register_dispatch(
            "tools.bricks.multiplex.debug.keybar", &token, .main
        ) { _ in
            guard let view = TerminalFocusArbiter.current,
                  let bar = view.inputAccessoryView as? TerminalKeyBar
            else { return }
            bar.debugExercise()
        }
    }
}
#endif
#endif
