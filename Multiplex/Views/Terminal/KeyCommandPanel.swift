import SwiftTerm
import UIKit

/// The hold-CTRL panel — KEY COMMANDS with two tabs. COMMANDS is a square
/// grid of saved chords (tap sends; a pinned row keeps the panel up; a hold
/// jumps to that row's setup). CUSTOM SETUP is the COMMAND SETUP editor's
/// list with an inline composer: KEYS or TEXT, the chord's modifiers and one
/// key (or one line of text with SUBMIT), REPEAT under the guard, and CLOSE
/// ON PRESS. Drafts are a transaction: DONE normalizes once and hands the
/// set to the store; CANCEL or an outside dismissal discards.
///
/// The controller owns state; every visual stands on the shortcut panel's
/// grammar (`ShortcutPanelRootView`, `ShortcutPressControl`,
/// `TallyHairlineGrid`, `TallyPanelHeader`) and the agent editor's shared
/// controls (`TallyEditor*`). Presentation belongs to
/// `KeyCommandPanelPresenter`.
@MainActor
final class KeyCommandPanelViewController: UIViewController {
    enum Tab: Equatable {
        case commands
        case setup
    }

    nonisolated static let commandsWidth: CGFloat =
        440 + 2 * UIKitChassis.popoverPanelInset
    nonisolated static let setupWidth: CGFloat =
        540 + 2 * UIKitChassis.popoverPanelInset
    /// The CTRL hold that opens the panel: shorter than the keyboard key's
    /// 0.5 s lock hold, because it is the daily path — a tap latches, a
    /// beat longer opens.
    nonisolated static let controlHoldDuration: TimeInterval = 0.3
    /// A held COMMANDS cell opens its row's setup — the rail keys' hold.
    nonisolated static let cellHoldDuration: TimeInterval = 0.5
    /// Below this panel width (an iPhone popover) the composer's KEYS and
    /// REPEAT lines wrap onto two rows instead of clipping. Measured against
    /// the scaled controls, so the Mac's larger faces wrap too.
    nonisolated static let compactComposerWidth: CGFloat = 480

    private let store: KeyCommandStore
    private weak var terminal: TerminalView?
    /// The popover's ceiling (the scene width less its margins); the two
    /// tabs ask for their own widths under it.
    private let maximumWidth: CGFloat
    /// The tier's cap and its paywall route (already wrapped by the
    /// presenter to close this popover first).
    private let plan: KeyCommandPlan
    private let perform: (KeyCommand) -> Void
    private let requestDismiss: () -> Void

    private(set) var selectedTab: Tab = .commands
    private(set) var drafts: [KeyCommand] = []
    private(set) var expandedID: UUID?
    private(set) var panelWidth: CGFloat

    private let panelView: ShortcutPanelRootView
    private let contentStack = UIStackView()
    private var rowViews: [UUID: KeyCommandRowView] = [:]
    private var headerReadout: UIKitChassisMonoLabel?
    private var observationGeneration = 0
    /// DONE writes the store, which the grid also observes; the flag keeps
    /// that observation from rebuilding a panel that is rebuilding itself.
    private var isApplyingLocalEdit = false

    init(
        store: KeyCommandStore,
        terminal: TerminalView?,
        maximumWidth: CGFloat = KeyCommandPanelViewController.setupWidth,
        plan: KeyCommandPlan = .unrestricted,
        perform: @escaping (KeyCommand) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.store = store
        self.terminal = terminal
        self.maximumWidth = maximumWidth
        self.plan = plan
        self.perform = perform
        requestDismiss = dismiss
        panelWidth = min(Self.commandsWidth, maximumWidth)
        panelView = ShortcutPanelRootView(width: panelWidth)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        view = panelView
        // PROTOTYPE(GLASS): the popover root's smoke is the one ground.
        panelView.backgroundColor = GlassPrototype.clearedBezel
        panelView.tallyBorderColor = UIKitChassis.bezelHi
        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 12
        panelView.install(contentStack: contentStack)
        rebuild()
        observeStore()
    }

    /// A peer's newer set (the Keychain mirror) can land while the panel is
    /// up; the grid re-reads the store, the setup drafts stay the user's.
    private func observeStore() {
        observationGeneration &+= 1
        let generation = observationGeneration
        withObservationTracking {
            _ = store.commands
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == observationGeneration else { return }
                observeStore()
                if selectedTab == .commands, !isApplyingLocalEdit { rebuild() }
            }
        }
    }

    func fittingContentSize(for width: CGFloat? = nil) -> CGSize {
        loadViewIfNeeded()
        return panelView.fittingSize(for: width ?? panelWidth)
    }

    func prepareForRemoval() {
        viewIfLoaded?.endEditing(true)
    }

    // MARK: Testable action boundary

    func selectTab(_ tab: Tab, expanding id: UUID? = nil) {
        guard tab != selectedTab || id != expandedID else { return }
        viewIfLoaded?.endEditing(true)
        if tab == .setup {
            if selectedTab != .setup { drafts = store.commands }
            expandedID = id
        } else {
            drafts = []
            expandedID = nil
        }
        selectedTab = tab
        rebuild()
    }

    /// COMMANDS tap: send, then close if the row says so.
    func press(_ command: KeyCommand) {
        perform(command)
        if command.closesPanel { requestDismiss() }
    }

    /// COMMANDS hold: that row's setup, already expanded.
    func hold(_ command: KeyCommand) {
        selectTab(.setup, expanding: command.id)
    }

    func expand(id: UUID?) {
        guard expandedID != id else { return }
        viewIfLoaded?.endEditing(true)
        expandedID = id
        rebuild()
    }

    @discardableResult
    func addCommand() -> KeyCommand? {
        guard selectedTab == .setup, canAddCommand else { return nil }
        let command = KeyCommand(kind: .chord(KeyChord(key: .enter)))
        drafts.append(command)
        expandedID = command.id
        rebuild()
        return command
    }

    /// The commands this tier lets the set hold; never above the model's cap.
    var limit: Int { min(plan.limit, KeyCommandSet.maximumCount) }

    var canAddCommand: Bool { drafts.count < limit }

    /// At the tier's cap with room left under the model's: ADD COMMAND
    /// becomes the Pro route instead of dimming.
    var addNeedsPro: Bool {
        !canAddCommand && plan.upgrade != nil && drafts.count < KeyCommandSet.maximumCount
    }

    /// The footer's ADD: a new draft, or — at the tier's cap — the paywall.
    /// A set that already holds more than the tier allows (synced from a Pro
    /// device) keeps every row; only adding is gated.
    func addOrUpgrade() {
        if addNeedsPro {
            plan.upgrade?()
        } else {
            addCommand()
        }
    }

    func moveCommand(id: UUID, offset: Int) {
        guard let source = drafts.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard drafts.indices.contains(destination) else { return }
        drafts.swapAt(source, destination)
        rebuild()
    }

    func deleteCommand(id: UUID) {
        drafts.removeAll { $0.id == id }
        if expandedID == id { expandedID = nil }
        rebuild()
    }

    /// The composer's writes: by ID, so a stale field delivery after a
    /// delete or move edits nothing. Only the row's own header line
    /// re-renders — typing never changes the panel's height.
    func updateDraft(_ command: KeyCommand) {
        guard let index = drafts.firstIndex(where: { $0.id == command.id }) else { return }
        var stable = command
        stable.id = drafts[index].id
        drafts[index] = stable
        rowViews[stable.id]?.render(command: stable, index: index, count: drafts.count)
    }

    func saveDrafts() {
        viewIfLoaded?.endEditing(true)
        isApplyingLocalEdit = true
        store.replace(drafts)
        isApplyingLocalEdit = false
        selectTab(.commands)
    }

    func cancelDrafts() {
        selectTab(.commands)
    }

    // MARK: Construction

    private func rebuild() {
        guard isViewLoaded else { return }
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rowViews.removeAll()
        panelWidth = min(selectedTab == .commands ? Self.commandsWidth : Self.setupWidth, maximumWidth)
        panelView.width = panelWidth

        contentStack.addArrangedSubview(makeHeader())
        contentStack.addArrangedSubview(makeTabPair())
        switch selectedTab {
        case .commands:
            contentStack.addArrangedSubview(makeCommandGrid())
            contentStack.addArrangedSubview(makeFootnote(
                "TAP SENDS · DOT = STAYS OPEN · HOLD A CELL TO EDIT · TAP OUTSIDE CLOSES"
            ))
        case .setup:
            contentStack.addArrangedSubview(makeRows())
            contentStack.addArrangedSubview(makeLegend())
            contentStack.addArrangedSubview(TallyEditorFooter.actions(
                identifierPrefix: "keyCommands",
                addState: addNeedsPro ? .upgrade : (canAddCommand ? .available : .capped),
                add: { [weak self] in self?.addOrUpgrade() },
                cancel: { [weak self] in self?.cancelDrafts() },
                done: { [weak self] in self?.saveDrafts() }
            ))
        }
        refreshPreferredContentSize()
    }

    private func makeHeader() -> UIView {
        let readout = UIKitChassisMonoLabel(
            "",
            font: UIKitChassis.monoFont(9, weight: .semibold),
            color: UIKitChassis.signal2,
            kern: 0.8
        )
        readout.accessibilityIdentifier = "keyCommands.readout"
        headerReadout = readout
        refreshHeaderReadout()
        return TallyPanelHeader.make(
            title: "KEY COMMANDS",
            trailing: readout,
            titleIdentifier: "keyCommands.title"
        )
    }

    private func refreshHeaderReadout() {
        switch selectedTab {
        case .commands:
            headerReadout?.setText("HOLD CTRL", ink: UIKitChassis.signal2)
        case .setup:
            headerReadout?.setText(
                "ALL HOSTS · \(drafts.count) OF \(limit)",
                ink: TallyPalette.customCommand
            )
        }
    }

    private func makeTabPair() -> UIView {
        let commands = KeyCommandSegmentCell(
            title: "COMMANDS",
            accessibilityLabel: "Commands",
            selected: selectedTab == .commands
        ) { [weak self] in self?.selectTab(.commands) }
        commands.accessibilityIdentifier = "keyCommands.tab.commands"
        let setup = KeyCommandSegmentCell(
            title: "CUSTOM SETUP",
            accessibilityLabel: "Custom setup",
            selected: selectedTab == .setup
        ) { [weak self] in self?.selectTab(.setup) }
        setup.accessibilityIdentifier = "keyCommands.tab.setup"
        let pair = TallyHairlineGrid.row([commands, setup])
        pair.layer.borderWidth = 1
        pair.layer.borderColor = UIKitChassis.bezelHi.resolvedColor(with: view.traitCollection).cgColor
        return pair
    }

    private func makeCommandGrid() -> UIView {
        var cells: [UIView] = store.commands.map { command in
            KeyCommandCell(
                command: command,
                press: { [weak self] in self?.press(command) },
                hold: { [weak self] in self?.hold(command) }
            )
        }
        if cells.isEmpty {
            cells.append(makeEmptyLabel("NO COMMANDS · CUSTOM SETUP"))
        }
        return TallyHairlineGrid.grid(cells, columns: 2)
    }

    private func makeFootnote(_ text: String) -> UIView {
        let label = UIKitChassisMonoLabel(
            text,
            font: UIKitChassis.monoFont(8, weight: .medium),
            color: UIKitChassis.signal3,
            kern: 0.6
        )
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.isAccessibilityElement = true
        return label
    }

    private func makeRows() -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 1
        stack.backgroundColor = UIKitChassis.bezelHi
        stack.layer.borderWidth = 1
        stack.layer.borderColor = UIKitChassis.bezelHi.resolvedColor(with: view.traitCollection).cgColor
        stack.accessibilityIdentifier = "keyCommands.rows"
        let compact = panelWidth < Self.compactComposerWidth * KeyCommandMetrics.scale
        for (index, command) in drafts.enumerated() {
            let row = KeyCommandRowView(
                command: command,
                index: index,
                count: drafts.count,
                expanded: expandedID == command.id,
                compact: compact,
                terminal: terminal,
                toggle: { [weak self] id in
                    guard let self else { return }
                    expand(id: expandedID == id ? nil : id)
                },
                move: { [weak self] id, offset in self?.moveCommand(id: id, offset: offset) },
                delete: { [weak self] id in self?.deleteCommand(id: id) },
                changed: { [weak self] command in self?.updateDraft(command) },
                layoutChanged: { [weak self] in self?.refreshPreferredContentSize() }
            )
            rowViews[command.id] = row
            stack.addArrangedSubview(row)
        }
        if drafts.isEmpty {
            stack.addArrangedSubview(makeEmptyLabel("NO COMMANDS"))
        }
        return stack
    }

    /// The one empty state both tabs share: a dim caps label on the chassis.
    private func makeEmptyLabel(_ title: String) -> UIView {
        let empty = UIKitChassisLabel(title, size: 10, color: UIKitChassis.signal3)
        empty.textAlignment = .center
        empty.backgroundColor = GlassPrototype.clearedChassis
        empty.accessibilityIdentifier = "keyCommands.empty"
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.heightAnchor.constraint(equalToConstant: KeyCommandMetrics.emptyStateHeight).isActive = true
        return empty
    }

    private func makeLegend() -> UIView {
        var rows = [
            TallyEditorLegend.row(
                color: TallyPalette.customCommand,
                text: "Chords send what a hardware keyboard would; text rows type one line, "
                    + "then Enter when SUBMIT is on."
            ),
            TallyEditorLegend.row(
                color: UIKitChassis.signal3,
                text: "Repeat guard: ×\(KeyCommandRepeatGuard.maximumCount) at most, "
                    + "\(KeyCommandRepeatGuard.gapRange.lowerBound)–\(KeyCommandRepeatGuard.gapRange.upperBound) ms "
                    + "between sends, whole burst within \(KeyCommandRepeatGuard.burstLimitMilliseconds / 1000) s. Values clamp."
            ),
        ]
        // The tier line exists only where a tier applies: Pro (and the
        // tests' unrestricted plan) never see it.
        if plan.upgrade != nil, limit < KeyCommandSet.maximumCount {
            let tier = TallyEditorLegend.row(
                color: UIKitChassis.signal2,
                text: "Free keeps \(limit) commands; Multiplex Pro raises the set to "
                    + "\(KeyCommandSet.maximumCount)."
            )
            tier.accessibilityIdentifier = "keyCommands.legend.tier"
            rows.append(tier)
        }
        return TallyEditorLegend.stack(rows)
    }

    private func refreshPreferredContentSize() {
        guard isViewLoaded else { return }
        panelView.invalidateIntrinsicContentSize()
        let size = panelView.fittingSize(for: panelWidth)
        guard preferredContentSize != size else { return }
        preferredContentSize = size
        parent?.preferredContentSizeDidChange(forChildContentContainer: self)
    }
}

#if DEBUG
/// The headless capture hooks: `debug.keycommands` (the grid),
/// `debug.keycommandsetup` (the list), `debug.keycommandcompose` (a fresh
/// row's composer up).
enum KeyCommandDebugMode: String, CaseIterable {
    case commands
    case setup
    case compose

    var hookName: String {
        switch self {
        case .commands: "keycommands"
        case .setup: "keycommandsetup"
        case .compose: "keycommandcompose"
        }
    }
}

extension KeyCommandPanelViewController {
    func debugShow(_ mode: KeyCommandDebugMode) {
        switch mode {
        case .commands:
            selectTab(.commands)
        case .setup:
            selectTab(.setup)
        case .compose:
            selectTab(.setup)
            if expandedID == nil { addCommand() }
        }
    }
}
#endif

/// Control geometry in this panel follows the type scale — the one place
/// the chassis breaks its "geometry stays authored" rule. iOS-on-Mac paints
/// the iPad grid at 77%; a 26-pt keycap holding a scaled glyph, a 26×14
/// switch, and 25×23 arrows read as toy parts there (2026-08-16), so every
/// dimension named here multiplies by `Theme.typeScale`, which is 1.0
/// everywhere but the Mac. Widths that the popover itself owns (the two tab
/// widths) stay authored.
enum KeyCommandMetrics {
    #if DEBUG
    /// Tests pin the Mac's 1.3 without running on a Mac.
    nonisolated(unsafe) static var scaleOverride: CGFloat?
    nonisolated static var scale: CGFloat { scaleOverride ?? Theme.typeScale }
    #else
    nonisolated static var scale: CGFloat { Theme.typeScale }
    #endif

    nonisolated static func scaled(_ value: CGFloat) -> CGFloat { ceil(value * scale) }

    /// Keycap sides (authored; the face view scales them).
    nonisolated static let cellCap: CGFloat = 28
    nonisolated static let rowCap: CGFloat = 24
    nonisolated static let composerCap: CGFloat = 26
    /// The stays-open dot on a cap's corner.
    nonisolated static var pinDot: CGFloat { scaled(4) }
    /// A COMMANDS cell's floor and a setup row header's floor.
    nonisolated static var cellMinHeight: CGFloat { scaled(52) }
    nonisolated static var rowHeaderMinHeight: CGFloat { scaled(30) }
    /// The composer's eyebrow column and its TYPE pair.
    nonisolated static var fieldLabelWidth: CGFloat { scaled(46) }
    nonisolated static var typeRowWidth: CGFloat { scaled(128) }
    /// The steppers' value box.
    nonisolated static var stepperValueWidth: CGFloat { scaled(44) }
    nonisolated static var stepperHeight: CGFloat { scaled(23) }
    /// Both tabs' empty-state label.
    nonisolated static var emptyStateHeight: CGFloat { scaled(64) }
}

// MARK: - Segment cell

/// One cell of a two-way choice — the COMMANDS | CUSTOM SETUP tab pair and
/// the composer's KEYS | TEXT — on the panel's press ground: bezelHi when
/// selected, signal ink; chassis and signal3 otherwise.
@MainActor
final class KeyCommandSegmentCell: ShortcutPressControl {
    private let label: UIKitChassisLabel
    private let action: () -> Void
    private var isSelectedCell: Bool

    init(
        title: String,
        accessibilityLabel: String,
        selected: Bool,
        size: CGFloat = 9,
        inset: CGFloat = 8,
        action: @escaping () -> Void
    ) {
        self.action = action
        isSelectedCell = selected
        label = UIKitChassisLabel(
            title,
            size: size,
            color: selected ? UIKitChassis.signal : UIKitChassis.signal3
        )
        super.init(frame: .zero)
        self.accessibilityLabel = accessibilityLabel
        if selected { accessibilityTraits.insert(.selected) }
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            label.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
        addTarget(self, action: #selector(pressed), for: .touchUpInside)
    }

    func setSelected(_ selected: Bool) {
        isSelectedCell = selected
        label.setInk(selected ? UIKitChassis.signal : UIKitChassis.signal3)
        if selected {
            accessibilityTraits.insert(.selected)
        } else {
            accessibilityTraits.remove(.selected)
        }
        refreshBackground()
    }

    override var restingBackgroundColor: UIColor {
        isSelectedCell ? UIKitChassis.bezelHi : super.restingBackgroundColor
    }

    @objc private func pressed() { action() }
}

// MARK: - Keycap faces

/// One keycap: chassis face, bezel hairline, the SF Symbol (or text) in
/// `signal` ink; latched swaps to the rail's inverted face.
@MainActor
final class KeyCapFaceView: UIKitTallyBorderedView {
    private let symbolView = UIImageView()
    private let textLabel = UILabel()
    private let pin = UIView()
    private let side: CGFloat
    private var face: KeyCapFace
    private var isLatched = false

    /// `side` is the authored size; the drawn face is `side × typeScale`.
    init(face: KeyCapFace, side: CGFloat, showsPin: Bool = false) {
        self.face = face
        self.side = KeyCommandMetrics.scaled(side)
        super.init(frame: .zero)
        isAccessibilityElement = false
        layer.cornerRadius = 3
        layer.cornerCurve = .continuous
        clipsToBounds = true
        symbolView.contentMode = .center
        symbolView.isUserInteractionEnabled = false
        textLabel.textAlignment = .center
        textLabel.numberOfLines = 1
        textLabel.isUserInteractionEnabled = false
        addSubview(symbolView)
        addSubview(textLabel)
        pin.backgroundColor = TallyPalette.customCommand
        pin.layer.cornerRadius = KeyCommandMetrics.pinDot / 2
        pin.isHidden = !showsPin
        addSubview(pin)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: self.side).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: self.side).isActive = true
        apply(face: face)
        refreshInk()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setLatched(_ latched: Bool) {
        guard latched != isLatched else { return }
        isLatched = latched
        refreshInk()
    }

    func setFace(_ face: KeyCapFace) {
        guard face != self.face else { return }
        self.face = face
        apply(face: face)
        refreshInk()
    }

    override var intrinsicContentSize: CGSize {
        let width: CGFloat
        if face.symbolName != nil {
            width = side
        } else {
            let text = textLabel.intrinsicContentSize.width
            width = max(side, ceil(text) + 12)
        }
        return CGSize(width: width, height: side)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        symbolView.frame = bounds
        textLabel.frame = bounds.insetBy(dx: 5, dy: 0)
        let dot = KeyCommandMetrics.pinDot
        pin.frame = CGRect(x: bounds.maxX - dot - 2, y: bounds.maxY - dot - 2, width: dot, height: dot)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshInk()
    }

    private func apply(face: KeyCapFace) {
        // `side` already carries the scale; the fonts below are raw sizes so
        // the glyph keeps its ratio to the face instead of scaling twice.
        if let symbolName = face.symbolName,
           let image = UIImage(
               systemName: symbolName,
               withConfiguration: UIImage.SymbolConfiguration(
                   pointSize: side * 0.46,
                   weight: .semibold
               )
           ) {
            symbolView.image = image
            symbolView.isHidden = false
            textLabel.isHidden = true
        } else {
            symbolView.isHidden = true
            textLabel.isHidden = false
            let mono = face.text.count <= 2
            textLabel.font = mono
                ? .monospacedSystemFont(ofSize: side * 0.44, weight: .semibold)
                : .monospacedSystemFont(ofSize: side * 0.38, weight: .medium)
            textLabel.text = face.text
        }
        invalidateIntrinsicContentSize()
    }

    private func refreshInk() {
        let ink = isLatched ? UIKitChassis.chassis : UIKitChassis.signal
        symbolView.tintColor = ink
        textLabel.textColor = ink
        backgroundColor = isLatched
            ? UIKitChassis.signal2
            : (GlassPrototype.enabled
                ? GlassPrototype.material(GlassPrototype.strataMaterial, fallback: TallyPalette.chassis)
                : UIKitChassis.chassis)
        tallyBorderColor = isLatched ? UIKitChassis.signal2 : UIKitChassis.bezelHi
    }
}

/// A row of keycap faces with the ↵ and ×N marks — the chord as the grid
/// and the rows draw it. Re-rendering with the same faces and marks is a
/// no-op, so a composer keystroke never rebuilds the caps.
@MainActor
final class KeyChordFacesView: UIView {
    private struct Signature: Equatable {
        var faces: [KeyCapFace]
        var pinned: Bool
        var submits: Bool
        var repeats: Int
    }

    private let stack = UIStackView()
    private var signature: Signature?

    init(command: KeyCommand, side: CGFloat) {
        super.init(frame: .zero)
        isAccessibilityElement = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        render(command: command, side: side)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func render(command: KeyCommand, side: CGFloat) {
        let next = Signature(
            faces: command.faces,
            pinned: !command.closesPanel,
            submits: command.textSnippet?.submits == true,
            repeats: command.repeatCount
        )
        guard next != signature else { return }
        signature = next
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, face) in next.faces.enumerated() {
            stack.addArrangedSubview(KeyCapFaceView(
                face: face,
                side: side,
                showsPin: index == next.faces.count - 1 && next.pinned
            ))
        }
        if next.submits {
            stack.addArrangedSubview(UIKitChassisMonoLabel(
                "↵",
                font: UIKitChassis.uiFont(side * 0.42, weight: .medium),
                color: UIKitChassis.signal2
            ))
        }
        if next.repeats > 1 {
            stack.addArrangedSubview(UIKitChassisMonoLabel(
                "×\(next.repeats)",
                font: UIKitChassis.monoFont(9, weight: .semibold),
                color: UIKitChassis.signal2,
                kern: 0.4
            ))
        }
    }
}

// MARK: - COMMANDS cell

@MainActor
final class KeyCommandCell: ShortcutPressControl {
    private let press: () -> Void
    private let hold: () -> Void
    private var didHold = false

    init(command: KeyCommand, press: @escaping () -> Void, hold: @escaping () -> Void) {
        self.press = press
        self.hold = hold
        super.init(frame: .zero)
        accessibilityIdentifier = "keyCommands.cell.\(command.id.uuidString)"
        accessibilityLabel = command.readout(.spoken)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(
            greaterThanOrEqualToConstant: KeyCommandMetrics.cellMinHeight
        ).isActive = true

        let faces = KeyChordFacesView(command: command, side: KeyCommandMetrics.cellCap)
        faces.setContentHuggingPriority(.required, for: .horizontal)
        faces.setContentCompressionResistancePriority(.required, for: .horizontal)
        let name = UIKitChassisLabel(
            command.name,
            size: 10,
            color: command.isShipped ? UIKitChassis.signal : TallyPalette.customCommand
        )
        let hintText = command.readout(.cellHint)
        let hint = UIKitChassisMonoLabel(
            hintText,
            font: UIKitChassis.monoFont(8),
            color: UIKitChassis.signal2
        )
        hint.lineBreakMode = .byTruncatingTail
        hint.isHidden = hintText.isEmpty
        let labels = UIStackView(arrangedSubviews: [name, hint])
        labels.axis = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [faces, labels])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addTarget(self, action: #selector(touchDown), for: .touchDown)
        addTarget(self, action: #selector(released), for: .touchUpInside)
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        recognizer.minimumPressDuration = KeyCommandPanelViewController.cellHoldDuration
        recognizer.cancelsTouchesInView = false
        addGestureRecognizer(recognizer)
    }

    override func accessibilityActivate() -> Bool {
        press()
        return true
    }

    @objc private func touchDown() {
        didHold = false
    }

    @objc private func released() {
        guard !didHold else { return }
        press()
    }

    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        didHold = true
        isHighlighted = false
        hold()
    }
}

// MARK: - CUSTOM SETUP row

@MainActor
final class KeyCommandRowView: UIView {
    private let toggle: (UUID) -> Void
    private let changed: (KeyCommand) -> Void
    private let layoutChanged: () -> Void
    private weak var terminal: TerminalView?
    private(set) var command: KeyCommand
    private let expanded: Bool
    private let compact: Bool

    private let indexLabel = UIKitChassisMonoLabel(
        "",
        font: UIKitChassis.monoFont(9, weight: .semibold),
        color: UIKitChassis.signal3
    )
    private let facesView: KeyChordFacesView
    private let nameLabel: UIKitChassisLabel
    private let readoutLabel = UIKitChassisMonoLabel(
        "",
        font: UIKitChassis.monoFont(8, weight: .medium),
        color: UIKitChassis.signal2,
        kern: 0.4
    )
    private let headerControl = KeyCommandRowHeaderControl()
    private var actions: TallyEditorRowActions.Trio?
    private var composer: KeyCommandComposerView?

    init(
        command: KeyCommand,
        index: Int,
        count: Int,
        expanded: Bool,
        compact: Bool = false,
        terminal: TerminalView?,
        toggle: @escaping (UUID) -> Void,
        move: @escaping (UUID, Int) -> Void,
        delete: @escaping (UUID) -> Void,
        changed: @escaping (KeyCommand) -> Void,
        layoutChanged: @escaping () -> Void
    ) {
        self.command = command
        self.expanded = expanded
        self.compact = compact
        self.terminal = terminal
        self.toggle = toggle
        self.changed = changed
        self.layoutChanged = layoutChanged
        facesView = KeyChordFacesView(command: command, side: KeyCommandMetrics.rowCap)
        nameLabel = UIKitChassisLabel(command.name, size: 10)
        super.init(frame: .zero)
        backgroundColor = GlassPrototype.clearedChassis
        accessibilityIdentifier = "keyCommands.row.\(command.id.uuidString)"

        indexLabel.setContentHuggingPriority(.required, for: .horizontal)
        indexLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        indexLabel.translatesAutoresizingMaskIntoConstraints = false
        indexLabel.widthAnchor.constraint(equalToConstant: 18).isActive = true
        facesView.setContentHuggingPriority(.required, for: .horizontal)
        facesView.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The readout is the row's secondary line: at phone width it
        // truncates before the name does.
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        readoutLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        readoutLabel.lineBreakMode = .byTruncatingTail

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let rowID = command.id
        let trio = TallyEditorRowActions.make(
            index: index,
            count: count,
            identifierPrefix: "keyCommands",
            rowID: rowID,
            scale: KeyCommandMetrics.scale,
            move: { offset in move(rowID, offset) },
            delete: { delete(rowID) }
        )
        actions = trio

        let headerContent = UIStackView(arrangedSubviews: [
            indexLabel, facesView, nameLabel, readoutLabel, spacer,
        ])
        headerContent.axis = .horizontal
        headerContent.alignment = .center
        headerContent.spacing = 10
        headerContent.isUserInteractionEnabled = false
        headerControl.addSubview(headerContent)
        headerContent.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerContent.leadingAnchor.constraint(equalTo: headerControl.leadingAnchor),
            headerContent.trailingAnchor.constraint(equalTo: headerControl.trailingAnchor),
            headerContent.topAnchor.constraint(equalTo: headerControl.topAnchor),
            headerContent.bottomAnchor.constraint(equalTo: headerControl.bottomAnchor),
            headerControl.heightAnchor.constraint(
                greaterThanOrEqualToConstant: KeyCommandMetrics.rowHeaderMinHeight
            ),
        ])
        headerControl.accessibilityIdentifier = "keyCommands.rowHeader.\(command.id.uuidString)"
        headerControl.accessibilityLabel = expanded
            ? "\(command.name), editing"
            : "\(command.name), edit"
        headerControl.addTarget(self, action: #selector(headerPressed), for: .touchUpInside)

        let headerLine = UIStackView(arrangedSubviews: [headerControl, trio.stack])
        headerLine.axis = .horizontal
        headerLine.alignment = .center
        headerLine.spacing = 10

        let content = UIStackView(arrangedSubviews: [headerLine])
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = 10
        if expanded {
            let composer = KeyCommandComposerView(
                command: command,
                terminal: terminal,
                compact: compact,
                changed: { [weak self] command in
                    guard let self else { return }
                    self.command = command
                    changed(command)
                },
                layoutChanged: layoutChanged
            )
            self.composer = composer
            content.addArrangedSubview(composer)
        }
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        if expanded {
            layer.borderWidth = 1
            layer.borderColor = UIKitChassis.signal2.resolvedColor(with: traitCollection).cgColor
        }
        render(command: command, index: index, count: count)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    /// Re-read the model into the header line — the composer below is the
    /// writer, so it is never rebuilt here.
    func render(command: KeyCommand, index: Int, count: Int) {
        self.command = command
        indexLabel.setText(String(format: "%02d", index + 1))
        facesView.render(command: command, side: KeyCommandMetrics.rowCap)
        nameLabel.setText(command.name)
        nameLabel.setInk(command.isShipped ? UIKitChassis.signal : TallyPalette.customCommand)
        readoutLabel.setText(
            command.readout,
            ink: command.closesPanel ? UIKitChassis.signal2 : TallyPalette.customCommand
        )
        actions?.up.isEnabled = index > 0
        actions?.down.isEnabled = index < count - 1
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard expanded,
              traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        layer.borderColor = UIKitChassis.signal2.resolvedColor(with: traitCollection).cgColor
    }

    @objc private func headerPressed() {
        toggle(command.id)
    }
}

/// The row header's press target — everything left of the ↑ ↓ 🗑 group.
@MainActor
private final class KeyCommandRowHeaderControl: UIControl {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }
}

// MARK: - Composer

/// The inline editor under an expanded row. Owns a draft copy of the
/// command; every control writes the draft, clamps the repeat under the
/// guard, refreshes the readouts, and hands the command up by ID.
@MainActor
final class KeyCommandComposerView: UIView, UITextFieldDelegate {
    private var command: KeyCommand
    private weak var terminal: TerminalView?
    private let compact: Bool
    private let changed: (KeyCommand) -> Void
    private let layoutChanged: () -> Void

    private var keysTypeCell: KeyCommandSegmentCell?
    private var textTypeCell: KeyCommandSegmentCell?
    private var modifierCaps: [KeyChord.Modifiers: KeyCapControl] = [:]
    private var keyCaps: [KeyChord.Key: KeyCapControl] = [:]
    private let characterField = KeyCommandTextField()
    private let textField = KeyCommandTextField()
    private var submitSwitch: TallyEditorSwitch?
    private var countStepper: KeyCommandStepper?
    private var gapStepper: KeyCommandStepper?
    private let burstLabel = UIKitChassisMonoLabel(
        "",
        font: UIKitChassis.monoFont(8.5, weight: .medium),
        color: UIKitChassis.signal3,
        kern: 0.4
    )
    private let sendsLabel = UIKitChassisMonoLabel(
        "",
        font: UIKitChassis.monoFont(8.5, weight: .medium),
        color: UIKitChassis.signal2,
        kern: 0.4
    )
    private let keysBlock = UIStackView()
    private let textBlock = UIStackView()

    init(
        command: KeyCommand,
        terminal: TerminalView?,
        compact: Bool = false,
        changed: @escaping (KeyCommand) -> Void,
        layoutChanged: @escaping () -> Void
    ) {
        self.command = command
        self.terminal = terminal
        self.compact = compact
        self.changed = changed
        self.layoutChanged = layoutChanged
        super.init(frame: .zero)
        accessibilityIdentifier = "keyCommands.composer"
        build()
        refreshFromCommand()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    // MARK: Testable writes

    func setKind(isText: Bool) {
        switch (command.kind, isText) {
        case (.chord, true):
            command.kind = .text(KeyTextSnippet(text: textField.text ?? "", submits: true))
        case (.text, false):
            command.kind = .chord(KeyChord(key: .enter))
        default:
            return
        }
        commit(relayout: true)
    }

    func toggleModifier(_ modifier: KeyChord.Modifiers) {
        guard case .chord(var chord) = command.kind else { return }
        if chord.modifiers.contains(modifier) {
            chord.modifiers.remove(modifier)
        } else {
            chord.modifiers.insert(modifier)
        }
        command.kind = .chord(chord)
        commit()
    }

    func selectKey(_ key: KeyChord.Key) {
        guard case .chord(var chord) = command.kind else { return }
        chord.key = key
        command.kind = .chord(chord)
        if case .character = key {} else { characterField.text = "" }
        commit()
    }

    func setText(_ text: String) {
        guard case .text(var snippet) = command.kind else { return }
        snippet.text = text
        command.kind = .text(snippet)
        commit()
    }

    func setSubmits(_ submits: Bool) {
        guard case .text(var snippet) = command.kind else { return }
        snippet.submits = submits
        command.kind = .text(snippet)
        commit()
    }

    func setRepeatCount(_ count: Int) {
        command.repeatCount = count
        commit()
    }

    func setRepeatGap(_ gap: Int) {
        command.repeatGapMilliseconds = gap
        commit()
    }

    func setClosesPanel(_ closes: Bool) {
        command.closesPanel = closes
        commit()
    }

    // MARK: Construction

    private func build() {
        let lines = UIStackView()
        lines.axis = .vertical
        lines.alignment = .fill
        lines.spacing = 10
        addSubview(lines)
        lines.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            lines.leadingAnchor.constraint(equalTo: leadingAnchor),
            lines.trailingAnchor.constraint(equalTo: trailingAnchor),
            lines.topAnchor.constraint(equalTo: topAnchor),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // TYPE
        let keysCell = KeyCommandSegmentCell(
            title: "KEYS", accessibilityLabel: "Keys", selected: true, size: 8, inset: 6
        ) { [weak self] in self?.setKind(isText: false) }
        keysCell.accessibilityIdentifier = "keyCommands.composer.type.keys"
        let textCell = KeyCommandSegmentCell(
            title: "TEXT", accessibilityLabel: "Text", selected: false, size: 8, inset: 6
        ) { [weak self] in self?.setKind(isText: true) }
        textCell.accessibilityIdentifier = "keyCommands.composer.type.text"
        keysTypeCell = keysCell
        textTypeCell = textCell
        let typeRow = TallyHairlineGrid.row([keysCell, textCell])
        typeRow.translatesAutoresizingMaskIntoConstraints = false
        typeRow.widthAnchor.constraint(equalToConstant: KeyCommandMetrics.typeRowWidth).isActive = true
        typeRow.layer.borderWidth = 1
        typeRow.layer.borderColor = UIKitChassis.bezelHi.resolvedColor(with: traitCollection).cgColor
        lines.addArrangedSubview(field("TYPE", typeRow))

        // KEYS
        keysBlock.axis = .vertical
        keysBlock.alignment = .fill
        keysBlock.spacing = 10
        let modifiers = UIStackView()
        modifiers.axis = .horizontal
        modifiers.alignment = .center
        modifiers.spacing = 4
        for modifier in KeyChord.Modifiers.ordered {
            let cap = KeyCapControl(
                face: modifier.face,
                side: KeyCommandMetrics.composerCap,
                accessibilityLabel: modifier.accessibilityWord
            ) { [weak self] in
                self?.toggleModifier(modifier)
            }
            cap.accessibilityIdentifier = "keyCommands.composer.modifier.\(modifier.word.lowercased())"
            modifierCaps[modifier] = cap
            modifiers.addArrangedSubview(cap)
        }
        let plus = UIKitChassisMonoLabel(
            "+",
            font: UIKitChassis.monoFont(12),
            color: UIKitChassis.signal3
        )
        func makeCap(_ key: KeyChord.Key) -> KeyCapControl {
            let cap = KeyCapControl(
                face: key.face,
                side: KeyCommandMetrics.composerCap,
                accessibilityLabel: key.accessibilityWord
            ) { [weak self] in
                self?.selectKey(key)
            }
            cap.accessibilityIdentifier = "keyCommands.composer.key.\(key.word.lowercased())"
            keyCaps[key] = cap
            return cap
        }
        func keyRow(_ caps: [UIView]) -> UIStackView {
            let row = UIStackView(arrangedSubviews: caps)
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 4
            return row
        }
        characterField.configure(placeholder: "A", width: 30, monoSize: 12, height: KeyCommandMetrics.composerCap)
        characterField.accessibilityLabel = "Letter or digit"
        characterField.accessibilityIdentifier = "keyCommands.composer.character"
        characterField.delegate = self
        characterField.addTarget(self, action: #selector(characterEdited), for: .editingChanged)
        let editingCaps = KeyChord.Key.composerEditingSet.map(makeCap)
        let arrowCaps = KeyChord.Key.composerArrowSet.map(makeCap)
        if compact {
            // A phone popover: modifiers + the editing keys on the KEYS line;
            // the direction keys and the letter field hang under the editing
            // keys, flush with their right edge, so the two key lines read as
            // one block beside the modifiers.
            let editingRow = keyRow(editingCaps)
            let firstLine = UIStackView(arrangedSubviews: [modifiers, plus, editingRow])
            firstLine.axis = .horizontal
            firstLine.alignment = .center
            firstLine.spacing = 8
            keysBlock.addArrangedSubview(field("KEYS", firstLine))
            let secondLine = UIView()
            let secondRow = keyRow(arrowCaps + [characterField])
            secondRow.translatesAutoresizingMaskIntoConstraints = false
            secondLine.addSubview(secondRow)
            keysBlock.addArrangedSubview(secondLine)
            NSLayoutConstraint.activate([
                secondRow.topAnchor.constraint(equalTo: secondLine.topAnchor),
                secondRow.bottomAnchor.constraint(equalTo: secondLine.bottomAnchor),
                secondRow.trailingAnchor.constraint(equalTo: editingRow.trailingAnchor),
                secondRow.leadingAnchor.constraint(greaterThanOrEqualTo: secondLine.leadingAnchor),
            ])
        } else {
            let keysLine = UIStackView(arrangedSubviews: [
                modifiers, plus, keyRow(editingCaps + arrowCaps + [characterField]),
            ])
            keysLine.axis = .horizontal
            keysLine.alignment = .center
            keysLine.spacing = 8
            keysBlock.addArrangedSubview(field("KEYS", keysLine))
        }
        lines.addArrangedSubview(keysBlock)

        // TEXT
        textBlock.axis = .vertical
        textBlock.alignment = .fill
        textBlock.spacing = 10
        textField.configure(
            placeholder: "One line, typed as-is",
            width: 220,
            monoSize: 11,
            height: KeyCommandMetrics.composerCap
        )
        textField.accessibilityLabel = "Text to type"
        textField.accessibilityIdentifier = "keyCommands.composer.text"
        textField.delegate = self
        textField.addTarget(self, action: #selector(textEdited), for: .editingChanged)
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let submit = TallyEditorSwitch(
            label: "SUBMIT",
            accessibilityLabel: "Submit with Enter",
            isOn: command.textSnippet?.submits ?? true,
            identifierPrefix: "keyCommands",
            scale: KeyCommandMetrics.scale
        ) { [weak self] value in self?.setSubmits(value) }
        submitSwitch = submit
        let textLine = UIStackView(arrangedSubviews: [textField, submit])
        textLine.axis = .horizontal
        textLine.alignment = .center
        textLine.spacing = 10
        textBlock.addArrangedSubview(field("TEXT", textLine, stretch: true))
        lines.addArrangedSubview(textBlock)

        // REPEAT
        let count = KeyCommandStepper(
            value: command.repeatCount,
            range: 1...KeyCommandRepeatGuard.maximumCount,
            step: 1,
            format: { "×\($0)" },
            accessibilityLabel: "Repeat count",
            changed: { [weak self] value in self?.setRepeatCount(value) }
        )
        count.accessibilityIdentifier = "keyCommands.composer.count"
        countStepper = count
        let every = UIKitChassisMonoLabel(
            "EVERY",
            font: UIKitChassis.monoFont(8.5, weight: .medium),
            color: UIKitChassis.signal3,
            kern: 0.6
        )
        let gap = KeyCommandStepper(
            value: command.repeatGapMilliseconds,
            range: KeyCommandRepeatGuard.gapRange,
            step: KeyCommandRepeatGuard.gapStep,
            format: { "\($0) MS" },
            accessibilityLabel: "Gap between sends",
            changed: { [weak self] value in self?.setRepeatGap(value) }
        )
        gap.accessibilityIdentifier = "keyCommands.composer.gap"
        gapStepper = gap
        burstLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        burstLabel.lineBreakMode = .byTruncatingTail
        if compact {
            let steppers = UIStackView(arrangedSubviews: [count, every, gap])
            steppers.axis = .horizontal
            steppers.alignment = .center
            steppers.spacing = 8
            lines.addArrangedSubview(field("REPEAT", steppers))
            lines.addArrangedSubview(field("", burstLabel, stretch: true))
        } else {
            let repeatLine = UIStackView(arrangedSubviews: [count, every, gap, burstLabel])
            repeatLine.axis = .horizontal
            repeatLine.alignment = .center
            repeatLine.spacing = 8
            lines.addArrangedSubview(field("REPEAT", repeatLine))
        }

        // PANEL
        let closes = TallyEditorSwitch(
            label: "CLOSE ON PRESS",
            accessibilityLabel: "Close the panel on press",
            isOn: command.closesPanel,
            identifierPrefix: "keyCommands",
            scale: KeyCommandMetrics.scale
        ) { [weak self] value in self?.setClosesPanel(value) }
        lines.addArrangedSubview(field("PANEL", closes))

        // SENDS
        sendsLabel.numberOfLines = 2
        sendsLabel.lineBreakMode = .byTruncatingTail
        sendsLabel.accessibilityIdentifier = "keyCommands.composer.sends"
        lines.addArrangedSubview(field("SENDS", sendsLabel, stretch: true))
    }

    /// One eyebrow'd line. The content keeps its own width — a trailing
    /// spacer takes the slack, or a horizontal stack would stretch the
    /// content's first keycap across the row — unless `stretch` says the
    /// content (a wrapping readout) should fill.
    private func field(_ title: String, _ content: UIView, stretch: Bool = false) -> UIView {
        let label = UIKitChassisLabel(title, size: 8, color: UIKitChassis.signal2)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: KeyCommandMetrics.fieldLabelWidth).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        var views = [label, content]
        if !stretch {
            content.setContentHuggingPriority(.required, for: .horizontal)
            let spacer = UIView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(spacer)
        }
        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        return row
    }

    // MARK: State → controls

    private func commit(relayout: Bool = false) {
        let clamped = KeyCommandRepeatGuard.clamp(
            count: command.repeatCount,
            gapMilliseconds: command.repeatGapMilliseconds
        )
        command.repeatCount = clamped.count
        command.repeatGapMilliseconds = clamped.gapMilliseconds
        refreshFromCommand(clamped: clamped.wasClamped)
        changed(command)
        if relayout { layoutChanged() }
    }

    private func refreshFromCommand(clamped: Bool = false) {
        let isText: Bool
        switch command.kind {
        case .chord(let chord):
            isText = false
            for (modifier, cap) in modifierCaps {
                cap.setLatched(chord.modifiers.contains(modifier))
            }
            for (key, cap) in keyCaps {
                cap.setLatched(key == chord.key)
            }
            if case .character(let character) = chord.key {
                if characterField.text != character.uppercased() {
                    characterField.text = character.uppercased()
                }
                characterField.setActive(true)
            } else {
                characterField.setActive(false)
            }
        case .text(let snippet):
            isText = true
            if textField.text != snippet.text { textField.text = snippet.text }
            submitSwitch?.setOn(snippet.submits)
        }
        keysBlock.isHidden = isText
        textBlock.isHidden = !isText
        keysTypeCell?.setSelected(!isText)
        textTypeCell?.setSelected(isText)

        countStepper?.setValue(command.repeatCount)
        gapStepper?.setValue(command.repeatGapMilliseconds)
        gapStepper?.setEnabled(command.isRepeating)
        let burst = KeyCommandRepeatGuard.burstMilliseconds(
            count: command.repeatCount,
            gapMilliseconds: command.repeatGapMilliseconds
        )
        let seconds = String(format: "%.2f", Double(burst) / 1000)
        burstLabel.setText(
            "BURST \(seconds) S · LIMIT \(KeyCommandRepeatGuard.burstLimitMilliseconds / 1000) S"
                + (clamped ? " · CLAMPED" : ""),
            ink: clamped ? TallyPalette.caution : UIKitChassis.signal3
        )
        sendsLabel.setText(KeyCommandDispatcher.describe(command, on: terminal))
    }

    // MARK: Fields

    @objc private func characterEdited() {
        guard case .chord(var chord) = command.kind else { return }
        let text = characterField.text ?? ""
        if let key = KeyChord.Key.fromFieldText(text) {
            chord.key = key
            characterField.text = text.uppercased()
            command.kind = .chord(chord)
            commit()
        } else if text.isEmpty, case .character = chord.key {
            chord.key = .enter
            command.kind = .chord(chord)
            commit()
        }
    }

    @objc private func textEdited() {
        setText(textField.text ?? "")
    }

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        guard textField === characterField else {
            return !string.contains(where: { $0.isNewline })
        }
        // One printable character replaces whatever was there.
        if string.isEmpty { return true }
        guard KeyChord.Key.fromFieldText(string) != nil else { return false }
        textField.text = string.uppercased()
        textField.sendActions(for: .editingChanged)
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return false
    }
}

/// A keycap that presses: latching modifiers, single-select keys.
@MainActor
final class KeyCapControl: UIControl {
    private let face: KeyCapFaceView
    private let action: () -> Void

    init(face: KeyCapFace, side: CGFloat, accessibilityLabel: String, action: @escaping () -> Void) {
        self.face = KeyCapFaceView(face: face, side: side)
        self.action = action
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        self.accessibilityLabel = accessibilityLabel
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        self.face.isUserInteractionEnabled = false
        addSubview(self.face)
        self.face.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            self.face.leadingAnchor.constraint(equalTo: leadingAnchor),
            self.face.trailingAnchor.constraint(equalTo: trailingAnchor),
            self.face.topAnchor.constraint(equalTo: topAnchor),
            self.face.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addTarget(self, action: #selector(pressed), for: .touchUpInside)
        addTarget(self, action: #selector(touchDown), for: .touchDown)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setLatched(_ latched: Bool) {
        face.setLatched(latched)
        if latched {
            accessibilityTraits.insert(.selected)
        } else {
            accessibilityTraits.remove(.selected)
        }
    }

    override func accessibilityActivate() -> Bool {
        action()
        return true
    }

    @objc private func touchDown() {
        TerminalKeyHaptics.keyPress(on: self)
    }

    @objc private func pressed() { action() }
}

/// − value + : the composer's count and gap.
@MainActor
final class KeyCommandStepper: UIView {
    private(set) var value: Int
    private let range: ClosedRange<Int>
    private let step: Int
    private let format: (Int) -> String
    private let changed: (Int) -> Void
    private var minus: TallyEditorRowActionButton!
    private var plus: TallyEditorRowActionButton!
    private let valueLabel = UIKitChassisMonoLabel(
        "",
        font: UIKitChassis.monoFont(9.5, weight: .semibold),
        color: UIKitChassis.signal
    )
    private var enabled = true

    init(
        value: Int,
        range: ClosedRange<Int>,
        step: Int,
        format: @escaping (Int) -> String,
        accessibilityLabel: String,
        changed: @escaping (Int) -> Void
    ) {
        self.value = value
        self.range = range
        self.step = step
        self.format = format
        self.changed = changed
        super.init(frame: .zero)
        minus = TallyEditorRowActionButton(
            systemImage: "minus",
            accessibilityLabel: "\(accessibilityLabel), less",
            enabled: true,
            scale: KeyCommandMetrics.scale,
            action: { [weak self] in self?.adjust(-1) }
        )
        plus = TallyEditorRowActionButton(
            systemImage: "plus",
            accessibilityLabel: "\(accessibilityLabel), more",
            enabled: true,
            scale: KeyCommandMetrics.scale,
            action: { [weak self] in self?.adjust(1) }
        )
        isAccessibilityElement = false
        valueLabel.textAlignment = .center
        valueLabel.backgroundColor = UIKitChassis.screen
        valueLabel.isAccessibilityElement = true
        valueLabel.accessibilityLabel = accessibilityLabel
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(
            greaterThanOrEqualToConstant: KeyCommandMetrics.stepperValueWidth
        ).isActive = true
        valueLabel.heightAnchor.constraint(equalToConstant: KeyCommandMetrics.stepperHeight).isActive = true
        let row = UIStackView(arrangedSubviews: [minus, valueLabel, plus])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 1
        row.backgroundColor = UIKitChassis.bezelHi
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setValue(_ value: Int) {
        guard value != self.value else { return }
        self.value = value
        render()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        render()
    }

    private func adjust(_ direction: Int) {
        let next = min(max(range.lowerBound, value + direction * step), range.upperBound)
        guard next != value else { return }
        value = next
        render()
        changed(next)
    }

    private func render() {
        valueLabel.setText(format(value), ink: enabled ? UIKitChassis.signal : UIKitChassis.signal3)
        valueLabel.accessibilityValue = format(value)
        minus.isEnabled = enabled && value > range.lowerBound
        plus.isEnabled = enabled && value < range.upperBound
        minus.tintColor = minus.isEnabled ? UIKitChassis.signal2 : UIKitChassis.signal3
        plus.tintColor = plus.isEnabled ? UIKitChassis.signal2 : UIKitChassis.signal3
    }
}

/// A one-line mono field on the screen ground with the bezel hairline.
@MainActor
final class KeyCommandTextField: UITextField {
    func configure(placeholder: String, width: CGFloat, monoSize: CGFloat, height: CGFloat = 26) {
        font = UIKitChassis.monoFont(monoSize)
        textColor = UIKitChassis.signal
        tintColor = UIKitChassis.signal
        backgroundColor = UIKitChassis.screen
        attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: UIKitChassis.monoFont(monoSize),
                .foregroundColor: UIKitChassis.signal3,
            ]
        )
        autocorrectionType = .no
        autocapitalizationType = .none
        smartDashesType = .no
        smartQuotesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
        returnKeyType = .done
        layer.borderWidth = 1
        layer.borderColor = UIKitChassis.bezelHi.resolvedColor(with: traitCollection).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: KeyCommandMetrics.scaled(height)).isActive = true
        widthAnchor.constraint(
            greaterThanOrEqualToConstant: KeyCommandMetrics.scaled(width)
        ).isActive = true
    }

    /// The character field reads as the chord's key while a character is
    /// selected: signal border; otherwise the resting hairline.
    func setActive(_ active: Bool) {
        layer.borderColor = (active ? UIKitChassis.signal2 : UIKitChassis.bezelHi)
            .resolvedColor(with: traitCollection).cgColor
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: 6, dy: 0)
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: 6, dy: 0)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        layer.borderColor = UIKitChassis.bezelHi.resolvedColor(with: traitCollection).cgColor
    }
}
