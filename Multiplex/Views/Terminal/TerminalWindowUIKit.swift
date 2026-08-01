import Observation
import OSLog
import UIKit
#if DEBUG
import SwiftTerm
#endif

@MainActor
struct TerminalWindowDependencies {
    let store: HostStore
    let hub: ConnectionHub
    let themes: ThemeStore
    let workspace: TerminalWorkspace
    let entitlements: EntitlementStore
}

@MainActor
struct TerminalWindowShellConfiguration {
    var deckControlLabel: String
    var availableWidth: CGFloat
    var contentSafeArea: UIEdgeInsets = .zero
    var railOwnsBottomSafeArea = false
    var showDeck: () -> Void
    var openTerminalRoute: (TerminalWindowRoute) -> Void
    var revealTab: (UUID) -> Void
    var tabsEmptied: () -> Void
    var terminalFocusAllowed: Bool
}

private struct TerminalWindowShellPresentationKey: Equatable {
    var deckControlLabel: String
    var availableWidth: CGFloat
    var contentSafeArea: UIEdgeInsets
    var railOwnsBottomSafeArea: Bool
    var terminalFocusAllowed: Bool

    init?(_ shell: TerminalWindowShellConfiguration?) {
        guard let shell else { return nil }
        deckControlLabel = shell.deckControlLabel
        availableWidth = shell.availableWidth
        contentSafeArea = shell.contentSafeArea
        railOwnsBottomSafeArea = shell.railOwnsBottomSafeArea
        terminalFocusAllowed = shell.terminalFocusAllowed
    }
}

#if !os(visionOS)
private struct TerminalWindowMergeSourceKey: Equatable {
    var id: UUID
    var label: String
}

private struct TerminalWindowNavigationChromeKey: Equatable {
    var usesShell: Bool
    var windowTitle: String
    var horizontalSizeClass: UIUserInterfaceSizeClass
    var activeControllerID: ObjectIdentifier?
    var usesMosh: Bool
    var needsYou: Bool
    var hasKeychainNotice: Bool
    var activeIsAuxiliary: Bool
    var auxiliaryCloseLabel: String
    var mergeSources: [TerminalWindowMergeSourceKey]
    var activeTabHasSession: Bool
    var keyboardLocked: Bool
    var compactAttachmentAvailability: FileAttachMenuAvailability?
}
#endif

/// The classic scene lays pane controls above the protected bottom strip,
/// then paints that noninteractive strip as a continuation of the surface
/// touching it. SwiftUI did this edge bleed implicitly; UIKit needs the
/// owning surface named explicitly.
@MainActor
enum TerminalWindowBottomSafeAreaFill: Equatable {
    case chassis
    case terminalKeyRail
    case auxiliaryRail

    static func resolve(
        isClassic: Bool,
        activeTab: TerminalRoute?,
        hasActiveTerminalController: Bool
    ) -> Self {
        guard isClassic else { return .chassis }
        if activeTab?.isAuxiliaryPane == true { return .auxiliaryRail }
        return hasActiveTerminalController ? .terminalKeyRail : .chassis
    }

    var color: UIColor {
        switch self {
        case .chassis: UIKitChassis.chassis
        case .terminalKeyRail, .auxiliaryRail: UIKitChassis.bezel
        }
    }
}

#if !os(visionOS)
/// Restores the explicit outer breathing room the SwiftUI terminal toolbar
/// applied after its final action on iPadOS 26+. Bar-item padding remains
/// disabled so the TALLY faces themselves keep their exact intrinsic widths;
/// this wrapper contributes space only between the last face and the window.
@MainActor
final class TerminalNavigationTrailingInsetView: UIView {
    static let trailingInset: CGFloat = 12

    let contentView: UIView

    init(contentView: UIView) {
        self.contentView = contentView
        super.init(frame: .zero)
        addSubview(contentView)
        isAccessibilityElement = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var intrinsicContentSize: CGSize {
        let content = contentView.intrinsicContentSize
        return CGSize(
            width: ceil(max(0, content.width)) + Self.trailingInset,
            height: ceil(max(0, content.height))
        )
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        intrinsicContentSize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let content = contentView.intrinsicContentSize
        let width = min(max(0, bounds.width - Self.trailingInset), max(0, content.width))
        let height = min(bounds.height, max(0, content.height))
        contentView.frame = CGRect(
            x: 0,
            y: max(0, (bounds.height - height) / 2),
            width: width,
            height: height
        )
    }
}

/// Keeps the legacy SwiftUI font controls as one fixed-size HStack. Separate
/// custom bar items inherit iPadOS's 44-point item width and system spacing,
/// which makes these two compact chips visibly wider and farther apart.
@MainActor
final class TerminalFontSizeControl: UIView {
    static let spacing: CGFloat = 4

    let smallerButton: UMDBarButton
    let largerButton: UMDBarButton

    init(fontDown: @escaping () -> Void, fontUp: @escaping () -> Void) {
        smallerButton = UMDBarButton(
            caption: "A−",
            systemImage: nil,
            prominent: false,
            accessibilityLabel: "Smaller text"
        )
        largerButton = UMDBarButton(
            caption: "A+",
            systemImage: nil,
            prominent: false,
            accessibilityLabel: "Larger text"
        )
        super.init(frame: .zero)

        smallerButton.addAction(UIAction { _ in fontDown() }, for: .touchUpInside)
        largerButton.addAction(UIAction { _ in fontUp() }, for: .touchUpInside)
        addSubview(smallerButton)
        addSubview(largerButton)

        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var intrinsicContentSize: CGSize {
        let smaller = smallerButton.intrinsicContentSize
        let larger = largerButton.intrinsicContentSize
        return CGSize(
            width: smaller.width + Self.spacing + larger.width,
            height: max(smaller.height, larger.height)
        )
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        intrinsicContentSize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let smaller = smallerButton.intrinsicContentSize
        let larger = largerButton.intrinsicContentSize
        let contentWidth = smaller.width + Self.spacing + larger.width
        let startX = max(0, (bounds.width - contentWidth) / 2)
        smallerButton.frame = CGRect(
            x: startX,
            y: (bounds.height - smaller.height) / 2,
            width: smaller.width,
            height: smaller.height
        )
        largerButton.frame = CGRect(
            x: smallerButton.frame.maxX + Self.spacing,
            y: (bounds.height - larger.height) / 2,
            width: larger.width,
            height: larger.height
        )
    }
}
#endif

/// UIKit owner of one classic terminal scene or the terminal side of the
/// adaptive shell. It owns route reconciliation, child pane lifetimes,
/// source labels, UMD/navigation chrome, helper detection, presentations,
/// focus, probes, and scene lifecycle. The same controller is used for
/// visionOS and iPadOS; only the outer placement of its chrome differs.
@MainActor
final class TerminalWindowViewController: UIViewController,
    UIAdaptivePresentationControllerDelegate
{
    private static let hostProbeInterval: Duration = .seconds(5)
    private static let focusedPaneProbeInterval: Duration = .seconds(1)

    private(set) var route: TerminalWindowRoute
    private var shell: TerminalWindowShellConfiguration?
    private let dependencies: TerminalWindowDependencies
    private let sceneWindows: SceneWindowRouting
    private let routeChanged: (TerminalWindowRoute) -> Void

    private var fontSize: CGFloat
    private var shownAgent: AgentKind?
    private var lastDetectedAgent: AgentKind?
    private var lastObservedActiveTabID: UUID?
    private var activePaneFingerprint: TmuxPaneFingerprint?
    private var creatingTab = false
    private var preparedForRemoval = false
    private var appLocked = false
    #if !os(visionOS)
    private var renderedNavigationChromeKey: TerminalWindowNavigationChromeKey?
    #endif

    private let rootView = TerminalWindowUIKitRootView()
    private let tabStrip = TerminalTabStripView()
    #if os(visionOS)
    private lazy var visionOrnaments = TerminalVisionOrnamentCoordinator(
        tabStrip: tabStrip
    )
    private let visionShellKeyContext = TerminalKeyClusterContext()
    private lazy var visionShellKeyCluster = TerminalKeyClusterGroupView(
        role: .standalone,
        metric: .regular,
        context: visionShellKeyContext
    )
    #endif
    private var paneControllers: [UUID: UIViewController] = [:]
    private var umdController: UIViewController?
    private var helperController: AgentHelperStripViewController?
    /// Mirrors the legacy helper's `.id(activeTab.hostID)`: even when two
    /// hosts expose the same agent kind, their editor drafts and command
    /// configuration must never share controller state.
    private var helperHostID: UUID?
    private var fileAttachController: FileAttachMenuViewController?
    private let passphrasePresenter = SSHKeyPassphrasePromptPresenterViewController()

    private var observationGeneration = 0
    private var hostProbeTask: Task<Void, Never>?
    private var activePaneTask: Task<Void, Never>?
    private var hideAgentTask: Task<Void, Never>?
    private var cloudRefreshTask: Task<Void, Never>?
    private var autoAttachTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []
    #if DEBUG
    private var debugObservers: [NSObjectProtocol] = []
    #endif

    private var presentedActivationID: String?
    private weak var presentedFeatureController: UIViewController?

    init(
        route: TerminalWindowRoute,
        dependencies: TerminalWindowDependencies,
        sceneWindows: SceneWindowRouting,
        shell: TerminalWindowShellConfiguration? = nil,
        routeChanged: @escaping (TerminalWindowRoute) -> Void = { _ in }
    ) {
        self.route = route
        self.dependencies = dependencies
        self.sceneWindows = sceneWindows
        self.shell = shell
        self.routeChanged = routeChanged
        #if os(visionOS)
        fontSize = 14
        #else
        fontSize = UIDevice.current.userInterfaceIdiom == .phone ? 12 : 14
        #endif
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        hostProbeTask?.cancel()
        activePaneTask?.cancel()
        hideAgentTask?.cancel()
        cloudRefreshTask?.cancel()
        autoAttachTask?.cancel()
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        #if DEBUG
        for observer in debugObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    override func loadView() {
        view = rootView
        view.backgroundColor = UIKitChassis.chassis
        #if os(visionOS)
        updateVisionOrnamentInstallation()
        #endif
        configurePassphrasePresenter()
        configureLifecycleObservers()
        #if DEBUG
        configureDebugObservers()
        #endif
        syncTabs()
        restartActiveTasks()
        observationGeneration &+= 1
        observeAndRender(generation: observationGeneration)
        cloudRefreshTask = Task { [weak store = dependencies.store] in
            await store?.refreshFromCloud()
        }
        dependencies.entitlements.refreshSlashChipMeter()
        #if DEBUG
        autoAttachTask = Task { [weak self] in
            guard let self else { return }
            await DeckScene.autoAttachIfRequested(
                store: dependencies.store,
                workspace: dependencies.workspace,
                openTerminalWindow: { [weak self] route in
                    guard let self else { return }
                    if let shell = self.shell {
                        shell.openTerminalRoute(route)
                    } else {
                        self.sceneWindows.openTerminal(route)
                    }
                }
            )
        }
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureNavigationChrome()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        restoreActiveTerminalFocusIfOwner()
        presentPendingFeatureIfPossible()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutNativeChrome()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        layoutNativeChrome()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
            || traitCollection.horizontalSizeClass
                != previousTraitCollection?.horizontalSizeClass
        else { return }
        renderNow()
    }

    func update(
        route: TerminalWindowRoute,
        shell: TerminalWindowShellConfiguration?
    ) {
        let oldActive = self.route.activeTabID
        let routeChangedExternally = self.route != route
        let shellChanged = TerminalWindowShellPresentationKey(self.shell)
            != TerminalWindowShellPresentationKey(shell)
        self.route = route
        self.shell = shell
        guard isViewLoaded else { return }
        guard routeChangedExternally || shellChanged else { return }
        #if os(visionOS)
        updateVisionOrnamentInstallation()
        #endif
        if routeChangedExternally {
            syncTabs()
        }
        if oldActive != route.activeTabID {
            activeTabDidChange(from: oldActive)
        } else {
            restartObservation()
        }
    }

    /// Propagated by the UIKit scene root. Spatial ornaments live outside
    /// that root's disabled content hierarchy, so locking must remove them
    /// explicitly; unlocking reinstalls the same native controllers.
    func setAppLocked(_ locked: Bool) {
        guard appLocked != locked else { return }
        appLocked = locked
        guard isViewLoaded else { return }

        if locked {
            #if os(visionOS)
            visionOrnaments.remove()
            updateVisionShellKeyCluster()
            #endif
        } else {
            #if os(visionOS)
            updateVisionOrnamentInstallation()
            #endif
            renderNow()
        }
    }

    /// Scene/shell teardown. Moved tabs have already left `route`; only tabs
    /// still owned here are real closes and detach their transports.
    func prepareForRemoval() {
        guard !preparedForRemoval else { return }
        preparedForRemoval = true
        observationGeneration &+= 1
        hostProbeTask?.cancel()
        activePaneTask?.cancel()
        hideAgentTask?.cancel()
        autoAttachTask?.cancel()
        #if os(visionOS)
        visionOrnaments.remove()
        visionShellKeyCluster.update(controller: nil)
        visionShellKeyCluster.removeFromSuperview()
        #endif
        dependencies.workspace.unregisterWindow(id: route.id)
        for tab in route.tabs {
            dependencies.workspace.closeTab(tab.id)
        }
        for controller in paneControllers.values {
            preparePaneForRemoval(controller)
            unmount(controller)
        }
        paneControllers.removeAll()
        replaceUMD(with: nil)
        replaceHelper(with: nil)
        passphrasePresenter.update(
            challenge: nil,
            onSubmit: { _, _, _ in },
            onCancel: { _ in }
        )
    }

    // MARK: Derived state

    private var store: HostStore { dependencies.store }
    private var hub: ConnectionHub { dependencies.hub }
    private var themes: ThemeStore { dependencies.themes }
    private var workspace: TerminalWorkspace { dependencies.workspace }
    private var entitlements: EntitlementStore { dependencies.entitlements }

    private var activeTab: TerminalRoute? { route.activeTab }
    private var activeController: TerminalSessionController? {
        activeTab.flatMap { workspace.controller(for: $0.id) }
    }
    private var activeTabHost: Host? {
        activeTab.flatMap { store.host(id: $0.hostID) }
    }
    private var terminalFocusAllowed: Bool {
        shell?.terminalFocusAllowed ?? true
    }
    private var contentSafeArea: UIEdgeInsets {
        shell?.contentSafeArea ?? .zero
    }
    private var railOwnsBottomSafeArea: Bool {
        shell?.railOwnsBottomSafeArea ?? false
    }
    private var showsAgentHelper: Bool {
        shownAgent != nil && activeController?.status == .live
    }
    private var terminalBottomChromeHeight: CGFloat {
        #if os(visionOS)
        0
        #else
        showsAgentHelper ? AgentHelperStripViewController.dockedHeight : 0
        #endif
    }
    private var mergeSources: [TerminalWorkspace.WindowEntry] {
        shell == nil ? workspace.mergeSources(for: route.id) : []
    }
    private var activeTabHasSession: Bool {
        guard let activeTab else { return false }
        return activeTab.sessionName != nil && store.host(id: activeTab.hostID) != nil
    }
    private var keyPassphraseChallenge: SSHKeyPassphraseChallenge? {
        let activeFirst = activeTab.map { [$0] } ?? []
        for tab in activeFirst + route.tabs.filter({ $0.id != activeTab?.id }) {
            if let challenge = workspace.controller(for: tab.id)?.keyPassphraseChallenge {
                return challenge
            }
        }
        return nil
    }
    private var activeTabKeychainNotice: KeychainLockNotice? {
        guard let activeTab,
              let sessionName = activeTab.sessionName,
              let host = store.host(id: activeTab.hostID),
              let notice = hub.model(for: host).keychainNotice,
              notice.sessionNames.contains(sessionName)
        else { return nil }
        return notice
    }
    private var detectedAgent: AgentKind? {
        guard let activeTab else { return nil }
        guard let sessionName = activeTab.sessionName else {
            return activeController?.directShellAgent
        }
        guard let host = store.host(id: activeTab.hostID) else { return nil }
        let model = hub.model(for: host)
        // A herdr tab shows the SESSION's focused pane, not its summoning
        // workspace: herdr keeps one focus per session and the full client
        // mirrors it, so switching workspaces inside the TUI must move the
        // helper strip too. Fall back to the tab's workspace record only
        // while no probe has named a focus yet.
        if host.sessionBackend == .herdr, let focused = model.herdrFocusedPaneID {
            for session in model.tmux.sessions {
                for window in session.windows {
                    if let pane = window.panes?.first(where: { $0.tmuxID == focused }) {
                        return pane.agent
                    }
                }
            }
            return nil
        }
        return model.tmux.sessions
            .first { $0.name == sessionName }?
            .activeAgent
    }
    private var resolvedTerminalTheme: TerminalTheme {
        themes.selected(for: traitCollection.userInterfaceStyle == .light ? .light : .dark)
    }

    // MARK: Observation

    private func restartObservation() {
        observationGeneration &+= 1
        observeAndRender(generation: observationGeneration)
    }

    private func observeAndRender(generation: Int) {
        guard generation == observationGeneration else { return }
        let snapshot = withObservationTracking {
            // Read every service value that changes this controller's
            // composition. Child controllers observe their own detailed
            // content; these reads only decide which native children/chrome
            // exist and what actions they expose.
            _ = store.hosts
            _ = workspace.windows
            _ = themes.appearance
            _ = resolvedTerminalTheme
            _ = entitlements.isPro
            _ = entitlements.canUseSlashChip
            _ = entitlements.canBrowseAgentHistory
            _ = activeController?.status
            _ = activeController?.keyboardObstruction
            _ = activeController?.directShellAgent
            _ = activeController?.directShellAttention
            _ = activeController?.pendingLink
            _ = activeController?.pendingPath
            _ = keyPassphraseChallenge
            _ = activeTabKeychainNotice
            #if !os(visionOS)
            _ = KeyboardLock.shared.isLocked
            #endif
            for tab in route.tabs where tab.isAuxiliaryPane {
                _ = workspace.auxiliaryController(for: tab.id)?.tabLabel
            }
            return detectedAgent
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeAndRender(generation: generation)
            }
        }
        updateShownAgent(from: snapshot)
        renderNow()
    }

    private func updateShownAgent(from agent: AgentKind?) {
        let activeID = activeTab?.id
        if lastObservedActiveTabID != activeID {
            hideAgentTask?.cancel()
            lastObservedActiveTabID = activeID
            lastDetectedAgent = agent
            shownAgent = agent
            activePaneFingerprint = nil
            return
        }
        guard lastDetectedAgent != agent else { return }
        lastDetectedAgent = agent
        hideAgentTask?.cancel()
        if let agent {
            shownAgent = agent
        } else {
            hideAgentTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(11))
                guard !Task.isCancelled else { return }
                self?.shownAgent = nil
                self?.renderNow()
            }
        }
    }

    private func renderNow() {
        guard isViewLoaded, !preparedForRemoval else { return }
        reconcilePaneControllers()
        renderTabStrip()
        renderUMD()
        renderHelper()
        #if os(visionOS)
        reconcileVisionChromeOwnership()
        updateVisionOrnaments(forceRevision: true)
        #endif
        configureNavigationChrome()
        updatePassphrasePrompt()
        #if os(visionOS)
        rootView.setTabsVisible(shell != nil && route.tabs.count > 1)
        #else
        rootView.setTabsVisible(route.tabs.count > 1)
        #endif
        rootView.setShellMode(shell != nil)
        layoutNativeChrome()
        presentPendingFeatureIfPossible()
        applyAppearanceToPresentedFeature()
    }

    // MARK: Route reconciliation

    private func syncTabs() {
        let orphanedAuxiliaries = route.tabs.filter { tab in
            tab.isAuxiliaryPane && workspace.auxiliaryController(for: tab.id) == nil
        }
        if !orphanedAuxiliaries.isEmpty {
            let ids = Set(orphanedAuxiliaries.map(\.id))
            mutateRoute { route in
                route.tabs.removeAll { ids.contains($0.id) }
                if let active = route.activeTabID, ids.contains(active) {
                    route.activeTabID = route.tabs.first?.id
                }
            }
            return
        }
        if route.tabs.isEmpty {
            workspace.unregisterWindow(id: route.id)
            if let shell {
                shell.tabsEmptied()
            } else {
                sceneWindows.closeCurrentScene()
            }
            return
        }
        for tab in route.tabs where !tab.isAuxiliaryPane {
            _ = workspace.controller(for: tab, store: store)
        }
        workspace.registerWindow(.init(
            id: route.id,
            tabs: route.tabs,
            label: windowLabel,
            reveal: { [weak self] tabID in
                guard let self else { return }
                activate(tabID)
                if let shell = self.shell {
                    shell.revealTab(tabID)
                } else {
                    self.workspace.controller(for: tabID)?.revealWindow()
                }
            },
            surrender: { [weak self] in
                guard let self else { return [] }
                let tabs = self.route.tabs
                self.mutateRoute { route in
                    route.tabs = []
                    route.activeTabID = nil
                }
                return tabs
            },
            adopt: { [weak self] tabs in
                self?.mutateRoute { $0.merge(tabs) }
            }
        ))
    }

    private func mutateRoute(_ mutation: (inout TerminalWindowRoute) -> Void) {
        let previousActive = route.activeTabID
        mutation(&route)
        routeChanged(route)
        syncTabs()
        if previousActive != route.activeTabID {
            activeTabDidChange(from: previousActive)
        } else {
            restartObservation()
        }
    }

    private func activeTabDidChange(from previousTabID: UUID?) {
        if activeTab?.isAuxiliaryPane == true {
            if let previousTabID {
                workspace.controller(for: previousTabID)?.releaseFocus()
            }
        } else {
            claimActiveTerminalFocusIfAllowed()
        }
        hideAgentTask?.cancel()
        activePaneFingerprint = nil
        lastObservedActiveTabID = nil
        shownAgent = detectedAgent
        lastDetectedAgent = detectedAgent
        restartActiveTasks()
        restartObservation()
    }

    private var windowLabel: String {
        let names = route.tabs.map(\.displayName).joined(separator: ", ")
        var seen = Set<UUID>()
        let hosts = route.tabs.compactMap { tab -> String? in
            guard seen.insert(tab.hostID).inserted else { return nil }
            return store.host(id: tab.hostID)?.name
        }
        return hosts.isEmpty ? names : "\(names) — \(hosts.joined(separator: ", "))"
    }

    func activate(_ tabID: UUID) {
        guard route.tabs.contains(where: { $0.id == tabID }) else { return }
        mutateRoute { $0.activate(tabID) }
    }

    func closeTab(_ tabID: UUID) {
        if shell != nil { workspace.controller(for: tabID)?.releaseFocus() }
        workspace.closeTab(tabID)
        mutateRoute { $0.removeTab(id: tabID) }
    }

    func splitTab(_ tabID: UUID) {
        guard shell == nil, route.tabs.count > 1 else { return }
        var splitTab: TerminalRoute?
        mutateRoute { splitTab = $0.removeTab(id: tabID) }
        if let splitTab {
            sceneWindows.openTerminal(TerminalWindowRoute(tab: splitTab))
        }
    }

    private func merge(_ windowID: UUID) {
        mutateRoute { $0.merge(workspace.surrenderTabs(of: windowID)) }
    }

    private func detachActiveTab() {
        guard let activeTab else { return }
        closeTab(activeTab.id)
    }

    private func confirmCloseActiveSession() {
        guard let activeTab,
              let sessionName = activeTab.sessionName,
              let host = store.host(id: activeTab.hostID)
        else { return }
        let alert = UIAlertController(
            title: "Close Session",
            message: "Kills “\(sessionName)” on \(host.name) and everything running in it, then closes the tab.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Close Session", style: .destructive) { [weak self] _ in
            self?.closeSession(activeTab)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func closeSession(_ tab: TerminalRoute) {
        guard let sessionName = tab.sessionName,
              let host = store.host(id: tab.hostID)
        else { return }
        let model = hub.model(for: host)
        Task { await model.killSession(named: sessionName) }
        closeTab(tab.id)
    }

    // MARK: New and auxiliary tabs

    func openNewTab(launching agent: AgentKind?) {
        guard !creatingTab,
              let activeTab,
              let host = store.host(id: activeTab.hostID)
        else { return }
        creatingTab = true
        let source = activeTab.sessionName
        let preferences = NewSessionPreferences()
        let script = preferences.rememberedScript(for: host)
        Task { [weak self] in
            guard let self else { return }
            defer { creatingTab = false }
            guard let created = await hub.model(for: host).createSession(
                base: agent?.launchCommand ?? source ?? "main",
                inDirectoryOf: source,
                applying: host.newSessionTmuxConf,
                running: script?.normalizedBody,
                typing: agent.map {
                    $0.launchCommand(
                        model: preferences.rememberedModel(for: $0),
                        initialPrompt: ""
                    )
                }
            ) else {
                presentNewTabFailure(hostName: host.name)
                return
            }
            let tab = TerminalRoute(hostID: host.id, mode: created)
            mutateRoute { route in
                route.tabs.append(tab)
                route.activate(tab.id)
            }
        }
    }

    private func presentNewTabFailure(hostName: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "Couldn't Create Session",
            message: "Check the connection to \(hostName) and try again.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    func openFileViewer(target: TerminalPathTarget?) {
        guard let activeTab, let host = store.host(id: activeTab.hostID) else { return }
        let anchorID = activeTab.id
        let hostID = activeTab.hostID
        let anchorSessionName = activeTab.sessionName
        Task { [weak self] in
            guard let self else { return }
            let cwd = await workspace.controller(for: anchorID)?.paneWorkingDirectory()
            let tab = TerminalRoute(
                hostID: hostID,
                mode: .fileViewer(path: target?.path ?? cwd ?? "~")
            )
            workspace.openFileViewer(
                tab: tab,
                host: host,
                startDirectory: cwd,
                anchorSessionName: anchorSessionName,
                target: target
            )
            dock(tab, after: anchorID)
        }
    }

    func openViewport(_ offer: ViewportOffer) {
        guard let activeTab, let host = store.host(id: activeTab.hostID) else { return }
        let tab = TerminalRoute(
            hostID: activeTab.hostID,
            mode: .viewport(urlString: offer.url.absoluteString)
        )
        workspace.openViewport(tab: tab, offer: offer, host: host)
        dock(tab, after: activeTab.id)
    }

    /// The Gallery's TERMINAL chip (and any future in-window herdr door):
    /// register-then-dock for auxiliary modes, plain dock for terminals.
    func openTab(_ tab: TerminalRoute) {
        if tab.isAgentGallery, let host = store.host(id: tab.hostID) {
            workspace.openAgentGallery(tab: tab, host: host)
        }
        let anchorID = activeTab?.id ?? tab.id
        dock(tab, after: anchorID)
    }

    private func dock(_ tab: TerminalRoute, after anchorID: UUID) {
        mutateRoute { route in
            if let index = route.tabs.firstIndex(where: { $0.id == anchorID }) {
                route.tabs.insert(tab, at: index + 1)
            } else {
                route.tabs.append(tab)
            }
            route.activate(tab.id)
        }
    }

    // MARK: Focus and probes

    /// Keyboard focus follows the visible tab whatever its transport is
    /// doing. Claiming is what resigns the tab that just went off screen, so
    /// gating this on `.live` would leave a hidden live session first
    /// responder while a connecting/ended pane is on screen — every keystroke
    /// would land invisibly in the session behind it.
    private func claimActiveTerminalFocusIfAllowed() {
        guard terminalFocusAllowed,
              activeTab?.isAuxiliaryPane != true
        else { return }
        activeController?.focusTerminal()
    }

    /// Appearance and scene activation are not user focus requests. Several
    /// Stage Manager / visionOS scenes foreground together, so each surface
    /// may only reassert the app-wide owner selected before suspension.
    private func restoreActiveTerminalFocusIfOwner() {
        guard activeTab?.isAuxiliaryPane != true else { return }
        Self.restoreFocusAfterSurfaceAppearance(
            activeController,
            allowed: terminalFocusAllowed
        )
    }

    /// Named seam for the UIKit focus contract and its two-window test.
    static func restoreFocusAfterSurfaceAppearance(
        _ controller: TerminalSessionController?,
        allowed: Bool
    ) {
        controller?.restoreFocusIfOwner(allowed: allowed)
    }

    private func restartActiveTasks() {
        hostProbeTask?.cancel()
        activePaneTask?.cancel()
        hostProbeTask = Task { [weak self] in await self?.keepHostProbeWarm() }
        activePaneTask = Task { [weak self] in await self?.watchActivePane() }
    }

    private func keepHostProbeWarm() async {
        #if DEBUG
        AgentChipDebugHook.install()
        NewTabDebugHook.install()
        MessageJumpDebugHook.install()
        TerminalLinkDebugHook.install()
        FileViewerDebugHook.install()
        #endif
        guard let hostID = activeTab?.hostID,
              let host = store.host(id: hostID)
        else { return }
        let model = hub.model(for: host)
        while !Task.isCancelled {
            if UIApplication.shared.applicationState == .active {
                entitlements.refreshSlashChipMeter()
                await model.refreshAndWait(ifStaleFor: 4)
            }
            try? await Task.sleep(for: Self.hostProbeInterval)
        }
    }

    private func watchActivePane() async {
        guard let watchedTab = activeTab,
              !watchedTab.isAuxiliaryPane,
              let host = store.host(id: watchedTab.hostID)
        else {
            activePaneFingerprint = nil
            shownAgent = nil
            renderNow()
            return
        }
        guard let sessionName = watchedTab.sessionName else {
            activePaneFingerprint = nil
            let initialAgent = activeController?.directShellAgent
            if shownAgent != initialAgent {
                shownAgent = initialAgent
                renderNow()
            }
            while !Task.isCancelled {
                if UIApplication.shared.applicationState == .active,
                   let controller = activeController,
                   let view = controller.terminalView,
                   TerminalFocusArbiter.current === view {
                    await controller.refreshDirectShellAgent(ifStaleFor: 0.8)
                    guard !Task.isCancelled,
                          activeTab?.id == watchedTab.id
                    else { return }
                    let nextAgent = controller.directShellAgent
                    if shownAgent != nextAgent {
                        hideAgentTask?.cancel()
                        shownAgent = nextAgent
                        renderNow()
                    }
                }
                try? await Task.sleep(for: Self.focusedPaneProbeInterval)
            }
            return
        }

        let model = hub.model(for: host)
        let initialAgent = detectedAgent
        let agentChanged = shownAgent != initialAgent
        shownAgent = initialAgent
        activePaneFingerprint = model.tmux.sessions
            .first(where: { $0.name == sessionName })?
            .activeWindow?
            .activePane?
            .processFingerprint
        if agentChanged { renderNow() }
        await model.refreshAndWait(ifStaleFor: 4)

        if host.sessionBackend == .herdr {
            // No list-panes fast path in herdr mode; the probe's snapshot is
            // the authority and `detectedAgent` follows the session's live
            // focused pane — re-read it each interval so a workspace switch
            // inside the TUI moves the strip within a probe tick.
            while !Task.isCancelled {
                guard activeTab?.id == watchedTab.id else { return }
                let nextAgent = detectedAgent
                if shownAgent != nextAgent {
                    hideAgentTask?.cancel()
                    shownAgent = nextAgent
                    renderNow()
                }
                try? await Task.sleep(for: Self.focusedPaneProbeInterval)
            }
            return
        }

        while !Task.isCancelled {
            if UIApplication.shared.applicationState == .active,
               let view = activeController?.terminalView,
               TerminalFocusArbiter.current === view {
                let detection = await model.detectActiveAgent(in: sessionName)
                guard !Task.isCancelled, activeTab?.id == watchedTab.id else { return }
                if let detection { apply(detection) }
            }
            try? await Task.sleep(for: Self.focusedPaneProbeInterval)
        }
    }

    private func apply(_ detection: ActivePaneAgentDetection) {
        let changedPane = activePaneFingerprint != detection.fingerprint
        let previousAgent = shownAgent
        activePaneFingerprint = detection.fingerprint
        hideAgentTask?.cancel()
        if let agent = detection.agent {
            shownAgent = agent
        } else if changedPane || detection.isDefinitive {
            shownAgent = nil
        }
        if previousAgent != shownAgent { renderNow() }
    }

    private func send(
        _ command: AgentCommand,
        via controller: TerminalSessionController
    ) {
        guard !command.consumesSlashChipTaste || entitlements.consumeSlashChip()
        else { return }
        controller.sendInput(command.payload)
        guard command.submitsAfterPause else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            controller.sendInput(Data([0x0D]))
        }
    }

    // MARK: Lifecycle

    private func configureLifecycleObservers() {
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self,
                      note.object as? UIScene === viewIfLoaded?.window?.windowScene
                else { return }
                Task { await self.store.refreshFromCloud() }
                self.entitlements.refreshSlashChipMeter()
                self.restoreActiveTerminalFocusIfOwner()
                for tab in self.route.tabs {
                    self.workspace.controller(for: tab.id)?.transportForegrounded()
                }
            }
        })
    }

    private func configurePassphrasePresenter() {
        addChild(passphrasePresenter)
        rootView.addSubview(passphrasePresenter.view)
        passphrasePresenter.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            passphrasePresenter.view.widthAnchor.constraint(equalToConstant: 0),
            passphrasePresenter.view.heightAnchor.constraint(equalToConstant: 0),
            passphrasePresenter.view.topAnchor.constraint(equalTo: rootView.topAnchor),
            passphrasePresenter.view.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
        ])
        passphrasePresenter.didMove(toParent: self)
    }

    private func updatePassphrasePrompt() {
        passphrasePresenter.update(
            challenge: keyPassphraseChallenge,
            onSubmit: { [weak self] challenge, passphrase, save in
                self?.acceptKeyPassphrase(
                    challenge,
                    passphrase: passphrase,
                    saveToICloud: save
                )
            },
            onCancel: { _ in }
        )
    }

    private func acceptKeyPassphrase(
        _ challenge: SSHKeyPassphraseChallenge,
        passphrase: String,
        saveToICloud: Bool
    ) {
        SSHKeyPassphraseSession.accept(
            passphrase,
            for: challenge.hostID,
            saveToICloud: saveToICloud
        )
        hub.resumeConnectionsWaitingForKeyPassphrase(hostID: challenge.hostID)
        workspace.resumeConnectionsWaitingForKeyPassphrase(hostID: challenge.hostID)
    }
}

// MARK: - Native child composition

extension TerminalWindowViewController {
    private func reconcilePaneControllers() {
        let liveIDs = Set(route.tabs.map(\.id))
        let removedIDs = paneControllers.keys.filter { !liveIDs.contains($0) }
        for id in removedIDs {
            guard let controller = paneControllers.removeValue(forKey: id) else {
                continue
            }
            preparePaneForRemoval(controller)
            unmount(controller)
        }

        for tab in route.tabs {
            let isActive = tab.id == activeTab?.id
            let pane = paneControllers[tab.id] ?? makePaneController(for: tab)
            guard let pane else { continue }
            if paneControllers[tab.id] == nil {
                paneControllers[tab.id] = pane
                addChild(pane)
                rootView.paneContainer.addSubview(pane.view)
                pane.didMove(toParent: self)
            }
            pane.view.frame = rootView.paneContainer.bounds
            pane.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            pane.view.isHidden = !isActive
            pane.view.isUserInteractionEnabled = isActive
            pane.view.accessibilityElementsHidden = !isActive
            updatePaneController(pane, for: tab, isActive: isActive)
        }
    }

    private func makePaneController(for tab: TerminalRoute) -> UIViewController? {
        if tab.isViewport {
            guard let viewport = workspace.viewportController(for: tab.id) else { return nil }
            return ViewportPaneViewController(
                controller: viewport,
                contentSafeArea: contentSafeArea,
                close: { [weak self] in self?.closeTab(tab.id) }
            )
        }
        if tab.isFileViewer {
            guard let fileViewer = workspace.fileViewerController(for: tab.id) else { return nil }
            return FileViewerPaneViewController(
                controller: fileViewer,
                contentSafeArea: contentSafeArea,
                isActive: tab.id == activeTab?.id,
                close: { [weak self] in self?.closeTab(tab.id) }
            )
        }
        if tab.isAgentGallery {
            guard let gallery = workspace.agentGalleryController(for: tab.id) else { return nil }
            return AgentGalleryPaneViewController(
                controller: gallery,
                model: hub.model(for: gallery.host),
                contentSafeArea: contentSafeArea,
                isActive: tab.id == activeTab?.id,
                close: { [weak self] in self?.closeTab(tab.id) },
                openTerminal: { [weak self] mode in
                    self?.openTab(TerminalRoute(hostID: tab.hostID, mode: mode))
                }
            )
        }
        return TerminalPaneViewController(configuration: paneConfiguration(
            for: tab,
            isActive: tab.id == activeTab?.id
        ))
    }

    private func updatePaneController(
        _ pane: UIViewController,
        for tab: TerminalRoute,
        isActive: Bool
    ) {
        if let terminal = pane as? TerminalPaneViewController {
            terminal.update(configuration: paneConfiguration(for: tab, isActive: isActive))
        } else if let viewport = pane as? ViewportPaneViewController {
            viewport.update(
                contentSafeArea: contentSafeArea,
                close: { [weak self] in self?.closeTab(tab.id) }
            )
        } else if let fileViewer = pane as? FileViewerPaneViewController {
            fileViewer.update(
                contentSafeArea: contentSafeArea,
                isActive: isActive,
                close: { [weak self] in self?.closeTab(tab.id) }
            )
        } else if let gallery = pane as? AgentGalleryPaneViewController {
            gallery.update(
                contentSafeArea: contentSafeArea,
                isActive: isActive,
                close: { [weak self] in self?.closeTab(tab.id) },
                openTerminal: { [weak self] mode in
                    self?.openTab(TerminalRoute(hostID: tab.hostID, mode: mode))
                }
            )
        }
    }

    private func paneConfiguration(
        for tab: TerminalRoute,
        isActive: Bool
    ) -> TerminalPaneConfiguration {
        TerminalPaneConfiguration(
            controller: workspace.controller(for: tab.id),
            hostExists: store.host(id: tab.hostID) != nil,
            fontSize: fontSize,
            theme: resolvedTerminalTheme,
            bottomChromeHeight: terminalBottomChromeHeight,
            contentSafeArea: contentSafeArea,
            railOwnsBottomSafeArea: railOwnsBottomSafeArea,
            isActive: isActive,
            focusAllowed: terminalFocusAllowed,
            close: { [weak self] in self?.closeTab(tab.id) }
        )
    }

    private func preparePaneForRemoval(_ pane: UIViewController) {
        (pane as? TerminalPaneViewController)?.prepareForRemoval()
        (pane as? ViewportPaneViewController)?.prepareForRemoval()
        (pane as? FileViewerPaneViewController)?.prepareForRemoval()
        (pane as? AgentGalleryPaneViewController)?.prepareForRemoval()
    }

    private func unmount(_ controller: UIViewController) {
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    private func renderTabStrip() {
        tabStrip.apply(
            items: tabItems,
            allowsSplit: shell == nil,
            activate: { [weak self] in self?.activate($0) },
            split: { [weak self] in self?.splitTab($0) },
            close: { [weak self] in self?.closeTab($0) }
        )
        #if os(visionOS)
        guard shell != nil else {
            visionOrnaments.state.topHostView.refreshFittingSize()
            return
        }
        #endif
        if tabStrip.superview !== rootView.tabScrollView {
            tabStrip.removeFromSuperview()
            rootView.tabScrollView.addSubview(tabStrip)
        }
        // Geometry belongs to `layoutNativeChrome`, which measures the strip
        // on every layout pass anyway: sizing it only here left a pass that
        // changed the fitting size without a render with a stale strip width
        // — cells compressed into each other, and the overflow past that
        // width stopped hit-testing entirely.
        rootView.setNeedsLayout()
    }

    private var tabItems: [TerminalTabStrip.Item] {
        let multiHost = Set(route.tabs.map(\.hostID)).count > 1
        return route.tabs.map { tab in
            TerminalTabStrip.Item(
                id: tab.id,
                title: tabTitle(for: tab),
                hostName: multiHost ? store.host(id: tab.hostID)?.name : nil,
                controller: workspace.controller(for: tab.id),
                isActive: tab.id == activeTab?.id,
                isAuxiliary: tab.isAuxiliaryPane
            )
        }
    }

    private func tabTitle(for tab: TerminalRoute) -> String {
        if tab.isAuxiliaryPane,
           let auxiliary = workspace.auxiliaryController(for: tab.id) {
            return auxiliary.tabLabel
        }
        return tab.displayName
    }

    private var windowTitle: String {
        guard let activeTab else { return "Terminal" }
        let hostName = store.host(id: activeTab.hostID)?.name
        let title = tabTitle(for: activeTab)
        return hostName.map { "\(title) — \($0)" } ?? title
    }

    private var umdTitle: String {
        guard let activeTab else { return windowTitle }
        let hostName = store.host(id: activeTab.hostID)?.name
        let title = tabTitle(for: activeTab)
        return hostName.map { "\(title) · \($0)" } ?? title
    }

    private var auxiliaryCloseLabel: String {
        if activeTab?.isFileViewer == true { return "Close file viewer" }
        if activeTab?.isAgentGallery == true { return "Close agent gallery" }
        return "Close viewport"
    }

    private func renderUMD() {
        #if os(visionOS)
        let needsUMD = true
        #else
        let needsUMD = shell != nil
        #endif
        guard needsUMD else {
            replaceUMD(with: nil)
            return
        }

        if activeTab?.isAuxiliaryPane == true {
            let configuration = ViewportUMDConfiguration(
                title: umdTitle,
                mergeSources: mergeSources,
                showDeck: { [weak self] in self?.showDeck() },
                merge: { [weak self] in self?.merge($0) },
                close: { [weak self] in
                    guard let id = self?.activeTab?.id else { return }
                    self?.closeTab(id)
                },
                style: shell == nil ? .regular : .shell,
                deckControlLabel: shell?.deckControlLabel ?? "DECK",
                contentSafeArea: contentSafeArea,
                closeAccessibilityLabel: auxiliaryCloseLabel
            )
            if let controller = umdController as? ViewportUMDViewController {
                controller.update(configuration: configuration)
            } else {
                replaceUMD(with: ViewportUMDViewController(configuration: configuration))
            }
            return
        }

        let configuration = UMDBarConfiguration(
            controller: activeController,
            title: umdTitle,
            mergeSources: mergeSources,
            showDeck: { [weak self] in self?.showDeck() },
            fontDown: { [weak self] in self?.changeFont(by: -1) },
            fontUp: { [weak self] in self?.changeFont(by: 1) },
            newSession: { [weak self] in self?.openNewTab(launching: $0) },
            openFileViewer: { [weak self] in self?.openFileViewer(target: nil) },
            merge: { [weak self] in self?.merge($0) },
            detach: { [weak self] in self?.detachActiveTab() },
            closeSession: activeTabHasSession
                ? { [weak self] in self?.confirmCloseActiveSession() } : nil,
            keychainTip: activeTabKeychainNotice != nil
                ? { [weak self] in self?.presentKeychainTip() } : nil,
            showsTmuxShortcuts: activeTab?.usesTmux == true,
            style: shell == nil ? .regular : .shell,
            deckControlLabel: shell?.deckControlLabel ?? "DECK",
            availableWidth: shell?.availableWidth,
            contentSafeArea: contentSafeArea
        )
        if let controller = umdController as? UMDBarViewController {
            controller.update(configuration: configuration)
        } else {
            replaceUMD(with: UMDBarViewController(configuration: configuration))
        }
    }

    private func replaceUMD(with replacement: UIViewController?) {
        guard umdController !== replacement else { return }
        if let existing = umdController {
            (existing as? UMDBarViewController)?.prepareForRemoval()
            #if os(visionOS)
            if shell != nil { unmount(existing) }
            #else
            unmount(existing)
            #endif
        }
        umdController = replacement
        guard let replacement else { return }
        #if os(visionOS)
        guard shell != nil else { return }
        #endif
        addChild(replacement)
        rootView.umdContainer.addSubview(replacement.view)
        replacement.view.frame = rootView.umdContainer.bounds
        replacement.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        replacement.didMove(toParent: self)
    }

    private func renderHelper() {
        guard let activeTab,
              let agent = shownAgent,
              let controller = activeController,
              controller.status == .live
        else {
            replaceHelper(with: nil)
            return
        }
        let commandConfiguration = store.agentCommandConfiguration(for: activeTab.hostID)
        let configuration = AgentHelperStripConfiguration(
            agent: agent,
            canShowCommands: entitlements.isPro || entitlements.canUseSlashChip,
            builtInPlacements: commandConfiguration.builtInPlacements(for: agent),
            customCommands: commandConfiguration.commands(for: agent),
            historyController: controller,
            historyLocked: !entitlements.canBrowseAgentHistory,
            floating: {
                #if os(visionOS)
                true
                #else
                false
                #endif
            }(),
            floatingMaximumWidth: {
                #if os(visionOS)
                visionFloatingHelperMaximumWidth
                #else
                nil
                #endif
            }(),
            contentSafeArea: {
                #if os(visionOS)
                .zero
                #else
                contentSafeArea
                #endif
            }(),
            send: { [weak self, weak controller] command in
                guard let self, let controller else { return }
                send(command, via: controller)
            },
            saveCommandConfiguration: { [weak self] commands, placements in
                self?.store.replaceAgentCommandConfiguration(
                    commands,
                    builtInPlacements: placements,
                    for: agent,
                    hostID: activeTab.hostID
                )
            },
            openPaywall: { [weak self] in self?.presentPaywall() },
            isFocusOwner: { [weak controller] in
                guard let terminalView = controller?.terminalView else { return false }
                return TerminalFocusArbiter.current === terminalView
            }
        )
        if let helperController,
           Self.canReuseAgentHelper(
               currentHostID: helperHostID,
               nextHostID: activeTab.hostID
           ) {
            helperController.update(configuration: configuration)
        } else {
            replaceHelper(with: AgentHelperStripViewController(configuration: configuration))
            helperHostID = activeTab.hostID
        }
    }

    static func canReuseAgentHelper(
        currentHostID: UUID?,
        nextHostID: UUID
    ) -> Bool {
        currentHostID == nextHostID
    }

    private func replaceHelper(with replacement: AgentHelperStripViewController?) {
        guard helperController !== replacement else { return }
        if let helperController {
            helperController.prepareForRemoval()
            #if os(visionOS)
            if shell != nil { unmount(helperController) }
            #else
            unmount(helperController)
            #endif
        }
        helperController = replacement
        helperHostID = nil
        guard let replacement else { return }
        #if os(visionOS)
        guard shell != nil else { return }
        #endif
        addChild(replacement)
        rootView.helperContainer.addSubview(replacement.view)
        replacement.didMove(toParent: self)
    }

    private func changeFont(by delta: CGFloat) {
        fontSize = min(32, max(9, fontSize + delta))
        renderNow()
    }

    private func showDeck() {
        if let shell {
            shell.showDeck()
        } else {
            sceneWindows.openDeck()
        }
    }
}

// MARK: - Layout and classic iPad navigation chrome

extension TerminalWindowViewController {
    #if os(visionOS)
    private func updateVisionOrnamentInstallation() {
        if shell == nil && !appLocked {
            visionOrnaments.install(on: self)
        } else {
            visionOrnaments.remove()
        }
    }

    private func updateVisionOrnaments(forceRevision: Bool = false) {
        guard shell == nil, !appLocked else { return }
        visionOrnaments.update(
            tabCount: route.tabs.count,
            isAuxiliary: activeTab?.isAuxiliaryPane == true,
            activeTerminalController: activeController,
            umdController: umdController,
            helperController: helperController,
            windowWidth: rootView.bounds.width,
            forceRevision: forceRevision
        )
    }

    private var visionFloatingHelperMaximumWidth: CGFloat {
        if let shell {
            return max(1, shell.availableWidth - 24)
        }
        return min(
            AgentHelperStripViewController.maximumFloatingWidth,
            max(
                1,
                rootView.bounds.width
                    - AgentHelperStripViewController.floatingEdgeClearance * 2
            )
        )
    }

    private func refreshVisionHelperWidthIfNeeded() {
        guard let helperController,
              helperController.configuration.floatingMaximumWidth
                != visionFloatingHelperMaximumWidth
        else { return }
        renderHelper()
    }

    /// A route never changes classic/shell ownership in production on
    /// visionOS, but keeping the transfer exact makes controller updates and
    /// focused tests safe. A dismantling ornament may still hold a stale
    /// reference; its host only detaches children it still owns.
    private func reconcileVisionChromeOwnership() {
        guard shell != nil else {
            updateVisionShellKeyCluster()
            return
        }
        mountVisionShellChrome(umdController, in: rootView.umdContainer)
        mountVisionShellChrome(helperController, in: rootView.helperContainer)
        updateVisionShellKeyCluster()
    }

    private func updateVisionShellKeyCluster() {
        let visible = shell != nil
            && !appLocked
            && activeTab?.isAuxiliaryPane != true
        guard visible else {
            visionShellKeyCluster.update(controller: nil)
            visionShellKeyCluster.removeFromSuperview()
            return
        }
        if visionShellKeyCluster.superview !== rootView {
            visionShellKeyCluster.removeFromSuperview()
            rootView.addSubview(visionShellKeyCluster)
        }
        visionShellKeyCluster.update(controller: activeController)
        visionShellKeyCluster.isHidden = false
    }

    private func mountVisionShellChrome(
        _ controller: UIViewController?,
        in container: UIView
    ) {
        guard let controller else { return }
        if controller.parent !== self {
            if controller.parent != nil {
                controller.willMove(toParent: nil)
                controller.view.removeFromSuperview()
                controller.removeFromParent()
            }
            addChild(controller)
            container.addSubview(controller.view)
            controller.didMove(toParent: self)
        } else if controller.view.superview !== container {
            controller.view.removeFromSuperview()
            container.addSubview(controller.view)
        }
        controller.view.frame = container.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    var visionOrnamentPresentationForTesting: TerminalVisionOrnamentPresentation {
        visionOrnaments.state.presentation
    }

    var visionOrnamentTabStripForTesting: TerminalTabStripView {
        tabStrip
    }

    var visionOrnamentRevisionForTesting: Int {
        visionOrnaments.state.revision
    }

    var visionShellKeyClusterForTesting: TerminalKeyClusterGroupView {
        visionShellKeyCluster
    }
    #endif

    private func layoutNativeChrome() {
        guard isViewLoaded else { return }
        let bounds = rootView.bounds
        #if os(visionOS)
        if shell == nil {
            refreshVisionHelperWidthIfNeeded()
            rootView.paneContainer.frame = bounds
            rootView.tabScrollView.frame = .zero
            rootView.umdContainer.frame = .zero
            rootView.helperContainer.frame = .zero
            rootView.helperContainer.isHidden = true
            for pane in paneControllers.values {
                pane.view.frame = rootView.paneContainer.bounds
            }
            updateVisionOrnaments()
            return
        }
        #endif
        // SwiftUI's classic NavigationStack proposed only the safe-area
        // height to its terminal VStack. A native child controller receives
        // the navigation controller's full bounds instead, so pinning the
        // pane to `bounds.maxY` puts the app-owned key rail under iPadOS's
        // home/Stage Manager resize region. Shell stages already reserve or
        // deliberately spend that strip themselves; only classic windows
        // consume the local bottom safe area here.
        let contentBounds = TerminalWindowUIKitRootView.contentBounds(
            in: bounds,
            reservesBottomSafeArea: shell == nil,
            safeAreaInsets: rootView.safeAreaInsets
        )
        let tabsFitting = tabStrip.fittingContentSize()
        let tabsHeight: CGFloat = route.tabs.count > 1
            ? tabsFitting.height
                + TerminalWindowUIKitRootView.tabRailVerticalInset * 2
            : 0
        let umdHeight: CGFloat = {
            guard let umdController else { return 0 }
            if let controller = umdController as? UMDBarViewController {
                return controller.fittingContentSize(
                    for: shell?.availableWidth ?? bounds.width
                ).height
            }
            return umdController.view.systemLayoutSizeFitting(
                CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        }()

        if shell != nil {
            rootView.umdContainer.frame = CGRect(
                x: 0, y: 0, width: bounds.width, height: umdHeight
            )
            rootView.tabScrollView.frame = CGRect(
                x: 0, y: umdHeight, width: bounds.width, height: tabsHeight
            )
            rootView.paneContainer.frame = CGRect(
                x: 0,
                y: umdHeight + tabsHeight,
                width: contentBounds.width,
                height: max(0, contentBounds.height - umdHeight - tabsHeight)
            )
        } else {
            // The classic window is the one plan hosted inside a
            // UINavigationController, and a native child controller receives
            // the navigation controller's FULL bounds — the translucent bar
            // overlays the top band. Spend the top safe area here exactly
            // like the bottom is spent below, or the tab rail lays out
            // entirely under the bar (user-reported as "tab system gone")
            // and the pane's first text row slides beneath it.
            let topInset = rootView.safeAreaInsets.top
            rootView.tabScrollView.frame = CGRect(
                x: 0, y: topInset, width: contentBounds.width, height: tabsHeight
            )
            rootView.paneContainer.frame = CGRect(
                x: 0,
                y: topInset + tabsHeight,
                width: contentBounds.width,
                height: max(0, contentBounds.height - topInset - tabsHeight)
            )
            rootView.umdContainer.frame = .zero
        }
        // One measurement per pass owns the rail's height, the strip's frame,
        // and the scroller's content size together, so they can never disagree
        // about how wide the tabs are.
        if tabStrip.superview === rootView.tabScrollView {
            let verticalInset = TerminalWindowUIKitRootView.tabRailVerticalInset
            tabStrip.frame = CGRect(
                x: TerminalWindowUIKitRootView.tabRailHorizontalInset,
                y: verticalInset,
                width: max(tabsFitting.width, 1),
                height: tabsFitting.height
            )
            rootView.tabScrollView.contentSize = CGSize(
                width: tabStrip.frame.maxX
                    + TerminalWindowUIKitRootView.tabRailHorizontalInset,
                height: tabsFitting.height + verticalInset * 2
            )
        }
        rootView.setBottomSafeAreaBackfill(
            frame: CGRect(
                x: contentBounds.minX,
                y: contentBounds.maxY,
                width: contentBounds.width,
                height: max(0, bounds.maxY - contentBounds.maxY)
            ),
            fill: TerminalWindowBottomSafeAreaFill.resolve(
                isClassic: shell == nil,
                activeTab: activeTab,
                hasActiveTerminalController: activeController != nil
            )
        )
        umdController?.view.frame = rootView.umdContainer.bounds

        if let helperController {
            #if !os(visionOS)
            let obstruction = activeController?.keyboardObstruction ?? 0
            rootView.helperContainer.frame = CGRect(
                x: 0,
                y: max(
                    rootView.paneContainer.frame.minY,
                    rootView.paneContainer.frame.maxY
                        - obstruction
                        - TerminalKeyBar.barHeight
                        - AgentHelperStripViewController.dockedHeight
                ),
                width: bounds.width,
                height: AgentHelperStripViewController.dockedHeight
            )
            #else
            if shell != nil,
               !appLocked,
               activeTab?.isAuxiliaryPane != true,
               visionShellKeyCluster.superview === rootView {
                let available = max(
                    1,
                    min(
                        shell?.availableWidth ?? rootView.paneContainer.bounds.width,
                        rootView.paneContainer.bounds.width
                    ) - 24
                )
                let keySize = visionShellKeyCluster.fittingSize(
                    maximumWidth: available
                )
                visionShellKeyCluster.frame = CGRect(
                    x: rootView.paneContainer.frame.midX - keySize.width / 2,
                    y: rootView.paneContainer.frame.maxY - 10 - keySize.height,
                    width: keySize.width,
                    height: keySize.height
                )
                let measured = helperController.fittingContentSize(
                    for: available
                )
                let helperSize = CGSize(
                    width: min(available, measured.width),
                    height: measured.height
                )
                rootView.helperContainer.frame = CGRect(
                    x: rootView.paneContainer.frame.midX - helperSize.width / 2,
                    y: visionShellKeyCluster.frame.minY - 8 - helperSize.height,
                    width: helperSize.width,
                    height: helperSize.height
                )
            } else {
                rootView.helperContainer.frame = .zero
            }
            #endif
            helperController.view.frame = rootView.helperContainer.bounds
            rootView.helperContainer.isHidden = false
        } else {
            rootView.helperContainer.frame = .zero
            rootView.helperContainer.isHidden = true
        }
        #if os(visionOS)
        if shell != nil,
           !appLocked,
           activeTab?.isAuxiliaryPane != true,
           visionShellKeyCluster.superview === rootView,
           helperController == nil {
            let available = max(
                1,
                min(
                    shell?.availableWidth ?? rootView.paneContainer.bounds.width,
                    rootView.paneContainer.bounds.width
                ) - 24
            )
            let keySize = visionShellKeyCluster.fittingSize(
                maximumWidth: available
            )
            visionShellKeyCluster.frame = CGRect(
                x: rootView.paneContainer.frame.midX - keySize.width / 2,
                y: rootView.paneContainer.frame.maxY - 10 - keySize.height,
                width: keySize.width,
                height: keySize.height
            )
        } else if visionShellKeyCluster.superview == nil {
            visionShellKeyCluster.frame = .zero
        }
        #endif
        for pane in paneControllers.values {
            pane.view.frame = rootView.paneContainer.bounds
        }
    }

    private func configureNavigationChrome(
        compactAttachmentAvailabilityOverride: FileAttachMenuAvailability? = nil
    ) {
        #if !os(visionOS)
        let compactAttachmentAvailability: FileAttachMenuAvailability? = {
            guard shell == nil,
                  traitCollection.horizontalSizeClass == .compact,
                  activeTab?.isAuxiliaryPane != true
            else { return nil }
            return compactAttachmentAvailabilityOverride
                ?? FileAttachMenuAvailability(controller: activeController)
        }()
        let key = TerminalWindowNavigationChromeKey(
            usesShell: shell != nil,
            windowTitle: windowTitle,
            horizontalSizeClass: traitCollection.horizontalSizeClass,
            activeControllerID: activeController.map(ObjectIdentifier.init),
            usesMosh: activeController?.host.useMosh == true,
            needsYou: {
                if case .needsYou = activeController?.directShellAttention { return true }
                return false
            }(),
            hasKeychainNotice: activeTabKeychainNotice != nil,
            activeIsAuxiliary: activeTab?.isAuxiliaryPane == true,
            auxiliaryCloseLabel: auxiliaryCloseLabel,
            mergeSources: mergeSources.map {
                TerminalWindowMergeSourceKey(id: $0.id, label: $0.label)
            },
            activeTabHasSession: activeTabHasSession,
            keyboardLocked: KeyboardLock.shared.isLocked,
            compactAttachmentAvailability: compactAttachmentAvailability
        )
        guard renderedNavigationChromeKey != key else { return }
        renderedNavigationChromeKey = key
        fileAttachController?.parkAttachButton()
        guard isViewLoaded, shell == nil else {
            navigationItem.leftBarButtonItems = nil
            navigationItem.rightBarButtonItems = nil
            return
        }
        title = windowTitle
        navigationItem.largeTitleDisplayMode = .never
        if let navigationBar = navigationController?.navigationBar {
            UIKitChassis.configureSheetNavigationBar(navigationBar)
        }

        let deck = makeButton(
            caption: "DECK",
            systemImage: "square.grid.2x2",
            accessibilityLabel: "Show Deck",
            action: { [weak self] in self?.showDeck() }
        )
        navigationItem.leftBarButtonItem = makeNavigationBarItem(customView: deck)

        var trailing: [UIBarButtonItem] = []
        if activeController?.host.useMosh == true {
            let badge = makeButton(
                caption: "MOSH",
                accessibilityLabel: "Connects over mosh",
                action: {}
            )
            badge.isUserInteractionEnabled = false
            trailing.append(makeNavigationBarItem(customView: badge))
        }
        if case .needsYou = activeController?.directShellAttention {
            trailing.append(makeNavigationBarItem(customView: UIKitTallyLamp(
                caption: "NEEDS YOU",
                color: TallyPalette.caution
            )))
        }
        if activeTabKeychainNotice != nil {
            let keychain = makeButton(
                caption: "KEYCHAIN LOCKED",
                accessibilityLabel: "The Mac's keychain is locked, so Claude Code shows signed out",
                action: { [weak self] in self?.presentKeychainTip() }
            )
            keychain.accessibilityHint = "Shows how to unlock the keychain"
            trailing.append(makeNavigationBarItem(customView: keychain))
        }

        if activeTab?.isAuxiliaryPane == true {
            if !mergeSources.isEmpty {
                trailing.append(makeNavigationBarItem(customView: makeMenuButton(
                    caption: "MERGE",
                    accessibilityLabel: "Merge another window into this one",
                    menu: makeMergeMenu()
                )))
            }
            trailing.append(makeNavigationBarItem(
                customView: makeButton(
                    caption: "CLOSE",
                    prominent: true,
                    accessibilityLabel: auxiliaryCloseLabel,
                    action: { [weak self] in
                        guard let id = self?.activeTab?.id else { return }
                        self?.closeTab(id)
                    }
                ),
                addsLegacyTrailingInset: true
            ))
        } else if traitCollection.horizontalSizeClass == .compact {
            if let activeController {
                let attach = ensureFileAttachController(for: activeController)
                attach.parkAttachButton()
            }
            trailing.append(makeNavigationBarItem(
                customView: makeMenuButton(
                    caption: "",
                    systemImage: "ellipsis",
                    accessibilityLabel: "Terminal actions",
                    menu: makeOverflowMenu(
                        displacesDirectActions: true,
                        attachmentAvailability: compactAttachmentAvailability
                    )
                ),
                addsLegacyTrailingInset: true
            ))
        } else {
            trailing.append(makeNavigationBarItem(customView: makeMenuButton(
                caption: "TAB",
                systemImage: "plus",
                accessibilityLabel: "New tab: another session or the file viewer",
                menu: makeNewTabMenu()
            )))
            if let activeController {
                let attach = ensureFileAttachController(for: activeController)
                trailing.append(makeNavigationBarItem(
                    customView: attach.takeAttachButton()
                ))
            }
            trailing.append(makeNavigationBarItem(customView: TerminalFontSizeControl(
                fontDown: { [weak self] in self?.changeFont(by: -1) },
                fontUp: { [weak self] in self?.changeFont(by: 1) }
            )))
            if !mergeSources.isEmpty {
                trailing.append(makeNavigationBarItem(customView: makeMenuButton(
                    caption: "MERGE",
                    accessibilityLabel: "Merge another window into this one",
                    menu: makeMergeMenu()
                )))
            }
            if activeController != nil {
                trailing.append(makeNavigationBarItem(customView: makeMenuButton(
                    caption: "",
                    systemImage: "ellipsis",
                    accessibilityLabel: "Terminal actions",
                    menu: makeOverflowMenu(displacesDirectActions: false)
                )))
            }
            if activeTabHasSession {
                trailing.append(makeNavigationBarItem(
                    customView: makeMenuButton(
                        caption: "DETACH",
                        prominent: true,
                        accessibilityLabel: "Detach or close the session",
                        menu: makeDetachMenu()
                    ),
                    addsLegacyTrailingInset: true
                ))
            } else {
                trailing.append(makeNavigationBarItem(
                    customView: makeButton(
                        caption: "DETACH",
                        prominent: true,
                        accessibilityLabel: "Detach: tmux keeps the session",
                        action: { [weak self] in self?.detachActiveTab() }
                    ),
                    addsLegacyTrailingInset: true
                ))
            }
        }
        // UIKit displays right-bar items in reverse visual order.
        navigationItem.rightBarButtonItems = trailing.reversed()
        #endif
    }

    /// Deterministic seam for asserting the snapshot-menu transition without
    /// opening a real SSH transport in a UIKit unit test.
    func renderCompactNavigationChromeForTesting(
        attachmentAvailability: FileAttachMenuAvailability
    ) {
        configureNavigationChrome(
            compactAttachmentAvailabilityOverride: attachmentAvailability
        )
    }

    #if !os(visionOS)
    /// iPadOS 26+ otherwise puts its shared Glass plate around each custom
    /// TALLY face in a navigation bar. These controls already own their
    /// complete background, border, highlight, and intrinsic geometry.
    private func makeNavigationBarItem(
        customView: UIView,
        addsLegacyTrailingInset: Bool = false
    ) -> UIBarButtonItem {
        let resolvedView: UIView
        if #available(iOS 26.0, *), addsLegacyTrailingInset {
            resolvedView = TerminalNavigationTrailingInsetView(contentView: customView)
        } else {
            resolvedView = customView
        }
        let item = UIBarButtonItem(customView: resolvedView)
        if #available(iOS 26.0, *) {
            item.hidesSharedBackground = true
        }
        if #available(iOS 27.0, *) {
            item.isPaddingRemoved = true
        }
        return item
    }

    private func ensureFileAttachController(
        for controller: TerminalSessionController
    ) -> FileAttachMenuViewController {
        if let fileAttachController {
            fileAttachController.update(controller: controller)
            fileAttachController.loadViewIfNeeded()
            return fileAttachController
        }
        let attach = FileAttachMenuViewController(controller: controller)
        fileAttachController = attach
        addChild(attach)
        attach.loadViewIfNeeded()
        rootView.parkFileAttachView(attach.view)
        attach.didMove(toParent: self)
        return attach
    }

    private func makeButton(
        caption: String,
        systemImage: String? = nil,
        prominent: Bool = false,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> UMDBarButton {
        let button = UMDBarButton(
            caption: caption,
            systemImage: systemImage,
            prominent: prominent,
            accessibilityLabel: accessibilityLabel
        )
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func makeMenuButton(
        caption: String,
        systemImage: String? = nil,
        prominent: Bool = false,
        accessibilityLabel: String,
        menu: UIMenu
    ) -> UMDBarButton {
        let button = UMDBarButton(
            caption: caption,
            systemImage: systemImage,
            prominent: prominent,
            accessibilityLabel: accessibilityLabel
        )
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        return button
    }

    private func makeNewTabMenu() -> UIMenu {
        var actions: [UIMenuElement] = [
            UIAction(title: "New Session") { [weak self] _ in
                self?.openNewTab(launching: nil)
            },
        ]
        actions.append(contentsOf: AgentKind.allCases.map { agent in
            UIAction(title: agent.displayName) { [weak self] _ in
                self?.openNewTab(launching: agent)
            }
        })
        actions.append(UIAction(title: "File Viewer") { [weak self] _ in
            self?.openFileViewer(target: nil)
        })
        return UIMenu(children: actions)
    }

    private func makeMergeMenu() -> UIMenu {
        var actions: [UIMenuElement] = mergeSources.map { source in
            UIAction(
                title: source.label,
                image: UIImage(systemName: "macwindow")
            ) { [weak self] _ in self?.merge(source.id) }
        }
        if mergeSources.count > 1 {
            actions.append(UIAction(
                title: "Merge All Windows",
                image: UIImage(systemName: "rectangle.stack")
            ) { [weak self] _ in
                guard let self else { return }
                for source in mergeSources { merge(source.id) }
            })
        }
        return UIMenu(children: actions)
    }

    private func makeDetachMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Detach") { [weak self] _ in self?.detachActiveTab() },
            UIAction(
                title: "Close Session",
                attributes: .destructive
            ) { [weak self] _ in self?.confirmCloseActiveSession() },
        ])
    }

    private func makeOverflowMenu(
        displacesDirectActions: Bool,
        attachmentAvailability: FileAttachMenuAvailability? = nil
    ) -> UIMenu {
        var groups: [UIMenuElement] = []
        if let activeController {
            let locked = KeyboardLock.shared.isLocked
            groups.append(UIAction(
                title: locked ? "Unlock Keyboard" : "Lock Keyboard Closed",
                image: UIImage(systemName: locked ? "lock.open" : "lock")
            ) { _ in activeController.toggleKeyboardLock() })
        }
        if displacesDirectActions {
            groups.append(UIMenu(title: "Text Size", children: [
                UIAction(title: "Smaller Text") { [weak self] _ in
                    self?.changeFont(by: -1)
                },
                UIAction(title: "Larger Text") { [weak self] _ in
                    self?.changeFont(by: 1)
                },
            ]))
            groups.append(UIMenu(title: "New Tab", children: makeNewTabMenu().children))
            if let attachMenu = fileAttachController?.makeSourceMenu(
                title: "Send File…",
                image: UIImage(systemName: "paperclip"),
                availability: attachmentAvailability
            ) {
                groups.append(attachMenu)
            }
            if !mergeSources.isEmpty {
                groups.append(UIMenu(title: "Merge Window", children: makeMergeMenu().children))
            }
            groups.append(UIAction(title: "Detach") { [weak self] _ in
                self?.detachActiveTab()
            })
            if activeTabHasSession {
                groups.append(UIAction(
                    title: "Close Session",
                    attributes: .destructive
                ) { [weak self] _ in self?.confirmCloseActiveSession() })
            }
        }
        return UIMenu(children: groups)
    }
    #endif
}

// MARK: - Native presentations

extension TerminalWindowViewController {
    private func presentPendingFeatureIfPossible() {
        guard !appLocked,
              isViewLoaded,
              view.window != nil,
              presentedViewController == nil,
              passphrasePresenter.presentedViewController == nil,
              presentedFeatureController == nil,
              let controller = activeController
        else { return }

        if let link = controller.pendingLink {
            let featureID = "link:\(activeTab?.id.uuidString ?? ""):" + link.id
            guard featureID != presentedActivationID else { return }
            presentedActivationID = featureID
            let sheet = TerminalLinkSheetViewController(
                link: link,
                viewportOffer: { [weak self] link in
                    ViewportOffer.make(for: link, host: self?.activeTabHost)
                },
                onOpen: { [weak controller] in controller?.openConfirmedLink($0) },
                onCopy: { [weak controller] in controller?.copyConfirmedTarget($0) },
                onOpenViewport: { [weak self] in self?.openViewport($0) }
            )
            sheet.onDismiss = { [weak self, weak controller] in
                controller?.dismissPendingLink()
                self?.dismissPresentedFeature()
            }
            presentFeature(sheet)
            return
        }

        if let target = controller.pendingPath {
            let featureID = "path:\(activeTab?.id.uuidString ?? ""):" + target.id
            guard featureID != presentedActivationID else { return }
            presentedActivationID = featureID
            let sheet = TerminalFilePathSheetViewController(
                target: target,
                hostName: activeTabHost?.name ?? "the host",
                onView: { [weak self] in self?.openFileViewer(target: $0) },
                onCopy: { [weak controller] in controller?.copyConfirmedTarget($0) }
            )
            sheet.onDismiss = { [weak self, weak controller] in
                controller?.dismissPendingPath()
                self?.dismissPresentedFeature()
            }
            presentFeature(sheet)
        }
    }

    private func presentFeature(_ content: UIViewController) {
        let navigation = UINavigationController(rootViewController: content)
        navigation.navigationBar.prefersLargeTitles = false
        navigation.view.backgroundColor = UIKitChassis.chassis
        UIKitChassis.configureSheetNavigationBar(navigation.navigationBar)
        navigation.presentationController?.delegate = self
        presentedFeatureController = navigation
        applyAppearanceToPresentedFeature()
        present(navigation, animated: true)
        navigation.presentationController?.delegate = self
    }

    /// The link and path sheets carry no appearance property of their own, so
    /// the stack they are hosted in wears the choice for them. `renderNow`
    /// re-runs this on every appearance change (the observation reads
    /// `themes.appearance`), which is what keeps an open sheet in step.
    private func applyAppearanceToPresentedFeature() {
        guard let presented = presentedFeatureController else { return }
        let style = themes.appearance.interfaceStyle
        guard presented.overrideUserInterfaceStyle != style else { return }
        presented.overrideUserInterfaceStyle = style
    }

    private func dismissPresentedFeature() {
        guard let presentedFeatureController else {
            presentedActivationID = nil
            restartObservation()
            return
        }
        presentedFeatureController.dismiss(animated: true) { [weak self] in
            self?.presentedFeatureController = nil
            self?.presentedActivationID = nil
            self?.restartObservation()
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        activeController?.dismissPendingLink()
        activeController?.dismissPendingPath()
        presentedFeatureController = nil
        presentedActivationID = nil
        restartObservation()
    }

    private func presentPaywall() {
        guard !appLocked, presentedViewController == nil else { return }
        let paywall = ProPaywallViewController(entitlements: entitlements)
        paywall.followAppAppearance(themes)
        let navigation = UINavigationController(rootViewController: paywall)
        UIKitChassis.configureSheetNavigationBar(navigation.navigationBar)
        paywall.onDone = { [weak navigation] in navigation?.dismiss(animated: true) }
        present(navigation, animated: true)
    }

    private func presentKeychainTip() {
        guard !appLocked,
              presentedViewController == nil,
              let activeTab,
              let host = store.host(id: activeTab.hostID),
              let notice = activeTabKeychainNotice
        else { return }
        let guide = KeychainUnlockViewController(
            host: host,
            sessionNames: notice.sessionNames
        )
        guide.followAppAppearance(themes)
        let navigation = UINavigationController(rootViewController: guide)
        UIKitChassis.configureSheetNavigationBar(navigation.navigationBar)
        guide.onDone = { [weak navigation] in navigation?.dismiss(animated: true) }
        present(navigation, animated: true)
    }
}

// MARK: - DEBUG automation

#if DEBUG
extension TerminalWindowViewController {
    private func configureDebugObservers() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
            debugObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in Task { @MainActor in action() } })
        }
        observe(.multiplexDebugAgentChip) { [weak self] in self?.debugTapFirstSlashChip() }
        observe(.multiplexDebugNewTab) { [weak self] in self?.debugNewTab() }
        observe(.multiplexDebugMessageJump) { [weak self] in self?.debugJumpToOldestMessage() }
        observe(.multiplexDebugMessageJumpBack) { [weak self] in
            guard let self, ownsFocusedTerminal else { return }
            activeController?.finishHistoryJump()
        }
        observe(.multiplexDebugLink) { [weak self] in self?.debugActivateFirstLink() }
        observe(.multiplexDebugLinkOpen) { [weak self] in
            guard let self, ownsFocusedTerminal else { return }
            activeController?.openPendingLink()
        }
        observe(.multiplexDebugViewportOpen) { [weak self] in
            self?.debugOpenViewportForPendingLink()
        }
        observe(.multiplexDebugFileViewer) { [weak self] in self?.debugOpenFileViewer() }
        observe(.multiplexDebugPathView) { [weak self] in self?.debugViewPendingPath() }
        observe(.multiplexDebugFileViewerRepoDiff) { [weak self] in
            guard let self,
                  let activeTab,
                  activeTab.isFileViewer,
                  let fileViewer = workspace.fileViewerController(for: activeTab.id)
            else { return }
            Task { await fileViewer.showRepoDiff() }
        }
        observe(.multiplexDebugLinkRegions) { [weak self] in self?.debugLogLinkRegions() }
    }

    private var ownsFocusedTerminal: Bool {
        guard let view = activeController?.terminalView else { return false }
        return TerminalFocusArbiter.current === view
    }

    private func debugTapFirstSlashChip() {
        guard ownsFocusedTerminal,
              let controller = activeController,
              let activeTab,
              let agent = shownAgent,
              entitlements.isPro || entitlements.canUseSlashChip,
              controller.status == .live,
              let command = AgentCommandSet.commands(
                in: .bar,
                for: agent,
                placementOverrides: store.agentCommandConfiguration(
                    for: activeTab.hostID
                ).builtInPlacements(for: agent)
              ).first(where: { $0.label.hasPrefix("/") })
        else { return }
        send(command, via: controller)
    }

    private func debugActivateFirstLink() {
        guard ownsFocusedTerminal, let view = activeController?.terminalView else { return }
        let terminal = view.getTerminal()
        for row in 0..<terminal.rows {
            var col = 0
            while col < terminal.cols {
                // Same seam-carrying lookup the long-press route uses, so
                // this hook proves the wrapped-glue cut headlessly too.
                guard let result = terminal.linkWithRowTexts(
                    at: .screen(Position(col: col, row: row)),
                    mode: .explicitAndImplicit
                ) else {
                    col += 1
                    continue
                }
                if activeController?.activateLink(
                    result.text, rowFragments: result.rowTexts
                ) == true { return }
                // A declined match must not stall the scan on its own
                // cells — step past the whole match's worth of columns
                // rather than re-resolving each one.
                col += max(1, result.text.count)
            }
        }
    }

    private func debugNewTab() {
        guard ownsFocusedTerminal else { return }
        openNewTab(launching: nil)
    }

    private func debugOpenViewportForPendingLink() {
        guard ownsFocusedTerminal,
              let controller = activeController,
              let link = controller.pendingLink,
              let offer = ViewportOffer.make(for: link, host: activeTabHost)
        else { return }
        controller.dismissPendingLink()
        openViewport(offer)
    }

    private func debugOpenFileViewer() {
        guard ownsFocusedTerminal else { return }
        openFileViewer(target: nil)
    }

    private func debugViewPendingPath() {
        guard ownsFocusedTerminal,
              let controller = activeController,
              let target = controller.pendingPath
        else { return }
        controller.dismissPendingPath()
        openFileViewer(target: target)
    }

    private func debugLogLinkRegions() {
        guard ownsFocusedTerminal, let view = activeController?.terminalView else { return }
        let logger = Logger(
            subsystem: "app.multiplexterm.multiplex",
            category: "links"
        )
        let regions = view.visibleLinkRegions()
            .filter { TerminalLink.resolve($0.target) != nil }
        logger.debug("link-regions count=\(regions.count, privacy: .public)")
        for region in regions {
            logger.debug(
                "link-region target=\(region.target, privacy: .public) rects=\(String(describing: region.rects), privacy: .public)"
            )
        }
    }

    private func debugJumpToOldestMessage() {
        guard ownsFocusedTerminal,
              let controller = activeController,
              let agent = shownAgent
        else { return }
        Task {
            controller.openAgentHistory(for: agent)
            for _ in 0..<60 {
                if case .loaded = controller.agentHistory { break }
                if case .unavailable = controller.agentHistory { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard case .loaded(_, let messages, true) = controller.agentHistory,
                  let oldest = messages.first(where: \.reachable)
            else { return }
            controller.startHistoryJump(to: oldest)
            controller.closeAgentHistory()
        }
    }
}
#endif

/// The tab rail's scroller. A `UIScrollView` delays content touches by 150 ms
/// and discards them outright if the finger drifts during that window, so once
/// the tabs overflow the rail a perfectly ordinary press never reached the
/// cell — the "tabs feel dead" report. Track immediately instead, and let a
/// genuine drag that starts on a cell still scroll the strip: UIKit's default
/// `touchesShouldCancel` answers *false* for a `UIControl`, which with
/// undelayed touches would pin the strip in place under any press.
@MainActor
final class TerminalTabScrollView: UIScrollView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        delaysContentTouches = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is TerminalTabCell { return true }
        return super.touchesShouldCancel(in: view)
    }
}

@MainActor
final class TerminalWindowUIKitRootView: UIView {
    static let tabRailHorizontalInset: CGFloat = 12
    static let tabRailVerticalInset: CGFloat = 6

    let paneContainer = UIView()
    let tabScrollView = TerminalTabScrollView()
    let umdContainer = UIView()
    let helperContainer = UIView()
    private let bottomSafeAreaBackfill = UIView()
    private let fileAttachPresenterParking = UIView()
    private let tabDivider = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIKitChassis.chassis
        paneContainer.backgroundColor = UIKitChassis.screen
        tabScrollView.backgroundColor = UIKitChassis.chassis
        tabScrollView.showsHorizontalScrollIndicator = false
        tabDivider.backgroundColor = UIKitChassis.bezelHi
        umdContainer.backgroundColor = .clear
        helperContainer.backgroundColor = .clear
        bottomSafeAreaBackfill.backgroundColor = UIKitChassis.bezel
        bottomSafeAreaBackfill.isUserInteractionEnabled = false
        bottomSafeAreaBackfill.isAccessibilityElement = false
        bottomSafeAreaBackfill.accessibilityIdentifier =
            "terminalWindow.bottomSafeAreaBackfill"

        addSubview(paneContainer)
        addSubview(tabScrollView)
        addSubview(tabDivider)
        addSubview(umdContainer)
        addSubview(helperContainer)
        addSubview(bottomSafeAreaBackfill)
        addSubview(fileAttachPresenterParking)
        fileAttachPresenterParking.frame = .zero
        fileAttachPresenterParking.clipsToBounds = true

        paneContainer.accessibilityIdentifier = "terminalWindow.panes"
        tabScrollView.accessibilityIdentifier = "terminalWindow.tabs"
        umdContainer.accessibilityIdentifier = "terminalWindow.umd"
        helperContainer.accessibilityIdentifier = "terminalWindow.helpers"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func layoutSubviews() {
        super.layoutSubviews()
        tabDivider.frame = CGRect(
            x: tabScrollView.frame.minX,
            y: max(tabScrollView.frame.minY, tabScrollView.frame.maxY - 1),
            width: tabScrollView.frame.width,
            height: tabScrollView.isHidden ? 0 : 1
        )
    }

    func setTabsVisible(_ visible: Bool) {
        tabScrollView.isHidden = !visible
        tabDivider.isHidden = !visible
    }

    func parkFileAttachView(_ view: UIView) {
        view.removeFromSuperview()
        fileAttachPresenterParking.addSubview(view)
        view.frame = .zero
        view.autoresizingMask = []
    }

    static func contentBounds(
        in bounds: CGRect,
        reservesBottomSafeArea: Bool,
        safeAreaInsets: UIEdgeInsets
    ) -> CGRect {
        guard reservesBottomSafeArea else { return bounds }
        var result = bounds
        result.size.height = max(0, bounds.height - safeAreaInsets.bottom)
        return result
    }

    func setBottomSafeAreaBackfill(
        frame: CGRect,
        fill: TerminalWindowBottomSafeAreaFill
    ) {
        bottomSafeAreaBackfill.frame = frame
        bottomSafeAreaBackfill.backgroundColor = fill.color
        bottomSafeAreaBackfill.isHidden = frame.height <= 0
        bringSubviewToFront(bottomSafeAreaBackfill)
    }

    func setShellMode(_ shell: Bool) {
        layer.cornerRadius = shell ? 0 : {
            #if os(visionOS)
            24
            #else
            0
            #endif
        }()
        clipsToBounds = true
        layer.borderWidth = shell ? 0 : {
            #if os(visionOS)
            1
            #else
            0
            #endif
        }()
        layer.borderColor = UIKitChassis.bezelHi
            .resolvedColor(with: traitCollection).cgColor
    }
}
