import Observation
import SwiftTerm
import UIKit
#if DEBUG
import notify
#endif

/// Native key face shared by the iPad rail and the visionOS ornament. The
/// transparent control can stay at a full touch target while `faceInset`
/// narrows only the painted chassis face in the compact phone tiers.
@MainActor
final class TerminalTallyKeyControl: UIControl {
    enum Face {
        case text(String, font: UIFont, kerning: CGFloat)
        case symbol(String, pointSize: CGFloat, weight: UIImage.SymbolWeight)
    }

    var isLatched = false {
        didSet { refreshAppearance() }
    }
    var faceInset: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }
    var repeats = false
    var longPressAction: (() -> Void)? {
        didSet { configureLongPress() }
    }
    var preferredSize: CGSize {
        didSet { invalidateIntrinsicContentSize() }
    }

    private let faceView = UIKitTallyBorderedView()
    private let textLabel = UILabel()
    private let symbolView = UIImageView()
    private let primaryAction: () -> Void
    private var repeatDelayTimer: Timer?
    private var repeatTimer: Timer?
    private var didRepeat = false
    private var didLongPress = false
    private weak var longPressRecognizer: UILongPressGestureRecognizer?

    init(
        face: Face,
        width: CGFloat,
        height: CGFloat,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        repeats: Bool = false,
        latched: Bool = false,
        faceInset: CGFloat = 0,
        longPressAction: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) {
        preferredSize = CGSize(width: width, height: height)
        primaryAction = action
        self.repeats = repeats
        isLatched = latched
        self.faceInset = faceInset
        self.longPressAction = longPressAction
        super.init(frame: .zero)

        isAccessibilityElement = true
        accessibilityTraits = .button
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))

        faceView.isUserInteractionEnabled = false
        addSubview(faceView)
        textLabel.textAlignment = .center
        textLabel.numberOfLines = 1
        faceView.addSubview(textLabel)
        symbolView.contentMode = .center
        faceView.addSubview(symbolView)

        switch face {
        case .text(let text, let font, let kerning):
            textLabel.attributedText = NSAttributedString(
                string: text,
                attributes: [.font: font, .kern: kerning]
            )
            symbolView.isHidden = true
        case .symbol(let name, let pointSize, let weight):
            textLabel.isHidden = true
            symbolView.image = UIImage(
                systemName: name,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: pointSize * Theme.typeScale,
                    weight: weight
                )
            )
        }

        addTarget(self, action: #selector(pressBegan), for: .touchDown)
        addTarget(self, action: #selector(pressEntered), for: .touchDragEnter)
        addTarget(self, action: #selector(pressExited), for: .touchDragExit)
        addTarget(self, action: #selector(pressEndedInside), for: .touchUpInside)
        addTarget(
            self,
            action: #selector(pressCancelled),
            for: [.touchUpOutside, .touchCancel]
        )
        configureLongPress()
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var intrinsicContentSize: CGSize { preferredSize }

    override var isHighlighted: Bool {
        didSet { refreshAppearance() }
    }

    override var isEnabled: Bool {
        didSet { refreshAppearance() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        faceView.frame = bounds.insetBy(dx: faceInset, dy: 0)
        textLabel.frame = faceView.bounds
        symbolView.frame = faceView.bounds
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshAppearance()
    }

    override func accessibilityActivate() -> Bool {
        primaryAction()
        return true
    }

    @objc private func pressBegan() {
        isHighlighted = true
        didRepeat = false
        didLongPress = false
        scheduleRepeatIfNeeded()
    }

    @objc private func pressEntered() {
        isHighlighted = true
        scheduleRepeatIfNeeded()
    }

    @objc private func pressExited() {
        isHighlighted = false
        cancelRepeat()
    }

    @objc private func pressEndedInside() {
        isHighlighted = false
        cancelRepeat()
        guard !didRepeat, !didLongPress else { return }
        primaryAction()
    }

    @objc private func pressCancelled() {
        isHighlighted = false
        cancelRepeat()
    }

    @objc private func beginRepeating() {
        guard isHighlighted, repeats else { return }
        didRepeat = true
        primaryAction()
        repeatTimer = Timer.scheduledTimer(
            timeInterval: 0.08,
            target: self,
            selector: #selector(repeatTick),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func repeatTick() {
        guard isHighlighted else {
            cancelRepeat()
            return
        }
        primaryAction()
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            didLongPress = true
            cancelRepeat()
            longPressAction?()
        case .ended, .cancelled, .failed:
            isHighlighted = false
        default:
            break
        }
    }

    private func scheduleRepeatIfNeeded() {
        guard repeats, repeatDelayTimer == nil, repeatTimer == nil else { return }
        repeatDelayTimer = Timer.scheduledTimer(
            timeInterval: 0.45,
            target: self,
            selector: #selector(beginRepeating),
            userInfo: nil,
            repeats: false
        )
    }

    private func cancelRepeat() {
        repeatDelayTimer?.invalidate()
        repeatDelayTimer = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func configureLongPress() {
        if longPressAction == nil {
            if let longPressRecognizer { removeGestureRecognizer(longPressRecognizer) }
            longPressRecognizer = nil
            return
        }
        guard longPressRecognizer == nil else { return }
        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(longPressed(_:))
        )
        recognizer.minimumPressDuration = 0.5
        recognizer.cancelsTouchesInView = false
        addGestureRecognizer(recognizer)
        longPressRecognizer = recognizer
    }

    private func refreshAppearance() {
        accessibilityTraits = isLatched ? [.button, .selected] : .button
        alpha = isEnabled ? 1 : 0.45
        let foreground = isLatched ? UIKitChassis.chassis : UIKitChassis.signal2
        textLabel.textColor = foreground
        symbolView.tintColor = foreground
        // PROTOTYPE(GLASS): resting key faces take the chip treatment —
        // strata over the smoke — under the GLASS selection; every other
        // appearance keeps the opaque chassis face. Latched and highlighted
        // states already resolve through glass-aware accessors.
        let restingFace = GlassPrototype.enabled
            ? GlassPrototype.material(
                GlassPrototype.strataMaterial,
                fallback: TallyPalette.chassis
            )
            : UIKitChassis.chassis
        faceView.backgroundColor = isLatched
            ? UIKitChassis.signal2
            : isHighlighted ? UIKitChassis.bezelHi : restingFace
        faceView.tallyBorderColor = isLatched
            ? UIKitChassis.signal2
            : UIKitChassis.bezelHi
    }
}

/// Native C/B slab used by both CTRL implementations. iPad installs it
/// synchronously in the terminal window; visionOS presents the same view in
/// a content-sized UIKit popover above the ornament.
@MainActor
final class TerminalCtrlComboView: UIKitTallyBorderedView {
    private let stack = UIStackView()
    private let faceHeight: CGFloat
    private let padding: CGFloat
    private(set) var keys: [TerminalTallyKeyControl] = []

    init(
        faceHeight: CGFloat,
        padding: CGFloat,
        fontSize: CGFloat,
        fontWeight: UIFont.Weight = .regular,
        kerning: CGFloat = 0,
        send: @escaping (String) -> Void
    ) {
        self.faceHeight = faceHeight
        self.padding = padding
        super.init(frame: .zero)
        // PROTOTYPE(GLASS): on visionOS this slab presents in a popover
        // over the popover's own bright platter — ground it in smoke so
        // the strata key faces read (iPad hosts it in-window and keeps the
        // baseline bezel via the fallback).
        backgroundColor = GlassPrototype.popoverGround(
            fallback: TallyPalette.bezel
        )
        tallyBorderColor = UIKitChassis.bezelHi
        accessibilityIdentifier = "terminal.ctrlCombos"

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])

        for letter in ["c", "b"] {
            let key = TerminalTallyKeyControl(
                face: .text(
                    letter.uppercased(),
                    font: UIKitChassis.monoFont(fontSize, weight: fontWeight),
                    kerning: kerning
                ),
                width: 46,
                height: faceHeight,
                accessibilityLabel: "Control \(letter.uppercased())",
                accessibilityIdentifier: "terminal.ctrlCombos.\(letter)",
                action: { send(letter) }
            )
            keys.append(key)
            stack.addArrangedSubview(key)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 46 * 2 + 6 + padding * 2, height: faceHeight + padding * 2)
    }
}

@MainActor
final class TerminalCtrlComboViewController: UIViewController {
    private let comboView: TerminalCtrlComboView

    init(
        faceHeight: CGFloat,
        padding: CGFloat,
        fontSize: CGFloat,
        fontWeight: UIFont.Weight = .regular,
        kerning: CGFloat = 0,
        send: @escaping (String) -> Void
    ) {
        comboView = TerminalCtrlComboView(
            faceHeight: faceHeight,
            padding: padding,
            fontSize: fontSize,
            fontWeight: fontWeight,
            kerning: kerning,
            send: send
        )
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = comboView.intrinsicContentSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        view = comboView
    }
}

#if !os(visionOS)

/// Pure layout ladder for the native rail. Its last two exact floors are
/// load-bearing: 420 points keeps RET + TMUX on iPhone Air, while 375 points
/// keeps every essential terminal key when TMUX moves to the shell bar.
/// "tmux" here names the shortcut-key SLOT — a herdr tab fills it with HRDR,
/// four mono characters like TMUX, so every tier holds for both backends.
enum TerminalKeyBarLayout {
    enum Tier: Equatable {
        case full
        case twoSymbolsAndPages
        case twoSymbols
        case regularEssentials
        case tightTmux
        case returnAndTmuxFloor
        case essentialsFloor
    }

    struct Metric: Equatable {
        var keyWidth: CGFloat
        var spacing: CGFloat
        var groupGap: CGFloat
        var faceInset: CGFloat = 0

        static let regular = Metric(keyWidth: 46, spacing: 6, groupGap: 12)
        static let tight = Metric(keyWidth: 40, spacing: 1, groupGap: 1, faceInset: 1)
        static let returnAndTmux = Metric(
            keyWidth: 40,
            spacing: 0,
            groupGap: 4,
            faceInset: 1
        )
        static let returnFloor = Metric(
            keyWidth: 40,
            spacing: 0,
            groupGap: 1,
            faceInset: 1
        )
        static let compact = Metric(keyWidth: 40, spacing: 4, groupGap: 4)
    }

    struct Specification: Equatable {
        var tier: Tier
        var symbols: [String]
        var pageKeys: Bool
        var tmux: Bool
        var metric: Metric
        var edgeInset: CGFloat

        func idealWidth(includesReturn: Bool) -> CGFloat {
            let gap = includesReturn ? min(metric.groupGap, 8) : metric.groupGap
            var groupCounts = [3]
            if !symbols.isEmpty { groupCounts.append(symbols.count) }
            let rightCount = (pageKeys ? 2 : 0)
                + 4
                + (includesReturn ? 1 : 0)
                + 1
                + (tmux ? 1 : 0)
            groupCounts.append(rightCount)
            let keys = groupCounts.reduce(0, +)
            let internalSpaces = groupCounts.reduce(0) { partial, count in
                partial + max(0, count - 1)
            }
            return edgeInset * 2
                + CGFloat(keys) * metric.keyWidth
                + CGFloat(internalSpaces) * metric.spacing
                + CGFloat(groupCounts.count - 1) * gap
        }
    }

    static func candidates(
        showsTmux: Bool,
        includesReturn: Bool
    ) -> [Specification] {
        var result = [
            Specification(
                tier: .full,
                symbols: ["~", "|", "/", "-"],
                pageKeys: true,
                tmux: showsTmux,
                metric: .regular,
                edgeInset: 8
            ),
            Specification(
                tier: .twoSymbolsAndPages,
                symbols: ["~", "/"],
                pageKeys: true,
                tmux: showsTmux,
                metric: .regular,
                edgeInset: 8
            ),
            Specification(
                tier: .twoSymbols,
                symbols: ["~", "/"],
                pageKeys: false,
                tmux: showsTmux,
                metric: .regular,
                edgeInset: 8
            ),
            Specification(
                tier: .regularEssentials,
                symbols: [],
                pageKeys: false,
                tmux: showsTmux,
                metric: .regular,
                edgeInset: 8
            ),
        ]
        if showsTmux {
            result.append(Specification(
                tier: .tightTmux,
                symbols: [],
                pageKeys: false,
                tmux: true,
                metric: .tight,
                edgeInset: 8
            ))
        }
        if showsTmux, includesReturn {
            result.append(Specification(
                tier: .returnAndTmuxFloor,
                symbols: [],
                pageKeys: false,
                tmux: true,
                metric: .returnAndTmux,
                edgeInset: 8
            ))
        }
        result.append(Specification(
            tier: .essentialsFloor,
            symbols: [],
            pageKeys: false,
            tmux: false,
            metric: includesReturn ? .returnFloor : .compact,
            edgeInset: includesReturn ? 7 : 8
        ))
        return result
    }

    static func specification(
        width: CGFloat,
        contentSafeArea: UIEdgeInsets,
        showsTmux: Bool,
        includesReturn: Bool
    ) -> Specification {
        let usable = max(0, width - contentSafeArea.left - contentSafeArea.right)
        let candidates = candidates(showsTmux: showsTmux, includesReturn: includesReturn)
        return candidates.first {
            $0.idealWidth(includesReturn: includesReturn) <= usable + 0.5
        } ?? candidates[candidates.count - 1]
    }
}

struct TerminalKeyBarObservedState: Equatable {
    var hardwareKeyboardConnected: Bool
    var keyboardLocked: Bool
    var isDictating: Bool
}

/// The iPad terminal's app-owned TALLY key rail. It is a normal UIKit sibling
/// of SwiftTerm, not an input accessory and not a hosted SwiftUI hierarchy.
/// That avoids TextInputUI's Stage Manager rehosting path while preserving one
/// ordered byte route for every key.
@MainActor
final class TerminalKeyBar: UIView, UIInputViewAudioFeedback {
    static let barHeight: CGFloat = 48

    var contentSafeArea = UIEdgeInsets.zero {
        didSet {
            guard contentSafeArea != oldValue else { return }
            setNeedsLayout()
        }
    }

    private weak var terminal: TerminalView?
    private weak var controller: TerminalSessionController?
    private let performShortcut: (ShortcutPanelItem) -> Void
    private let finishTmuxCopyMode: () -> Void
    /// Which multiplexer owns this tab's shortcut key: TMUX, HRDR, or none.
    /// Both faces are four mono characters, so every layout tier below is
    /// backend-independent by construction.
    private let shortcutBackend: Host.SessionBackend?
    private let showsReturnKey: Bool
    private let topBorder = UIView()
    private var ctrlLatched = false
    private var observedState: TerminalKeyBarObservedState?
    private var observationGeneration = 0
    private var renderedSignature: RenderSignature?
    private(set) var renderedKeys: [TerminalTallyKeyControl] = []
    private weak var ctrlKeyControl: TerminalTallyKeyControl?
    private weak var shortcutPopoverController: UIViewController?
    private var ctrlComboView: TerminalCtrlComboView?

    private struct RenderSignature: Equatable {
        var tier: TerminalKeyBarLayout.Tier
        var state: TerminalKeyBarObservedState
    }

    init(
        terminal: TerminalView,
        controller: TerminalSessionController?,
        performShortcut: @escaping (ShortcutPanelItem) -> Void,
        finishTmuxCopyMode: @escaping () -> Void,
        shortcutBackend: Host.SessionBackend?
    ) {
        self.terminal = terminal
        self.controller = controller
        self.performShortcut = performShortcut
        self.finishTmuxCopyMode = finishTmuxCopyMode
        self.shortcutBackend = shortcutBackend
        showsReturnKey = UIDevice.current.userInterfaceIdiom == .pad
        ctrlLatched = terminal.controlModifier
        super.init(frame: .zero)

        backgroundColor = UIKitChassis.bezel
        accessibilityIdentifier = "terminal.keybar"
        topBorder.backgroundColor = UIKitChassis.bezelHi
        topBorder.isAccessibilityElement = false
        addSubview(topBorder)
        HardwareKeyboardMonitor.shared.startIfNeeded()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controlModifierDidReset),
            name: .terminalViewControlModifierReset,
            object: terminal
        )
        observationGeneration &+= 1
        observeAndRender(generation: observationGeneration)
        #if DEBUG
        KeyBarDebugHook.install()
        TmuxShortcutDebugHook.install()
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    var enableInputClicksWhenVisible: Bool { true }
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.barHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        topBorder.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        let state = observedState ?? currentObservedState
        let includesReturn = showsReturnKey || state.keyboardLocked
        let specification = TerminalKeyBarLayout.specification(
            width: bounds.width,
            contentSafeArea: contentSafeArea,
            showsTmux: shortcutBackend != nil,
            includesReturn: includesReturn
        )
        let signature = RenderSignature(tier: specification.tier, state: state)
        if renderedSignature != signature {
            rebuildRow(specification: specification, state: state)
            renderedSignature = signature
        }
        layoutRow(specification: specification, includesReturn: includesReturn)
        bringSubviewToFront(topBorder)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { hideCtrlCombos() }
    }

    @objc private func controlModifierDidReset() {
        ctrlLatched = false
        ctrlKeyControl?.isLatched = false
        hideCtrlCombos()
    }

    private var currentObservedState: TerminalKeyBarObservedState {
        TerminalKeyBarObservedState(
            hardwareKeyboardConnected: HardwareKeyboardMonitor.shared.isConnected,
            keyboardLocked: KeyboardLock.shared.isLocked,
            isDictating: controller?.isDictating == true
        )
    }

    private func observeAndRender(generation: Int) {
        guard generation == observationGeneration else { return }
        let state = withObservationTracking {
            currentObservedState
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeAndRender(generation: generation)
            }
        }
        guard state != observedState else { return }
        observedState = state
        renderedSignature = nil
        setNeedsLayout()
    }

    private func rebuildRow(
        specification: TerminalKeyBarLayout.Specification,
        state: TerminalKeyBarObservedState
    ) {
        for key in renderedKeys { key.removeFromSuperview() }
        renderedKeys.removeAll(keepingCapacity: true)
        ctrlKeyControl = nil
        let metric = specification.metric
        let includesReturn = showsReturnKey || state.keyboardLocked

        var groups: [[RailKey]] = [[
            caps("ESC", .esc, "Escape", identifier: "escape"),
            caps("CTRL", .ctrl, "Control", identifier: "control", latched: ctrlLatched),
            caps("TAB", .tab, "Tab", identifier: "tab"),
        ]]
        if !specification.symbols.isEmpty {
            groups.append(specification.symbols.map { symbol in
                RailKey(
                    key: .text(symbol),
                    face: .text(symbol, font: UIKitChassis.monoFont(15), kerning: 0),
                    accessibility: symbol,
                    identifier: "symbol.\(symbolIdentifier(symbol))"
                )
            })
        }

        var right: [RailKey] = []
        if specification.pageKeys {
            right.append(arrowKey(
                "arrow.up.to.line", .pageUp, "Page up", identifier: "pageUp"
            ))
            right.append(arrowKey(
                "arrow.down.to.line", .pageDown, "Page down", identifier: "pageDown"
            ))
        }
        right.append(contentsOf: [
            arrowKey("arrow.left", .left, "Arrow left", identifier: "left"),
            arrowKey("arrow.up", .up, "Arrow up", identifier: "up"),
            arrowKey("arrow.down", .down, "Arrow down", identifier: "down"),
            arrowKey("arrow.right", .right, "Arrow right", identifier: "right"),
        ])
        if includesReturn {
            right.append(caps("RET", .returnKey, "Return", identifier: "return"))
        }
        if state.hardwareKeyboardConnected {
            right.append(RailKey(
                key: .dictation,
                face: .symbol(
                    state.isDictating ? "mic.fill" : "mic",
                    pointSize: 13,
                    weight: .semibold
                ),
                accessibility: state.isDictating ? "Stop dictation" : "Dictate",
                identifier: "dictation",
                latched: state.isDictating
            ))
        } else {
            right.append(RailKey(
                key: .keyboard,
                face: .symbol(
                    state.keyboardLocked ? "lock.fill" : "keyboard",
                    pointSize: 13,
                    weight: .semibold
                ),
                accessibility: state.keyboardLocked
                    ? "Unlock keyboard"
                    : "Show or hide keyboard. Hold to lock the keyboard closed",
                identifier: "keyboard",
                latched: state.keyboardLocked,
                longPressKey: state.keyboardLocked ? nil : .lockKeyboard
            ))
        }
        if specification.tmux, let backend = shortcutBackend {
            // The identifier names the slot, not the occupant — debug hooks
            // and tests address "tmux" for either backend's key.
            right.append(RailKey(
                key: .showShortcutPanel,
                face: .text(
                    backend == .herdr ? "HRDR" : "TMUX",
                    font: UIKitChassis.monoFont(9, weight: .semibold),
                    kerning: 0.7
                ),
                accessibility: backend == .herdr
                    ? "Show herdr shortcuts"
                    : "Show tmux shortcuts",
                identifier: "tmux"
            ))
        }
        groups.append(right)

        for group in groups {
            for descriptor in group {
                let control = TerminalTallyKeyControl(
                    face: descriptor.face,
                    width: metric.keyWidth,
                    height: 34,
                    accessibilityLabel: descriptor.accessibility,
                    accessibilityIdentifier: "terminal.keybar.\(descriptor.identifier)",
                    repeats: descriptor.repeats,
                    latched: descriptor.latched,
                    faceInset: metric.faceInset,
                    longPressAction: descriptor.longPressKey.map { key in
                        { [weak self] in self?.press(key) }
                    },
                    action: { [weak self] in self?.press(descriptor.key) }
                )
                control.accessibilityUserInputLabels = [descriptor.accessibility]
                addSubview(control)
                renderedKeys.append(control)
                if descriptor.identifier == "control" { ctrlKeyControl = control }
            }
        }
    }

    private func layoutRow(
        specification: TerminalKeyBarLayout.Specification,
        includesReturn: Bool
    ) {
        let metric = specification.metric
        let leftCount = 3
        let symbolCount = specification.symbols.count
        let rightCount = renderedKeys.count - leftCount - symbolCount
        let counts = symbolCount > 0
            ? [leftCount, symbolCount, rightCount]
            : [leftCount, rightCount]
        let groupGap = includesReturn ? min(metric.groupGap, 8) : metric.groupGap
        let internalSpacingCount = counts.reduce(0) { $0 + max(0, $1 - 1) }
        let minimumContentWidth = CGFloat(renderedKeys.count) * metric.keyWidth
            + CGFloat(internalSpacingCount) * metric.spacing
            + CGFloat(counts.count - 1) * groupGap
        let available = max(
            0,
            bounds.width - contentSafeArea.left - contentSafeArea.right
                - specification.edgeInset * 2
        )
        let flexibleGap = groupGap
            + max(0, available - minimumContentWidth) / CGFloat(max(1, counts.count - 1))

        var index = 0
        var x = contentSafeArea.left + specification.edgeInset
        for groupIndex in counts.indices {
            for keyIndex in 0..<counts[groupIndex] {
                let key = renderedKeys[index]
                key.frame = CGRect(x: x, y: 7, width: metric.keyWidth, height: 34)
                x += metric.keyWidth
                if keyIndex < counts[groupIndex] - 1 { x += metric.spacing }
                index += 1
            }
            if groupIndex < counts.count - 1 { x += flexibleGap }
        }
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
            ctrlLatched = latched
            ctrlKeyControl?.isLatched = latched
            if latched { showCtrlCombos() } else { hideCtrlCombos() }
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
        case .showShortcutPanel:
            showShortcutPanel()
        case .shortcut(let item):
            click()
            performShortcut(item)
        }
    }

    private func showShortcutPanel() {
        guard shortcutPopoverController == nil,
              let content = ShortcutPanelContent.content(for: shortcutBackend),
              let presenter = presentingViewController
        else { return }
        let sceneWidth = window?.bounds.width ?? presenter.view.bounds.width
        let panelWidth = min(
            ShortcutPanelViewController.preferredWidth,
            max(280, sceneWidth - 24)
        )
        let controller = ShortcutPanelViewController(
            content: content,
            width: panelWidth,
            select: { [weak self] item in
                self?.shortcutPopoverController?.dismiss(animated: true)
                self?.press(.shortcut(item))
            },
            loadChoices: { [weak self] in
                await self?.controller?.loadShortcutSwitchChoices()
            },
            selectChoice: { [weak self] choice in
                self?.shortcutPopoverController?.dismiss(animated: true)
                self?.click()
                self?.controller?.selectShortcutSwitchChoice(choice)
            }
        )
        shortcutPopoverController = controller
        controller.modalPresentationStyle = .popover
        controller.loadViewIfNeeded()
        controller.view.backgroundColor = UIKitChassis.bezel
        controller.preferredContentSize = controller.fittingContentSize()
        if let popover = controller.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = CGRect(
                x: bounds.maxX - 44,
                y: bounds.minY,
                width: 44,
                height: bounds.height
            )
            popover.permittedArrowDirections = .down
            popover.backgroundColor = UIKitChassis.bezel
            popover.delegate = self
        }
        presenter.present(controller, animated: true)
    }

    private func showCtrlCombos() {
        guard ctrlComboView == nil, let window else { return }
        let slab = TerminalCtrlComboView(
            faceHeight: 34,
            padding: 8,
            fontSize: 15
        ) { [weak self] letter in
            self?.sendCtrlCombo(letter)
        }
        slab.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(slab)
        layoutIfNeeded()
        let anchorX = ctrlKeyControl?.frame.midX ?? 85
        let centerX = slab.centerXAnchor.constraint(
            equalTo: leadingAnchor,
            constant: anchorX
        )
        centerX.priority = .defaultHigh
        NSLayoutConstraint.activate([
            centerX,
            slab.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            slab.bottomAnchor.constraint(equalTo: topAnchor, constant: -6),
        ])
        ctrlComboView = slab
    }

    private func hideCtrlCombos() {
        ctrlComboView?.removeFromSuperview()
        ctrlComboView = nil
    }

    private func sendCtrlCombo(_ letter: String) {
        hideCtrlCombos()
        guard let terminal, terminal.controlModifier else { return }
        click()
        terminal.insertText(letter)
    }

    private var presentingViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    private func arrow(_ app: [UInt8], _ normal: [UInt8]) -> [UInt8] {
        terminal?.getTerminal().applicationCursor == true ? app : normal
    }

    private func click() {
        UIDevice.current.playInputClick()
    }

    private func caps(
        _ label: String,
        _ key: TerminalKey,
        _ accessibility: String,
        identifier: String,
        latched: Bool = false
    ) -> RailKey {
        RailKey(
            key: key,
            face: .text(
                label,
                font: UIKitChassis.monoFont(11, weight: .semibold),
                kerning: 1.1
            ),
            accessibility: accessibility,
            identifier: identifier,
            latched: latched
        )
    }

    private func arrowKey(
        _ image: String,
        _ key: TerminalKey,
        _ accessibility: String,
        identifier: String
    ) -> RailKey {
        RailKey(
            key: key,
            face: .symbol(image, pointSize: 12, weight: .semibold),
            accessibility: accessibility,
            identifier: identifier,
            repeats: true
        )
    }

    private func symbolIdentifier(_ symbol: String) -> String {
        switch symbol {
        case "~": "tilde"
        case "|": "pipe"
        case "/": "slash"
        case "-": "hyphen"
        default: symbol
        }
    }

    #if DEBUG
    func debugShowTmuxShortcuts() {
        guard let terminal, TerminalFocusArbiter.current === terminal else { return }
        showShortcutPanel()
    }

    func debugSendTmuxCopyMode() {
        guard let terminal, TerminalFocusArbiter.current === terminal else { return }
        press(.shortcut(ShortcutPanelItem(TmuxShortcut.copyMode)))
    }

    func debugFinishTmuxCopyMode() {
        guard let terminal, TerminalFocusArbiter.current === terminal else { return }
        finishTmuxCopyMode()
    }

    func debugBeginSelectText() {
        guard let terminal, TerminalFocusArbiter.current === terminal else { return }
        controller?.beginSelectTextMode()
    }

    func debugFinishSelectText() {
        guard let terminal, TerminalFocusArbiter.current === terminal else { return }
        controller?.finishSelectTextMode()
    }

    func debugSelectTextAll() {
        guard let terminal, TerminalFocusArbiter.current === terminal else { return }
        terminal.selectAll(nil)
    }

    /// Raises the app's selection block at screen center through the shared
    /// long-press / touch-double-tap entry point (no headless tap exists).
    func debugShowLongPressMenu() {
        guard let terminal, TerminalFocusArbiter.current === terminal else { return }
        _ = terminal.presentSelectionMenu(at: CGPoint(
            x: terminal.bounds.midX,
            y: terminal.bounds.midY
        ))
    }

    func debugSendRemoteRightClick() {
        guard let terminal, TerminalFocusArbiter.current === terminal else { return }
        terminal.sendRemoteRightClick(
            at: CGPoint(x: terminal.bounds.midX, y: terminal.bounds.midY)
        )
    }

    func debugPerformConfirmedTmuxClose(_ shortcut: TmuxShortcut) {
        guard let terminal,
              TerminalFocusArbiter.current === terminal,
              shortcut.requiresDoubleActivation
        else { return }
        press(.shortcut(ShortcutPanelItem(shortcut)))
    }

    func debugToggleDictation() {
        guard let terminal, TerminalFocusArbiter.current === terminal else { return }
        press(.dictation)
    }

    func debugExercise() {
        guard let terminal, TerminalFocusArbiter.current === terminal else { return }
        for symbol in ["~", "|", "/", "-"] { press(.text(symbol)) }
        terminal.controlModifier = true
        ctrlLatched = true
        ctrlKeyControl?.isLatched = true
        terminal.insertText("c")
    }

    func debugShowCtrlCombos() {
        guard let terminal, TerminalFocusArbiter.current === terminal else { return }
        if !terminal.controlModifier { press(.ctrl) }
    }
    #endif
}

private struct RailKey {
    var key: TerminalKey
    var face: TerminalTallyKeyControl.Face
    var accessibility: String
    var identifier: String
    var repeats = false
    var latched = false
    var longPressKey: TerminalKey?
}

private enum TerminalKey {
    case esc, ctrl, tab, returnKey
    case text(String)
    case up, down, left, right
    case pageUp, pageDown
    case keyboard
    case lockKeyboard
    case dictation
    case showShortcutPanel
    case shortcut(ShortcutPanelItem)
}

extension TerminalKeyBar: UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyle(
        for controller: UIPresentationController
    ) -> UIModalPresentationStyle { .none }

    func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle { .none }
}

#if DEBUG
@MainActor
enum TmuxShortcutDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.tmuxshortcuts", &token, .main
        ) { _ in focusedBar()?.debugShowTmuxShortcuts() }

        var copyToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.tmuxcopy", &copyToken, .main
        ) { _ in focusedBar()?.debugSendTmuxCopyMode() }

        var copyDoneToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.tmuxcopydone", &copyDoneToken, .main
        ) { _ in focusedBar()?.debugFinishTmuxCopyMode() }

        var selectTextToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.selecttext", &selectTextToken, .main
        ) { _ in focusedBar()?.debugBeginSelectText() }

        var selectTextDoneToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.selecttextdone", &selectTextDoneToken, .main
        ) { _ in focusedBar()?.debugFinishSelectText() }

        var selectTextAllToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.selecttextall", &selectTextAllToken, .main
        ) { _ in focusedBar()?.debugSelectTextAll() }

        var longPressMenuToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.longpressmenu", &longPressMenuToken, .main
        ) { _ in focusedBar()?.debugShowLongPressMenu() }

        var herdrMenuToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.herdrmenu", &herdrMenuToken, .main
        ) { _ in focusedBar()?.debugSendRemoteRightClick() }

        var closePaneToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.tmuxclosepane", &closePaneToken, .main
        ) { _ in focusedBar()?.debugPerformConfirmedTmuxClose(.closePane) }

        var closeWindowToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.tmuxclosewindow", &closeWindowToken, .main
        ) { _ in focusedBar()?.debugPerformConfirmedTmuxClose(.closeWindow) }

        var ctrlCombosToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.ctrlcombos", &ctrlCombosToken, .main
        ) { _ in focusedBar()?.debugShowCtrlCombos() }
    }

    private static func focusedBar() -> TerminalKeyBar? {
        guard let view = TerminalFocusArbiter.current else { return nil }
        return view.superview?.subviews.compactMap { $0 as? TerminalKeyBar }.first
    }
}

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
                  let bar = view.superview?.subviews.compactMap({ $0 as? TerminalKeyBar }).first
            else { return }
            bar.debugExercise()
        }

        var dictationToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.dictation", &dictationToken, .main
        ) { _ in
            guard let view = TerminalFocusArbiter.current,
                  let bar = view.superview?.subviews.compactMap({ $0 as? TerminalKeyBar }).first
            else { return }
            bar.debugToggleDictation()
        }
    }
}
#endif

#endif

#if os(visionOS)

struct TerminalKeyClusterMetric: Equatable {
    var keyWidth: CGFloat
    var spacing: CGFloat
    var groupGap: CGFloat

    static let regular = TerminalKeyClusterMetric(keyWidth: 46, spacing: 6, groupGap: 12)
    static let compact = TerminalKeyClusterMetric(keyWidth: 36, spacing: 4, groupGap: 8)
}

/// One shared owner per ornament. ViewThatFits may construct several native
/// metric candidates, so terminal state and DEBUG routing live here to ensure
/// one notification still emits one proof sequence.
@MainActor
final class TerminalKeyClusterContext {
    private weak var controller: TerminalSessionController?
    private weak var observedTerminal: TerminalView?
    private let groups = NSHashTable<TerminalKeyClusterGroupView>.weakObjects()
    private var controlResetObserver: NSObjectProtocol?
    #if DEBUG
    private var debugObservers: [NSObjectProtocol] = []
    #endif

    private(set) var ctrlLatched = false

    init() {
        #if DEBUG
        KeyClusterDebugHook.install()
        let center = NotificationCenter.default
        debugObservers = [
            center.addObserver(
                forName: .multiplexDebugKeyCluster,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.debugExercise() }
            },
            center.addObserver(
                forName: .multiplexDebugCtrlCombos,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.debugShowCtrlCombos() }
            },
        ]
        #endif
    }

    /// Block-based registrations outlive the object that installed them, and
    /// `update(controller:)` only retires the previous terminal's — a context
    /// that goes away with its window would otherwise strand every one it
    /// still holds.
    deinit {
        let center = NotificationCenter.default
        if let controlResetObserver {
            center.removeObserver(controlResetObserver)
        }
        #if DEBUG
        for observer in debugObservers {
            center.removeObserver(observer)
        }
        #endif
    }

    func update(controller: TerminalSessionController?) {
        let controllerChanged = self.controller !== controller
        self.controller = controller
        let terminal = controller?.terminalView
        guard controllerChanged || observedTerminal !== terminal else { return }
        if let controlResetObserver {
            NotificationCenter.default.removeObserver(controlResetObserver)
        }
        observedTerminal = terminal
        ctrlLatched = terminal?.controlModifier ?? false
        controlResetObserver = terminal.map { terminal in
            NotificationCenter.default.addObserver(
                forName: .terminalViewControlModifierReset,
                object: terminal,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.controlModifierDidReset() }
            }
        }
        broadcast()
    }

    func register(_ group: TerminalKeyClusterGroupView) {
        groups.add(group)
        group.applyContextState()
    }

    func sendEscape() { observedTerminal?.send(EscapeSequences.cmdEsc) }
    func sendTab() { observedTerminal?.send([0x09]) }
    func sendReturn() { observedTerminal?.send([0x0D]) }

    func sendArrow(app: [UInt8], normal: [UInt8]) {
        guard let terminal = observedTerminal else { return }
        terminal.send(terminal.getTerminal().applicationCursor ? app : normal)
    }

    func toggleKeyboard() {
        controller?.toggleKeyboard()
    }

    func toggleControl(from group: TerminalKeyClusterGroupView) {
        guard let terminal = observedTerminal else { return }
        let latched = !terminal.controlModifier
        terminal.controlModifier = latched
        ctrlLatched = latched
        broadcast()
        if latched { group.showCtrlCombos() } else { hideCtrlCombos() }
    }

    func sendCtrlCombo(_ letter: String) {
        hideCtrlCombos()
        guard let terminal = observedTerminal, terminal.controlModifier else { return }
        terminal.insertText(letter)
    }

    private func controlModifierDidReset() {
        ctrlLatched = false
        hideCtrlCombos()
        broadcast()
    }

    private func broadcast() {
        for group in groups.allObjects { group.applyContextState() }
    }

    private func hideCtrlCombos() {
        for group in groups.allObjects { group.hideCtrlCombos() }
    }

    #if DEBUG
    private var visibleControlGroup: TerminalKeyClusterGroupView? {
        groups.allObjects.first {
            $0.carriesControlKey
                && $0.window != nil
                && !$0.isHidden
                && $0.alpha > 0
                && !$0.bounds.isEmpty
        }
    }

    private func debugExercise() {
        guard let terminal = observedTerminal,
              TerminalFocusArbiter.current === terminal
        else { return }
        terminal.send(EscapeSequences.cmdEsc)
        terminal.send([0x09])
        terminal.controlModifier = true
        ctrlLatched = true
        broadcast()
        terminal.insertText("c")
    }

    private func debugShowCtrlCombos() {
        guard let terminal = observedTerminal,
              TerminalFocusArbiter.current === terminal,
              !terminal.controlModifier
        else { return }
        terminal.controlModifier = true
        ctrlLatched = true
        broadcast()
        visibleControlGroup?.showCtrlCombos()
    }
    #endif
}

@MainActor
final class TerminalKeyClusterGroupView: UIKitTallyBorderedView {
    enum Role: Equatable {
        case leading
        case trailing
        case standalone
    }

    private enum StandaloneVariant: Equatable {
        case regular
        case compact
        case minimal
    }

    let role: Role
    private let metric: TerminalKeyClusterMetric
    private let context: TerminalKeyClusterContext
    private var standaloneVariant: StandaloneVariant?
    private weak var ctrlKey: TerminalTallyKeyControl?
    private weak var comboPopoverController: UIViewController?
    private(set) var keys: [TerminalTallyKeyControl] = []

    var carriesControlKey: Bool { role != .trailing }

    init(
        role: Role,
        metric: TerminalKeyClusterMetric,
        context: TerminalKeyClusterContext
    ) {
        self.role = role
        self.metric = metric
        self.context = context
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.bezel
        tallyBorderColor = UIKitChassis.bezelHi
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true
        accessibilityIdentifier = "terminal.keyCluster.\(role.identifier)"
        rebuildKeys(variant: role == .standalone ? .regular : nil)
        context.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var intrinsicContentSize: CGSize {
        fittingSize(maximumWidth: nil)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let variant = role == .standalone ? variant(for: bounds.width) : nil
        if variant != standaloneVariant {
            rebuildKeys(variant: variant)
        }
        layoutKeys(variant: variant)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { hideCtrlCombos() }
    }

    func update(controller: TerminalSessionController?) {
        context.update(controller: controller)
        applyContextState()
    }

    func applyContextState() {
        ctrlKey?.isLatched = context.ctrlLatched
    }

    func fittingSize(maximumWidth: CGFloat?) -> CGSize {
        switch role {
        case .leading:
            return CGSize(width: leadingWidth(metric), height: 44)
        case .trailing:
            return CGSize(width: trailingWidth(metric), height: 44)
        case .standalone:
            let maximum = maximumWidth ?? .greatestFiniteMagnitude
            let regular = standaloneWidth(metric: .regular, minimal: false)
            if regular <= maximum { return CGSize(width: regular, height: 44) }
            let compact = standaloneWidth(metric: .compact, minimal: false)
            if compact <= maximum { return CGSize(width: compact, height: 44) }
            return CGSize(
                width: standaloneWidth(metric: .compact, minimal: true),
                height: 44
            )
        }
    }

    func showCtrlCombos() {
        guard comboPopoverController == nil,
              let ctrlKey,
              let presenter = presentingViewController
        else { return }
        let controller = TerminalCtrlComboViewController(
            faceHeight: 26,
            padding: 12,
            fontSize: 9,
            fontWeight: .semibold,
            kerning: 1.1,
            send: { [weak self] letter in
                self?.comboPopoverController?.dismiss(animated: true)
                self?.context.sendCtrlCombo(letter)
            }
        )
        comboPopoverController = controller
        controller.modalPresentationStyle = .popover
        // The popover hosts in its own window: hand it the same appearance
        // override the ornament mount carries, or a pinned LIGHT presents a
        // dark slab (`.unspecified` under SYSTEM keeps the native style).
        controller.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        controller.loadViewIfNeeded()
        // PROTOTYPE(GLASS): the popover window carries no scene traits —
        // mirror the glass selection the same way the style is mirrored
        // above, so the slab and its key faces resolve the smoke materials.
        controller.view.traitOverrides[GlassAppearanceTrait.self] =
            traitCollection[GlassAppearanceTrait.self]
        if let popover = controller.popoverPresentationController {
            popover.sourceView = ctrlKey
            popover.sourceRect = ctrlKey.bounds
            popover.permittedArrowDirections = .down
            popover.delegate = self
        }
        presenter.present(controller, animated: true)
    }

    func hideCtrlCombos() {
        comboPopoverController?.dismiss(animated: false)
        comboPopoverController = nil
    }

    private func rebuildKeys(variant: StandaloneVariant?) {
        for key in keys { key.removeFromSuperview() }
        keys.removeAll(keepingCapacity: true)
        ctrlKey = nil
        standaloneVariant = variant
        let activeMetric: TerminalKeyClusterMetric
        let minimal: Bool
        if role == .standalone {
            activeMetric = variant == .regular ? .regular : .compact
            minimal = variant == .minimal
        } else {
            activeMetric = metric
            minimal = false
        }

        if role != .trailing {
            append(caps("ESC", "Escape", activeMetric, identifier: "escape") { [weak context] in
                context?.sendEscape()
            })
            let control = caps(
                "CTRL",
                "Control",
                activeMetric,
                identifier: "control",
                latched: context.ctrlLatched
            ) { [weak self, weak context] in
                guard let self, let context else { return }
                context.toggleControl(from: self)
            }
            append(control)
            ctrlKey = control
            append(caps("TAB", "Tab", activeMetric, identifier: "tab") { [weak context] in
                context?.sendTab()
            })
        }
        if role != .leading {
            if !minimal {
                append(arrow(
                    "arrow.left", "Arrow left", activeMetric, identifier: "left",
                    app: EscapeSequences.moveLeftApp,
                    normal: EscapeSequences.moveLeftNormal
                ))
                append(arrow(
                    "arrow.up", "Arrow up", activeMetric, identifier: "up",
                    app: EscapeSequences.moveUpApp,
                    normal: EscapeSequences.moveUpNormal
                ))
                append(arrow(
                    "arrow.down", "Arrow down", activeMetric, identifier: "down",
                    app: EscapeSequences.moveDownApp,
                    normal: EscapeSequences.moveDownNormal
                ))
                append(arrow(
                    "arrow.right", "Arrow right", activeMetric, identifier: "right",
                    app: EscapeSequences.moveRightApp,
                    normal: EscapeSequences.moveRightNormal
                ))
            }
            append(caps("RET", "Return", activeMetric, identifier: "return") { [weak context] in
                context?.sendReturn()
            })
            let keyboard = TerminalTallyKeyControl(
                face: .symbol("keyboard", pointSize: 12, weight: .semibold),
                width: activeMetric.keyWidth,
                height: 26,
                accessibilityLabel: "Show or hide keyboard",
                accessibilityIdentifier: "terminal.keyCluster.keyboard",
                action: { [weak context] in context?.toggleKeyboard() }
            )
            append(keyboard)
        }
    }

    private func layoutKeys(variant: StandaloneVariant?) {
        let activeMetric = role == .standalone && variant != .regular
            ? TerminalKeyClusterMetric.compact
            : metric
        var x: CGFloat = 12
        let y: CGFloat = 9
        // `layout(range:)` leaves the cursor on the last key's trailing edge
        // with no spacing appended, so a group boundary advances by the whole
        // `groupGap` — the pre-UIKit `HStack(spacing: groupGap)` gap, and what
        // the reserved slab widths below already pay for. Subtracting
        // `spacing` here packed the keys left and dumped the slack on the
        // right edge.
        switch role {
        case .leading:
            layout(range: keys.indices, x: &x, y: y, spacing: activeMetric.spacing)
        case .trailing:
            layout(range: 0..<4, x: &x, y: y, spacing: activeMetric.spacing)
            x += activeMetric.groupGap
            layout(range: 4..<keys.count, x: &x, y: y, spacing: activeMetric.groupGap)
        case .standalone:
            layout(range: 0..<3, x: &x, y: y, spacing: activeMetric.spacing)
            x += activeMetric.groupGap
            let arrowCount = variant == .minimal ? 0 : 4
            if arrowCount > 0 {
                layout(range: 3..<(3 + arrowCount), x: &x, y: y, spacing: activeMetric.spacing)
                x += activeMetric.groupGap
            }
            layout(
                range: (3 + arrowCount)..<keys.count,
                x: &x,
                y: y,
                spacing: activeMetric.groupGap
            )
        }
    }

    private func layout(
        range: Range<Int>,
        x: inout CGFloat,
        y: CGFloat,
        spacing: CGFloat
    ) {
        for index in range {
            let key = keys[index]
            key.frame = CGRect(
                x: x,
                y: y,
                width: key.preferredSize.width,
                height: key.preferredSize.height
            )
            x += key.preferredSize.width
            if index < range.upperBound - 1 { x += spacing }
        }
    }

    private func variant(for width: CGFloat) -> StandaloneVariant {
        if standaloneWidth(metric: .regular, minimal: false) <= width + 0.5 {
            return .regular
        }
        if standaloneWidth(metric: .compact, minimal: false) <= width + 0.5 {
            return .compact
        }
        return .minimal
    }

    private func leadingWidth(_ metric: TerminalKeyClusterMetric) -> CGFloat {
        24 + metric.keyWidth * 3 + metric.spacing * 2
    }

    private func trailingWidth(_ metric: TerminalKeyClusterMetric) -> CGFloat {
        24 + metric.keyWidth * 6 + metric.spacing * 3 + metric.groupGap * 2
    }

    private func standaloneWidth(
        metric: TerminalKeyClusterMetric,
        minimal: Bool
    ) -> CGFloat {
        let left = metric.keyWidth * 3 + metric.spacing * 2
        let arrows = minimal ? 0 : metric.keyWidth * 4 + metric.spacing * 3
        let groups = minimal ? 3 : 4
        return 24 + left + arrows + metric.keyWidth * 2
            + CGFloat(groups - 1) * metric.groupGap
    }

    private func append(_ key: TerminalTallyKeyControl) {
        addSubview(key)
        keys.append(key)
    }

    private func caps(
        _ label: String,
        _ accessibility: String,
        _ metric: TerminalKeyClusterMetric,
        identifier: String,
        latched: Bool = false,
        action: @escaping () -> Void
    ) -> TerminalTallyKeyControl {
        TerminalTallyKeyControl(
            face: .text(
                label,
                font: UIKitChassis.monoFont(9, weight: .semibold),
                kerning: 1.1
            ),
            width: metric.keyWidth,
            height: 26,
            accessibilityLabel: accessibility,
            accessibilityIdentifier: "terminal.keyCluster.\(identifier)",
            latched: latched,
            action: action
        )
    }

    private func arrow(
        _ image: String,
        _ accessibility: String,
        _ metric: TerminalKeyClusterMetric,
        identifier: String,
        app: [UInt8],
        normal: [UInt8]
    ) -> TerminalTallyKeyControl {
        TerminalTallyKeyControl(
            face: .symbol(image, pointSize: 12, weight: .semibold),
            width: metric.keyWidth,
            height: 26,
            accessibilityLabel: accessibility,
            accessibilityIdentifier: "terminal.keyCluster.\(identifier)",
            repeats: true,
            action: { [weak context] in context?.sendArrow(app: app, normal: normal) }
        )
    }

    private var presentingViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}

private extension TerminalKeyClusterGroupView.Role {
    var identifier: String {
        switch self {
        case .leading: "leading"
        case .trailing: "trailing"
        case .standalone: "standalone"
        }
    }
}

extension TerminalKeyClusterGroupView: UIPopoverPresentationControllerDelegate {
    func adaptivePresentationStyle(
        for controller: UIPresentationController
    ) -> UIModalPresentationStyle { .none }

    func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle { .none }
}

#if DEBUG
extension Notification.Name {
    static let multiplexDebugKeyCluster = Notification.Name("MultiplexDebugKeyCluster")
    static let multiplexDebugCtrlCombos = Notification.Name("MultiplexDebugCtrlCombos")
}

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

        var combosToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.ctrlcombos", &combosToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugCtrlCombos, object: nil)
        }
    }
}

#endif

#endif
