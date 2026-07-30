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
    private weak var controller: TerminalSessionController?
    private let performTmuxShortcut: (TmuxShortcut) -> Void
    private let finishTmuxCopyMode: () -> Void
    private let showsTmuxShortcuts: Bool
    private let model = Model()
    private var host: UIHostingController<KeyBarRow>?
    private weak var tmuxPopoverController: UIViewController?

    init(
        terminal: TerminalView,
        controller: TerminalSessionController?,
        performTmuxShortcut: @escaping (TmuxShortcut) -> Void,
        finishTmuxCopyMode: @escaping () -> Void,
        showsTmuxShortcuts: Bool
    ) {
        self.terminal = terminal
        self.controller = controller
        self.performTmuxShortcut = performTmuxShortcut
        self.finishTmuxCopyMode = finishTmuxCopyMode
        self.showsTmuxShortcuts = showsTmuxShortcuts
        super.init(frame: .zero)
        model.ctrlLatched = terminal.controlModifier
        // The rightmost key depends on whether a physical keyboard is
        // attached, which can change at any moment (a Magic Keyboard is
        // detached mid-session all the time).
        HardwareKeyboardMonitor.shared.startIfNeeded()

        let host = UIHostingController(rootView: KeyBarRow(
            model: model,
            controller: controller,
            hardwareKeyboard: HardwareKeyboardMonitor.shared,
            showsTmuxShortcuts: showsTmuxShortcuts,
            showsReturnKey: UIDevice.current.userInterfaceIdiom == .pad,
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
        case .returnKey:
            click()
            terminal.send([0x0D])
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
        case .keyboard:
            TerminalFocusArbiter.toggle(terminal)
        case .lockKeyboard:
            click()
            TerminalFocusArbiter.lock(terminal)
        case .dictation:
            controller?.toggleDictation()
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

    /// Presses the rail's dictation key without touching the screen. The
    /// simulator can be pointed at the Mac's microphone (Device → Audio
    /// Input), so this drives the whole authorization → mic → recognizer →
    /// ordered-pump path; the attached session's `tmux capture-pane` shows
    /// the transcribed words typed at the prompt.
    func debugToggleDictation() {
        guard let terminal, TerminalFocusArbiter.current === terminal else { return }
        press(.dictation)
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
    case esc, ctrl, tab, returnKey
    case text(String)
    case up, down, left, right
    case pageUp, pageDown
    case keyboard
    case lockKeyboard
    case dictation
    case showTmuxShortcuts
    case tmux(TmuxShortcut)
}

/// The rail: modifiers left, shell symbols center, then arrows, an iPad-only
/// RET key, and the keyboard toggle on the right.
/// Fixed-size keys let ViewThatFits measure every tier honestly. The original
/// iPad ladder stays first; phone tiers compact the key metric only after page
/// keys and symbols are gone. Regular phones retain TMUX; below 390 points the
/// essentials-only tier drops it while every terminal lifeline key remains
/// available, and the iPhone shell moves the shortcut to its top-right bar.
private struct KeyBarRow: View {
    var model: TerminalKeyBar.Model
    /// Only for the dictation key's live state; every key still sends
    /// through the bar's own `TerminalView` path.
    var controller: TerminalSessionController?
    var hardwareKeyboard: HardwareKeyboardMonitor
    var showsTmuxShortcuts: Bool
    var showsReturnKey: Bool
    var press: (TerminalKey) -> Void
    /// The keyboard key doubles as the lock control: read here so the face
    /// flips to the latched lock the moment the arbiter engages it.
    private let keyboardLock = KeyboardLock.shared

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(symbols: ["~", "|", "/", "-"], withPageKeys: true, showsTmux: showsTmuxShortcuts)
                .padding(.horizontal, 8)
            row(symbols: ["~", "/"], withPageKeys: true, showsTmux: showsTmuxShortcuts)
                .padding(.horizontal, 8)
            row(symbols: ["~", "/"], withPageKeys: false, showsTmux: showsTmuxShortcuts)
                .padding(.horizontal, 8)
            row(symbols: [], withPageKeys: false, showsTmux: showsTmuxShortcuts)
                .padding(.horizontal, 8)
            if showsTmuxShortcuts {
                row(
                    symbols: [],
                    withPageKeys: false,
                    showsTmux: true,
                    metric: .compactTight
                )
                .padding(.horizontal, 8)
            }
            row(
                symbols: [],
                withPageKeys: false,
                showsTmux: false,
                metric: showsReturnKey ? .compactTight : .compact
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
        // RET adds one key on iPad. Slightly smaller minimum group gaps keep
        // PgUp/PgDn in the standard 768-point portrait tier; at wider sizes
        // the Spacers expand exactly as before.
        let groupGap = showsReturnKey ? min(metric.groupGap, 8) : metric.groupGap

        return HStack(spacing: metric.spacing) {
            capsKey("ESC", .esc, "Escape", metric: metric)
            capsKey(
                "CTRL",
                .ctrl,
                "Control",
                latched: model.ctrlLatched,
                metric: metric
            )
            capsKey("TAB", .tab, "Tab", metric: metric)
            Spacer(minLength: groupGap)
            if !symbols.isEmpty {
                ForEach(symbols, id: \.self) { symbol in
                    Key(
                        action: { press(.text(symbol)) },
                        width: metric.keyWidth,
                        faceHorizontalInset: metric.faceHorizontalInset,
                        accessibilityText: symbol
                    ) {
                        Text(symbol).font(.mono(15))
                    }
                }
                Spacer(minLength: groupGap)
            }
            if withPageKeys {
                // Page keys scroll pagers and CLI-agent transcripts
                // (Claude Code pages with PgUp/PgDn); they autorepeat
                // like the arrows.
                arrowKey("arrow.up.to.line", .pageUp, "Page up", metric: metric)
                arrowKey("arrow.down.to.line", .pageDown, "Page down", metric: metric)
            }
            arrowKey("arrow.left", .left, "Arrow left", metric: metric)
            arrowKey("arrow.up", .up, "Arrow up", metric: metric)
            arrowKey("arrow.down", .down, "Arrow down", metric: metric)
            arrowKey("arrow.right", .right, "Arrow right", metric: metric)
            if showsReturnKey {
                capsKey("RET", .returnKey, "Return", metric: metric)
            }
            // A physical keyboard suppresses the software one outright, so
            // the toggle has nothing left to toggle. Spend the slot on the
            // affordance the hardware keyboard genuinely lacks instead —
            // the mic key the software keyboard would have carried.
            if hardwareKeyboard.isConnected {
                let listening = controller?.isDictating == true
                Key(
                    action: { press(.dictation) },
                    width: metric.keyWidth,
                    faceHorizontalInset: metric.faceHorizontalInset,
                    latched: listening,
                    accessibilityText: listening ? "Stop dictation" : "Dictate"
                ) {
                    Image(systemName: listening ? "mic.fill" : "mic")
                        .font(.ui(13, weight: .semibold))
                }
            } else {
                // Short press toggles the keyboard (or unlocks a locked
                // one); a long press locks it so terminal taps stop
                // summoning it. Locked wears the latched face + a padlock.
                let locked = keyboardLock.isLocked
                Key(
                    action: { press(.keyboard) },
                    width: metric.keyWidth,
                    faceHorizontalInset: metric.faceHorizontalInset,
                    latched: locked,
                    longPressAction: locked ? nil : { press(.lockKeyboard) },
                    accessibilityText: locked
                        ? "Unlock keyboard"
                        : "Show or hide keyboard. Hold to lock the keyboard closed"
                ) {
                    Image(systemName: locked ? "lock.fill" : "keyboard")
                        .font(.ui(13, weight: .semibold))
                }
            }
            if showsTmux {
                // Keep the tmux dropdown at the rail's trailing edge until
                // the essentials-only phone tier takes over.
                Key(
                    action: { press(.showTmuxShortcuts) },
                    width: metric.keyWidth,
                    faceHorizontalInset: metric.faceHorizontalInset,
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
            faceHorizontalInset: metric.faceHorizontalInset,
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
            faceHorizontalInset: metric.faceHorizontalInset,
            repeats: true,
            accessibilityText: accessibility
        ) {
            Image(systemName: icon).font(.ui(12, weight: .semibold))
        }
    }

    private struct KeyMetric {
        let keyWidth: CGFloat
        let spacing: CGFloat
        let groupGap: CGFloat
        var faceHorizontalInset: CGFloat = 0

        static let regular = KeyMetric(keyWidth: 46, spacing: 6, groupGap: 12)
        // Preserve 40-point hit regions while narrowing only their visible
        // faces. The tighter transparent gaps fit either the phone's 390-point
        // TMUX tier or the iPad's RET-bearing essentials tier without crowding
        // a face directly against the screen edge.
        static let compactTight = KeyMetric(
            keyWidth: 40,
            spacing: 1,
            groupGap: 1,
            faceHorizontalInset: 1
        )
        static let compact = KeyMetric(keyWidth: 40, spacing: 4, groupGap: 4)
    }
}

/// One key: a chassis chip scaled to a touch target. Latched (sticky CTRL)
/// inverts the face — prominence, not color, marks the held modifier.
private struct Key<Label: View>: View {
    var action: () -> Void
    var width: CGFloat = 46
    var faceHorizontalInset: CGFloat = 0
    var repeats = false
    var latched = false
    /// A second, hold-to-fire action (the keyboard key's lock). Keys with
    /// one carry their own tap + long-press pair instead of a Button — a
    /// gesture riding alongside a Button cannot reliably suppress the
    /// button's touch-up action after the hold fires.
    var longPressAction: (() -> Void)? = nil
    var accessibilityText: String
    @ViewBuilder var label: () -> Label

    @State private var holding = false

    var body: some View {
        if let longPressAction {
            label()
                .frame(
                    width: width - (faceHorizontalInset * 2),
                    height: 34
                )
                .foregroundStyle(latched ? Theme.chassis : Theme.signal2)
                .background(latched ? Theme.signal2
                    : holding ? Theme.bezelHi : Theme.chassis)
                .overlay(Rectangle().strokeBorder(
                    latched ? Theme.signal2 : Theme.bezelHi, lineWidth: 1))
                .padding(.horizontal, faceHorizontalInset)
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
                .onLongPressGesture(
                    minimumDuration: 0.5,
                    perform: {
                        holding = false
                        longPressAction()
                    },
                    onPressingChanged: { holding = $0 }
                )
                .chassisHover(2)
                .accessibilityLabel(accessibilityText)
                .accessibilityAddTraits(latched ? .isSelected : [])
        } else {
            Button(action: action) {
                label()
                    .frame(
                        width: width - (faceHorizontalInset * 2),
                        height: 34
                    )
            }
            .buttonStyle(KeyFace(
                latched: latched,
                horizontalHitPadding: faceHorizontalInset
            ))
            .buttonRepeatBehavior(repeats ? .enabled : .disabled)
            .chassisHover(2)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(latched ? .isSelected : [])
        }
    }
}

private struct KeyFace: ButtonStyle {
    var latched: Bool
    var horizontalHitPadding: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(latched ? Theme.chassis : Theme.signal2)
            .background(latched ? Theme.signal2
                : configuration.isPressed ? Theme.bezelHi : Theme.chassis)
            .overlay(Rectangle().strokeBorder(
                latched ? Theme.signal2 : Theme.bezelHi, lineWidth: 1))
            .padding(.horizontal, horizontalHitPadding)
            .contentShape(Rectangle())
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

        var dictationToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.dictation", &dictationToken, .main
        ) { _ in
            guard let view = TerminalFocusArbiter.current,
                  let bar = view.superview?.subviews
                    .compactMap({ $0 as? TerminalKeyBar }).first
            else { return }
            bar.debugToggleDictation()
        }
    }
}
#endif

#if DEBUG
#Preview("iPad Key Bar") {
    KeyBarRow(
        model: TerminalKeyBar.Model(),
        controller: nil,
        hardwareKeyboard: HardwareKeyboardMonitor.shared,
        showsTmuxShortcuts: true,
        showsReturnKey: true,
        press: { _ in }
    )
    .frame(width: 1024, height: TerminalKeyBar.barHeight)
}

#Preview("Compact Key Bar") {
    KeyBarRow(
        model: TerminalKeyBar.Model(),
        controller: nil,
        hardwareKeyboard: HardwareKeyboardMonitor.shared,
        showsTmuxShortcuts: true,
        showsReturnKey: false,
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

/// The visionOS terminal's key cluster — ESC, a latching CTRL, TAB, the
/// DECCKM-aware autorepeat arrows, RET, and the keyboard toggle as chassis
/// slabs in the window's bottom ornament. The floating visionOS keyboard has
/// none of these keys and SwiftTerm plumbs no input accessory on visionOS,
/// so the window's chrome carries them instead; arrows + RET are how a CLI
/// agent's option picker is driven without summoning the keyboard at all.
///
/// Two layouts, one instance either way (the latch state and the DEBUG
/// proof hook must have a single owner per window): standalone, the
/// original single slab (the shell overlay's key row), or flanking a
/// `center` row — the classic window's UMD — with ESC/CTRL/TAB on its left
/// and the navigation keys on its right, so the ornament spends one console
/// line on keys and window controls together.
///
/// Same guarantees as the iPad key rail: every key sends through
/// `TerminalView.send` → the view delegate → the controller's ordered input
/// pump, and CTRL rides SwiftTerm's `controlModifier`, consumed by the next
/// character the keyboard types — the cluster observes the reset
/// notification to release the latch visual.
struct TerminalKeyCluster<Center: View>: View {
    var controller: TerminalSessionController?

    /// The row the keys flank (the classic window's UMD); nil renders the
    /// original standalone slab.
    private let center: Center?

    @State private var ctrlLatched = false

    private var terminal: TerminalView? { controller?.terminalView }

    init(
        controller: TerminalSessionController?,
        @ViewBuilder center: () -> Center
    ) {
        self.controller = controller
        self.center = center()
    }

    var body: some View {
        layout
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

    private typealias Metric = KeyClusterMetric

    @ViewBuilder
    private var layout: some View {
        if let center {
            // One console row at EVERY width: key faces compact first, and
            // when even compact overflows the caller's clamp the row keeps
            // its ideal width and spills past the window edges symmetrically
            // — the shipped unclamped UMD's own narrow-window behavior.
            // ViewThatFits compares each tier's IDEAL width against the
            // proposal, so the fixedSize floor is only reached when compact
            // genuinely cannot fit; without fixedSize the last tier would
            // instead compress the UMD (title truncated to "AGEN…").
            // A restacked keys-under-UMD fallback was tried and rejected:
            // ornament content hanging ~100 pt below the anchor is clipped
            // by the system at compact window widths — the key row rendered
            // as an unusable sliver (2026-07, simulator-verified).
            ViewThatFits(in: .horizontal) {
                consoleRow(center, metric: .regular)
                consoleRow(center, metric: .compact)
                consoleRow(center, metric: .compact)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } else {
            standaloneSlab
        }
    }

    /// ESC/CTRL/TAB ride one slab left of the center row, the navigation
    /// keys another on its right. Slab padding (9) around the 26 pt key
    /// faces matches the UMD's height, so the three slabs read as one
    /// console line.
    private func consoleRow(_ center: Center, metric: Metric) -> some View {
        HStack(spacing: 10) {
            slab {
                HStack(spacing: metric.spacing) {
                    escKey(metric)
                    ctrlKey(metric)
                    tabKey(metric)
                }
            }
            center
            slab {
                HStack(spacing: metric.groupGap) {
                    arrowGroup(metric)
                    retKey(metric)
                    keyboardToggleKey(metric)
                }
            }
        }
    }

    private var standaloneSlab: some View {
        slab {
            // Ornaments propose unbounded width, so a classic window always
            // gets the regular tier; the tiers exist for the (debug-forced)
            // shell, whose pane can be phone-narrow. Faces compact before
            // any key leaves the cluster; the floor keeps the original trio
            // plus RET and the keyboard toggle — the window's only keyboard
            // control.
            ViewThatFits(in: .horizontal) {
                row(.regular)
                row(.compact)
                row(.compact, minimal: true)
            }
        }
    }

    private func slab(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.bezel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.bezelHi, lineWidth: 1))
    }

    private func row(_ metric: Metric, minimal: Bool = false) -> some View {
        HStack(spacing: metric.groupGap) {
            HStack(spacing: metric.spacing) {
                escKey(metric)
                ctrlKey(metric)
                tabKey(metric)
            }
            if !minimal {
                arrowGroup(metric)
            }
            retKey(metric)
            keyboardToggleKey(metric)
        }
    }

    private func escKey(_ metric: Metric) -> some View {
        capsKey("ESC", "Escape", metric: metric) {
            $0.send(EscapeSequences.cmdEsc)
        }
    }

    private func ctrlKey(_ metric: Metric) -> some View {
        capsKey("CTRL", "Control", latched: ctrlLatched, metric: metric) { terminal in
            let latched = !terminal.controlModifier
            terminal.controlModifier = latched
            ctrlLatched = latched
        }
    }

    private func tabKey(_ metric: Metric) -> some View {
        capsKey("TAB", "Tab", metric: metric) { $0.send([0x09]) }
    }

    private func arrowGroup(_ metric: Metric) -> some View {
        HStack(spacing: metric.spacing) {
            arrowKey(
                "arrow.left", "Arrow left", metric: metric,
                app: EscapeSequences.moveLeftApp,
                normal: EscapeSequences.moveLeftNormal)
            arrowKey(
                "arrow.up", "Arrow up", metric: metric,
                app: EscapeSequences.moveUpApp,
                normal: EscapeSequences.moveUpNormal)
            arrowKey(
                "arrow.down", "Arrow down", metric: metric,
                app: EscapeSequences.moveDownApp,
                normal: EscapeSequences.moveDownNormal)
            arrowKey(
                "arrow.right", "Arrow right", metric: metric,
                app: EscapeSequences.moveRightApp,
                normal: EscapeSequences.moveRightNormal)
        }
    }

    private func retKey(_ metric: Metric) -> some View {
        capsKey("RET", "Return", metric: metric) { $0.send([0x0D]) }
    }

    private func keyboardToggleKey(_ metric: Metric) -> some View {
        TerminalClusterKey(
            face: .icon("keyboard"),
            accessibility: "Show or hide keyboard",
            width: metric.keyWidth,
            action: { controller?.toggleKeyboard() }
        )
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

    private func capsKey(
        _ label: String, _ accessibility: String, latched: Bool = false,
        metric: Metric,
        press: @escaping (TerminalView) -> Void
    ) -> some View {
        TerminalClusterKey(
            face: .caps(label),
            accessibility: accessibility,
            width: metric.keyWidth,
            latched: latched
        ) {
            if let terminal { press(terminal) }
        }
    }

    /// Arrows honor DECCKM the same way SwiftTerm's own key handling does,
    /// and autorepeat while held like the iPad rail's.
    private func arrowKey(
        _ icon: String, _ accessibility: String, metric: Metric,
        app: [UInt8], normal: [UInt8]
    ) -> some View {
        TerminalClusterKey(
            face: .icon(icon),
            accessibility: accessibility,
            width: metric.keyWidth,
            repeats: true
        ) {
            guard let terminal else { return }
            terminal.send(terminal.getTerminal().applicationCursor ? app : normal)
        }
    }
}

/// Key sizing tiers, hoisted out of the generic cluster (generic types
/// cannot hold static stored properties).
private struct KeyClusterMetric {
    let keyWidth: CGFloat
    let spacing: CGFloat
    let groupGap: CGFloat

    static let regular = KeyClusterMetric(keyWidth: 46, spacing: 6, groupGap: 12)
    static let compact = KeyClusterMetric(keyWidth: 36, spacing: 4, groupGap: 8)
}

/// The standalone slab — the shell overlay's key row, with no UMD to flank.
extension TerminalKeyCluster where Center == EmptyView {
    init(controller: TerminalSessionController?) {
        self.controller = controller
        self.center = nil
    }
}

/// One monitor key: the chassis-chip face at key proportions. Latched
/// (sticky CTRL) inverts the face — prominence, not color, marks the held
/// modifier, same as the iPad rail.
struct TerminalClusterKey: View {
    enum Face {
        case caps(String)
        case icon(String)
    }

    var face: Face
    var accessibility: String
    var width: CGFloat = 46
    var repeats = false
    var latched = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            faceView
                .foregroundStyle(latched ? Theme.chassis : Theme.signal2)
                .frame(width: width, height: 26)
                .background(latched ? Theme.signal2 : Theme.chassis)
                .overlay(Rectangle().strokeBorder(
                    latched ? Theme.signal2 : Theme.bezelHi, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(repeats ? .enabled : .disabled)
        .chassisHover(2)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(latched ? .isSelected : [])
    }

    @ViewBuilder
    private var faceView: some View {
        switch face {
        case .caps(let label):
            Text(label)
                .font(.mono(9, weight: .semibold))
                .kerning(1.1)
        case .icon(let systemName):
            Image(systemName: systemName)
                .font(.ui(12, weight: .semibold))
        }
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
