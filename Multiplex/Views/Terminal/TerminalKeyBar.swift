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
        /// Side safe areas the pane spans. The rail's bezel fills them; the
        /// keys stay inside, clear of the Dynamic Island and the corners.
        var contentSafeArea = EdgeInsets()
    }

    static let barHeight: CGFloat = 48

    /// Set by `SwiftTermView` whenever the shell's pane spans a side safe
    /// area — the keys inset, the bezel does not.
    var contentSafeArea: EdgeInsets {
        get { model.contentSafeArea }
        set { model.contentSafeArea = newValue }
    }

    private weak var terminal: TerminalView?
    private let performTmuxShortcut: (TmuxShortcut) -> Void
    private let finishTmuxCopyMode: () -> Void
    private let model = Model()
    private var host: UIHostingController<KeyBarRow>?
    private weak var tmuxPopoverController: UIViewController?

    init(
        terminal: TerminalView,
        performTmuxShortcut: @escaping (TmuxShortcut) -> Void,
        finishTmuxCopyMode: @escaping () -> Void
    ) {
        self.terminal = terminal
        self.performTmuxShortcut = performTmuxShortcut
        self.finishTmuxCopyMode = finishTmuxCopyMode
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
        TmuxShortcutDebugHook.install()
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
        case .showTmuxShortcuts:
            showTmuxShortcuts()
        case .tmux(let shortcut):
            click()
            performTmuxShortcut(shortcut)
        }
    }

    /// A SwiftUI popover accepts a keyboard-adjusted, full-height proposal
    /// when the floating iPad keyboard hugs a Stage Manager window. Present
    /// the same TALLY panel through UIKit so its measured content height is
    /// authoritative and cannot grow a blank tail over the app-owned rail.
    private func showTmuxShortcuts() {
        guard tmuxPopoverController == nil,
              let presenter = presentingViewController
        else { return }

        // Stage Manager can make an iPad scene compact enough that UIKit
        // would otherwise adapt this popover into a full-window form sheet.
        // Keep a real edge margin and let the shared panel fit the live scene.
        let sceneWidth = window?.bounds.width ?? presenter.view.bounds.width
        let panelWidth = min(
            TmuxShortcutPanel.preferredWidth,
            max(280, sceneWidth - 24)
        )
        let panel = TmuxShortcutPanel(width: panelWidth) { [weak self] shortcut in
            self?.tmuxPopoverController?.dismiss(animated: true)
            self?.press(.tmux(shortcut))
        }
        let controller = UIHostingController(rootView: panel)
        tmuxPopoverController = controller
        // Preserve the popover container boundary, but opt this app-owned
        // dropdown out of SwiftUI's keyboard safe area. A nearby floating
        // keyboard otherwise translates the grid after presentation, clipping
        // its top and leaving the displaced height as an empty bottom tail.
        controller.safeAreaRegions = .container
        controller.modalPresentationStyle = .popover
        controller.view.backgroundColor = UIColor(Theme.bezel)

        let fittingSize = controller.sizeThatFits(in: CGSize(
            width: panelWidth,
            height: UIScreen.main.bounds.height
        ))
        controller.preferredContentSize = CGSize(
            width: panelWidth,
            height: fittingSize.height
        )

        if let popover = controller.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = CGRect(
                x: bounds.maxX - 44,
                y: bounds.minY,
                width: 44,
                height: bounds.height
            )
            popover.permittedArrowDirections = .down
            popover.backgroundColor = UIColor(Theme.bezel)
            popover.delegate = self
        }
        presenter.present(controller, animated: true)
    }

    private var presentingViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    /// Arrows honor DECCKM the same way SwiftTerm's own key handling does.
    private func arrow(_ app: [UInt8], _ normal: [UInt8]) -> [UInt8] {
        terminal?.getTerminal().applicationCursor == true ? app : normal
    }

    private func click() {
        UIDevice.current.playInputClick()
    }

    #if DEBUG
    func debugShowTmuxShortcuts() {
        guard let terminal, TerminalFocusArbiter.current === terminal else { return }
        showTmuxShortcuts()
    }

    /// Sends Copy Mode through the same SwiftTerm delegate and ordered input
    /// pump used by a real shortcut-row press.
    func debugSendTmuxCopyMode() {
        guard let terminal, TerminalFocusArbiter.current === terminal else { return }
        press(.tmux(.copyMode))
    }

    /// Runs the contextual HUD's DONE action without synthesizing a screen
    /// tap, covering controller → SwiftTerm → ordered pump → tmux cancel.
    func debugFinishTmuxCopyMode() {
        guard let terminal, TerminalFocusArbiter.current === terminal else { return }
        finishTmuxCopyMode()
    }

    /// Physical-device control-path proof for the two destructive rows. The
    /// notification is the already-confirmed second activation; it enters the
    /// same `press(.tmux)` branch and controller closure as the real panel.
    func debugPerformConfirmedTmuxClose(_ shortcut: TmuxShortcut) {
        guard let terminal,
              TerminalFocusArbiter.current === terminal,
              shortcut.requiresDoubleActivation
        else { return }
        press(.tmux(shortcut))
    }

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

extension TerminalKeyBar: UIPopoverPresentationControllerDelegate {
    /// A compact Stage Manager scene still has room for the content-sized
    /// dropdown. Never replace the terminal with UIKit's adaptive form sheet.
    func adaptivePresentationStyle(
        for controller: UIPresentationController
    ) -> UIModalPresentationStyle {
        .none
    }

    func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle {
        .none
    }
}

private enum TerminalKey {
    case esc, ctrl, tab
    case text(String)
    case up, down, left, right
    case pageUp, pageDown
    case dismiss
    case showTmuxShortcuts
    case tmux(TmuxShortcut)
}

/// The rail: modifiers left, shell symbols center, arrows + dismiss right.
/// Fixed-size keys let ViewThatFits measure every tier honestly. The original
/// iPad ladder stays first; phone tiers compact the key metric only after page
/// keys and symbols are gone. Regular phones retain TMUX; the final 375-point
/// tier drops it while every terminal lifeline key remains available.
private struct KeyBarRow: View {
    var model: TerminalKeyBar.Model
    var press: (TerminalKey) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(symbols: ["~", "|", "/", "-"], withPageKeys: true)
                .padding(.horizontal, 8)
            row(symbols: ["~", "/"], withPageKeys: true)
                .padding(.horizontal, 8)
            row(symbols: ["~", "/"], withPageKeys: false)
                .padding(.horizontal, 8)
            row(symbols: [], withPageKeys: false)
                .padding(.horizontal, 8)
            row(
                symbols: [],
                withPageKeys: false,
                showsTmux: true,
                metric: .compactWithTmux
            )
            .padding(.horizontal, 1)
            row(
                symbols: [],
                withPageKeys: false,
                showsTmux: false,
                metric: .compact
            )
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 7)
        // Inside the ViewThatFits' proposal, so a pane spanning the Island's
        // band still measures its tiers against the width the keys can use —
        // and outside the background, which keeps running to the edge.
        .padding(.leading, model.contentSafeArea.leading)
        .padding(.trailing, model.contentSafeArea.trailing)
        .frame(maxWidth: .infinity)
        .background(Theme.bezel)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.bezelHi).frame(height: 1)
        }
    }

    private func row(
        symbols: [String],
        withPageKeys: Bool,
        showsTmux: Bool = true,
        metric: KeyMetric = .regular
    ) -> some View {
        HStack(spacing: metric.spacing) {
            capsKey("ESC", .esc, "Escape", metric: metric)
            capsKey(
                "CTRL",
                .ctrl,
                "Control",
                latched: model.ctrlLatched,
                metric: metric
            )
            capsKey("TAB", .tab, "Tab", metric: metric)
            Spacer(minLength: metric.groupGap)
            if !symbols.isEmpty {
                ForEach(symbols, id: \.self) { symbol in
                    Key(
                        action: { press(.text(symbol)) },
                        width: metric.keyWidth,
                        accessibilityText: symbol
                    ) {
                        Text(symbol).font(.mono(15))
                    }
                }
                Spacer(minLength: metric.groupGap)
            }
            if withPageKeys {
                // Page keys scroll pagers and CLI-agent transcripts
                // (Claude Code pages with PgUp/PgDn); they autorepeat
                // like the arrows.
                arrowKey("arrow.up.to.line", .pageUp, "Page up", metric: metric)
                arrowKey("arrow.down.to.line", .pageDown, "Page down", metric: metric)
            }
            arrowKey("arrow.left", .left, "Arrow left", metric: metric)
            arrowKey("arrow.down", .down, "Arrow down", metric: metric)
            arrowKey("arrow.up", .up, "Arrow up", metric: metric)
            arrowKey("arrow.right", .right, "Arrow right", metric: metric)
            Key(
                action: { press(.dismiss) },
                width: metric.keyWidth,
                accessibilityText: "Hide keyboard"
            ) {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 13, weight: .semibold))
            }
            if showsTmux {
                // Keep the tmux dropdown at the rail's trailing edge until
                // the essentials-only phone tier takes over.
                Key(
                    action: { press(.showTmuxShortcuts) },
                    width: metric.keyWidth,
                    accessibilityText: "Show tmux shortcuts"
                ) {
                    Text("TMUX").font(.mono(9, weight: .semibold)).kerning(0.7)
                }
            }
        }
    }

    private func capsKey(
        _ label: String,
        _ key: TerminalKey,
        _ accessibility: String,
        latched: Bool = false,
        metric: KeyMetric = .regular
    ) -> some View {
        Key(
            action: { press(key) },
            width: metric.keyWidth,
            latched: latched,
            accessibilityText: accessibility
        ) {
            Text(label).font(.mono(11, weight: .semibold)).kerning(1.1)
        }
    }

    private func arrowKey(
        _ icon: String,
        _ key: TerminalKey,
        _ accessibility: String,
        metric: KeyMetric = .regular
    ) -> some View {
        Key(
            action: { press(key) },
            width: metric.keyWidth,
            repeats: true,
            accessibilityText: accessibility
        ) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
        }
    }

    private struct KeyMetric {
        let keyWidth: CGFloat
        let spacing: CGFloat
        let groupGap: CGFloat

        static let regular = KeyMetric(keyWidth: 46, spacing: 6, groupGap: 12)
        static let compactWithTmux = KeyMetric(
            keyWidth: 40,
            spacing: 3,
            groupGap: 1
        )
        static let compact = KeyMetric(keyWidth: 40, spacing: 4, groupGap: 4)
    }
}

/// One key: a chassis chip scaled to a touch target. Latched (sticky CTRL)
/// inverts the face — prominence, not color, marks the held modifier.
private struct Key<Label: View>: View {
    var action: () -> Void
    var width: CGFloat = 46
    var repeats = false
    var latched = false
    var accessibilityText: String
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: width, height: 34)
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
/// Opens the focused iPad terminal's tmux shortcut popover for real-device
/// and simulator layout capture without synthesizing a screen tap.
@MainActor
enum TmuxShortcutDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.tmuxshortcuts", &token, .main
        ) { _ in
            guard let view = TerminalFocusArbiter.current,
                  let bar = view.superview?.subviews
                    .compactMap({ $0 as? TerminalKeyBar }).first
            else { return }
            bar.debugShowTmuxShortcuts()
        }

        var copyToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.tmuxcopy", &copyToken, .main
        ) { _ in
            guard let view = TerminalFocusArbiter.current,
                  let bar = view.superview?.subviews
                    .compactMap({ $0 as? TerminalKeyBar }).first
            else { return }
            bar.debugSendTmuxCopyMode()
        }

        var copyDoneToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.tmuxcopydone", &copyDoneToken, .main
        ) { _ in
            guard let view = TerminalFocusArbiter.current,
                  let bar = view.superview?.subviews
                    .compactMap({ $0 as? TerminalKeyBar }).first
            else { return }
            bar.debugFinishTmuxCopyMode()
        }

        var closePaneToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.tmuxclosepane",
            &closePaneToken,
            .main
        ) { _ in
            guard let view = TerminalFocusArbiter.current,
                  let bar = view.superview?.subviews
                    .compactMap({ $0 as? TerminalKeyBar }).first
            else { return }
            bar.debugPerformConfirmedTmuxClose(.closePane)
        }

        var closeWindowToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.tmuxclosewindow",
            &closeWindowToken,
            .main
        ) { _ in
            guard let view = TerminalFocusArbiter.current,
                  let bar = view.superview?.subviews
                    .compactMap({ $0 as? TerminalKeyBar }).first
            else { return }
            bar.debugPerformConfirmedTmuxClose(.closeWindow)
        }
    }
}

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

#if DEBUG
#Preview("iPad Key Bar") {
    KeyBarRow(
        model: TerminalKeyBar.Model(),
        press: { _ in }
    )
    .frame(width: 1024, height: TerminalKeyBar.barHeight)
}

#Preview("Compact Key Bar") {
    KeyBarRow(
        model: TerminalKeyBar.Model(),
        press: { _ in }
    )
    .frame(width: 390, height: TerminalKeyBar.barHeight)
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

#Preview("Terminal Key Cluster") {
    TerminalKeyCluster(controller: nil)
        .padding()
}
#endif
#endif
