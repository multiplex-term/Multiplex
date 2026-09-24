import Observation
import os
import SwiftTerm
import UIKit
import UniformTypeIdentifiers
#if DEBUG
import notify
#endif

/// Native key face shared by the iPad rail and the visionOS ornament. The
/// transparent control can stay at a full touch target while `faceInset`
/// narrows only the painted chassis face in the compact phone tiers.
@MainActor
final class TerminalTallyKeyControl: UIControl, UIDragInteractionDelegate {
    enum Face {
        case text(String, font: UIFont, kerning: CGFloat)
        case symbol(String, pointSize: CGFloat, weight: UIImage.SymbolWeight)
    }

    var isLatched = false {
        didSet {
            guard isLatched != oldValue else { return }
            refreshAppearance()
        }
    }
    var faceInset: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }
    var repeats = false
    var longPressAction: (() -> Void)? {
        didSet { configureLongPress() }
    }
    /// How long a press must hold before `longPressAction` fires. The
    /// keyboard key's lock keeps the 0.5 s default; CTRL's Key Commands
    /// hold is shorter (`KeyCommandPanelViewController.controlHoldDuration`).
    var longPressDuration: TimeInterval = 0.5 {
        didSet { longPressRecognizer?.minimumPressDuration = longPressDuration }
    }
    var preferredSize: CGSize {
        didSet { invalidateIntrinsicContentSize() }
    }
    /// Arrange Keys: the face wiggles, press and hold are inert, and the key
    /// is a system drag source (the tab strip's `UIDragInteraction`). It
    /// stays a live, hoverable target — visionOS gaze needs one.
    var isArranging = false {
        didSet {
            guard isArranging != oldValue else { return }
            longPressRecognizer?.isEnabled = !isArranging
            cancelRepeat()
            isHighlighted = false
            if isArranging {
                startWiggle()
                installArrangeDragInteraction()
                observeForegroundForWiggle()
            } else {
                stopWiggle()
                setDraggedAway(false)
                setDropTarget(false)
                arrangeDragInteraction?.isEnabled = false
                foregroundObserver.map(NotificationCenter.default.removeObserver)
                foregroundObserver = nil
            }
            accessibilityHint = isArranging ? String(localized: "Drag to move this key") : nil
        }
    }
    /// The owner mints the drag item for a lift of this key; nil declines.
    var arrangeDragItem: ((UIDragSession) -> UIDragItem?)?

    private static let wiggleAnimationKey = "arrange.wiggle"
    private var arrangeDragInteraction: UIDragInteraction?
    private var foregroundObserver: NSObjectProtocol?
    var isArrangeDragSourceForTesting: Bool { arrangeDragInteraction?.isEnabled == true }
    /// Lifted into a system drag: the slot reads as the hole the key left.
    private(set) var isDraggedAway = false
    /// The key a drop would land on, lit the way a tab cell's target is.
    private(set) var isDropTarget = false
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

    deinit {
        foregroundObserver.map(NotificationCenter.default.removeObserver)
    }

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
        guard !isArranging else { return false }
        primaryAction()
        return true
    }

    /// Installed on first use, toggled with the mode.
    private func installArrangeDragInteraction() {
        if let arrangeDragInteraction {
            arrangeDragInteraction.isEnabled = true
            return
        }
        let drag = TerminalTabDragPolicy.makeDragInteraction(delegate: self)
        addInteraction(drag)
        arrangeDragInteraction = drag
    }

    /// Backgrounding strips layer animations; a key still in the mode
    /// wiggles again on return.
    private func observeForegroundForWiggle() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeWiggleIfNeeded() }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Core Animation drops a layer's animations when it leaves the
        // window; a key re-mounted mid-mode wiggles again.
        if isArranging, window != nil { startWiggle() }
    }

    /// The slot dims to the hole the key left while the system carries its preview.
    func setDraggedAway(_ away: Bool) {
        guard isDraggedAway != away else { return }
        isDraggedAway = away
        refreshAppearance()
        if away {
            stopWiggle()
        } else if isArranging {
            startWiggle()
        }
    }

    func setDropTarget(_ targeted: Bool) {
        guard isDropTarget != targeted else { return }
        isDropTarget = targeted
        refreshAppearance()
    }

    /// Holds the wiggle still for a landing animation.
    func suspendWiggle() {
        stopWiggle()
    }

    /// Restarts a wiggle backgrounding dropped or a landing paused.
    func resumeWiggleIfNeeded() {
        guard isArranging, !isDraggedAway else { return }
        startWiggle()
    }

    private func startWiggle() {
        guard window != nil,
              layer.animation(forKey: Self.wiggleAnimationKey) == nil,
              !UIAccessibility.isReduceMotionEnabled
        else { return }
        let amplitude = 1.5 * CGFloat.pi / 180
        let rotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rotation.values = [-amplitude, amplitude, -amplitude]
        rotation.keyTimes = [0, 0.5, 1]
        rotation.duration = 0.14
        rotation.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        rotation.repeatCount = .greatestFiniteMagnitude
        // Out of phase with its neighbours, or the row rocks as one slab.
        rotation.timeOffset = Double.random(in: 0..<rotation.duration)
        layer.add(rotation, forKey: Self.wiggleAnimationKey)
    }

    private func stopWiggle() {
        layer.removeAnimation(forKey: Self.wiggleAnimationKey)
    }

    @objc private func pressBegan() {
        guard !isArranging else { return }
        TerminalKeyHaptics.keyPress(on: self)
        isHighlighted = true
        didRepeat = false
        didLongPress = false
        scheduleRepeatIfNeeded()
    }

    @objc private func pressEntered() {
        guard !isArranging else { return }
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
        guard !didRepeat, !didLongPress, !isArranging else { return }
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
        TerminalKeyHaptics.keyPress(on: self)
        primaryAction()
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard !isArranging else { return }
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
        recognizer.minimumPressDuration = longPressDuration
        recognizer.cancelsTouchesInView = true
        addGestureRecognizer(recognizer)
        longPressRecognizer = recognizer
    }

    private func refreshAppearance() {
        accessibilityTraits = isLatched ? [.button, .selected] : .button
        alpha = isDraggedAway ? 0.3 : isEnabled ? 1 : 0.45
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
            : isHighlighted || isDropTarget ? UIKitChassis.bezelHi : restingFace
        // The drop target wears the signal border a tab cell does.
        faceView.tallyBorderColor = isLatched || isDropTarget
            ? UIKitChassis.signal2
            : UIKitChassis.bezelHi
    }

    // MARK: Arrange Keys drag source

    func dragInteraction(
        _ interaction: UIDragInteraction,
        itemsForBeginning session: UIDragSession
    ) -> [UIDragItem] {
        guard isArranging, let item = arrangeDragItem?(session) else { return [] }
        item.previewProvider = { [weak self] in
            guard let self else { return nil }
            return UIDragPreview(view: self, parameters: self.dragPreviewParameters())
        }
        return [item]
    }

    func dragInteraction(
        _ interaction: UIDragInteraction,
        previewForLifting item: UIDragItem,
        session: UIDragSession
    ) -> UITargetedDragPreview? {
        UITargetedDragPreview(view: self, parameters: dragPreviewParameters())
    }

    func dragInteraction(
        _ interaction: UIDragInteraction,
        sessionWillBegin session: UIDragSession
    ) {
        setDraggedAway(true)
    }

    func dragInteraction(
        _ interaction: UIDragInteraction,
        sessionDidEnd session: UIDragSession,
        with operation: UIDropOperation
    ) {
        setDraggedAway(false)
    }

    func dragInteraction(
        _ interaction: UIDragInteraction,
        sessionIsRestrictedToDraggingApplication session: UIDragSession
    ) -> Bool {
        true
    }

    func dragInteraction(
        _ interaction: UIDragInteraction,
        prefersFullSizePreviewsFor session: UIDragSession
    ) -> Bool {
        true
    }

    private func dragPreviewParameters() -> UIDragPreviewParameters {
        let parameters = UIDragPreviewParameters()
        let path = UIBezierPath(rect: faceView.frame)
        parameters.backgroundColor = .clear
        parameters.visiblePath = path
        parameters.shadowPath = path
        return parameters
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
                accessibilityLabel: String(localized: "Control \(letter.uppercased())"),
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

private let keyArrangeLog = Logger(subsystem: "app.multiplexterm.multiplex", category: "keys")

/// A key in a row with the slot it occupies.
struct RenderedKey {
    let slot: KeyBarSlot
    let control: TerminalTallyKeyControl
}

/// Local-object marker for an Arrange Keys drag.
struct KeyBarDragPayload: TerminalChromeDragPayload {
    static let dragTypeTag = "application/x-multiplex-key-slot"
    var surfaceID: UUID
    var slot: KeyBarSlot
}

/// What a drop surface — the rail, the cluster context — tells the
/// coordinator.
@MainActor
protocol KeyBarDropSurface: AnyObject {
    /// Arrange Keys is on and the slot is on this surface.
    func canArrange(_ slot: KeyBarSlot) -> Bool
    /// Every key on the surface, in row order.
    var dropControls: [RenderedKey] { get }
    /// Lands `source` on `target`, writing the order; false when nothing moves.
    func dropKey(_ source: KeyBarSlot, onto target: KeyBarSlot) -> Bool
    /// Lays the surface out after a commit so the row shows the new order.
    func layoutAfterDrop()
}

/// The tab strip's drop dance for a row of keys, shared by the iPad rail
/// and the visionOS cluster: a process-local item per lift, the nearest
/// other key as the target (lit like a tab cell's), and a landing that
/// parks the displaced keys on their old centres for UIKit's drop animator
/// while the preview flies to the key's new control.
@MainActor
final class KeyBarDropCoordinator: NSObject, UIDropInteractionDelegate {
    private unowned let surface: any KeyBarDropSurface
    private let surfaceID = UUID()
    private var targetSlot: KeyBarSlot?
    private var pending: (slot: KeyBarSlot, landed: TerminalTallyKeyControl, displaced: [TerminalTallyKeyControl])?

    init(surface: any KeyBarDropSurface) {
        self.surface = surface
    }

    /// Idempotent: a host asked twice keeps one interaction.
    func installDropTarget(on host: UIView) {
        guard !host.interactions.contains(where: { ($0 as? UIDropInteraction)?.delegate === self })
        else { return }
        host.addInteraction(UIDropInteraction(delegate: self))
    }

    func makeDragItem(for slot: KeyBarSlot, session: UIDragSession) -> UIDragItem? {
        guard surface.canArrange(slot), surface.dropControls.count > 1 else { return nil }
        keyArrangeLog.debug("arrange lift \(slot.rawValue, privacy: .public)")
        return TerminalChromeDragItem.make(
            KeyBarDragPayload(surfaceID: surfaceID, slot: slot),
            session: session
        )
    }

    func clearTarget() {
        setTarget(nil)
    }

    /// A rebuild mid-landing (a tier change) replaces the keys; nothing is
    /// left parked.
    func cancelLanding() {
        finishLanding()
    }

    /// The key a drop at `point` (in `view`'s coordinates) lands on: the
    /// nearest other key by centre, nil over the dragged key's own slot.
    func targetSlot(at point: CGPoint, in view: UIView, source: KeyBarSlot) -> KeyBarSlot? {
        let row = surface.dropControls
        guard let sourceIndex = row.firstIndex(where: { $0.slot == source }) else { return nil }
        let frames = row.map { entry in
            entry.control.superview?.convert(entry.control.frame, to: view) ?? entry.control.frame
        }
        return RowDropGeometry.dropTargetIndex(
            x: point.x,
            restingFrames: frames,
            sourceIndex: sourceIndex
        ).map { row[$0].slot }
    }

    private func source(of session: UIDropSession) -> KeyBarSlot? {
        guard let payload = TerminalChromeDragItem.payload(KeyBarDragPayload.self, from: session),
              payload.surfaceID == surfaceID,
              surface.canArrange(payload.slot)
        else { return nil }
        return payload.slot
    }

    private func target(for session: UIDropSession, in interaction: UIDropInteraction) -> KeyBarSlot? {
        guard let view = interaction.view, let source = source(of: session) else { return nil }
        return targetSlot(at: session.location(in: view), in: view, source: source)
    }

    private func setTarget(_ slot: KeyBarSlot?) {
        guard targetSlot != slot else { return }
        targetSlot = slot
        for entry in surface.dropControls {
            entry.control.setDropTarget(entry.slot == slot)
        }
    }

    private func center(of control: UIView, in view: UIView) -> CGPoint {
        control.superview?.convert(control.center, to: view) ?? control.center
    }

    private func land(_ source: KeyBarSlot, on target: KeyBarSlot, in view: UIView) {
        finishLanding()
        surface.layoutAfterDrop()
        var oldCenters: [KeyBarSlot: CGPoint] = [:]
        for entry in surface.dropControls {
            oldCenters[entry.slot] = center(of: entry.control, in: view)
        }
        var landed = false
        UIView.performWithoutAnimation {
            landed = surface.dropKey(source, onto: target)
            surface.layoutAfterDrop()
        }
        guard landed else { return }
        var key: TerminalTallyKeyControl?
        var displaced: [TerminalTallyKeyControl] = []
        UIView.performWithoutAnimation {
            for entry in surface.dropControls {
                if entry.slot == source {
                    key = entry.control
                    continue
                }
                guard let oldCenter = oldCenters[entry.slot] else { continue }
                let dx = oldCenter.x - center(of: entry.control, in: view).x
                guard abs(dx) > 0.5 else { continue }
                entry.control.suspendWiggle()
                entry.control.transform = CGAffineTransform(translationX: dx, y: 0)
                displaced.append(entry.control)
            }
        }
        guard let key else { return }
        pending = (source, key, displaced)
        keyArrangeLog.debug(
            "arrange drop \(source.rawValue, privacy: .public) onto \(target.rawValue, privacy: .public)"
        )
    }

    private func finishLanding(slot: KeyBarSlot? = nil) {
        guard let pending, slot == nil || slot == pending.slot else { return }
        UIView.performWithoutAnimation {
            for control in pending.displaced {
                control.transform = .identity
                control.resumeWiggleIfNeeded()
            }
        }
        self.pending = nil
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        canHandle session: UIDropSession
    ) -> Bool {
        source(of: session) != nil
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidEnter session: UIDropSession
    ) {
        setTarget(target(for: session, in: interaction))
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
        let target = target(for: session, in: interaction)
        setTarget(target)
        return UIDropProposal(operation: target == nil ? .forbidden : .move)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidExit session: UIDropSession
    ) {
        setTarget(nil)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidEnd session: UIDropSession
    ) {
        setTarget(nil)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        previewForDropping item: UIDragItem,
        withDefault defaultPreview: UITargetedDragPreview
    ) -> UITargetedDragPreview? {
        guard let payload = item.localObject as? KeyBarDragPayload,
              let pending,
              payload.slot == pending.slot,
              let container = pending.landed.superview
        else { return defaultPreview }
        return defaultPreview.retargetedPreview(
            with: UIDragPreviewTarget(container: container, center: pending.landed.center)
        )
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        performDrop session: UIDropSession
    ) {
        guard let view = interaction.view, let source = source(of: session) else { return }
        let target = targetSlot(at: session.location(in: view), in: view, source: source)
        setTarget(nil)
        guard let target else { return }
        land(source, on: target, in: view)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        item: UIDragItem,
        willAnimateDropWith animator: UIDragAnimating
    ) {
        guard let payload = item.localObject as? KeyBarDragPayload,
              let pending,
              payload.slot == pending.slot
        else { return }
        animator.addAnimations { [weak self] in
            guard self?.pending?.slot == pending.slot else { return }
            for control in pending.displaced {
                control.transform = .identity
            }
        }
        animator.addCompletion { [weak self] _ in
            self?.finishLanding(slot: pending.slot)
        }
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        concludeDrop session: UIDropSession
    ) {
        finishLanding()
    }
}

/// VoiceOver's road through the mode: one step left or right.
@MainActor
private func keyMoveActions(_ move: @escaping (Int) -> Bool) -> [UIAccessibilityCustomAction] {
    [
        UIAccessibilityCustomAction(name: String(localized: "Move left")) { _ in move(-1) },
        UIAccessibilityCustomAction(name: String(localized: "Move right")) { _ in move(1) },
    ]
}

/// The talk key's VoiceOver name on the rail and in the visionOS cluster —
/// one wording, flipped in place with the latch.
private func talkbackKeyLabel(open: Bool) -> String {
    open
        ? String(localized: "Close the message box")
        : String(localized: "Open the message box")
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

    /// Window-edge daylight for the iPad-width tiers. The tight and floor
    /// tiers keep 8/7: `SingleWindowShellLayout`'s 390/420 pt cutoffs are
    /// measured against those, and widening them would move the cutoffs.
    /// The Mac keeps the authored 8 — its window has no rounded bottom
    /// corners crowding the row, and its point grid is already scaled. Pure
    /// in its input so both branches stay assertable from either host.
    static func regularEdgeInset(isIOSAppOnMac: Bool) -> CGFloat {
        isIOSAppOnMac ? 8 : 16
    }

    static let regularEdgeInset = regularEdgeInset(
        isIOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac
    )

    struct Metric: Equatable {
        var keyWidth: CGFloat
        var spacing: CGFloat
        var groupGap: CGFloat
        var faceInset: CGFloat = 0

        static let regular = Metric(keyWidth: 46, spacing: 6, groupGap: 12)
        /// The phone tiers run 36 pt faces (the visionOS compact cluster's
        /// width) since the talk key joined the right group: at 40 pt every
        /// phone tier overflowed its cutoff (tight 425 > 390, RET floor 400 >
        /// 375), and the key is essential at every tier — so the faces
        /// yield, and `SingleWindowShellLayout`'s 390 / 420 cutoffs and the
        /// 375 locked floor hold unchanged (pinned by the width-ladder test).
        static let tight = Metric(keyWidth: 36, spacing: 1, groupGap: 1, faceInset: 1)
        static let returnAndTmux = Metric(
            keyWidth: 36,
            spacing: 0,
            groupGap: 4,
            faceInset: 1
        )
        static let returnFloor = Metric(
            keyWidth: 36,
            spacing: 0,
            groupGap: 1,
            faceInset: 1
        )
        static let compact = Metric(keyWidth: 36, spacing: 4, groupGap: 4)
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
            // arrows · RET · talk · keyboard/mic · TMUX
            let rightCount = (pageKeys ? 2 : 0)
                + 4
                + (includesReturn ? 1 : 0)
                + 1
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
                edgeInset: regularEdgeInset
            ),
            Specification(
                tier: .twoSymbolsAndPages,
                symbols: ["~", "/"],
                pageKeys: true,
                tmux: showsTmux,
                metric: .regular,
                edgeInset: regularEdgeInset
            ),
            Specification(
                tier: .twoSymbols,
                symbols: ["~", "/"],
                pageKeys: false,
                tmux: showsTmux,
                metric: .regular,
                edgeInset: regularEdgeInset
            ),
            Specification(
                tier: .regularEssentials,
                symbols: [],
                pageKeys: false,
                tmux: showsTmux,
                metric: .regular,
                edgeInset: regularEdgeInset
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

    /// The resting frame of every key in a row of `keyCount`, in row order.
    /// Groups are counted, never named — three keys, the tier's symbols, the
    /// rest — so a custom order permutes keys across the same slots and the
    /// gaps stay put. The slack between the minimum row and the usable width
    /// is spread evenly over the group gaps.
    static func keyFrames(
        specification: Specification,
        keyCount: Int,
        includesReturn: Bool,
        width: CGFloat,
        contentSafeArea: UIEdgeInsets,
        keyTop: CGFloat,
        keyHeight: CGFloat
    ) -> [CGRect] {
        guard keyCount > 0 else { return [] }
        let metric = specification.metric
        let leftCount = min(3, keyCount)
        let symbolCount = min(specification.symbols.count, keyCount - leftCount)
        let rightCount = keyCount - leftCount - symbolCount
        var counts = [leftCount]
        if symbolCount > 0 { counts.append(symbolCount) }
        if rightCount > 0 { counts.append(rightCount) }
        let groupGap = includesReturn ? min(metric.groupGap, 8) : metric.groupGap
        let internalSpacingCount = counts.reduce(0) { $0 + max(0, $1 - 1) }
        let minimumContentWidth = CGFloat(keyCount) * metric.keyWidth
            + CGFloat(internalSpacingCount) * metric.spacing
            + CGFloat(counts.count - 1) * groupGap
        let available = max(
            0,
            width - contentSafeArea.left - contentSafeArea.right
                - specification.edgeInset * 2
        )
        let flexibleGap = groupGap
            + max(0, available - minimumContentWidth) / CGFloat(max(1, counts.count - 1))

        var frames: [CGRect] = []
        frames.reserveCapacity(keyCount)
        var x = contentSafeArea.left + specification.edgeInset
        for (groupIndex, count) in counts.enumerated() {
            for keyIndex in 0..<count {
                frames.append(CGRect(x: x, y: keyTop, width: metric.keyWidth, height: keyHeight))
                x += metric.keyWidth
                if keyIndex < count - 1 { x += metric.spacing }
            }
            if groupIndex < counts.count - 1 { x += flexibleGap }
        }
        return frames
    }
}

struct TerminalKeyBarObservedState: Equatable {
    var hardwareKeyboardConnected: Bool
    var keyboardLocked: Bool
    var isDictating: Bool
    /// The talk key latches while this tab's message box is open.
    var talkbackOpen: Bool
    /// Arrange Keys is on for this tab: the keys wiggle and drag, and none
    /// of them sends.
    var arranging: Bool
    /// The app-wide key order (`KeyBarOrderStore`).
    var order: KeyBarOrder
}

/// The iPad terminal's app-owned TALLY key rail. It is a normal UIKit sibling
/// of SwiftTerm, not an input accessory and not a hosted SwiftUI hierarchy.
/// That avoids TextInputUI's Stage Manager rehosting path while preserving one
/// ordered byte route for every key.
@MainActor
final class TerminalKeyBar: UIView, UIInputViewAudioFeedback, KeyBarDropSurface {
    /// The rail is the window's bottom edge on iPad: its keys keep their
    /// full press target, and the chassis below them is trimmed to a hairline
    /// so the terminal keeps the row (the window's own rounded corner and,
    /// where it applies, the home-indicator strip already sit under it).
    static let keyHeight: CGFloat = 34
    static let keyTopInset: CGFloat = 7
    /// Trimmed on iPad/iPhone, where the rail is the window's bottom edge
    /// and the window's own corner already sits under it. The Mac keeps the
    /// authored symmetry — its window bottom is the Mac's, not ours.
    ///
    /// Where the pane instead spends the home-indicator strip (iPhone
    /// landscape, and every iPad window), the rail reaches the display edge:
    /// the hairline would leave the keys sitting on the indicator itself, so
    /// those rails buy back a little daylight below the faces.
    static func keyBottomInset(
        isIOSAppOnMac: Bool,
        spendsBottomStrip: Bool = false
    ) -> CGFloat {
        if isIOSAppOnMac { return keyTopInset }
        return spendsBottomStrip ? 8 : 3
    }

    static let keyBottomInset = keyBottomInset(
        isIOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac
    )
    static let barHeight: CGFloat = keyTopInset + keyHeight + keyBottomInset

    /// The rail's height for a pane that does (or does not) spend the bottom
    /// strip. `barHeight` is the plain case, kept as a constant because the
    /// top rail mirrors it for its own minimum height.
    static func barHeight(spendsBottomStrip: Bool) -> CGFloat {
        keyTopInset + keyHeight + keyBottomInset(
            isIOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac,
            spendsBottomStrip: spendsBottomStrip
        )
    }

    var contentSafeArea = UIEdgeInsets.zero {
        didSet {
            guard contentSafeArea != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// Whether this rail reaches the window's own bottom edge rather than the
    /// bottom safe area's. Only the chassis below the faces changes with it.
    var spendsBottomStrip = false {
        didSet {
            guard spendsBottomStrip != oldValue else { return }
            invalidateIntrinsicContentSize()
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
    /// The app-wide key order; injected so a test rail can arrange against
    /// its own defaults.
    private let orderStore: KeyBarOrderStore
    private let topBorder = UIView()
    private var ctrlLatched = false
    private var observedState: TerminalKeyBarObservedState?
    private var observationGeneration = 0
    private var renderedSignature: RenderSignature?
    /// The row in the user's order — every key with the slot it occupies.
    private var rendered: [RenderedKey] = []
    var renderedKeys: [TerminalTallyKeyControl] { rendered.map(\.control) }
    var renderedSlots: [KeyBarSlot] { rendered.map(\.slot) }
    private weak var ctrlKeyControl: TerminalTallyKeyControl?
    private weak var talkKeyControl: TerminalTallyKeyControl?
    private weak var shortcutKeyControl: TerminalTallyKeyControl?
    private(set) lazy var dropCoordinator = KeyBarDropCoordinator(surface: self)
    /// The ARRANGE KEYS bar — the mode's lamp, RESET, DONE — hung over the
    /// rail the way the C / B slab is, so it rides with the keys above a
    /// docked keyboard.
    private var arrangeBar: TerminalContextBarView?
    private var arrangeBarOffersReset = false
    var isArrangingForTesting: Bool { observedState?.arranging == true }
    var arrangeBarForTesting: TerminalContextBarView? { arrangeBar }
    private weak var shortcutPopoverController: UIViewController?
    private let keyCommandsPresenter = KeyCommandPanelPresenter()
    /// The tier's Key Commands cap and paywall route, handed down with the
    /// pane's configuration; the rail carries it to the presenter unread.
    var keyCommandPlan: KeyCommandPlan = .unrestricted
    private var ctrlComboView: TerminalCtrlComboView?
    var ctrlCombosArePresentedForTesting: Bool { ctrlComboView != nil }

    /// What forces a rebuild of the row. The talk key's latch is deliberately
    /// not part of it — it flips in place, like CTRL's, so opening the
    /// message box never re-creates the keys under the finger.
    private struct RenderSignature: Equatable {
        var tier: TerminalKeyBarLayout.Tier
        var hardwareKeyboardConnected: Bool
        var keyboardLocked: Bool
        var isDictating: Bool

        init(tier: TerminalKeyBarLayout.Tier, state: TerminalKeyBarObservedState) {
            self.tier = tier
            hardwareKeyboardConnected = state.hardwareKeyboardConnected
            keyboardLocked = state.keyboardLocked
            isDictating = state.isDictating
        }
    }

    init(
        terminal: TerminalView,
        controller: TerminalSessionController?,
        performShortcut: @escaping (ShortcutPanelItem) -> Void,
        finishTmuxCopyMode: @escaping () -> Void,
        shortcutBackend: Host.SessionBackend?,
        orderStore: KeyBarOrderStore = .shared
    ) {
        self.terminal = terminal
        self.controller = controller
        self.performShortcut = performShortcut
        self.finishTmuxCopyMode = finishTmuxCopyMode
        self.shortcutBackend = shortcutBackend
        self.orderStore = orderStore
        showsReturnKey = UIDevice.current.userInterfaceIdiom == .pad
        ctrlLatched = terminal.controlModifier
        super.init(frame: .zero)

        backgroundColor = UIKitChassis.bezel
        accessibilityIdentifier = "terminal.keybar"
        topBorder.backgroundColor = UIKitChassis.bezelHi
        topBorder.isAccessibilityElement = false
        addSubview(topBorder)
        dropCoordinator.installDropTarget(on: self)
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
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: Self.barHeight(spendsBottomStrip: spendsBottomStrip)
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The rail's own faces never animate: a row rebuilt or re-tiered
        // inside someone else's animation block (the Talkback card's spring
        // runs the window's whole render, and this pass lands in its
        // `layoutIfNeeded`) would otherwise fly its keys in from zero
        // frames. The rail as a whole still rides its container's motion.
        UIView.performWithoutAnimation {
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
            // The order permutes the same keys: the row flips in place.
            let arranged = orderStore.order.arrange(renderedSlots)
            if arranged != renderedSlots {
                let bySlot = Dictionary(uniqueKeysWithValues: rendered.map { ($0.slot, $0) })
                rendered = arranged.compactMap { bySlot[$0] }
            }
            talkKeyControl?.isLatched = state.talkbackOpen
            talkKeyControl?.accessibilityLabel = talkbackKeyLabel(open: state.talkbackOpen)
            applyArranging(state.arranging, offersReset: !orderStore.order.isStandard)
            layoutRow(specification: specification, includesReturn: includesReturn)
            bringSubviewToFront(topBorder)
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            hideCtrlCombos()
            // The mode is this rail's to show; a rail leaving the window (a
            // tab switch, a merge, a close) takes the mode with it.
            hideArrangeBar()
            controller?.setKeyBarArranging(false)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The bar mounts in the window; a rail that joins one mid-mode
        // (rare — the mode ends on leaving) hangs it on the next pass.
        if window != nil, observedState?.arranging == true { setNeedsLayout() }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        // A key released over the terminal above the rail still lands.
        if let superview { dropCoordinator.installDropTarget(on: superview) }
    }

    /// Tests paint a state without waiting on the observation's turn — the
    /// UMD bar's and the pane's seam.
    func applyObservedState(_ state: TerminalKeyBarObservedState) {
        observedState = state
        setNeedsLayout()
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
            isDictating: controller?.isDictating == true,
            talkbackOpen: controller?.talkbackOpen == true,
            arranging: controller?.keyBarArranging == true,
            order: orderStore.order
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
        // The layout pass compares render signatures itself: a state change
        // that only moves the talk latch re-latches in place; the rest
        // rebuild the row.
        setNeedsLayout()
    }

    private func rebuildRow(
        specification: TerminalKeyBarLayout.Specification,
        state: TerminalKeyBarObservedState
    ) {
        dropCoordinator.cancelLanding()
        for entry in rendered { entry.control.removeFromSuperview() }
        rendered.removeAll(keepingCapacity: true)
        ctrlKeyControl = nil
        talkKeyControl = nil
        shortcutKeyControl = nil
        let metric = specification.metric
        let includesReturn = showsReturnKey || state.keyboardLocked

        // Tap CTRL latches (and raises the C / B slab); a hold on the same
        // key opens Key Commands and never toggles the latch.
        var control = caps(
            "CTRL", .ctrl, String(localized: "Control"),
            identifier: "control", slot: .control, latched: ctrlLatched
        )
        control.longPressKey = .keyCommands
        var descriptors: [RailKey] = [
            caps("ESC", .esc, String(localized: "Escape"), identifier: "escape", slot: .escape),
            control,
            caps("TAB", .tab, String(localized: "Tab"), identifier: "tab", slot: .tab),
        ]
        descriptors += specification.symbols.compactMap { symbol in
            symbolSlot(symbol).map { slot in
                RailKey(
                    key: .text(symbol),
                    slot: slot,
                    face: .text(symbol, font: UIKitChassis.monoFont(15), kerning: 0),
                    accessibility: symbol,
                    identifier: "symbol.\(slot.rawValue)"
                )
            }
        }
        if specification.pageKeys {
            descriptors.append(arrowKey(
                "arrow.up.to.line", .pageUp, String(localized: "Page up"),
                identifier: "pageUp", slot: .pageUp
            ))
            descriptors.append(arrowKey(
                "arrow.down.to.line", .pageDown, String(localized: "Page down"),
                identifier: "pageDown", slot: .pageDown
            ))
        }
        descriptors.append(contentsOf: [
            arrowKey(
                "arrow.left", .left, String(localized: "Arrow left"),
                identifier: "left", slot: .left
            ),
            arrowKey("arrow.up", .up, String(localized: "Arrow up"), identifier: "up", slot: .up),
            arrowKey(
                "arrow.down", .down, String(localized: "Arrow down"),
                identifier: "down", slot: .down
            ),
            arrowKey(
                "arrow.right", .right, String(localized: "Arrow right"),
                identifier: "right", slot: .right
            ),
        ])
        if includesReturn {
            descriptors.append(RailKey(
                key: .returnKey,
                slot: .returnKey,
                face: .symbol("return", pointSize: 12, weight: .semibold),
                accessibility: String(localized: "Return"),
                identifier: "return"
            ))
        }
        // Talkback — the message box under the pane; RET · talk · keyboard.
        // Latched while the box is open, like CTRL and the keyboard lock.
        descriptors.append(RailKey(
            key: .talkback,
            slot: .talkback,
            face: .symbol("text.bubble", pointSize: 13, weight: .semibold),
            accessibility: talkbackKeyLabel(open: state.talkbackOpen),
            identifier: "talkback",
            latched: state.talkbackOpen
        ))
        // One slot, two occupants — the mic beside a hardware keyboard, the
        // keyboard key without one. An order names the slot, so it holds.
        if state.hardwareKeyboardConnected {
            descriptors.append(RailKey(
                key: .dictation,
                slot: .keyboard,
                face: .symbol(
                    state.isDictating ? "mic.fill" : "mic",
                    pointSize: 13,
                    weight: .semibold
                ),
                accessibility: state.isDictating
                    ? String(localized: "Stop dictation")
                    : String(localized: "Dictate"),
                identifier: "dictation",
                latched: state.isDictating
            ))
        } else {
            descriptors.append(RailKey(
                key: .keyboard,
                slot: .keyboard,
                face: .symbol(
                    state.keyboardLocked ? "lock.fill" : "keyboard",
                    pointSize: 13,
                    weight: .semibold
                ),
                accessibility: state.keyboardLocked
                    ? String(localized: "Unlock keyboard")
                    : String(localized: """
                        Show or hide keyboard. Hold to lock the keyboard closed
                        """),
                identifier: "keyboard",
                latched: state.keyboardLocked,
                longPressKey: state.keyboardLocked ? nil : .lockKeyboard
            ))
        }
        if specification.tmux, let backend = shortcutBackend {
            // The identifier names the slot, not the occupant — debug hooks
            // and tests address "tmux" for either backend's key.
            descriptors.append(RailKey(
                key: .showShortcutPanel,
                slot: .shortcuts,
                face: .text(
                    backend == .herdr ? "HRDR" : "TMUX",
                    font: UIKitChassis.monoFont(9, weight: .semibold),
                    kerning: 0.7
                ),
                accessibility: backend == .herdr
                    ? String(localized: "Show herdr shortcuts")
                    : String(localized: "Show tmux shortcuts"),
                identifier: "tmux"
            ))
        }

        // The tier decided WHICH keys the row carries; the order decides
        // where each one sits. Groups are counted at layout, so the gaps
        // stay put whatever lands in them.
        let bySlot = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.slot, $0) })
        for slot in orderStore.order.arrange(descriptors.map(\.slot)) {
            guard let descriptor = bySlot[slot] else { continue }
            let control = TerminalTallyKeyControl(
                face: descriptor.face,
                width: metric.keyWidth,
                height: Self.keyHeight,
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
            if let hold = descriptor.longPressKey { control.longPressDuration = hold.holdDuration }
            control.accessibilityUserInputLabels = [descriptor.accessibility]
            control.arrangeDragItem = { [weak self] session in
                self?.dropCoordinator.makeDragItem(for: slot, session: session)
            }
            addSubview(control)
            rendered.append(RenderedKey(slot: slot, control: control))
            switch slot {
            case .control: ctrlKeyControl = control
            case .talkback: talkKeyControl = control
            case .shortcuts: shortcutKeyControl = control
            default: break
            }
        }
    }

    /// Every key's resting frame for the row as it stands (`rendered` order).
    private func restingFrames(
        specification: TerminalKeyBarLayout.Specification,
        includesReturn: Bool
    ) -> [CGRect] {
        TerminalKeyBarLayout.keyFrames(
            specification: specification,
            keyCount: rendered.count,
            includesReturn: includesReturn,
            width: bounds.width,
            contentSafeArea: contentSafeArea,
            keyTop: Self.keyTopInset,
            keyHeight: Self.keyHeight
        )
    }

    private func layoutRow(
        specification: TerminalKeyBarLayout.Specification,
        includesReturn: Bool
    ) {
        let frames = restingFrames(specification: specification, includesReturn: includesReturn)
        for (entry, frame) in zip(rendered, frames) {
            entry.control.frame = frame
        }
    }

    // MARK: Arrange Keys

    /// Flips the mode in place — never a rebuild under a finger.
    /// `offersReset`: the order differs from the shipped one.
    private func applyArranging(_ arranging: Bool, offersReset: Bool) {
        if !arranging { dropCoordinator.clearTarget() }
        for entry in rendered where entry.control.isArranging != arranging {
            entry.control.isArranging = arranging
            entry.control.accessibilityCustomActions = arranging
                ? keyMoveActions { [weak self] in self?.moveKey(entry.slot, by: $0) ?? false }
                : nil
        }
        if arranging {
            showArrangeBar(offersReset: offersReset)
        } else {
            hideArrangeBar()
        }
    }

    private func showArrangeBar(offersReset: Bool) {
        if arrangeBar != nil, arrangeBarOffersReset == offersReset { return }
        hideArrangeBar()
        let bar = TerminalContextBarView.arrangeKeys(
            canReset: offersReset,
            reset: { [weak self] in self?.orderStore.reset() },
            done: { [weak self] in self?.controller?.setKeyBarArranging(false) }
        )
        bar.accessibilityIdentifier = "terminal.keybar.arrangeBar"
        guard mountOverRail(bar, centerX: bar.centerXAnchor.constraint(equalTo: centerXAnchor)) else { return }
        dropCoordinator.installDropTarget(on: bar)
        arrangeBar = bar
        arrangeBarOffersReset = offersReset
    }

    private func hideArrangeBar() {
        arrangeBar?.removeFromSuperview()
        arrangeBar = nil
    }

    /// The C / B slab's mount, shared with the ARRANGE KEYS bar: a window
    /// subview pinned over the rail's top, so it rides with the rail above a
    /// docked keyboard. The slab may overrun the trailing edge (the C / B
    /// slab on a phone); the bar is clamped inside both.
    @discardableResult
    private func mountOverRail(
        _ slab: UIView,
        centerX: NSLayoutConstraint,
        clampsTrailing: Bool = true
    ) -> Bool {
        guard let window else { return false }
        slab.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(slab)
        centerX.priority = .defaultHigh
        var constraints = [
            centerX,
            slab.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            slab.bottomAnchor.constraint(equalTo: topAnchor, constant: -6),
        ]
        if clampsTrailing {
            constraints.append(slab.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8))
        }
        NSLayoutConstraint.activate(constraints)
        return true
    }

    /// One step along the row — VoiceOver's road and the headless proof's.
    @discardableResult
    func moveKey(_ slot: KeyBarSlot, by delta: Int) -> Bool {
        let slots = renderedSlots
        guard let index = slots.firstIndex(of: slot),
              slots.indices.contains(index + delta)
        else { return false }
        let order = orderStore.order.moving(slot, toVisibleIndex: index + delta, among: slots)
        guard order != orderStore.order else { return false }
        orderStore.setOrder(order)
        return true
    }

    // MARK: KeyBarDropSurface

    func canArrange(_ slot: KeyBarSlot) -> Bool {
        observedState?.arranging == true && rendered.contains { $0.slot == slot }
    }

    var dropControls: [RenderedKey] { rendered }

    /// Lands `source` on `target` and writes the order; the layout pass
    /// flips the row in place from the store's change.
    @discardableResult
    func dropKey(_ source: KeyBarSlot, onto target: KeyBarSlot) -> Bool {
        let slots = renderedSlots
        guard source != target,
              slots.contains(source),
              let targetIndex = slots.firstIndex(of: target)
        else { return false }
        let order = orderStore.order.moving(source, toVisibleIndex: targetIndex, among: slots)
        guard order != orderStore.order else { return false }
        orderStore.setOrder(order)
        setNeedsLayout()
        return true
    }

    func layoutAfterDrop() {
        layoutIfNeeded()
    }

    private func press(_ key: TerminalKey) {
        guard let terminal else { return }
        switch key {
        case .esc:
            click()
            terminal.send(EscapeSequences.cmdEsc)
        case .ctrl:
            // Ignore a late tap after the hold presents.
            guard !keyCommandsPresenter.isPresented else { return }
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
        case .talkback:
            click()
            controller?.toggleTalkback()
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
        case .keyCommands:
            showKeyCommandsPanel()
        }
    }

    /// Hold CTRL: the KEY COMMANDS popover, anchored to the CTRL key like the
    /// TMUX dropdown to its own. The presenter owns the lifecycle; this rail
    /// supplies the anchor, the click, and the opaque chassis ground.
    private func showKeyCommandsPanel() {
        hideCtrlCombos()
        guard let terminal, let presenter = presentingViewController else { return }
        let sceneWidth = window?.bounds.width ?? presenter.view.bounds.width
        keyCommandsPresenter.present(
            from: presenter,
            anchor: ctrlKeyControl ?? self,
            terminal: terminal,
            maximumWidth: max(280, sceneWidth - 24),
            plan: keyCommandPlan,
            feedback: { [weak self] in self?.click() },
            configure: { panel, popover in
                panel.view.backgroundColor = UIKitChassis.bezel
                popover.backgroundColor = UIKitChassis.bezel
            }
        )
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
                if !item.keepsPanelOpen {
                    self?.shortcutPopoverController?.dismiss(animated: true)
                }
                self?.press(.shortcut(item))
            },
            // A held resize row repeats coarse steps — clicked like a press,
            // dispatched straight to the controller (no dismissal decision).
            selectCoarse: { [weak self] item in
                self?.click()
                self?.controller?.performPanelShortcutCoarse(item)
            },
            rename: { [weak self] item, name in
                self?.click()
                self?.controller?.performPanelRename(item, to: name)
            },
            loadChoices: { [weak self] in
                await self?.controller?.loadShortcutSwitchChoices()
            },
            // Switching leaves the panel up: the list is a switchboard, and
            // hopping windows should not cost a reopen.
            selectChoice: { [weak self] choice in
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
            // Anchored to the TMUX/HRDR key wherever the order put it; the
            // trailing corner is the fallback for a rail without the key.
            popover.sourceRect = shortcutKeyControl?.frame ?? CGRect(
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
        guard !keyCommandsPresenter.isPresented, ctrlComboView == nil, window != nil else { return }
        let slab = TerminalCtrlComboView(
            faceHeight: 34,
            padding: 8,
            fontSize: 15
        ) { [weak self] letter in
            self?.sendCtrlCombo(letter)
        }
        layoutIfNeeded()
        let anchorX = ctrlKeyControl?.frame.midX ?? 85
        mountOverRail(
            slab,
            centerX: slab.centerXAnchor.constraint(equalTo: leadingAnchor, constant: anchorX),
            clampsTrailing: false
        )
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
        slot: KeyBarSlot,
        latched: Bool = false
    ) -> RailKey {
        RailKey(
            key: key,
            slot: slot,
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
        identifier: String,
        slot: KeyBarSlot
    ) -> RailKey {
        RailKey(
            key: key,
            slot: slot,
            face: .symbol(image, pointSize: 12, weight: .semibold),
            accessibility: accessibility,
            identifier: identifier,
            repeats: true
        )
    }

    private func symbolSlot(_ symbol: String) -> KeyBarSlot? {
        switch symbol {
        case "~": .tilde
        case "|": .pipe
        case "/": .slash
        case "-": .hyphen
        default: nil
        }
    }

    #if DEBUG
    func debugShowTmuxShortcuts() {
        guard let terminal, TerminalFocusArbiter.current === terminal else { return }
        showShortcutPanel()
    }

    /// Hold CTRL, headlessly. `setup` lands on the CUSTOM SETUP tab and
    /// `compose` also adds a row so its composer is up. A panel already
    /// present just moves, so one capture run can walk every state.
    func debugShowKeyCommands(_ mode: KeyCommandDebugMode) {
        guard let terminal, TerminalFocusArbiter.current === terminal else { return }
        if !keyCommandsPresenter.isPresented { showKeyCommandsPanel() }
        keyCommandsPresenter.panel?.debugShow(mode)
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

    /// The `⋯` menu's Arrange Keys, headlessly (no simulator route can open
    /// a native menu). Posting again is DONE.
    func debugToggleArranging() {
        controller?.toggleKeyBarArranging()
    }

    /// A headless drop: the leftmost key moves to the row's end through the
    /// order model, proving the write-back and every rail's rebuild.
    func debugMoveFirstKeyToEnd() {
        guard let first = renderedSlots.first else { return }
        moveKey(first, by: rendered.count - 1)
    }
    #endif
}

private struct RailKey {
    var key: TerminalKey
    /// The position this key occupies in the user's order.
    var slot: KeyBarSlot
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
    case talkback
    case showShortcutPanel
    case shortcut(ShortcutPanelItem)
    case keyCommands

    /// How long a rail key must hold before it fires this as its hold
    /// action. Key Commands is the daily path and holds shorter than the
    /// keyboard key's lock.
    var holdDuration: TimeInterval {
        switch self {
        case .keyCommands: KeyCommandPanelViewController.controlHoldDuration
        default: 0.5
        }
    }
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

        for mode in KeyCommandDebugMode.allCases {
            var token: Int32 = 0
            notify_register_dispatch(
                "app.multiplexterm.multiplex.debug.\(mode.hookName)", &token, .main
            ) { _ in focusedBar()?.debugShowKeyCommands(mode) }
        }

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

}

/// The rail beside the focused terminal — every headless hook's target.
@MainActor
private func focusedBar() -> TerminalKeyBar? {
    guard let view = TerminalFocusArbiter.current else { return nil }
    return view.superview?.subviews.compactMap { $0 as? TerminalKeyBar }.first
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
        ) { _ in focusedBar()?.debugExercise() }

        var dictationToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.dictation", &dictationToken, .main
        ) { _ in focusedBar()?.debugToggleDictation() }

        var arrangeToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.arrangekeys", &arrangeToken, .main
        ) { _ in focusedBar()?.debugToggleArranging() }

        var arrangeMoveToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.arrangekeysmove", &arrangeMoveToken, .main
        ) { _ in focusedBar()?.debugMoveFirstKeyToEnd() }
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
/// one notification still emits one proof sequence. It is also the Arrange
/// Keys drop surface: the two slabs flanking the UMD are separate views, and
/// a key dropped on the other slab crosses the UMD.
@MainActor
final class TerminalKeyClusterContext: KeyBarDropSurface {
    /// The keys the ornament carries, in shipped order — three leading, seven
    /// trailing. The user's order permutes them across those ten slots.
    static let ornamentSlots: [KeyBarSlot] = [
        .escape, .control, .tab, .left, .up, .down, .right, .returnKey, .talkback, .keyboard,
    ]
    static let leadingSlotCount = 3
    private static let arrowSlots: Set<KeyBarSlot> = [.left, .up, .down, .right]

    private weak var controller: TerminalSessionController?
    private(set) weak var observedTerminal: TerminalView?
    /// The tier's Key Commands cap and paywall route, set by the window that
    /// holds the entitlement store; every group of this context presents
    /// with it.
    var keyCommandPlan: KeyCommandPlan = .unrestricted
    private let orderStore: KeyBarOrderStore
    private let groups = NSHashTable<TerminalKeyClusterGroupView>.weakObjects()
    private var controlResetObserver: NSObjectProtocol?
    private var stateObservationGeneration = 0
    private(set) lazy var dropCoordinator = KeyBarDropCoordinator(surface: self)
    #if DEBUG
    private var debugObservers: [NSObjectProtocol] = []
    #endif

    private(set) var ctrlLatched = false
    /// The talk key latches while the active tab's message box is open —
    /// read from the controller, never mirrored.
    var talkbackOpen: Bool { controller?.talkbackOpen == true }
    /// Arrange Keys is on for the active tab.
    var arranging: Bool { controller?.keyBarArranging == true }
    var order: KeyBarOrder { orderStore.order }

    init(orderStore: KeyBarOrderStore = .shared) {
        self.orderStore = orderStore
        observeOrderAndMode()
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
            center.addObserver(
                forName: .multiplexDebugKeyCommands,
                object: nil,
                queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let mode = note.userInfo?["mode"] as? KeyCommandDebugMode else { return }
                    self?.debugShowKeyCommands(mode)
                }
            },
            center.addObserver(
                forName: .multiplexDebugArrangeKeys,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.debugToggleArranging() }
            },
            center.addObserver(
                forName: .multiplexDebugArrangeKeysMove,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.debugMoveFirstKeyToEnd() }
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
        if controllerChanged {
            // The mode is the active tab's to show; a tab going off the
            // ornament takes it along (the iPad rail ends it on leaving its
            // window — there is no such moment for an ornament slab).
            self.controller?.setKeyBarArranging(false)
            dropCoordinator.clearTarget()
        }
        self.controller = controller
        let terminal = controller?.terminalView
        if controllerChanged {
            observeOrderAndMode()
            rebuildAllIfSlotsChanged()
        }
        // Every group applies the context's state on its own update; only a
        // changed terminal re-registers the latch-reset observer.
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
        dropCoordinator.installDropTarget(on: group)
        group.applyContextState()
    }

    /// The console row is one drop surface: the ornament enrols the UMD and
    /// the ARRANGE KEYS slab between and below the key slabs, so a key
    /// released there still lands beside the nearer key.
    func installDropTarget(on host: UIView) {
        dropCoordinator.installDropTarget(on: host)
    }

    // MARK: Order

    /// The keys a role shows, in the user's order: the first three of the
    /// ornament's sequence lead, the other seven trail; a standalone slab
    /// shows the lot (its minimal tier drops the arrows first).
    func slots(for role: TerminalKeyClusterGroupView.Role, minimal: Bool) -> [KeyBarSlot] {
        let ordered = order.arrange(Self.ornamentSlots)
        switch role {
        case .leading:
            return Array(ordered.prefix(Self.leadingSlotCount))
        case .trailing:
            return Array(ordered.dropFirst(Self.leadingSlotCount))
        case .standalone:
            return minimal
                ? order.arrange(Self.ornamentSlots.filter { !Self.arrowSlots.contains($0) })
                : ordered
        }
    }

    /// The store's order and the tab's mode, watched here rather than by
    /// each fitting candidate: a change rebuilds the slabs whose keys moved
    /// and flips the arranging state on every registered group.
    private func observeOrderAndMode() {
        stateObservationGeneration &+= 1
        let generation = stateObservationGeneration
        withObservationTracking {
            _ = orderStore.order
            _ = controller?.keyBarArranging
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.stateObservationGeneration else { return }
                self.observeOrderAndMode()
                self.rebuildAllIfSlotsChanged()
                self.broadcast()
            }
        }
    }

    /// Only slabs whose rendered keys no longer match the order rebuild.
    private func rebuildAllIfSlotsChanged() {
        for group in groups.allObjects { group.rebuildIfSlotsChanged() }
    }

    /// One step along the sequence — VoiceOver's road and the headless
    /// proof's; crossing the UMD is just an index.
    @discardableResult
    func moveKey(_ slot: KeyBarSlot, by delta: Int) -> Bool {
        let sequence = dropControls.map(\.slot)
        guard let index = sequence.firstIndex(of: slot),
              sequence.indices.contains(index + delta)
        else { return false }
        let moved = order.moving(slot, toVisibleIndex: index + delta, among: sequence)
        guard moved != order else { return false }
        orderStore.setOrder(moved)
        rebuildAllIfSlotsChanged()
        return true
    }

    // MARK: KeyBarDropSurface

    /// The slabs on screen, leading first (or the standalone one alone).
    /// `ViewThatFits` may keep discarded candidates registered; only one per
    /// role is in the window with real bounds.
    private func visibleGroups() -> [TerminalKeyClusterGroupView] {
        let onScreen = groups.allObjects.filter {
            $0.window != nil && !$0.isHidden && $0.alpha > 0 && !$0.bounds.isEmpty
        }
        if let standalone = onScreen.first(where: { $0.role == .standalone }) { return [standalone] }
        return [onScreen.first { $0.role == .leading }, onScreen.first { $0.role == .trailing }]
            .compactMap { $0 }
    }

    func canArrange(_ slot: KeyBarSlot) -> Bool {
        arranging && dropControls.contains { $0.slot == slot }
    }

    /// Both slabs' keys as one row.
    var dropControls: [RenderedKey] { visibleGroups().flatMap(\.rendered) }

    /// Lands `source` on `target` and writes the order — across the UMD
    /// when the target sits in the other slab; the slabs whose keys moved
    /// rebuild.
    @discardableResult
    func dropKey(_ source: KeyBarSlot, onto target: KeyBarSlot) -> Bool {
        let sequence = dropControls.map(\.slot)
        guard source != target,
              sequence.contains(source),
              let targetIndex = sequence.firstIndex(of: target)
        else { return false }
        let moved = order.moving(source, toVisibleIndex: targetIndex, among: sequence)
        guard moved != order else { return false }
        orderStore.setOrder(moved)
        rebuildAllIfSlotsChanged()
        return true
    }

    func layoutAfterDrop() {
        for group in visibleGroups() { group.layoutIfNeeded() }
    }

    // MARK: Keys

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

    func toggleTalkback() {
        controller?.toggleTalkback()
        // The window re-renders every group on the open flip; the broadcast
        // latches the sibling candidates this same turn.
        broadcast()
    }

    func toggleControl(from group: TerminalKeyClusterGroupView) {
        // Ignore a late tap after a cluster hold presents.
        guard allowsCtrlComboPresentation,
              let terminal = observedTerminal
        else { return }
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

    // `ViewThatFits` can retain multiple cluster candidates.
    var allowsCtrlComboPresentation: Bool {
        !groups.allObjects.contains { $0.keyCommandsArePresented }
    }

    func prepareForKeyCommandsPresentation() -> Bool {
        guard allowsCtrlComboPresentation else { return false }
        hideCtrlCombos()
        return true
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

    private func debugShowKeyCommands(_ mode: KeyCommandDebugMode) {
        guard let terminal = observedTerminal,
              TerminalFocusArbiter.current === terminal
        else { return }
        visibleControlGroup?.debugShowKeyCommands(mode)
    }

    /// The `⋯` menu's Arrange Keys, headlessly; posting again is DONE.
    private func debugToggleArranging() {
        guard let terminal = observedTerminal,
              TerminalFocusArbiter.current === terminal
        else { return }
        controller?.toggleKeyBarArranging()
    }

    /// A headless drop: the leftmost key moves to the sequence's end — from
    /// the leading slab across the UMD into the trailing one.
    private func debugMoveFirstKeyToEnd() {
        guard let terminal = observedTerminal,
              TerminalFocusArbiter.current === terminal
        else { return }
        let sequence = dropControls.map(\.slot)
        guard let first = sequence.first else { return }
        moveKey(first, by: sequence.count - 1)
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
    private weak var talkKey: TerminalTallyKeyControl?
    private weak var comboPopoverController: UIViewController?
    private let keyCommandsPresenter = KeyCommandPanelPresenter()
    /// The slab's keys with the slots they occupy, in row order.
    private(set) var rendered: [RenderedKey] = []
    var keys: [TerminalTallyKeyControl] { rendered.map(\.control) }
    var renderedSlots: [KeyBarSlot] { rendered.map(\.slot) }

    /// Whether the CTRL key landed in this slab (the user's order decides).
    var carriesControlKey: Bool { ctrlKey != nil }
    var keyCommandsArePresented: Bool { keyCommandsPresenter.isPresented }
    var ctrlCombosArePresentedForTesting: Bool { comboPopoverController != nil }

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
        layoutKeys()
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
        talkKey?.isLatched = context.talkbackOpen
        talkKey?.accessibilityLabel = talkbackKeyLabel(open: context.talkbackOpen)
        let arranging = context.arranging
        for entry in rendered where entry.control.isArranging != arranging {
            entry.control.isArranging = arranging
            entry.control.accessibilityCustomActions = arranging
                ? keyMoveActions { [weak context] in context?.moveKey(entry.slot, by: $0) ?? false }
                : nil
        }
    }

    /// Rebuilds only when the order changed this slab's keys.
    func rebuildIfSlotsChanged() {
        let expected = context.slots(for: role, minimal: standaloneVariant == .minimal)
        guard renderedSlots != expected else { return }
        rebuildKeys(variant: standaloneVariant)
        setNeedsLayout()
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
        guard context.allowsCtrlComboPresentation,
              comboPopoverController == nil,
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

    /// Hold CTRL: the KEY COMMANDS popover above the ornament's CTRL key —
    /// the C / B slab's mechanism. The presenter owns the lifecycle; this
    /// ornament supplies the anchor and carries its appearance and glass
    /// mirroring across the popover's own window.
    func showKeyCommands() {
        guard context.prepareForKeyCommandsPresentation(),
              let ctrlKey,
              let terminal = context.observedTerminal,
              let presenter = presentingViewController
        else { return }
        let sceneWidth = window?.bounds.width ?? presenter.view.bounds.width
        keyCommandsPresenter.present(
            from: presenter,
            anchor: ctrlKey,
            terminal: terminal,
            maximumWidth: max(280, sceneWidth - 24),
            plan: context.keyCommandPlan
        ) { panel, _ in
            panel.overrideUserInterfaceStyle = overrideUserInterfaceStyle
            panel.view.traitOverrides[GlassAppearanceTrait.self] =
                traitCollection[GlassAppearanceTrait.self]
            panel.view.backgroundColor = GlassPrototype.popoverGround(
                fallback: TallyPalette.bezel
            )
        }
    }

    #if DEBUG
    func debugShowKeyCommands(_ mode: KeyCommandDebugMode) {
        if !keyCommandsPresenter.isPresented { showKeyCommands() }
        keyCommandsPresenter.panel?.debugShow(mode)
    }
    #endif

    // MARK: Geometry

    /// Every slot's resting frame, in row order — the slab's authored
    /// rhythm, which never changes with the order.
    private func slotFrames() -> [CGRect] {
        let runs: [Int]
        switch role {
        case .leading:
            runs = [rendered.count]
        case .trailing:
            runs = [4] + Array(repeating: 1, count: max(0, rendered.count - 4))
        case .standalone:
            let arrows = standaloneVariant == .minimal ? 0 : 4
            runs = [3] + (arrows > 0 ? [arrows] : [])
                + Array(repeating: 1, count: max(0, rendered.count - 3 - arrows))
        }
        return Self.slotFrames(
            widths: rendered.map(\.control.preferredSize.width),
            runs: runs,
            spacing: activeMetric.spacing,
            groupGap: activeMetric.groupGap
        )
    }

    /// Runs of keys `spacing` apart and a `groupGap` between runs (the
    /// pre-UIKit `HStack(spacing: groupGap)`), from the slab's 12-point
    /// inset. Pure: the drop geometry reads these frames.
    static func slotFrames(
        widths: [CGFloat],
        runs: [Int],
        spacing: CGFloat,
        groupGap: CGFloat
    ) -> [CGRect] {
        var frames: [CGRect] = []
        var remaining = widths[...]
        var x: CGFloat = 12
        for (runIndex, count) in runs.enumerated() {
            if runIndex > 0 { x += groupGap }
            for index in 0..<count {
                guard let width = remaining.popFirst() else { return frames }
                frames.append(CGRect(x: x, y: 9, width: width, height: 26))
                x += width
                if index < count - 1 { x += spacing }
            }
        }
        return frames
    }

    private func layoutKeys() {
        for (entry, frame) in zip(rendered, slotFrames()) {
            entry.control.frame = frame
        }
    }

    private var activeMetric: TerminalKeyClusterMetric {
        role == .standalone && standaloneVariant != .regular
            ? TerminalKeyClusterMetric.compact
            : metric
    }

    // MARK: Keys

    private func rebuildKeys(variant: StandaloneVariant?) {
        for entry in rendered { entry.control.removeFromSuperview() }
        rendered.removeAll(keepingCapacity: true)
        ctrlKey = nil
        talkKey = nil
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
        // The slab's slots are authored; the user's order decides which key
        // sits in each — so a key can lead here and trail after a drag.
        for slot in context.slots(for: role, minimal: minimal) {
            guard let control = makeKey(slot, activeMetric) else { continue }
            control.arrangeDragItem = { [weak context] session in
                context?.dropCoordinator.makeDragItem(for: slot, session: session)
            }
            addSubview(control)
            rendered.append(RenderedKey(slot: slot, control: control))
        }
        applyContextState()
    }

    /// Rail-only slots never reach a cluster (`ornamentSlots`): nil, never
    /// a stand-in key.
    private func makeKey(
        _ slot: KeyBarSlot,
        _ metric: TerminalKeyClusterMetric
    ) -> TerminalTallyKeyControl? {
        switch slot {
        case .escape:
            return caps("ESC", String(localized: "Escape"), metric, identifier: "escape") { [weak context] in
                context?.sendEscape()
            }
        case .control:
            let control = caps(
                "CTRL",
                String(localized: "Control"),
                metric,
                identifier: "control",
                latched: context.ctrlLatched
            ) { [weak self, weak context] in
                guard let self, let context else { return }
                context.toggleControl(from: self)
            }
            // Hold CTRL opens Key Commands and never toggles the latch.
            control.longPressDuration = KeyCommandPanelViewController.controlHoldDuration
            control.longPressAction = { [weak self] in
                self?.showKeyCommands()
            }
            ctrlKey = control
            return control
        case .tab:
            return caps("TAB", String(localized: "Tab"), metric, identifier: "tab") { [weak context] in
                context?.sendTab()
            }
        case .left:
            return arrow(
                "arrow.left", String(localized: "Arrow left"), metric,
                identifier: "left",
                app: EscapeSequences.moveLeftApp,
                normal: EscapeSequences.moveLeftNormal
            )
        case .up:
            return arrow(
                "arrow.up", String(localized: "Arrow up"), metric,
                identifier: "up",
                app: EscapeSequences.moveUpApp,
                normal: EscapeSequences.moveUpNormal
            )
        case .down:
            return arrow(
                "arrow.down", String(localized: "Arrow down"), metric,
                identifier: "down",
                app: EscapeSequences.moveDownApp,
                normal: EscapeSequences.moveDownNormal
            )
        case .right:
            return arrow(
                "arrow.right", String(localized: "Arrow right"), metric,
                identifier: "right",
                app: EscapeSequences.moveRightApp,
                normal: EscapeSequences.moveRightNormal
            )
        case .returnKey:
            return TerminalTallyKeyControl(
                face: .symbol("return", pointSize: 12, weight: .semibold),
                width: metric.keyWidth,
                height: 26,
                accessibilityLabel: String(localized: "Return"),
                accessibilityIdentifier: "terminal.keyCluster.return",
                action: { [weak context] in context?.sendReturn() }
            )
        case .talkback:
            // Talkback — RET · talk · keyboard, mirroring the iPad rail;
            // latched while the message box is open.
            let talk = TerminalTallyKeyControl(
                face: .symbol("text.bubble", pointSize: 12, weight: .semibold),
                width: metric.keyWidth,
                height: 26,
                accessibilityLabel: talkbackKeyLabel(open: context.talkbackOpen),
                accessibilityIdentifier: "terminal.keyCluster.talkback",
                latched: context.talkbackOpen,
                action: { [weak context] in context?.toggleTalkback() }
            )
            talkKey = talk
            return talk
        case .keyboard:
            return TerminalTallyKeyControl(
                face: .symbol("keyboard", pointSize: 12, weight: .semibold),
                width: metric.keyWidth,
                height: 26,
                accessibilityLabel: String(localized: "Show or hide keyboard"),
                accessibilityIdentifier: "terminal.keyCluster.keyboard",
                action: { [weak context] in context?.toggleKeyboard() }
            )
        default:
            return nil
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

    /// arrows · RET · talk · keyboard — four arrows in a run, then three
    /// tail keys each a group gap apart.
    private func trailingWidth(_ metric: TerminalKeyClusterMetric) -> CGFloat {
        24 + metric.keyWidth * 7 + metric.spacing * 3 + metric.groupGap * 3
    }

    private func standaloneWidth(
        metric: TerminalKeyClusterMetric,
        minimal: Bool
    ) -> CGFloat {
        let left = metric.keyWidth * 3 + metric.spacing * 2
        let arrows = minimal ? 0 : metric.keyWidth * 4 + metric.spacing * 3
        let groups = minimal ? 4 : 5
        return 24 + left + arrows + metric.keyWidth * 3
            + CGFloat(groups - 1) * metric.groupGap
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
    static let multiplexDebugKeyCommands = Notification.Name("MultiplexDebugKeyCommands")
    static let multiplexDebugArrangeKeys = Notification.Name("MultiplexDebugArrangeKeys")
    static let multiplexDebugArrangeKeysMove = Notification.Name("MultiplexDebugArrangeKeysMove")
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

        for mode in KeyCommandDebugMode.allCases {
            var token: Int32 = 0
            notify_register_dispatch(
                "app.multiplexterm.multiplex.debug.\(mode.hookName)", &token, .main
            ) { _ in
                NotificationCenter.default.post(
                    name: .multiplexDebugKeyCommands, object: nil, userInfo: ["mode": mode]
                )
            }
        }

        var arrangeToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.arrangekeys", &arrangeToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugArrangeKeys, object: nil)
        }

        var arrangeMoveToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.arrangekeysmove", &arrangeMoveToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugArrangeKeysMove, object: nil)
        }
    }
}

#endif

#endif
