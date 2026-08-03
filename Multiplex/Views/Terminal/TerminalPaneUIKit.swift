import Observation
import SwiftTerm
import UIKit
import UniformTypeIdentifiers

@MainActor
struct TerminalPaneConfiguration {
    var controller: TerminalSessionController?
    var hostExists: Bool
    var fontSize: CGFloat
    var theme: TerminalTheme
    var bottomChromeHeight: CGFloat
    var contentSafeArea: UIEdgeInsets
    var railOwnsBottomSafeArea: Bool
    var isActive: Bool
    var focusAllowed: Bool
    var close: () -> Void
}

/// A compact projection of everything the pane paints above the live
/// SwiftTerm surface. Keeping this value equatable lets Observation re-arm
/// without rebuilding the terminal view or losing selection/scroll state.
struct TerminalPaneObservedState: Equatable {
    var status: TerminalSessionController.Status
    var isResuming: Bool
    var tmuxCopyModeUIActive: Bool
    var selectTextModeUIActive: Bool
    var historyJump: TerminalSessionController.HistoryJumpPhase?
    var historyNotice: String?
    var dropState: TerminalSessionController.DropState?
    #if !os(visionOS)
    var dictation: TerminalSessionController.DictationState?
    var isDictating: Bool
    var keyboardLocked: Bool
    #endif

    @MainActor
    init(controller: TerminalSessionController) {
        status = controller.status
        isResuming = controller.isResuming
        tmuxCopyModeUIActive = controller.tmuxCopyModeUIActive
        selectTextModeUIActive = controller.selectTextModeUIActive
        historyJump = controller.historyJump
        historyNotice = controller.historyNotice
        dropState = controller.dropState
        #if !os(visionOS)
        dictation = controller.dictation
        isDictating = controller.isDictating
        keyboardLocked = KeyboardLock.shared.isLocked
        #endif
    }
}

/// Native owner of one terminal tab's screen and app-owned overlays. The
/// adopted `TerminalSurfaceView` remains alive across updates; only small HUD
/// views are rebuilt as observed state changes.
@MainActor
final class TerminalPaneViewController: UIViewController, UIDropInteractionDelegate {
    private var configuration: TerminalPaneConfiguration
    private var observedState: TerminalPaneObservedState?
    private var observationGeneration = 0

    private(set) var terminalSurface: TerminalSurfaceView?
    private(set) var statusView: UIView?
    private(set) var findingVeil: TerminalHistoryFindingVeilView?
    private(set) var dropTargetVeil: DropTargetVeilView?
    private(set) var missingHostView: UIView?
    private var selectionActionsOverlay: TerminalSelectionActionsOverlay?
    private var longPressMenuOverlay: TerminalLongPressMenuOverlay?

    private let topCenterStack = UIStackView()
    private let topTrailingStack = UIStackView()
    private let bottomStack = UIStackView()

    init(configuration: TerminalPaneConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        let root = UIView()
        root.clipsToBounds = true
        view = root
        installPrimarySurface()
        installOverlayStacks()
        root.addInteraction(UIDropInteraction(delegate: self))
        observationGeneration &+= 1
        observeAndRender(generation: observationGeneration)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        focusIfAppropriate()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        applyBackgrounds()
    }

    func update(configuration: TerminalPaneConfiguration) {
        let oldController = self.configuration.controller
        let becameActive = !self.configuration.isActive && configuration.isActive
        self.configuration = configuration
        guard isViewLoaded else { return }

        if oldController !== configuration.controller {
            observationGeneration &+= 1
            observedState = nil
            installPrimarySurface()
            observeAndRender(generation: observationGeneration)
            return
        }

        applyBackgrounds()
        terminalSurface?.update(configuration: surfaceConfiguration)
        if let observedState {
            render(observedState)
        } else {
            renderControllerlessState()
        }
        if becameActive { focusIfAppropriate() }
    }

    func prepareForRemoval() {
        observationGeneration &+= 1
        var inactive = surfaceConfiguration
        inactive.isActive = false
        terminalSurface?.update(configuration: inactive)
        selectionActionsOverlay?.detach()
        selectionActionsOverlay = nil
        longPressMenuOverlay?.detach()
        longPressMenuOverlay = nil
        hideDropTarget()
    }

    /// Focused UIKit tests can inject a coherent state without reaching into
    /// the session controller's private transport setters.
    func applyObservedState(_ state: TerminalPaneObservedState) {
        observedState = state
        render(state)
    }

    static func connectingCaption(
        hostName: String,
        sessionName: String?,
        isResuming: Bool
    ) -> String {
        guard isResuming else { return "Connecting to \(hostName)…" }
        return sessionName == nil
            ? "Reconnecting to \(hostName)…"
            : "Reattaching to \(hostName)…"
    }

    // MARK: Drop interaction

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        configuration.controller?.status == .live
            && session.hasItemsConforming(toTypeIdentifiers: [UTType.item.identifier])
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidEnter session: UIDropSession
    ) {
        guard configuration.controller?.status == .live else { return }
        showDropTarget()
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidExit session: UIDropSession
    ) {
        hideDropTarget()
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidEnd session: UIDropSession
    ) {
        hideDropTarget()
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
        UIDropProposal(operation: configuration.controller?.status == .live ? .copy : .forbidden)
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        performDrop session: UIDropSession
    ) {
        hideDropTarget()
        guard let controller = configuration.controller,
              controller.status == .live
        else { return }
        let providers = session.items.map(\.itemProvider)
        Task { @MainActor [weak controller] in
            controller?.deliverDrop(await TerminalDropLoader.load(providers))
        }
    }

    // MARK: Primary surface

    private var surfaceConfiguration: TerminalSurfaceView.Configuration {
        TerminalSurfaceView.Configuration(
            fontSize: configuration.fontSize,
            theme: configuration.theme,
            bottomChromeHeight: configuration.bottomChromeHeight,
            contentSafeArea: configuration.contentSafeArea,
            railOwnsBottomSafeArea: configuration.railOwnsBottomSafeArea,
            isActive: configuration.isActive && configuration.focusAllowed,
            shortcutBackend: configuration.controller?.route.sessionBackend
        )
    }

    private func installPrimarySurface() {
        terminalSurface?.removeFromSuperview()
        terminalSurface = nil
        missingHostView?.removeFromSuperview()
        missingHostView = nil
        clearTransientViews()
        applyBackgrounds()

        if let controller = configuration.controller {
            let surface = TerminalSurfaceView(
                controller: controller,
                configuration: surfaceConfiguration
            )
            surface.accessibilityIdentifier = "terminalPane.surface"
            view.insertSubview(surface, at: 0)
            pinToEdges(surface, of: view)
            terminalSurface = surface
        } else if !configuration.hostExists {
            let missing = makeMissingHostPanel()
            view.addSubview(missing)
            constrainCenteredPanel(missing)
            missingHostView = missing
        }
    }

    private func applyBackgrounds() {
        // PROTOTYPE(GLASS): the terminal surface carries the pane; this
        // wrapper goes clear so the screen ground never double-tints.
        view.backgroundColor = GlassPrototype.terminalWrapperGround(
            themeBackground: UIColor(configuration.theme.background)
        )
    }

    private func renderControllerlessState() {
        clearTransientViews()
        if configuration.controller == nil,
           !configuration.hostExists,
           missingHostView == nil {
            let missing = makeMissingHostPanel()
            view.addSubview(missing)
            constrainCenteredPanel(missing)
            missingHostView = missing
        }
    }

    // MARK: Observation and rendering

    private func observeAndRender(generation: Int) {
        guard generation == observationGeneration else { return }
        guard let controller = configuration.controller else {
            renderControllerlessState()
            return
        }
        let state = withObservationTracking {
            TerminalPaneObservedState(controller: controller)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeAndRender(generation: generation)
            }
        }
        let previous = observedState
        observedState = state
        render(state)
        if previous?.status != .live, state.status == .live {
            focusIfAppropriate()
        }
    }

    private func render(_ state: TerminalPaneObservedState) {
        guard isViewLoaded, let controller = configuration.controller else { return }
        terminalSurface?.update(configuration: surfaceConfiguration)
        renderStatus(state, controller: controller)
        renderFindingVeil(state)
        renderTopCenter(state, controller: controller)
        renderTopTrailing(state, controller: controller)
        renderBottom(state)
        renderSelectionActions(state, controller: controller)
    }

    /// Select Text mode's app-owned COPY/SELECT ALL bar. Installed while the
    /// mode is on for the active pane; detaching restores the fork's stock
    /// selection flow and clears any live selection with it.
    private func renderSelectionActions(
        _ state: TerminalPaneObservedState,
        controller: TerminalSessionController
    ) {
        let wantsOverlay = state.selectTextModeUIActive
            && configuration.isActive
            && state.status == .live
        if wantsOverlay {
            if selectionActionsOverlay == nil,
               let terminal = controller.terminalView {
                selectionActionsOverlay = TerminalSelectionActionsOverlay(
                    terminal: terminal,
                    done: { [weak controller] in
                        controller?.finishSelectTextMode()
                    }
                )
            }
        } else if let overlay = selectionActionsOverlay {
            overlay.detach()
            selectionActionsOverlay = nil
        }
        renderLongPressMenu(state, controller: controller)
    }

    /// The idle long-press block (SELECT / SELECT ALL / PASTE) rides every
    /// live active pane; inside select-text mode long presses seed the
    /// selection instead, so any visible block hides with the mode change.
    private func renderLongPressMenu(
        _ state: TerminalPaneObservedState,
        controller: TerminalSessionController
    ) {
        let wantsMenu = configuration.isActive && state.status == .live
        if wantsMenu {
            if longPressMenuOverlay == nil,
               let terminal = controller.terminalView {
                longPressMenuOverlay = TerminalLongPressMenuOverlay(
                    terminal: terminal,
                    select: { [weak self] position in
                        guard let controller = self?.configuration.controller else { return }
                        controller.beginSelectTextMode(
                            atScreenPosition: (col: position.col, row: position.row)
                        )
                        guard controller.selectTextModeUIActive else { return }
                        controller.terminalView?.seedWordSelection(atBufferPosition: position)
                    },
                    selectAll: { [weak self] position in
                        guard let controller = self?.configuration.controller else { return }
                        controller.beginSelectTextMode(
                            atScreenPosition: (col: position.col, row: position.row)
                        )
                        guard controller.selectTextModeUIActive else { return }
                        controller.terminalView?.selectAll(nil)
                    }
                )
            }
            if state.selectTextModeUIActive { longPressMenuOverlay?.hide() }
        } else if let overlay = longPressMenuOverlay {
            overlay.detach()
            longPressMenuOverlay = nil
        }
    }

    private func renderStatus(
        _ state: TerminalPaneObservedState,
        controller: TerminalSessionController
    ) {
        statusView?.removeFromSuperview()
        statusView = nil
        let replacement: UIView?
        switch state.status {
        case .connecting:
            let caption = Self.connectingCaption(
                hostName: controller.host.name,
                sessionName: controller.route.sessionName,
                isResuming: state.isResuming
            )
            replacement = TerminalPanePanelView.connecting(caption: caption)
            replacement?.accessibilityIdentifier = "terminalPane.status.connecting"
        case .live:
            replacement = nil
        case .ended(let reason):
            replacement = TerminalPanePanelView.ended(
                reason: reason,
                reconnect: { [weak controller] in controller?.reconnect() },
                close: configuration.close
            )
            replacement?.accessibilityIdentifier = "terminalPane.status.ended"
        }
        guard let replacement else { return }
        insertBelowChrome(replacement)
        constrainCenteredPanel(replacement)
        statusView = replacement
    }

    private func renderFindingVeil(_ state: TerminalPaneObservedState) {
        let isFinding: Bool
        if case .finding = state.historyJump { isFinding = true } else { isFinding = false }
        if isFinding, findingVeil == nil {
            let veil = TerminalHistoryFindingVeilView()
            veil.accessibilityIdentifier = "terminalPane.history.findingVeil"
            if let surface = terminalSurface {
                view.insertSubview(veil, aboveSubview: surface)
            } else {
                view.insertSubview(veil, at: 0)
            }
            pinToEdges(veil, of: view)
            findingVeil = veil
        } else if !isFinding {
            findingVeil?.removeFromSuperview()
            findingVeil = nil
        }
    }

    private func renderTopCenter(
        _ state: TerminalPaneObservedState,
        controller: TerminalSessionController
    ) {
        removeArrangedSubviews(from: topCenterStack)
        guard configuration.isActive else { return }
        if state.tmuxCopyModeUIActive {
            let bar = TerminalContextBarView.copyMode { [weak controller] in
                controller?.finishTmuxCopyMode()
            }
            bar.accessibilityIdentifier = "terminalPane.context.copyMode"
            topCenterStack.addArrangedSubview(bar)
        }
        // Select Text mode carries its own chrome in the floating block
        // (`TerminalSelectionActionsOverlay`) — nothing top-center.
        #if !os(visionOS)
        if let dictation = state.dictation {
            guard !state.tmuxCopyModeUIActive else { return }
            let bar = TerminalContextBarView.dictation(
                dictation,
                stop: { [weak controller] in controller?.stopDictation() },
                cancel: { [weak controller] in controller?.cancelDictation() }
            )
            bar.accessibilityIdentifier = "terminalPane.context.dictation"
            topCenterStack.addArrangedSubview(bar)
        } else if state.keyboardLocked {
            // Top-center, not top-trailing: the trailing slot carries the
            // window's own chrome (the backend switch), which the tip covered.
            let locked = TerminalKeyboardLockedView(
                isDictating: state.isDictating,
                toggleDictation: { [weak controller] in controller?.toggleDictation() }
            )
            locked.accessibilityIdentifier = "terminalPane.keyboardLocked"
            topCenterStack.addArrangedSubview(locked)
        }
        #endif
    }

    private func renderTopTrailing(
        _ state: TerminalPaneObservedState,
        controller: TerminalSessionController
    ) {
        removeArrangedSubviews(from: topTrailingStack)
        guard configuration.isActive else { return }
        if !state.tmuxCopyModeUIActive, let phase = state.historyJump {
            let jump = TerminalContextBarView.historyJump(
                phase,
                cancel: { [weak controller] in controller?.cancelHistoryJump() },
                backToLive: { [weak controller] in controller?.finishHistoryJump() }
            )
            jump.accessibilityIdentifier = "terminalPane.context.historyJump"
            topTrailingStack.addArrangedSubview(jump)
        }
    }

    private func renderBottom(_ state: TerminalPaneObservedState) {
        removeArrangedSubviews(from: bottomStack)
        if let notice = state.historyNotice {
            let pill = TerminalHistoryNoticePillView(text: notice)
            pill.accessibilityIdentifier = "terminalPane.history.notice"
            bottomStack.addArrangedSubview(pill)
        }
        if let dropState = state.dropState {
            let pill = DropStatusPillView(state: dropState)
            pill.accessibilityIdentifier = "terminalPane.drop.status"
            bottomStack.addArrangedSubview(pill)
        }
    }

    /// Deliberately unconditional in the transport's status: becoming the
    /// visible tab must move the app-wide input session onto this pane even
    /// when it is connecting or ended, or the tab that just went off screen
    /// keeps the keyboard. The `.live` condition belongs only to the
    /// status-change caller in `observeAndRender`.
    private func focusIfAppropriate() {
        guard configuration.isActive, configuration.focusAllowed else { return }
        configuration.controller?.focusTerminal()
    }

    // MARK: Hierarchy helpers

    private func installOverlayStacks() {
        for stack in [topCenterStack, topTrailingStack, bottomStack] {
            stack.axis = .vertical
            stack.spacing = 8
            view.addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
        }
        topCenterStack.alignment = .center
        topTrailingStack.alignment = .trailing
        bottomStack.alignment = .center
        NSLayoutConstraint.activate([
            topCenterStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            topCenterStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topCenterStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            topCenterStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),

            topTrailingStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            topTrailingStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            topTrailingStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),

            bottomStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            bottomStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            bottomStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
        ])
    }

    private func showDropTarget() {
        guard dropTargetVeil == nil,
              configuration.controller?.status == .live
        else { return }
        let veil = DropTargetVeilView()
        veil.accessibilityIdentifier = "terminalPane.drop.target"
        view.addSubview(veil)
        pinToEdges(veil, of: view)
        dropTargetVeil = veil
    }

    private func hideDropTarget() {
        dropTargetVeil?.removeFromSuperview()
        dropTargetVeil = nil
    }

    private func clearTransientViews() {
        statusView?.removeFromSuperview()
        statusView = nil
        findingVeil?.removeFromSuperview()
        findingVeil = nil
        selectionActionsOverlay?.detach()
        selectionActionsOverlay = nil
        longPressMenuOverlay?.detach()
        longPressMenuOverlay = nil
        hideDropTarget()
        removeArrangedSubviews(from: topCenterStack)
        removeArrangedSubviews(from: topTrailingStack)
        removeArrangedSubviews(from: bottomStack)
    }

    private func insertBelowChrome(_ child: UIView) {
        if topCenterStack.superview === view {
            view.insertSubview(child, belowSubview: topCenterStack)
        } else {
            view.addSubview(child)
        }
    }

    private func constrainCenteredPanel(_ child: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            child.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            child.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            child.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func pinToEdges(_ child: UIView, of parent: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    private func removeArrangedSubviews(from stack: UIStackView) {
        for child in stack.arrangedSubviews {
            stack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
    }

    private func makeMissingHostPanel() -> UIView {
        let title = UILabel()
        title.text = "This host was removed"
        title.font = UIKitChassis.monoFont(17, weight: .semibold)
        title.textColor = UIKitChassis.signal
        title.textAlignment = .center

        let detail = UILabel()
        detail.text = "The tab can't reconnect because its host no longer exists in the deck."
        // Body copy, not chrome: a semantic style keeps Dynamic Type (fixed
        // `uiFont` sizes ignore it, and the two mechanisms never compound).
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = UIKitChassis.signal2
        detail.textAlignment = .center
        detail.numberOfLines = 0
        detail.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true

        let close = UIKitChassisChip(
            "CLOSE TAB",
            prominent: true,
            accessibilityLabel: "Close tab",
            action: configuration.close
        )
        let panel = TerminalPanePanelView(arrangedSubviews: [title, detail, close])
        panel.accessibilityIdentifier = "terminalPane.missingHost"
        return panel
    }
}

// MARK: - Native pane chrome

@MainActor
final class TerminalPanePanelView: UIKitTallyBorderedView {
    private let stack = UIStackView()

    init(arrangedSubviews: [UIView]) {
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.bezel
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 30),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -30),
        ])
        for child in arrangedSubviews { stack.addArrangedSubview(child) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    static func connecting(caption: String) -> TerminalPanePanelView {
        let progress = UIActivityIndicatorView(style: .medium)
        progress.color = UIKitChassis.signal2
        progress.startAnimating()
        let label = UILabel()
        label.text = caption
        label.font = UIKitChassis.monoFont(14)
        label.textColor = UIKitChassis.signal2
        label.textAlignment = .center
        label.numberOfLines = 0
        let panel = TerminalPanePanelView(arrangedSubviews: [progress, label])
        panel.isAccessibilityElement = true
        panel.accessibilityLabel = caption
        return panel
    }

    static func ended(
        reason: String?,
        reconnect: @escaping () -> Void,
        close: @escaping () -> Void
    ) -> TerminalPanePanelView {
        var views: [UIView] = [
            UIKitTallyLamp(
                caption: reason == nil ? "DETACHED" : "ENDED",
                color: UIKitChassis.signal3
            ),
        ]
        if let reason {
            let label = UILabel()
            label.text = reason
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = UIKitChassis.signal2
            label.textAlignment = .center
            label.numberOfLines = 0
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
            views.append(label)
        }
        let reconnectChip = UIKitChassisChip(
            "RECONNECT",
            prominent: true,
            accessibilityLabel: "Reconnect",
            action: reconnect
        )
        let closeChip = UIKitChassisChip(
            "CLOSE TAB",
            accessibilityLabel: "Close tab",
            action: close
        )
        let actions = UIStackView(arrangedSubviews: [reconnectChip, closeChip])
        actions.axis = .horizontal
        actions.alignment = .center
        actions.spacing = 12
        views.append(actions)
        let panel = TerminalPanePanelView(arrangedSubviews: views)
        panel.accessibilityLabel = reason.map { "Ended, \($0)" } ?? "Detached"
        return panel
    }
}

@MainActor
final class TerminalContextBarView: UIKitTallyBorderedView {
    private let row = UIStackView()

    init(items: [UIView]) {
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.bezel
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        clipsToBounds = true
        shouldGroupAccessibilityChildren = true
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 18
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
        for item in items { row.addArrangedSubview(item) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    static func copyMode(done: @escaping () -> Void) -> TerminalContextBarView {
        TerminalContextBarView(items: [
            UIKitTallyLamp(caption: "COPY MODE", color: TallyPalette.caution),
            UIKitChassisChip(
                "DONE",
                prominent: true,
                accessibilityLabel: "Done",
                action: done
            ),
        ])
    }

}

/// Select Text mode's ONE piece of chrome — the mode lamp, its selection
/// actions, and its exit, all in the floating block (the top-center HUD
/// moved down here so cancel sits beside the work). Installing it hands the
/// fork's selection chrome to the app (`TerminalView.selectionUIHandler`):
/// the native menu never shows, a plain tap seeds a word selection, and the
/// handler reports the selection's screen box so the block can float
/// beside it — with no selection yet, the block parks top-center (COPY
/// hidden until there is something to copy; DONE always reachable). Lives
/// as a subview of the `TerminalView` itself (the link hover overlay's
/// pattern) so the reported rect needs no conversion.
@MainActor
final class TerminalSelectionActionsOverlay {
    private weak var terminal: TerminalView?
    private let bar: TerminalContextBarView
    private let copyChip: UIKitChassisChip

    init(terminal: TerminalView, done: @escaping () -> Void) {
        self.terminal = terminal
        // COPY finishes the job: pasteboard, then the mode ends with it —
        // the grab is what the mode was entered for.
        copyChip = UIKitChassisChip(
            "COPY",
            prominent: true,
            accessibilityLabel: "Copy selection",
            action: { [weak terminal] in
                terminal?.copy(nil)
                done()
            }
        )
        bar = TerminalContextBarView(items: [
            UIKitTallyLamp(caption: "SELECT TEXT", color: TallyPalette.caution),
            copyChip,
            UIKitChassisChip(
                "SELECT ALL",
                accessibilityLabel: "Select all in pane",
                action: { [weak terminal] in terminal?.selectAll(nil) }
            ),
            UIKitChassisChip(
                "DONE",
                accessibilityLabel: "Done selecting",
                action: done
            ),
        ])
        bar.accessibilityIdentifier = "terminalPane.selection.actions"
        terminal.addSubview(bar)
        terminal.selectionUIHandler = { [weak self] rect in
            self?.place(rect)
        }
        // A selection can already exist when the mode's chrome installs —
        // SELECT from the long-press block seeds it before Observation
        // re-renders the pane — so place the block for it right away.
        place(terminal.selectionUIRect())
    }

    /// Uninstall: the fork returns to its stock selection flow and any live
    /// selection clears with the mode.
    func detach() {
        terminal?.selectionUIHandler = nil
        terminal?.clearSelection()
        bar.removeFromSuperview()
    }

    /// Float the block beside the selection; without one it parks
    /// top-center — the mode stays visible and DONE stays reachable.
    private func place(_ rect: CGRect?) {
        guard let terminal else { return }
        copyChip.isHidden = rect == nil
        if let rect {
            floatContextBar(bar, near: rect, in: terminal)
        } else {
            let size = bar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            bar.frame = CGRect(
                origin: CGPoint(
                    x: max(8, (terminal.bounds.width - size.width) / 2),
                    y: 8
                ),
                size: size
            )
            bar.isHidden = false
            terminal.bringSubviewToFront(bar)
        }
    }
}

/// Shared placement for floating context bars over the terminal: centered
/// above the anchor, below when the top would clip, always inside the
/// terminal's bounds.
@MainActor
private func floatContextBar(
    _ bar: TerminalContextBarView,
    near rect: CGRect,
    in terminal: TerminalView
) {
    let size = bar.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    let bounds = terminal.bounds
    let margin: CGFloat = 8
    let x = min(
        max(rect.midX - size.width / 2, margin),
        max(margin, bounds.width - size.width - margin)
    )
    var y = rect.minY - size.height - margin
    if y < margin {
        y = rect.maxY + margin
    }
    if y + size.height > bounds.height - margin {
        y = max(margin, bounds.height - size.height - margin)
    }
    bar.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
    bar.isHidden = false
    terminal.bringSubviewToFront(bar)
}

/// The long-press block OUTSIDE select-text mode — the app-drawn
/// replacement for UIMenuController's SELECT / SELECT ALL / PASTE. SELECT
/// and SELECT ALL hand off into select-text mode (seeded at the pressed
/// word / the whole pane); PASTE types the pasteboard into the live screen
/// exactly like the old menu action. Installed for every live active
/// terminal pane through `TerminalView.longPressMenuHandler`; a tap
/// anywhere dismisses the block and is consumed, the native menu's own
/// contract.
@MainActor
final class TerminalLongPressMenuOverlay {
    private weak var terminal: TerminalView?
    private var bar: TerminalContextBarView!
    private var pressedPosition: Position?
    private let select: (Position) -> Void
    private let selectAll: (Position) -> Void

    init(
        terminal: TerminalView,
        select: @escaping (Position) -> Void,
        selectAll: @escaping (Position) -> Void
    ) {
        self.terminal = terminal
        self.select = select
        self.selectAll = selectAll
        bar = TerminalContextBarView(items: [
            UIKitChassisChip(
                "SELECT",
                prominent: true,
                accessibilityLabel: "Select text",
                action: { [weak self] in self?.performSelect() }
            ),
            UIKitChassisChip(
                "SELECT ALL",
                accessibilityLabel: "Select all in pane",
                action: { [weak self] in self?.performSelectAll() }
            ),
            UIKitChassisChip(
                "PASTE",
                accessibilityLabel: "Paste",
                action: { [weak self] in self?.performPaste() }
            ),
        ])
        bar.accessibilityIdentifier = "terminalPane.longPress.menu"
        bar.isHidden = true
        terminal.addSubview(bar)
        terminal.longPressMenuHandler = { [weak self] region, position in
            self?.show(near: region, position: position)
        }
    }

    func hide() {
        bar.isHidden = true
        terminal?.appMenuDismiss = nil
    }

    func detach() {
        terminal?.longPressMenuHandler = nil
        terminal?.appMenuDismiss = nil
        bar.removeFromSuperview()
    }

    private func show(near region: CGRect, position: Position) {
        guard let terminal else { return }
        pressedPosition = position
        floatContextBar(bar, near: region, in: terminal)
        terminal.appMenuDismiss = { [weak self] in self?.hide() }
    }

    private func performSelect() {
        hide()
        guard let pressedPosition else { return }
        select(pressedPosition)
    }

    private func performSelectAll() {
        hide()
        guard let pressedPosition else { return }
        selectAll(pressedPosition)
    }

    private func performPaste() {
        hide()
        terminal?.paste(nil)
    }
}

extension TerminalContextBarView {
    #if !os(visionOS)
    static func dictation(
        _ state: TerminalSessionController.DictationState,
        stop: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) -> TerminalContextBarView {
        switch state {
        case .listening(let pending):
            var items: [UIView] = [
                UIKitTallyLamp(caption: "LISTENING", color: TallyPalette.tally),
            ]
            if !pending.isEmpty {
                let pendingLabel = UILabel()
                pendingLabel.text = pending
                pendingLabel.font = UIKitChassis.monoFont(12)
                pendingLabel.textColor = UIKitChassis.signal3
                pendingLabel.lineBreakMode = .byTruncatingHead
                pendingLabel.numberOfLines = 1
                pendingLabel.accessibilityLabel = "Heard, not typed yet: \(pending)"
                pendingLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
                items.append(pendingLabel)
            }
            items.append(UIKitChassisChip(
                "CANCEL",
                accessibilityLabel: "Cancel dictation",
                action: cancel
            ))
            items.append(UIKitChassisChip(
                "STOP",
                prominent: true,
                accessibilityLabel: "Stop dictation",
                action: stop
            ))
            return TerminalContextBarView(items: items)
        case .failed(let message):
            let messageLabel = UILabel()
            messageLabel.text = message
            messageLabel.font = .preferredFont(forTextStyle: .footnote)
            messageLabel.adjustsFontForContentSizeCategory = true
            messageLabel.textColor = UIKitChassis.signal2
            messageLabel.numberOfLines = 2
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
            return TerminalContextBarView(items: [
                UIKitTallyLamp(caption: "DICTATION", color: TallyPalette.caution),
                messageLabel,
            ])
        }
    }
    #endif

    static func historyJump(
        _ phase: TerminalSessionController.HistoryJumpPhase,
        cancel: @escaping () -> Void,
        backToLive: @escaping () -> Void
    ) -> TerminalContextBarView {
        let caption: String
        let preview: String
        let action: UIView
        switch phase {
        case .finding(let value):
            caption = "FINDING"
            preview = value
            action = UIKitChassisChip(
                "CANCEL",
                accessibilityLabel: "Cancel finding message",
                action: cancel
            )
        case .jumped(let value, _):
            caption = "JUMPED"
            preview = value
            action = UIKitChassisChip(
                "BACK TO LIVE",
                prominent: true,
                accessibilityLabel: "Back to live",
                action: backToLive
            )
        }
        let previewLabel = UILabel()
        previewLabel.text = preview
        previewLabel.font = UIKitChassis.monoFont(10)
        previewLabel.textColor = UIKitChassis.signal2
        previewLabel.numberOfLines = 1
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        return TerminalContextBarView(items: [
            UIKitTallyLamp(caption: caption, color: TallyPalette.caution),
            previewLabel,
            action,
        ])
    }
}

#if !os(visionOS)
@MainActor
final class TerminalKeyboardLockedView: UIKitTallyBorderedView {
    init(isDictating: Bool, toggleDictation: @escaping () -> Void) {
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.bezel
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        clipsToBounds = true
        shouldGroupAccessibilityChildren = true

        let lock = UIImageView(image: UIImage(systemName: "lock.fill"))
        lock.tintColor = UIKitChassis.signal2
        lock.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 10 * Theme.typeScale,
            weight: .semibold
        )
        let caption = UILabel()
        let size = 10 * Theme.typeScale
        caption.attributedText = NSAttributedString(
            string: "KEYBOARD LOCKED",
            attributes: [
                .font: UIKitChassis.monoFont(10, weight: .semibold),
                .kern: size * 0.11,
                .foregroundColor: UIKitChassis.signal2,
            ]
        )
        let labelRow = UIStackView(arrangedSubviews: [lock, caption])
        labelRow.axis = .horizontal
        labelRow.alignment = .center
        labelRow.spacing = 7
        let labelShell = UIView()
        labelShell.addSubview(labelRow)
        labelRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            labelRow.leadingAnchor.constraint(equalTo: labelShell.leadingAnchor, constant: 10),
            labelRow.trailingAnchor.constraint(equalTo: labelShell.trailingAnchor, constant: -10),
            labelRow.topAnchor.constraint(equalTo: labelShell.topAnchor, constant: 7),
            labelRow.bottomAnchor.constraint(equalTo: labelShell.bottomAnchor, constant: -7),
        ])

        let divider = UIView()
        divider.backgroundColor = UIKitChassis.bezelHi
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 20),
        ])

        // SwiftUI's original control used `.buttonStyle(.plain)`. A custom
        // button keeps UIKit from printing its native tinted button ground
        // behind the TALLY lock badge.
        let mic = UIButton(type: .custom)
        mic.setImage(UIImage(systemName: isDictating ? "mic.fill" : "mic"), for: .normal)
        // Type-locked chrome glyph: authored point size, riding `typeScale`
        // like the padlock beside it. Without a configuration UIKit draws it
        // at the default body symbol size and never scales it on Mac.
        mic.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(
                pointSize: 12 * Theme.typeScale,
                weight: .semibold
            ),
            forImageIn: .normal
        )
        mic.tintColor = isDictating ? UIKitChassis.chassis : UIKitChassis.signal2
        mic.backgroundColor = isDictating ? UIKitChassis.signal2 : .clear
        mic.accessibilityLabel = isDictating ? "Stop dictation" : "Dictate"
        mic.accessibilityHint = "Types what you say into the session as you speak, never pressing Return"
        mic.addAction(UIAction { _ in toggleDictation() }, for: .touchUpInside)
        mic.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mic.widthAnchor.constraint(equalToConstant: 36),
            mic.heightAnchor.constraint(equalToConstant: 32),
        ])

        let row = UIStackView(arrangedSubviews: [labelShell, divider, mic])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 0
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}
#endif

@MainActor
final class TerminalHistoryFindingVeilView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIKitChassis.screen.withAlphaComponent(0.72)
        isAccessibilityElement = true
        accessibilityLabel = "Searching transcript"

        let progress = UIActivityIndicatorView(style: .medium)
        progress.color = UIKitChassis.signal2
        progress.startAnimating()
        let label = UIKitChassisLabel(
            "SEARCHING TRANSCRIPT",
            size: 10,
            color: UIKitChassis.signal2
        )
        let stack = UIStackView(arrangedSubviews: [progress, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

@MainActor
final class TerminalHistoryNoticePillView: UIKitTallyBorderedView {
    init(text: String) {
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.bezel
        isAccessibilityElement = true
        accessibilityLabel = text

        let dot = UIView()
        dot.backgroundColor = TallyPalette.caution
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5),
        ])
        let label = UILabel()
        label.text = text
        label.font = UIKitChassis.monoFont(10)
        label.textColor = UIKitChassis.signal2
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        let row = UIStackView(arrangedSubviews: [dot, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}
