#if !os(visionOS)
import SwiftUI
import SwiftTerm
import UIKit
#if DEBUG
import notify
#endif

/// The iPad terminal's app-owned TALLY key rail. It is a normal subview of
/// the terminal container—not an `inputAccessoryView`. iPadOS rehosts custom
/// accessories through TextInputUI while a Stage Manager window moves,
/// repeatedly rebuilding the floating keyboard scene and stalling the UI.
/// Keeping the rail in Multiplex's own view tree preserves the keys without
/// registering that keyboard-scene tracking path.
///
/// Every key sends through `TerminalView.send` → the view delegate → the
/// controller's ordered input pump, so rail bytes can never reorder around
/// keystrokes. CTRL rides SwiftTerm's `controlModifier`, which the next typed
/// character consumes; the rail observes that reset to release its latch.
@MainActor
final class TerminalKeyBar: UIView, UIInputViewAudioFeedback {
    @Observable @MainActor
    final class Model {
        var ctrlLatched = false
    }

    static let barHeight: CGFloat = 48

    private weak var terminal: TerminalView?
    private let model = Model()
    private var host: UIHostingController<KeyBarRow>?

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        model.ctrlLatched = terminal.controlModifier

        let host = UIHostingController(rootView: KeyBarRow(
            model: model,
            press: { [weak self] key in self?.press(key) }
        ))
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

    var enableInputClicksWhenVisible: Bool { true }

    @objc private func controlModifierDidReset() {
        model.ctrlLatched = false
    }

    private func press(_ key: TerminalKey) {
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
        case .pageUp:
            click()
            terminal.send(EscapeSequences.cmdPageUp)
        case .pageDown:
            click()
            terminal.send(EscapeSequences.cmdPageDown)
        case .dismiss:
            _ = terminal.resignFirstResponder()
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
        guard let terminal, TerminalFocusArbiter.current === terminal else { return }
        for symbol in ["~", "|", "/", "-"] { press(.text(symbol)) }
        press(.ctrl)
        terminal.insertText("c")
    }
    #endif
}

private enum TerminalKey {
    case esc, ctrl, tab
    case text(String)
    case up, down, left, right
    case pageUp, pageDown
    case dismiss
}

/// The rail: modifiers left, shell symbols center, arrows + dismiss right.
/// Fixed-size keys so ViewThatFits can actually measure — when the bar is
/// narrow (a small Stage Manager window), keep the
/// path essentials (`~` and `/`) while dropping the less-used symbols first.
private struct KeyBarRow: View {
    var model: TerminalKeyBar.Model
    var press: (TerminalKey) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(symbols: ["~", "|", "/", "-"], withPageKeys: true)
            row(symbols: ["~", "/"], withPageKeys: true)
            row(symbols: ["~", "/"], withPageKeys: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Theme.bezel)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.bezelHi).frame(height: 1)
        }
    }

    private func row(symbols: [String], withPageKeys: Bool) -> some View {
        HStack(spacing: 6) {
            capsKey("ESC", .esc, "Escape")
            capsKey("CTRL", .ctrl, "Control", latched: model.ctrlLatched)
            capsKey("TAB", .tab, "Tab")
            Spacer(minLength: 12)
            if !symbols.isEmpty {
                ForEach(symbols, id: \.self) { symbol in
                    Key(action: { press(.text(symbol)) }, accessibilityText: symbol) {
                        Text(symbol).font(.mono(15))
                    }
                }
                Spacer(minLength: 12)
            }
            if withPageKeys {
                // Page keys scroll pagers and CLI-agent transcripts
                // (Claude Code pages with PgUp/PgDn); they autorepeat
                // like the arrows.
                arrowKey("arrow.up.to.line", .pageUp, "Page up")
                arrowKey("arrow.down.to.line", .pageDown, "Page down")
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
/// app.multiplexterm.multiplex.debug.keybar` runs the focused terminal's key-bar
/// proof sequence without touching the screen.
@MainActor
enum KeyBarDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.keybar", &token, .main
        ) { _ in
            guard let view = TerminalFocusArbiter.current,
                  let bar = view.superview?.subviews
                    .compactMap({ $0 as? TerminalKeyBar }).first
            else { return }
            bar.debugExercise()
        }
    }
}
#endif
#endif

#if os(visionOS)
import SwiftUI
import SwiftTerm
#if DEBUG
import notify
#endif

/// The visionOS terminal's key cluster — ESC, a latching CTRL, and TAB on a
/// chassis slab beside the UMD. The floating visionOS keyboard has none of
/// these keys and SwiftTerm plumbs no input accessory on visionOS, so the
/// window's bottom ornament carries them instead.
///
/// Same guarantees as the iPad key rail: every key sends through
/// `TerminalView.send` → the view delegate → the controller's ordered input
/// pump, and CTRL rides SwiftTerm's `controlModifier`, consumed by the next
/// character the keyboard types — the cluster observes the reset
/// notification to release the latch visual.
struct TerminalKeyCluster: View {
    var controller: TerminalSessionController?

    @State private var ctrlLatched = false

    private var terminal: TerminalView? { controller?.terminalView }

    var body: some View {
        HStack(spacing: 6) {
            key("ESC", "Escape") { $0.send(EscapeSequences.cmdEsc) }
            key("CTRL", "Control", latched: ctrlLatched) { terminal in
                let latched = !terminal.controlModifier
                terminal.controlModifier = latched
                ctrlLatched = latched
            }
            key("TAB", "Tab") { $0.send([0x09]) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.bezel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.bezelHi, lineWidth: 1))
        // SwiftTerm consumes the modifier on the next typed character.
        .onReceive(NotificationCenter.default.publisher(
            for: .terminalViewControlModifierReset
        )) { notification in
            if notification.object as? TerminalView === terminal {
                ctrlLatched = false
            }
        }
        // A tab switch swaps the terminal under the cluster — show the
        // incoming view's own latch state, not the outgoing tab's.
        .onChange(of: controller?.route.id) {
            ctrlLatched = terminal?.controlModifier ?? false
        }
        #if DEBUG
        .onAppear { KeyClusterDebugHook.install() }
        .onReceive(NotificationCenter.default.publisher(
            for: .multiplexDebugKeyCluster
        )) { _ in
            debugExercise()
        }
        #endif
    }

    #if DEBUG
    /// Headless proof sequence, iPad-keybar style: ESC and TAB through the
    /// cluster's own send path, then a latched CTRL consumed by a typed 'c'
    /// — `tmux capture-pane` on the attached session shows `^C`. Only the
    /// focused terminal's cluster reacts, so one notification never types
    /// into several shells.
    private func debugExercise() {
        guard let terminal, TerminalFocusArbiter.current === terminal else { return }
        terminal.send(EscapeSequences.cmdEsc)
        terminal.send([0x09])
        terminal.controlModifier = true
        ctrlLatched = true
        terminal.insertText("c")
    }
    #endif

    /// One key: the chassis-chip face at key proportions. Latched (sticky
    /// CTRL) inverts the face — prominence, not color, marks the held
    /// modifier, same as the iPad rail.
    private func key(
        _ label: String, _ accessibility: String, latched: Bool = false,
        press: @escaping (TerminalView) -> Void
    ) -> some View {
        Button {
            if let terminal { press(terminal) }
        } label: {
            Text(label)
                .font(.mono(9, weight: .semibold))
                .kerning(1.1)
                .foregroundStyle(latched ? Theme.chassis : Theme.signal2)
                .frame(width: 46, height: 26)
                .background(latched ? Theme.signal2 : Theme.chassis)
                .overlay(Rectangle().strokeBorder(
                    latched ? Theme.signal2 : Theme.bezelHi, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chassisHover(2)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(latched ? .isSelected : [])
    }
}

#if DEBUG
extension Notification.Name {
    static let multiplexDebugKeyCluster = Notification.Name("MultiplexDebugKeyCluster")
}

/// Headless-verification hook, same shape as the iPad `KeyBarDebugHook`:
/// `xcrun simctl spawn <udid> notifyutil -p
/// app.multiplexterm.multiplex.debug.keycluster` runs the focused terminal's
/// key-cluster proof sequence without touching the screen (visionOS ornament
/// buttons can't be driven synthetically).
@MainActor
enum KeyClusterDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.keycluster", &token, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugKeyCluster, object: nil)
        }
    }
}
#endif
#endif
