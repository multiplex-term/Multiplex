import Observation
import UIKit

/// Namespace for the wall's three UIKit presentation modes.
enum FleetWall {
    enum Presentation: Equatable {
        case standard
        case shellCompact
        case shellRail
    }
}

@MainActor
struct FleetWallConfiguration {
    let store: HostStore
    let hub: ConnectionHub
    let networkChanges: NetworkChangeMonitor
    let workspace: TerminalWorkspace
    /// Present when the scene can supply it: the wall's own guide sheets then
    /// follow a live appearance change instead of snapshotting the choice
    /// (`AppAppearanceFollowing`). Without it they read the scene window.
    var themes: ThemeStore? = nil
    var terminalOpener: TerminalRouteOpener
    var presentation: FleetWall.Presentation
    var selectedTerminal: TerminalRoute?
    var shellSafeArea: UIEdgeInsets
    var reduceMotion: Bool
    var sceneIsActive: Bool
    var addHost: () -> Void
    var editHost: (Host) -> Void
    var openSettings: () -> Void
    var openFAQ: () -> Void
    var usesSystemNavigation = false
}

// MARK: - Native wall container / navigation chrome

/// Owns the iPad 26+ navigation bar used by classic deck scenes. Shell and
/// visionOS presentations embed the same wall controller directly.
@MainActor
final class FleetWallContainerViewController: UIViewController {
    private var configuration: FleetWallConfiguration
    private let wallController: FleetWallViewController
    private var embeddedController: UIViewController?
    private var navigationControllerHost: UINavigationController?
    private var navigationTitleView: FleetNavigationTitleView?

    init(configuration: FleetWallConfiguration) {
        self.configuration = configuration
        wallController = FleetWallViewController(configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIKitChassis.chassis
        installChildIfNeeded()
    }

    func update(configuration: FleetWallConfiguration) {
        let navigationChanged = wantsSystemNavigation(for: self.configuration)
            != wantsSystemNavigation(for: configuration)
        self.configuration = configuration
        if isViewLoaded, navigationChanged {
            uninstallChild()
            installChildIfNeeded()
        }
        var wallConfiguration = configuration
        wallConfiguration.usesSystemNavigation = wantsSystemNavigation(for: configuration)
        wallController.update(configuration: wallConfiguration)
        configureNavigationChrome()
    }

    private func installChildIfNeeded() {
        var wallConfiguration = configuration
        wallConfiguration.usesSystemNavigation = wantsSystemNavigation(for: configuration)
        wallController.update(configuration: wallConfiguration)

        let child: UIViewController
        if wallConfiguration.usesSystemNavigation {
            let navigation = UINavigationController(rootViewController: wallController)
            navigationControllerHost = navigation
            child = navigation
        } else {
            navigationControllerHost = nil
            child = wallController
        }
        embeddedController = child
        addChild(child)
        view.addSubview(child.view)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        child.didMove(toParent: self)
        configureNavigationChrome()
    }

    private func uninstallChild() {
        guard let child = embeddedController else { return }
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
        embeddedController = nil
        navigationControllerHost = nil
        navigationTitleView = nil
    }

    private func wantsSystemNavigation(for configuration: FleetWallConfiguration) -> Bool {
        #if os(visionOS)
        return false
        #else
        if #available(iOS 26.0, *) {
            return configuration.presentation == .standard
        }
        return false
        #endif
    }

    private func configureNavigationChrome() {
        guard let navigationControllerHost else { return }
        UIKitChassis.configureSheetNavigationBar(navigationControllerHost.navigationBar)
        navigationControllerHost.navigationBar.prefersLargeTitles = false

        let titleView = navigationTitleView ?? FleetNavigationTitleView()
        navigationTitleView = titleView
        titleView.setSummary(wallController.fleetSummary)
        wallController.onFleetSummaryChange = { [weak titleView] summary in
            titleView?.setSummary(summary)
        }
        wallController.navigationItem.titleView = titleView
        wallController.navigationItem.largeTitleDisplayMode = .never

        // One custom view intentionally owns all three chips. iOS-app-on-Mac
        // otherwise reduces single custom toolbar controls to bare glyphs.
        let actions = UIStackView(arrangedSubviews: [
            UIKitChassisChip(
                "HOST",
                systemImage: "plus",
                accessibilityLabel: "Add host",
                action: configuration.addHost
            ),
            UIKitChassisChip(
                "FAQ",
                systemImage: "questionmark",
                accessibilityLabel: "Frequently asked questions",
                action: configuration.openFAQ
            ),
            UIKitChassisChip(
                "SETTINGS",
                systemImage: "gearshape",
                accessibilityLabel: "Settings",
                action: configuration.openSettings
            ),
        ])
        actions.axis = .horizontal
        actions.alignment = .center
        actions.spacing = 8
        actions.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0, leading: 0, bottom: 0, trailing: 12
        )
        actions.isLayoutMarginsRelativeArrangement = true
        let item = UIBarButtonItem(customView: actions)
        #if !os(visionOS)
        // The stack already draws three complete TALLY faces. iPadOS must not
        // wrap that custom group in an additional shared Glass capsule or add
        // bar-item padding around its exact intrinsic geometry.
        if #available(iOS 26.0, *) {
            item.hidesSharedBackground = true
        }
        if #available(iOS 27.0, *) {
            item.isPaddingRemoved = true
        }
        #endif
        wallController.navigationItem.rightBarButtonItem = item
    }
}

@MainActor
private final class FleetNavigationTitleView: UIView {
    private let titleLabel = UIKitChassisLabel("Multiplex", size: 15)
    private let summaryLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        summaryLabel.font = UIKitChassis.monoFont(11)
        summaryLabel.textColor = UIKitChassis.signal2
        summaryLabel.numberOfLines = 1
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [titleLabel, summaryLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 14
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setSummary(_ summary: String) {
        summaryLabel.text = summary
        accessibilityLabel = "Multiplex, \(summary)"
    }
}

// MARK: - Wall controller

@MainActor
final class FleetWallViewController: UIViewController {
    private struct WallSnapshot: Equatable {
        let hosts: [Host]
        let sessionCounts: [UUID: Int]
        let offline: Bool
        let passphraseChallenge: SSHKeyPassphraseChallenge?
    }

    private static let feedInterval: Duration = .seconds(5)

    private var configuration: FleetWallConfiguration
    private let rootStack = UIStackView()
    private let fixedHeaderContainer = UIView()
    private let fixedHeader = FleetHeaderView()
    private let fixedHeaderRule = UIView()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let passphrasePresenter = SSHKeyPassphrasePromptPresenterViewController()
    private var contentLeadingConstraint: NSLayoutConstraint?
    private var contentTrailingConstraint: NSLayoutConstraint?
    private var contentTopConstraint: NSLayoutConstraint?
    private var contentBottomConstraint: NSLayoutConstraint?
    private var fixedHeaderLeadingConstraint: NSLayoutConstraint?
    private var fixedHeaderTrailingConstraint: NSLayoutConstraint?
    private var sections: [UUID: FleetHostSectionView] = [:]
    private var awaitingSignalView: FleetAwaitingSignalView?
    private var inlineHeader: FleetHeaderView?
    private var latestSnapshot: WallSnapshot?
    private var observationGeneration = 0
    private var feedTask: Task<Void, Never>?
    private var feedIdentity: FleetFeedID?
    private var availableColumnCount: Int?
    private var resolvedColumnCount = 1
    private var keyPassphraseHostID: UUID?
    private var isOnScreen = false

    var onFleetSummaryChange: ((String) -> Void)?
    private(set) var fleetSummary = "0 HOSTS · 0 SESSIONS"

    init(configuration: FleetWallConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIKitChassis.chassis
        configureHierarchy()
        observeWall()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isOnScreen = true
        restartFeedIfNeeded(force: true)
        synchronizePassphrasePrompt()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        feedTask?.cancel()
        feedTask = nil
        feedIdentity = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateColumnCount()
    }

    deinit {
        feedTask?.cancel()
    }

    func update(configuration: FleetWallConfiguration) {
        let dependenciesChanged = self.configuration.store !== configuration.store
            || self.configuration.hub !== configuration.hub
            || self.configuration.networkChanges !== configuration.networkChanges
            || self.configuration.workspace !== configuration.workspace
        let layoutChanged = self.configuration.presentation != configuration.presentation
            || self.configuration.shellSafeArea != configuration.shellSafeArea
            || self.configuration.usesSystemNavigation != configuration.usesSystemNavigation
        let activeChanged = self.configuration.sceneIsActive != configuration.sceneIsActive
        self.configuration = configuration

        if isViewLoaded {
            if layoutChanged { configurePresentationLayout() }
            if dependenciesChanged { observeWall() }
            propagateConfiguration()
            if activeChanged { restartFeedIfNeeded(force: true) }
            updateColumnCount()
        }
    }

    private func configureHierarchy() {
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 0
        view.addSubview(rootStack)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        fixedHeaderContainer.backgroundColor = UIKitChassis.chassis
        fixedHeaderContainer.addSubview(fixedHeader)
        fixedHeaderContainer.addSubview(fixedHeaderRule)
        fixedHeader.translatesAutoresizingMaskIntoConstraints = false
        fixedHeaderRule.translatesAutoresizingMaskIntoConstraints = false
        fixedHeaderRule.backgroundColor = UIKitChassis.bezelHi
        fixedHeaderLeadingConstraint = fixedHeader.leadingAnchor.constraint(
            equalTo: fixedHeaderContainer.leadingAnchor
        )
        fixedHeaderTrailingConstraint = fixedHeader.trailingAnchor.constraint(
            equalTo: fixedHeaderContainer.trailingAnchor
        )
        NSLayoutConstraint.activate([
            fixedHeaderLeadingConstraint!,
            fixedHeaderTrailingConstraint!,
            fixedHeader.topAnchor.constraint(equalTo: fixedHeaderContainer.topAnchor),
            fixedHeader.bottomAnchor.constraint(equalTo: fixedHeaderRule.topAnchor),
            fixedHeaderRule.leadingAnchor.constraint(equalTo: fixedHeaderContainer.leadingAnchor),
            fixedHeaderRule.trailingAnchor.constraint(equalTo: fixedHeaderContainer.trailingAnchor),
            fixedHeaderRule.bottomAnchor.constraint(equalTo: fixedHeaderContainer.bottomAnchor),
            fixedHeaderRule.heightAnchor.constraint(equalToConstant: 1),
        ])
        rootStack.addArrangedSubview(fixedHeaderContainer)

        scrollView.alwaysBounceVertical = true
        scrollView.backgroundColor = UIKitChassis.chassis
        rootStack.addArrangedSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 0
        scrollView.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentLeadingConstraint = contentStack.leadingAnchor.constraint(
            equalTo: scrollView.contentLayoutGuide.leadingAnchor
        )
        contentTrailingConstraint = contentStack.trailingAnchor.constraint(
            equalTo: scrollView.contentLayoutGuide.trailingAnchor
        )
        contentTopConstraint = contentStack.topAnchor.constraint(
            equalTo: scrollView.contentLayoutGuide.topAnchor
        )
        contentBottomConstraint = contentStack.bottomAnchor.constraint(
            equalTo: scrollView.contentLayoutGuide.bottomAnchor
        )
        NSLayoutConstraint.activate([
            contentLeadingConstraint!,
            contentTrailingConstraint!,
            contentTopConstraint!,
            contentBottomConstraint!,
            scrollView.contentLayoutGuide.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor
            ),
        ])

        addChild(passphrasePresenter)
        view.addSubview(passphrasePresenter.view)
        passphrasePresenter.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            passphrasePresenter.view.widthAnchor.constraint(equalToConstant: 0),
            passphrasePresenter.view.heightAnchor.constraint(equalToConstant: 0),
            passphrasePresenter.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            passphrasePresenter.view.topAnchor.constraint(equalTo: view.topAnchor),
        ])
        passphrasePresenter.didMove(toParent: self)

        configurePresentationLayout()
    }

    private func configurePresentationLayout() {
        let presentation = configuration.presentation
        let shell = presentation != .standard
        fixedHeaderContainer.isHidden = !shell
        fixedHeader.configure(
            presentation: presentation,
            summary: fleetSummary,
            actions: headerActions
        )

        // The shell spends the bottom safe area and its panes hand back the
        // clearance exactly once: the wall restores it as scroll padding
        // below. Letting UIKit adjust the viewport's content inset for the
        // same band would count it twice, so the shell viewport opts out —
        // the classic deck passes a zero shell inset and keeps the automatic
        // adjustment (its nav bar and home indicator ride on it).
        scrollView.contentInsetAdjustmentBehavior = shell ? .never : .automatic

        let wallPadding: CGFloat = presentation == .shellRail ? 12 : 26
        let safe = configuration.shellSafeArea
        fixedHeaderLeadingConstraint?.constant = wallPadding + safe.left
        fixedHeaderTrailingConstraint?.constant = -(wallPadding + safe.right)
        fixedHeader.setTopInset(min(wallPadding, 16))

        let leading = wallPadding + safe.left
        let trailing = wallPadding + safe.right
        contentLeadingConstraint?.constant = leading
        contentTrailingConstraint?.constant = -trailing
        contentTopConstraint?.constant = presentation == .standard ? wallPadding : 0
        contentBottomConstraint?.constant = -(wallPadding + safe.bottom)

        renderWall(latestSnapshot)
    }

    private var headerActions: FleetHeaderActions {
        FleetHeaderActions(
            addHost: configuration.addHost,
            openFAQ: configuration.openFAQ,
            openSettings: configuration.openSettings
        )
    }

    // MARK: Observation

    private func observeWall() {
        guard isViewLoaded else { return }
        observationGeneration += 1
        let generation = observationGeneration
        let snapshot = withObservationTracking {
            let hosts = configuration.store.hosts
            var counts: [UUID: Int] = [:]
            for host in hosts where host.isEnabled {
                counts[host.id] = configuration.hub.model(for: host).sessionCount
            }
            let challenge: SSHKeyPassphraseChallenge?
            if let keyPassphraseHostID,
               let host = configuration.store.host(id: keyPassphraseHostID) {
                challenge = configuration.hub.model(for: host).keyPassphraseChallenge
            } else {
                challenge = nil
            }
            return WallSnapshot(
                hosts: hosts,
                sessionCounts: counts,
                offline: configuration.networkChanges.isOffline,
                passphraseChallenge: challenge
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.observeWall()
            }
        }
        latestSnapshot = snapshot
        renderWall(snapshot)
        synchronizePassphrasePrompt(challenge: snapshot.passphraseChallenge)
        restartFeedIfNeeded(force: false)
    }

    private func renderWall(_ snapshot: WallSnapshot?) {
        guard isViewLoaded, let snapshot else { return }
        let hostCount = snapshot.hosts.count
        let sessionCount = snapshot.sessionCounts.values.reduce(0, +)
        fleetSummary = "\(hostCount) HOST\(hostCount == 1 ? "" : "S") · "
            + "\(sessionCount) SESSION\(sessionCount == 1 ? "" : "S")"
        fixedHeader.setSummary(fleetSummary)
        inlineHeader?.setSummary(fleetSummary)
        onFleetSummaryChange?(fleetSummary)

        var desiredViews: [UIView] = []
        if shouldShowInlineHeader {
            let header = inlineHeader ?? FleetHeaderView()
            inlineHeader = header
            header.configure(
                presentation: configuration.presentation,
                summary: fleetSummary,
                actions: headerActions
            )
            desiredViews.append(header)
        } else {
            inlineHeader = nil
        }

        if snapshot.hosts.isEmpty {
            sections.values.forEach { $0.stopObserving() }
            sections.removeAll()
            let awaiting = awaitingSignalView ?? FleetAwaitingSignalView()
            awaitingSignalView = awaiting
            awaiting.configure(addHost: configuration.addHost)
            desiredViews.append(awaiting)
        } else {
            awaitingSignalView = nil
            let liveIDs = Set(snapshot.hosts.map(\.id))
            for id in Array(sections.keys) where !liveIDs.contains(id) {
                sections.removeValue(forKey: id)?.stopObserving()
            }
            for host in snapshot.hosts {
                let section = sections[host.id] ?? FleetHostSectionView(
                    host: host,
                    model: host.isEnabled ? configuration.hub.model(for: host) : nil,
                    configuration: hostSectionConfiguration(for: host)
                )
                sections[host.id] = section
                section.update(
                    host: host,
                    model: host.isEnabled ? configuration.hub.model(for: host) : nil,
                    configuration: hostSectionConfiguration(for: host)
                )
                desiredViews.append(section)
            }
        }

        // An attached UIMenu belongs to its source view. Detaching an
        // otherwise unchanged host section dismisses that menu immediately,
        // so leave the hierarchy alone when the semantic wall order is the
        // same. Probe observations commonly repaint with these exact views.
        let alreadyArranged = contentStack.arrangedSubviews.count == desiredViews.count
            && zip(contentStack.arrangedSubviews, desiredViews).allSatisfy { current, desired in
                current === desired
            }
        if !alreadyArranged {
            contentStack.arrangedSubviews.forEach {
                contentStack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            desiredViews.forEach(contentStack.addArrangedSubview)
        }
        updateColumnCount()
    }

    private var shouldShowInlineHeader: Bool {
        configuration.presentation == .standard && !configuration.usesSystemNavigation
    }

    private func propagateConfiguration() {
        fixedHeader.configure(
            presentation: configuration.presentation,
            summary: fleetSummary,
            actions: headerActions
        )
        inlineHeader?.configure(
            presentation: configuration.presentation,
            summary: fleetSummary,
            actions: headerActions
        )
        guard let hosts = latestSnapshot?.hosts else { return }
        for host in hosts {
            sections[host.id]?.update(
                host: host,
                model: host.isEnabled ? configuration.hub.model(for: host) : nil,
                configuration: hostSectionConfiguration(for: host)
            )
        }
    }

    private func hostSectionConfiguration(for host: Host) -> FleetHostSectionConfiguration {
        FleetHostSectionConfiguration(
            store: configuration.store,
            workspace: configuration.workspace,
            presentation: configuration.presentation,
            selectedTerminal: configuration.selectedTerminal,
            networkOffline: latestSnapshot?.offline ?? false,
            reduceMotion: configuration.reduceMotion,
            columnCount: resolvedColumnCount,
            duplicateAttachTitle: configuration.terminalOpener.duplicateAttachTitle,
            openTabAccessibilityText: configuration.terminalOpener.openTabAccessibilityText,
            openShell: { [weak self] in
                self?.open(TerminalRoute(hostID: host.id, mode: .shell))
            },
            openSession: { [weak self] session in
                self?.focusOrAttach(host, session: session)
            },
            openDuplicateSession: { [weak self] session in
                self?.open(TerminalRoute(
                    hostID: host.id,
                    mode: .attach(sessionName: session.name)
                ))
            },
            requestNewSession: { [weak self] in self?.presentNewSession(on: host) },
            requestDeleteSession: { [weak self] session in
                self?.confirmDelete(session: session, on: host)
            },
            reconnect: { [weak self] model in
                guard let self else { return }
                if !self.requestKeyPassphraseIfNeeded(model) { model.refresh() }
            },
            requestPassphrase: { [weak self] model in
                _ = self?.requestKeyPassphraseIfNeeded(model)
            },
            showUnreachable: { [weak self] reason in
                self?.presentUnreachable(host: host, reason: reason)
            },
            showTmuxGuide: { [weak self] in self?.presentTmuxGuide(for: host) },
            showKeychainGuide: { [weak self] names in
                self?.presentKeychainGuide(for: host, sessionNames: names)
            },
            moveUp: { [weak self] in self?.configuration.store.moveUp(host) },
            moveDown: { [weak self] in self?.configuration.store.moveDown(host) },
            setEnabled: { [weak self] enabled in self?.setEnabled(enabled, for: host) },
            editHost: { [weak self] in self?.configuration.editHost(host) },
            removeHost: { [weak self] in self?.confirmRemove(host) },
            // The store mutation on its own animates nothing — the new order
            // only reaches the grid through the section's re-render and the
            // layout pass after it. The section therefore owns the animation
            // block (see its `droppedSession`), which is where that pass runs.
            reorderSession: { [weak self] source, target, sessions in
                self?.configuration.store.moveSession(
                    source,
                    to: target,
                    for: host.id,
                    available: sessions
                )
            },
            modelDidChange: { [weak self] in
                self?.synchronizePassphrasePrompt()
            }
        )
    }

    // MARK: Responsive grid

    private func updateColumnCount() {
        guard isViewLoaded else { return }
        let wallPadding: CGFloat = configuration.presentation == .shellRail ? 12 : 26
        let safe = configuration.shellSafeArea
        let availableWidth = max(
            0,
            view.bounds.width - wallPadding * 2 - safe.left - safe.right
        )
        availableColumnCount = FleetTileGridSizing.columnCount(
            current: availableColumnCount,
            availableWidth: availableWidth
        )
        let fullest = latestSnapshot?.hosts.filter(\.isEnabled).map { host in
            max(1, (latestSnapshot?.sessionCounts[host.id] ?? 0) + 1)
        }.max() ?? 1
        let resolved = FleetTileGridSizing.columnCount(
            availableColumns: availableColumnCount
                ?? FleetTileGridSizing.initialColumnCount(availableWidth: availableWidth),
            tileCount: fullest
        )
        guard resolvedColumnCount != resolved else { return }
        resolvedColumnCount = resolved
        propagateConfiguration()
    }

    // MARK: Feed cadence

    private func restartFeedIfNeeded(force: Bool) {
        guard isViewLoaded else { return }
        let hosts = latestSnapshot?.hosts ?? configuration.store.hosts
        let active = configuration.sceneIsActive && isOnScreen
        // `FleetFeedID` normalizes every host through
        // `connectionModelConfiguration`, so command-setup, setup-script,
        // launch-model, and tmux-conf edits (and the `updatedAt` bump any save
        // carries) deliberately keep the running feed instead of cancelling
        // every host's probe and resetting its connect-retry backoff.
        let identity = FleetFeedID(hosts: hosts, active: active)
        guard force || feedIdentity != identity else { return }
        feedTask?.cancel()
        feedTask = nil
        feedIdentity = identity
        guard active else { return }
        feedTask = Task { [weak self] in await self?.runFeed(hosts: hosts) }
    }

    private func runFeed(hosts: [Host]) async {
        for host in hosts where !host.isEnabled {
            configuration.hub.suspendModel(for: host.id)
        }
        let models = hosts.filter(\.isEnabled).map { configuration.hub.model(for: $0) }
        await withTaskGroup(of: Void.self) { group in
            for model in models {
                group.addTask { await Self.runFeed(for: model) }
            }
        }
    }

    private static func runFeed(for model: HostConnectionModel) async {
        model.resetConnectRetryBackoff()
        while !Task.isCancelled {
            guard UIApplication.shared.applicationState == .active else {
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
                continue
            }
            await model.refreshAndWait(ifStaleFor: 4)
            do { try await Task.sleep(for: feedInterval) }
            catch { return }
        }
    }

    // MARK: Actions and presentations

    private func open(_ route: TerminalRoute) {
        configuration.terminalOpener(TerminalWindowRoute(tab: route))
    }

    private func focusOrAttach(_ host: Host, session: TmuxSession) {
        if configuration.workspace.focusTab(hostID: host.id, sessionName: session.name) {
            return
        }
        open(TerminalRoute(hostID: host.id, mode: .attach(sessionName: session.name)))
    }

    private func presentNewSession(on host: Host) {
        let sessions = configuration.hub.model(for: host).tmux.sessions
        let controller = NewSessionViewController(
            host: host,
            existingNames: sessions.map(\.name)
        ) { [weak self] submission in
            self?.createSession(on: host, submission: submission)
        }
        let navigation = UINavigationController(rootViewController: controller)
        UIKitChassis.configureSheetNavigationBar(navigation.navigationBar)
        navigation.modalPresentationStyle = .formSheet
        controller.onDismiss = { [weak navigation] in navigation?.dismiss(animated: true) }
        present(navigation, animated: true)
    }

    private func createSession(on host: Host, submission: NewSessionSubmission) {
        let name = TmuxProbe.sanitizedSessionName(submission.name)
        let model = configuration.hub.model(for: host)
        Task { [weak self] in
            guard let created = await model.createSession(
                base: name,
                inDirectoryOf: nil,
                startingIn: submission.directory,
                applying: host.newSessionTmuxConf,
                running: submission.script?.normalizedBody,
                typing: submission.agent?.launchCommand(
                    model: submission.model,
                    initialPrompt: submission.initialPrompt
                )
            ) else { return }
            self?.open(TerminalRoute(
                hostID: host.id,
                mode: .attach(sessionName: created)
            ))
        }
    }

    private func confirmDelete(session: TmuxSession, on host: Host) {
        let alert = UIAlertController(
            title: "Delete Session",
            message: "Kills “\(session.name)” on \(host.name) and everything running in it.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            let model = self.configuration.hub.model(for: host)
            Task { await model.killSession(session) }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func confirmRemove(_ host: Host) {
        let alert = UIAlertController(
            title: "Remove Host",
            message: "Removes “\(host.name)” and its saved secret from this device and your synced devices. tmux sessions on the host keep running.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.configuration.hub.dropModel(for: host.id)
            self.configuration.store.remove(host)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func presentUnreachable(host: Host, reason: String) {
        let alert = UIAlertController(
            title: "\(host.name) Unreachable",
            message: reason,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    private func presentTmuxGuide(for host: Host) {
        let controller = TmuxInstallViewController(host: host)
        controller.followAppAppearance(configuration.themes, presentedFrom: self)
        let navigation = UINavigationController(rootViewController: controller)
        UIKitChassis.configureSheetNavigationBar(navigation.navigationBar)
        navigation.modalPresentationStyle = .formSheet
        controller.onDone = { [weak navigation] in navigation?.dismiss(animated: true) }
        present(navigation, animated: true)
    }

    private func presentKeychainGuide(for host: Host, sessionNames: [String]) {
        let controller = KeychainUnlockViewController(host: host, sessionNames: sessionNames)
        controller.followAppAppearance(configuration.themes, presentedFrom: self)
        let navigation = UINavigationController(rootViewController: controller)
        UIKitChassis.configureSheetNavigationBar(navigation.navigationBar)
        navigation.modalPresentationStyle = .formSheet
        controller.onDone = { [weak navigation] in navigation?.dismiss(animated: true) }
        present(navigation, animated: true)
    }

    private func setEnabled(_ enabled: Bool, for host: Host) {
        configuration.store.setEnabled(enabled, for: host.id)
        if !enabled { configuration.hub.suspendModel(for: host.id) }
    }

    @discardableResult
    private func requestKeyPassphraseIfNeeded(_ model: HostConnectionModel) -> Bool {
        guard model.keyPassphraseChallenge != nil else { return false }
        if model.requestKeyPassphrase() != nil {
            keyPassphraseHostID = model.host.id
            observeWall()
        }
        return true
    }

    private func synchronizePassphrasePrompt(
        challenge explicitChallenge: SSHKeyPassphraseChallenge? = nil
    ) {
        let challenge: SSHKeyPassphraseChallenge?
        if let explicitChallenge {
            challenge = explicitChallenge
        } else if let keyPassphraseHostID,
                  let host = configuration.store.host(id: keyPassphraseHostID) {
            challenge = configuration.hub.model(for: host).keyPassphraseChallenge
        } else {
            challenge = nil
        }
        passphrasePresenter.update(
            challenge: challenge,
            onSubmit: { [weak self] challenge, passphrase, saveToICloud in
                guard let self else { return }
                SSHKeyPassphraseSession.accept(
                    passphrase,
                    for: challenge.hostID,
                    saveToICloud: saveToICloud
                )
                self.configuration.hub.resumeConnectionsWaitingForKeyPassphrase(
                    hostID: challenge.hostID
                )
                self.configuration.workspace.resumeConnectionsWaitingForKeyPassphrase(
                    hostID: challenge.hostID
                )
                self.keyPassphraseHostID = nil
                self.observeWall()
            },
            onCancel: { [weak self] _ in
                self?.keyPassphraseHostID = nil
                self?.observeWall()
            }
        )
    }
}

// MARK: - Header

private struct FleetHeaderActions {
    let addHost: () -> Void
    let openFAQ: () -> Void
    let openSettings: () -> Void
}

@MainActor
private final class FleetHeaderView: UIView {
    private enum CompactLayout: Equatable {
        case summaryAndCaptions
        case captions
        case icons
    }

    private let standardTitleLabel = UIKitChassisLabel("Multiplex", size: 15)
    private let railTitleLabel = UIKitChassisLabel("Multiplex", size: 13)
    private let summaryLabel = UILabel()
    private var addChip: UIKitChassisChip!
    private var faqChip: UIKitChassisChip!
    private var settingsChip: UIKitChassisChip!
    private let stack = UIStackView()
    private var presentation: FleetWall.Presentation = .standard
    private var actions = FleetHeaderActions(addHost: {}, openFAQ: {}, openSettings: {})
    private var topConstraint: NSLayoutConstraint?
    private var bottomConstraint: NSLayoutConstraint?
    private var compactLayout = CompactLayout.captions
    private var compactLabeledMinimumWidth: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addChip = UIKitChassisChip(
            "HOST",
            systemImage: "plus",
            accessibilityLabel: "Add host"
        ) { [weak self] in self?.actions.addHost() }
        faqChip = UIKitChassisChip(
            "FAQ",
            systemImage: "questionmark",
            accessibilityLabel: "Frequently asked questions"
        ) { [weak self] in self?.actions.openFAQ() }
        settingsChip = UIKitChassisChip(
            "SETTINGS",
            systemImage: "gearshape",
            accessibilityLabel: "Settings"
        ) { [weak self] in self?.actions.openSettings() }
        summaryLabel.font = UIKitChassis.monoFont(11)
        summaryLabel.textColor = UIKitChassis.signal2
        summaryLabel.numberOfLines = 1
        summaryLabel.adjustsFontSizeToFitWidth = true
        summaryLabel.minimumScaleFactor = 0.75
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        standardTitleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        railTitleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        topConstraint = stack.topAnchor.constraint(equalTo: topAnchor)
        bottomConstraint = stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            topConstraint!,
            bottomConstraint!,
        ])
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(
        presentation: FleetWall.Presentation,
        summary: String,
        actions: FleetHeaderActions
    ) {
        self.presentation = presentation
        self.actions = actions
        setSummary(summary)
        standardTitleLabel.setText("Multiplex")
        railTitleLabel.setText("Multiplex")
        rebuild()
        setNeedsLayout()
    }

    func setSummary(_ summary: String) {
        summaryLabel.text = summary
        summaryLabel.accessibilityLabel = summary
        if presentation == .shellCompact {
            setNeedsLayout()
        }
    }

    func setTopInset(_ inset: CGFloat) {
        topConstraint?.constant = inset
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard presentation == .shellCompact else { return }
        let labeledWidth = compactLabeledMinimumWidth ?? measureCompactLabeledWidth()
        compactLabeledMinimumWidth = labeledWidth
        let summaryWidth = summaryLabel.intrinsicContentSize.width + stack.spacing
        let resolved: CompactLayout
        if labeledWidth + summaryWidth <= bounds.width {
            resolved = .summaryAndCaptions
        } else if labeledWidth <= bounds.width {
            resolved = .captions
        } else {
            resolved = .icons
        }
        applyCompactLayout(resolved)
    }

    /// Mirrors the old SwiftUI `ViewThatFits` candidates. The flexible spacer
    /// has no intrinsic width, while every visible arranged view contributes
    /// one stack gap. Measuring the actual native labels and chips keeps the
    /// phone on the captioned candidate for as long as it genuinely fits.
    private func measureCompactLabeledWidth() -> CGFloat {
        applyCompactLayout(.captions)
        return standardTitleLabel.intrinsicContentSize.width
            + addChip.intrinsicContentSize.width
            + faqChip.intrinsicContentSize.width
            + settingsChip.intrinsicContentSize.width
            + stack.spacing * 4
    }

    private func applyCompactLayout(_ layout: CompactLayout) {
        guard compactLayout != layout || compactLabeledMinimumWidth == nil else { return }
        compactLayout = layout
        let iconsOnly = layout == .icons
        summaryLabel.isHidden = layout != .summaryAndCaptions
        addChip.setContent(caption: iconsOnly ? "" : "HOST", systemImage: "plus")
        faqChip.setContent(caption: iconsOnly ? "" : "FAQ", systemImage: "questionmark")
        settingsChip.setContent(
            caption: iconsOnly ? "" : "SETTINGS",
            systemImage: "gearshape"
        )
    }

    private func rebuild() {
        compactLabeledMinimumWidth = nil
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        switch presentation {
        case .shellRail:
            summaryLabel.font = UIKitChassis.monoFont(8.5)
            summaryLabel.isHidden = false
            stack.spacing = 8
            addChip.setContent(caption: "", systemImage: "plus")
            faqChip.setContent(caption: "", systemImage: "questionmark")
            settingsChip.setContent(caption: "", systemImage: "gearshape")
            bottomConstraint?.constant = -12
        case .shellCompact, .standard:
            summaryLabel.font = UIKitChassis.monoFont(11)
            stack.spacing = 10
            addChip.setContent(caption: "HOST", systemImage: "plus")
            faqChip.setContent(caption: "FAQ", systemImage: "questionmark")
            settingsChip.setContent(caption: "SETTINGS", systemImage: "gearshape")
            summaryLabel.isHidden = presentation == .shellCompact
            compactLayout = .captions
            bottomConstraint?.constant = -16
        }
        stack.addArrangedSubview(
            presentation == .shellRail ? railTitleLabel : standardTitleLabel
        )
        stack.addArrangedSubview(UIView())
        stack.addArrangedSubview(summaryLabel)
        stack.addArrangedSubview(addChip)
        stack.addArrangedSubview(faqChip)
        stack.addArrangedSubview(settingsChip)
    }
}

// MARK: - Host section

@MainActor
private struct FleetHostSectionConfiguration {
    let store: HostStore
    let workspace: TerminalWorkspace
    var presentation: FleetWall.Presentation
    var selectedTerminal: TerminalRoute?
    var networkOffline: Bool
    var reduceMotion: Bool
    var columnCount: Int
    var duplicateAttachTitle: String
    var openTabAccessibilityText: String
    var openShell: () -> Void
    var openSession: (TmuxSession) -> Void
    var openDuplicateSession: (TmuxSession) -> Void
    var requestNewSession: () -> Void
    var requestDeleteSession: (TmuxSession) -> Void
    var reconnect: (HostConnectionModel) -> Void
    var requestPassphrase: (HostConnectionModel) -> Void
    var showUnreachable: (String) -> Void
    var showTmuxGuide: () -> Void
    var showKeychainGuide: ([String]) -> Void
    var moveUp: () -> Void
    var moveDown: () -> Void
    var setEnabled: (Bool) -> Void
    var editHost: () -> Void
    var removeHost: () -> Void
    var reorderSession: (String, String, [TmuxSession]) -> Void
    var modelDidChange: () -> Void
}

@MainActor
private final class FleetHostSectionView: UIView {
    private struct Snapshot: Equatable {
        let phase: HostConnectionModel.Phase
        let tmux: TmuxState
        let keyPassphraseChallenge: SSHKeyPassphraseChallenge?
        let hasLiveProbe: Bool
        let miniatures: [String: [String]]
        let attention: [String: PaneAgentState]
        let keychainNotice: KeychainLockNotice?
        let openSessionNames: Set<String>
        let orderedSessions: [TmuxSession]
    }

    private enum GridIdentity: Equatable {
        case unknown
        case probing
        case sessions([String])
        case noServer
        case tmuxMissing
        case failed
    }

    private struct RailIdentity: Equatable {
        let hostID: UUID
        let hostName: String
        let hostAddress: String
        let hostUsesMosh: Bool
        let hostIsEnabled: Bool
        let phase: HostConnectionModel.Phase?
        let keyPassphraseRequired: Bool
        let keychainNotice: KeychainLockNotice?
        let networkOffline: Bool
        let presentation: FleetWall.Presentation
        let reduceMotion: Bool
        let canMoveUp: Bool
        let canMoveDown: Bool
    }

    private let stack = UIStackView()
    private let rail = FleetHostRailView()
    private let grid = FleetTileGridView()
    private var host: Host
    private var model: HostConnectionModel?
    private var configuration: FleetHostSectionConfiguration
    private var observationGeneration = 0
    private var currentSnapshot: Snapshot?
    private var renderedRailIdentity: RailIdentity?
    private var tileViews: [String: UIView] = [:]

    init(
        host: Host,
        model: HostConnectionModel?,
        configuration: FleetHostSectionConfiguration
    ) {
        self.host = host
        self.model = model
        self.configuration = configuration
        super.init(frame: .zero)

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.addArrangedSubview(rail)
        stack.addArrangedSubview(grid)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
        ])
        observeModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func update(
        host: Host,
        model: HostConnectionModel?,
        configuration: FleetHostSectionConfiguration
    ) {
        let modelChanged = self.model !== model
        self.host = host
        self.model = model
        self.configuration = configuration
        grid.columnCount = configuration.columnCount
        grid.centersGrid = configuration.presentation == .shellCompact
            || configuration.columnCount == 1
        if modelChanged {
            observeModel()
        } else {
            render(currentSnapshot)
        }
    }

    func stopObserving() {
        observationGeneration += 1
    }

    private func observeModel() {
        observationGeneration += 1
        let generation = observationGeneration
        guard let model else {
            currentSnapshot = nil
            render(nil)
            return
        }
        let snapshot = withObservationTracking {
            let sessions = model.tmux.sessions
            return Snapshot(
                phase: model.phase,
                tmux: model.tmux,
                keyPassphraseChallenge: model.keyPassphraseChallenge,
                hasLiveProbe: model.hasLiveProbe,
                miniatures: model.miniatures,
                attention: model.attention,
                keychainNotice: model.keychainNotice,
                openSessionNames: Set(sessions.compactMap { session in
                    configuration.workspace.hasTab(
                        hostID: host.id,
                        sessionName: session.name
                    ) ? session.name : nil
                }),
                orderedSessions: configuration.store.orderedSessions(
                    sessions,
                    for: host.id
                )
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.observeModel()
            }
        }
        let previousIdentity = currentSnapshot.map { gridIdentity(for: $0.tmux) }
        currentSnapshot = snapshot
        let identity = gridIdentity(for: snapshot.tmux)
        if !configuration.reduceMotion,
           let previousIdentity,
           previousIdentity != identity {
            UIView.transition(
                with: grid,
                duration: 0.3,
                options: [.transitionCrossDissolve, .beginFromCurrentState],
                animations: { [weak self] in
                self?.render(snapshot)
                self?.grid.layoutIfNeeded()
                }
            )
        } else {
            render(snapshot)
        }
        configuration.modelDidChange()
    }

    private func gridIdentity(for state: TmuxState) -> GridIdentity {
        switch state {
        case .unknown: .unknown
        case .probing: .probing
        case .sessions(let sessions): .sessions(sessions.map(\.name))
        case .noServer: .noServer
        case .tmuxMissing: .tmuxMissing
        case .failed: .failed
        }
    }

    private func render(_ snapshot: Snapshot?) {
        let connected = snapshot?.phase == .connected
        let canMoveUp = configuration.store.canMoveUp(host)
        let canMoveDown = configuration.store.canMoveDown(host)
        let railIdentity = RailIdentity(
            hostID: host.id,
            hostName: host.name,
            hostAddress: host.address,
            hostUsesMosh: host.useMosh,
            hostIsEnabled: host.isEnabled,
            phase: snapshot?.phase,
            keyPassphraseRequired: snapshot?.keyPassphraseChallenge != nil,
            keychainNotice: snapshot?.keychainNotice,
            networkOffline: configuration.networkOffline,
            presentation: configuration.presentation,
            reduceMotion: configuration.reduceMotion,
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown
        )
        rail.updateActions(
            openShell: { [weak self] in self?.configuration.openShell() },
            requestPassphrase: { [weak self] in
                guard let self, let model = self.model else { return }
                self.configuration.requestPassphrase(model)
            },
            showUnreachable: { [weak self] reason in
                self?.configuration.showUnreachable(reason)
            },
            showKeychainGuide: { [weak self] names in
                self?.configuration.showKeychainGuide(names)
            }
        )
        if renderedRailIdentity != railIdentity {
            renderedRailIdentity = railIdentity
            rail.configure(
                host: host,
                phase: snapshot?.phase,
                keyPassphraseRequired: snapshot?.keyPassphraseChallenge != nil,
                keychainNotice: snapshot?.keychainNotice,
                connected: connected,
                networkOffline: configuration.networkOffline,
                presentation: configuration.presentation,
                reduceMotion: configuration.reduceMotion,
                canMoveUp: canMoveUp,
                canMoveDown: canMoveDown,
                menu: hostMenu,
                openShell: { [weak self] in self?.configuration.openShell() },
                requestPassphrase: { [weak self] in
                    guard let self, let model = self.model else { return }
                    self.configuration.requestPassphrase(model)
                },
                showUnreachable: { [weak self] reason in
                    self?.configuration.showUnreachable(reason)
                },
                showKeychainGuide: { [weak self] names in
                    self?.configuration.showKeychainGuide(names)
                }
            )
        }

        grid.columnCount = configuration.columnCount
        grid.centersGrid = configuration.presentation == .shellCompact
            || configuration.columnCount == 1

        guard host.isEnabled, let model, let snapshot else {
            let tile = reusableSpecialTile(key: "disabled") { FleetNoSignalTileView() }
                as! FleetNoSignalTileView
            tile.configure(
                host: host,
                mode: .disabled,
                compact: configuration.presentation == .shellRail,
                action: { [weak self] in self?.configuration.setEnabled(true) }
            )
            grid.setItems([FleetGridItem(id: "disabled", view: tile)])
            pruneTiles(keeping: ["disabled"])
            return
        }

        switch snapshot.tmux {
        case .sessions(let sessions):
            let ordered = snapshot.orderedSessions
            var items: [FleetGridItem] = []
            let newTile = reusableSpecialTile(key: "new") { FleetNewSessionTileView() }
                as! FleetNewSessionTileView
            newTile.configure(
                hostName: host.name,
                compact: configuration.presentation == .shellRail,
                action: configuration.requestNewSession
            )
            items.append(FleetGridItem(id: "new", view: newTile))
            for session in ordered {
                let key = "session:\(session.name)"
                let tile: FleetSessionTileView
                if let existing = tileViews[key] as? FleetSessionTileView {
                    tile = existing
                } else {
                    tile = FleetSessionTileView()
                    tileViews[key] = tile
                }
                tile.configure(FleetSessionTileConfiguration(
                    hostID: host.id,
                    session: session,
                    lines: snapshot.miniatures[session.name] ?? [],
                    attention: snapshot.attention[session.name],
                    hasLiveAgentState: snapshot.hasLiveProbe,
                    hasOpenTab: snapshot.openSessionNames.contains(session.name),
                    compact: configuration.presentation == .shellRail,
                    selected: configuration.selectedTerminal?.hostID == host.id
                        && configuration.selectedTerminal?.sessionName == session.name,
                    duplicateAttachTitle: configuration.duplicateAttachTitle,
                    openTabAccessibilityText: configuration.openTabAccessibilityText,
                    attach: { [weak self] in self?.configuration.openSession(session) },
                    attachNewWindow: { [weak self] in
                        self?.configuration.openDuplicateSession(session)
                    },
                    delete: { [weak self] in
                        self?.configuration.requestDeleteSession(session)
                    },
                    droppedSession: { [weak self] source in
                        guard let self else { return }
                        let move = {
                            self.configuration.reorderSession(source, session.name, sessions)
                            // Session order is device-local HostStore state,
                            // not a probe change. Re-arm its Observation read
                            // now so the native grid settles immediately after
                            // the drop — and run the grid's layout pass inside
                            // the animation block, since that pass is the only
                            // thing that moves a tile.
                            self.observeModel()
                            self.grid.layoutIfNeeded()
                        }
                        if self.configuration.reduceMotion {
                            move()
                        } else {
                            UIView.animate(
                                withDuration: 0.32,
                                delay: 0,
                                usingSpringWithDamping: 1,
                                initialSpringVelocity: 0,
                                options: [.beginFromCurrentState],
                                animations: move
                            )
                        }
                    }
                ))
                items.append(FleetGridItem(id: key, view: tile))
            }
            grid.setItems(items)
            pruneTiles(keeping: Set(items.map(\.id)))
        case .noServer:
            let tile = reusableSpecialTile(key: "new") { FleetNewSessionTileView() }
                as! FleetNewSessionTileView
            tile.configure(
                hostName: host.name,
                compact: configuration.presentation == .shellRail,
                action: configuration.requestNewSession
            )
            grid.setItems([FleetGridItem(id: "new", view: tile)])
            pruneTiles(keeping: ["new"])
        case .tmuxMissing:
            let tile = reusableSpecialTile(key: "tmux") { FleetTmuxMissingTileView() }
                as! FleetTmuxMissingTileView
            tile.configure(
                compact: configuration.presentation == .shellRail,
                action: configuration.showTmuxGuide
            )
            grid.setItems([FleetGridItem(id: "tmux", view: tile)])
            pruneTiles(keeping: ["tmux"])
        case .failed:
            let tile = reusableSpecialTile(key: "failed") { FleetNoSignalTileView() }
                as! FleetNoSignalTileView
            tile.configure(
                host: host,
                mode: snapshot.keyPassphraseChallenge == nil ? .unreachable : .passphrase,
                compact: configuration.presentation == .shellRail,
                action: { [weak self, weak model] in
                    guard let self, let model else { return }
                    self.configuration.reconnect(model)
                }
            )
            grid.setItems([FleetGridItem(id: "failed", view: tile)])
            pruneTiles(keeping: ["failed"])
        case .unknown, .probing:
            let tile = reusableSpecialTile(key: "acquiring") { FleetAcquiringTileView() }
                as! FleetAcquiringTileView
            tile.configure(compact: configuration.presentation == .shellRail)
            grid.setItems([FleetGridItem(id: "acquiring", view: tile)])
            pruneTiles(keeping: ["acquiring"])
        }
    }

    private var hostMenu: UIMenu {
        let moveUp = UIAction(
            title: "Move Up",
            image: UIImage(systemName: "arrow.up"),
            attributes: configuration.store.canMoveUp(host) ? [] : [.disabled]
        ) { [weak self] _ in self?.configuration.moveUp() }
        let moveDown = UIAction(
            title: "Move Down",
            image: UIImage(systemName: "arrow.down"),
            attributes: configuration.store.canMoveDown(host) ? [] : [.disabled]
        ) { [weak self] _ in self?.configuration.moveDown() }
        let enabled = UIAction(
            title: host.isEnabled ? "Disable Host" : "Enable Host",
            image: UIImage(systemName: host.isEnabled ? "pause.circle" : "play.circle")
        ) { [weak self] _ in
            guard let self else { return }
            self.configuration.setEnabled(!self.host.isEnabled)
        }
        let edit = UIAction(title: "Edit Host…") { [weak self] _ in
            self?.configuration.editHost()
        }
        let remove = UIAction(title: "Remove Host…", attributes: .destructive) {
            [weak self] _ in self?.configuration.removeHost()
        }
        return UIMenu(children: [
            moveUp,
            moveDown,
            UIMenu(options: .displayInline, children: [enabled, edit, remove]),
        ])
    }

    private func reusableSpecialTile(
        key: String,
        make: () -> UIView
    ) -> UIView {
        if let existing = tileViews[key] { return existing }
        let view = make()
        tileViews[key] = view
        return view
    }

    private func pruneTiles(keeping ids: Set<String>) {
        for key in Array(tileViews.keys) where !ids.contains(key) {
            tileViews.removeValue(forKey: key)
        }
    }
}

// MARK: - Host rail

@MainActor
private final class FleetHostRailView: UIView, UIContextMenuInteractionDelegate {
    private struct PresentationIdentity: Equatable {
        let hostID: UUID
        let hostName: String
        let hostAddress: String
        let hostUsesMosh: Bool
        let hostIsEnabled: Bool
        let phase: HostConnectionModel.Phase?
        let keyPassphraseRequired: Bool
        let keychainNotice: KeychainLockNotice?
        let connected: Bool
        let networkOffline: Bool
        let presentation: FleetWall.Presentation
        let reduceMotion: Bool
        let canMoveUp: Bool
        let canMoveDown: Bool
    }

    private let stack = UIStackView()
    private var menu = UIMenu()
    private var renderedIdentity: PresentationIdentity?
    private var openShell: () -> Void = {}
    private var requestPassphrase: () -> Void = {}
    private var showUnreachable: (String) -> Void = { _ in }
    private var showKeychainGuide: ([String]) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(
        host: Host,
        phase: HostConnectionModel.Phase?,
        keyPassphraseRequired: Bool,
        keychainNotice: KeychainLockNotice?,
        connected: Bool,
        networkOffline: Bool,
        presentation: FleetWall.Presentation,
        reduceMotion: Bool,
        canMoveUp: Bool,
        canMoveDown: Bool,
        menu: UIMenu,
        openShell: @escaping () -> Void,
        requestPassphrase: @escaping () -> Void,
        showUnreachable: @escaping (String) -> Void,
        showKeychainGuide: @escaping ([String]) -> Void
    ) {
        updateActions(
            openShell: openShell,
            requestPassphrase: requestPassphrase,
            showUnreachable: showUnreachable,
            showKeychainGuide: showKeychainGuide
        )
        let identity = PresentationIdentity(
            hostID: host.id,
            hostName: host.name,
            hostAddress: host.address,
            hostUsesMosh: host.useMosh,
            hostIsEnabled: host.isEnabled,
            phase: phase,
            keyPassphraseRequired: keyPassphraseRequired,
            keychainNotice: keychainNotice,
            connected: connected,
            networkOffline: networkOffline,
            presentation: presentation,
            reduceMotion: reduceMotion,
            canMoveUp: canMoveUp,
            canMoveDown: canMoveDown
        )
        guard renderedIdentity != identity else { return }
        renderedIdentity = identity
        self.menu = menu
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = presentation == .shellRail ? 8 : 10

        let rule = UIView()
        rule.backgroundColor = UIKitChassis.bezel
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(rule)

        let name = UIKitChassisLabel(
            host.name,
            size: presentation == .shellRail ? 11 : 12,
            color: host.isEnabled ? UIKitChassis.signal : UIKitChassis.signal3
        )
        let address = UILabel()
        address.font = UIKitChassis.monoFont(presentation == .shellRail ? 9.5 : 11)
        address.textColor = UIKitChassis.signal2
        address.text = host.address
        address.numberOfLines = presentation == .shellRail ? 1 : 2
        address.lineBreakMode = .byTruncatingTail
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let mosh = FleetBadgeView(caption: "MOSH")
        mosh.accessibilityLabel = "Connects over mosh"
        mosh.isHidden = !host.useMosh
        let status = makeStatus(
            host: host,
            phase: phase,
            keyPassphraseRequired: keyPassphraseRequired,
            keychainNotice: keychainNotice,
            networkOffline: networkOffline,
            reduceMotion: reduceMotion,
            requestPassphrase: { [weak self] in self?.requestPassphrase() },
            showUnreachable: { [weak self] reason in self?.showUnreachable(reason) },
            showKeychainGuide: { [weak self] names in self?.showKeychainGuide(names) }
        )
        let shell = UIKitChassisChip(
            "SHELL",
            accessibilityLabel: "Open shell on \(host.name)",
            action: { [weak self] in self?.openShell() }
        )
        shell.alpha = connected ? 1 : 0
        shell.isUserInteractionEnabled = connected
        shell.accessibilityElementsHidden = !connected
        let menuButton = FleetMenuBadgeButton()
        menuButton.menu = menu
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.accessibilityLabel = "Host options for \(host.name)"

        if presentation == .shellRail {
            let first = UIStackView(arrangedSubviews: [name, UIView(), status, menuButton])
            first.axis = .horizontal
            first.alignment = .center
            first.spacing = 8
            let second = UIStackView(arrangedSubviews: [address, mosh, UIView(), shell])
            second.axis = .horizontal
            second.alignment = .center
            second.spacing = 8
            stack.addArrangedSubview(first)
            stack.addArrangedSubview(second)
        } else {
            let controls = FleetHostControlsRow(
                status: status,
                shell: shell,
                menuButton: menuButton
            )
            let row = UIStackView(arrangedSubviews: [
                name, address, mosh, UIView(), controls,
            ])
            row.axis = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 14
            stack.addArrangedSubview(row)
        }
        accessibilityLabel = "\(host.name), \(host.address)"
    }

    func updateActions(
        openShell: @escaping () -> Void,
        requestPassphrase: @escaping () -> Void,
        showUnreachable: @escaping (String) -> Void,
        showKeychainGuide: @escaping ([String]) -> Void
    ) {
        self.openShell = openShell
        self.requestPassphrase = requestPassphrase
        self.showUnreachable = showUnreachable
        self.showKeychainGuide = showKeychainGuide
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menu
        }
    }

    private func makeStatus(
        host: Host,
        phase: HostConnectionModel.Phase?,
        keyPassphraseRequired: Bool,
        keychainNotice: KeychainLockNotice?,
        networkOffline: Bool,
        reduceMotion: Bool,
        requestPassphrase: @escaping () -> Void,
        showUnreachable: @escaping (String) -> Void,
        showKeychainGuide: @escaping ([String]) -> Void
    ) -> UIView {
        if !host.isEnabled {
            return FleetRailStatusView(
                text: "DISABLED",
                dotColor: TallyPalette.signal3,
                textColor: UIKitChassis.signal3,
                accessibilityLabel: "\(host.name) is disabled and is not being connected"
            )
        }
        if networkOffline {
            return FleetRailStatusView(
                text: "OFFLINE",
                dotColor: TallyPalette.signal3,
                textColor: UIKitChassis.signal3,
                accessibilityLabel: "This device has no network connection"
            )
        }
        guard let phase else {
            return FleetRailStatusView(
                text: "STANDBY",
                dotColor: nil,
                textColor: UIKitChassis.signal3,
                accessibilityLabel: "Standby"
            )
        }
        switch phase {
        case .connected:
            if let keychainNotice {
                return FleetRailStatusView(
                    text: "KEYCHAIN LOCKED",
                    dotColor: TallyPalette.caution,
                    textColor: TallyPalette.caution,
                    accessibilityLabel: "\(host.name): the Mac's keychain is locked, so Claude Code shows signed out",
                    accessibilityHint: "Shows how to unlock the keychain",
                    action: { showKeychainGuide(keychainNotice.sessionNames) }
                )
            }
            return FleetRailStatusView(
                text: "CONNECTED",
                dotColor: TallyPalette.ok,
                textColor: UIKitChassis.signal2,
                accessibilityLabel: "\(host.name) connected"
            )
        case .connecting:
            return FleetRailStatusView(
                text: "LINKING",
                dotColor: UIKitChassis.signal2,
                textColor: UIKitChassis.signal2,
                accessibilityLabel: "\(host.name) linking",
                pulsing: !reduceMotion
            )
        case .failed(let reason):
            if keyPassphraseRequired {
                return FleetRailStatusView(
                    text: "NEEDS PASSPHRASE",
                    dotColor: TallyPalette.caution,
                    textColor: TallyPalette.caution,
                    accessibilityLabel: "\(host.name) needs its SSH key passphrase",
                    accessibilityHint: "Opens the SSH key passphrase prompt",
                    action: requestPassphrase
                )
            }
            return FleetRailStatusView(
                text: "UNREACHABLE",
                dotColor: TallyPalette.signal3,
                textColor: UIKitChassis.signal3,
                accessibilityLabel: "\(host.name) unreachable",
                accessibilityHint: "Shows why the host could not be reached",
                action: { showUnreachable(reason) }
            )
        case .idle:
            return FleetRailStatusView(
                text: "STANDBY",
                dotColor: nil,
                textColor: UIKitChassis.signal3,
                accessibilityLabel: "\(host.name) standby"
            )
        }
    }
}

@MainActor
private final class FleetHostControlsRow: UIStackView {
    private let baselineSource: UIView

    init(status: UIView, shell: UIView, menuButton: UIView) {
        baselineSource = status
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = 14
        addArrangedSubview(status)
        addArrangedSubview(shell)
        addArrangedSubview(menuButton)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("unused") }

    /// The legacy first-text-baseline row aligned its labels while centering
    /// the three trailing faces. Forward the status baseline to the outer row
    /// without asking the differently sized faces to invent matching baselines.
    override var forFirstBaselineLayout: UIView { baselineSource }
    override var forLastBaselineLayout: UIView { baselineSource }
}

@MainActor
private final class FleetRailStatusView: UIView {
    private var action: (() -> Void)?
    private let label = UILabel()

    init(
        text: String,
        dotColor: UIColor?,
        textColor: UIColor,
        accessibilityLabel: String,
        accessibilityHint: String? = nil,
        pulsing: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.action = action
        super.init(frame: .zero)
        label.font = UIKitChassis.monoFont(9)
        label.textColor = textColor
        label.attributedText = NSAttributedString(
            string: text,
            attributes: [.kern: 1.0, .foregroundColor: textColor]
        )
        var views: [UIView] = []
        if let dotColor {
            let dot = FleetColorDotView(color: dotColor, diameter: 6)
            views.append(dot)
            if pulsing {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 1
                animation.toValue = 0.25
                animation.duration = 0.7
                animation.autoreverses = true
                animation.repeatCount = .infinity
                dot.layer.add(animation, forKey: "fleet-pulse")
            }
        }
        views.append(label)
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 12 * Theme.typeScale),
        ])
        isAccessibilityElement = true
        accessibilityTraits = action == nil ? [.staticText] : [.button]
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        if action != nil {
            hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(pressed)))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var forFirstBaselineLayout: UIView { label }
    override var forLastBaselineLayout: UIView { label }

    override func accessibilityActivate() -> Bool {
        action?()
        return action != nil
    }

    @objc private func pressed() { action?() }
}

@MainActor
private final class FleetMenuBadgeButton: UIButton {
    private static var iconSlot: CGFloat { 10 * Theme.typeScale }

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: ceil(Self.iconSlot + 18),
            height: ceil(Self.iconSlot + 10)
        )
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setImage(
            UIImage(
                systemName: "ellipsis",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 9 * Theme.typeScale,
                    weight: .semibold
                )
            ),
            for: .normal
        )
        tintColor = UIKitChassis.signal2
        backgroundColor = UIKitChassis.chassis
        layer.borderWidth = 1
        refreshBorder()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (button: FleetMenuBadgeButton, _: UITraitCollection) in
            button.refreshBorder()
        }
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        imageView?.contentMode = .scaleAspectFit
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView?.frame = CGRect(
            x: (bounds.width - Self.iconSlot) / 2,
            y: (bounds.height - Self.iconSlot) / 2,
            width: Self.iconSlot,
            height: Self.iconSlot
        ).integral
    }

    private func refreshBorder() {
        layer.borderColor = UIKitChassis.bezelHi.resolvedColor(with: traitCollection).cgColor
    }
}

// MARK: - Responsive tile grid

private struct FleetGridItem {
    let id: String
    let view: UIView
}

@MainActor
private final class FleetTileGridView: UIView {
    var columnCount = 1 {
        didSet {
            columnCount = max(1, columnCount)
            if oldValue != columnCount { invalidateLayout() }
        }
    }
    var centersGrid = true {
        didSet { if oldValue != centersGrid { invalidateLayout() } }
    }

    private var items: [FleetGridItem] = []
    private var cachedHeight: CGFloat = 150

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: cachedHeight)
    }

    func setItems(_ items: [FleetGridItem]) {
        let keep = Set(items.map(\.id))
        for old in self.items where !keep.contains(old.id) {
            old.view.removeFromSuperview()
        }
        self.items = items
        for item in items where item.view.superview !== self {
            addSubview(item.view)
        }
        invalidateLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, !items.isEmpty else {
            updateHeight(0)
            return
        }
        let columns = max(1, columnCount)
        let gutter = FleetTileGridSizing.gutter
        let preferredGridWidth = FleetTileGridSizing.requiredWidth(
            columnCount: columns,
            tileWidth: FleetTileGridSizing.preferredTileWidth
        )
        let gridWidth = min(bounds.width, preferredGridWidth)
        let tileWidth = max(0, (gridWidth - CGFloat(columns - 1) * gutter) / CGFloat(columns))
        let originX = (centersGrid || columns == 1) ? max(0, (bounds.width - gridWidth) / 2) : 0
        var y: CGFloat = 0
        var index = 0
        while index < items.count {
            let end = min(index + columns, items.count)
            let row = items[index..<end]
            var heights: [CGFloat] = []
            for item in row {
                // Tiles are framed by hand, so their autoresizing masks stay
                // translated and UIKit synthesizes REQUIRED width/height
                // constraints from whatever frame they carry right now —
                // .zero for a tile added in this pass. Measuring against that
                // at a required fitting width is unsatisfiable, and the engine
                // resolves it by breaking the tile's own required content pins
                // instead: the labels solve to zero size at the tile's
                // top-left over an empty ground. Seed the real width first,
                // and leave the fitting width non-required so any residual
                // conflict degrades this measurement, never the tile's
                // internal layout.
                item.view.frame.size.width = tileWidth
                let size = item.view.systemLayoutSizeFitting(
                    CGSize(width: tileWidth, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .defaultHigh,
                    verticalFittingPriority: .fittingSizeLevel
                )
                heights.append(max(1, ceil(size.height)))
            }
            let rowHeight = heights.max() ?? 1
            for (offset, item) in row.enumerated() {
                item.view.frame = CGRect(
                    x: originX + CGFloat(offset) * (tileWidth + gutter),
                    y: y,
                    width: tileWidth,
                    height: rowHeight
                )
            }
            y += rowHeight
            index = end
            if index < items.count { y += gutter }
        }
        updateHeight(y)
    }

    private func invalidateLayout() {
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }

    private func updateHeight(_ height: CGFloat) {
        guard abs(cachedHeight - height) > 0.5 else { return }
        cachedHeight = height
        invalidateIntrinsicContentSize()
    }
}

// MARK: - Shared tile primitives

@MainActor
class FleetPressView: UIKitTallyBorderedView, UIContextMenuInteractionDelegate {
    var pressAction: (() -> Void)?
    var menuProvider: (() -> UIMenu?)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 4))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(pressed)))
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    override func accessibilityActivate() -> Bool {
        pressAction?()
        return pressAction != nil
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard menuProvider?() != nil else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
            [weak self] _ in self?.menuProvider?()
        }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(rect: bounds)
        return UITargetedPreview(view: self, parameters: parameters)
    }

    @objc private func pressed() { pressAction?() }
}

@MainActor
private final class FleetBadgeView: UIKitTallyBorderedView {
    private let label = UILabel()
    private let imageView = UIImageView()

    init(caption: String = "", systemImage: String? = nil, prominent: Bool = false) {
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.chassis
        let stack = UIStackView(arrangedSubviews: [imageView, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 5
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = prominent ? UIKitChassis.signal : UIKitChassis.signal2
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        label.font = UIKitChassis.monoFont(8, weight: .semibold)
        label.textColor = prominent ? UIKitChassis.signal : UIKitChassis.signal2
        label.numberOfLines = 1
        configure(caption: caption, systemImage: systemImage, prominent: prominent)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(caption: String, systemImage: String? = nil, prominent: Bool = false) {
        label.text = caption
        imageView.isHidden = systemImage == nil
        imageView.image = systemImage.flatMap {
            UIImage(
                systemName: $0,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 8 * Theme.typeScale,
                    weight: .semibold
                )
            )
        }
        tallyBorderColor = prominent ? UIKitChassis.signal2 : UIKitChassis.bezelHi
        label.textColor = prominent ? UIKitChassis.signal : UIKitChassis.signal2
        imageView.tintColor = prominent ? UIKitChassis.signal : UIKitChassis.signal2
        accessibilityLabel = caption
    }
}

@MainActor
private final class FleetColorDotView: UIView {
    private let dynamicColor: UIColor

    init(color: UIColor, diameter: CGFloat) {
        dynamicColor = color
        super.init(frame: .zero)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter * Theme.typeScale),
            heightAnchor.constraint(equalToConstant: diameter * Theme.typeScale),
        ])
        layer.cornerRadius = diameter * Theme.typeScale / 2
        refresh()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (dot: FleetColorDotView, _: UITraitCollection) in
            dot.refresh()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    private func refresh() {
        backgroundColor = dynamicColor
        layer.shadowColor = dynamicColor.resolvedColor(with: traitCollection).cgColor
        layer.shadowOpacity = 0.7
        layer.shadowRadius = 4
        layer.shadowOffset = .zero
    }
}

@MainActor
private final class FleetTallyLampView: UIView {
    init(caption: String = "LIVE", color: UIColor = TallyPalette.tally) {
        super.init(frame: .zero)
        let dot = FleetColorDotView(color: color, diameter: 7)
        let label = UILabel()
        label.font = UIKitChassis.monoFont(9, weight: .bold)
        label.textColor = color
        label.attributedText = NSAttributedString(
            string: caption,
            attributes: [.kern: 1.2, .foregroundColor: color]
        )
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [dot, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 5
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = caption.lowercased()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

@MainActor
private final class FleetHatchedView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = TallyPalette.screen
        isOpaque = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (view: FleetHatchedView, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setStrokeColor(
            TallyPalette.screenHatch.resolvedColor(with: traitCollection).cgColor
        )
        context.setLineWidth(5)
        var x = -bounds.height
        while x < bounds.width {
            context.move(to: CGPoint(x: x, y: bounds.height))
            context.addLine(to: CGPoint(x: x + bounds.height, y: 0))
            x += 14
        }
        context.strokePath()
    }

}

// MARK: - Session tile

@MainActor
struct FleetSessionTileConfiguration {
    let hostID: UUID
    let session: TmuxSession
    let lines: [String]
    let attention: PaneAgentState?
    let hasLiveAgentState: Bool
    let hasOpenTab: Bool
    let compact: Bool
    let selected: Bool
    let duplicateAttachTitle: String
    let openTabAccessibilityText: String
    let attach: () -> Void
    let attachNewWindow: () -> Void
    let delete: () -> Void
    let droppedSession: (String) -> Void

    /// Data equality of everything the tile draws. The actions are the only
    /// exclusions: equal data means their captured host/session inputs are
    /// equivalent, while the closures receive a fresh identity on every pass.
    func hasSameContent(as other: FleetSessionTileConfiguration) -> Bool {
        hostID == other.hostID
            && session == other.session
            && lines == other.lines
            && attention == other.attention
            && hasLiveAgentState == other.hasLiveAgentState
            && hasOpenTab == other.hasOpenTab
            && compact == other.compact
            && selected == other.selected
            && duplicateAttachTitle == other.duplicateAttachTitle
            && openTabAccessibilityText == other.openTabAccessibilityText
    }
}

@MainActor
final class FleetSessionTileView: FleetPressView,
    UIDragInteractionDelegate, UIDropInteractionDelegate
{
    private struct DragPayload {
        let hostID: UUID
        let sessionName: String
    }

    private let contentStack = UIStackView()
    private var configuration: FleetSessionTileConfiguration?
    private var isDropTarget = false {
        didSet {
            guard oldValue != isDropTarget else { return }
            applyBorder()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIKitChassis.bezel
        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 0
        contentStack.isUserInteractionEnabled = false
        addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        let drag = UIDragInteraction(delegate: self)
        drag.isEnabled = true
        addInteraction(drag)
        addInteraction(UIDropInteraction(delegate: self))
        accessibilityIdentifier = "fleet.sessionTile"
    }

    func configure(_ configuration: FleetSessionTileConfiguration) {
        // Every pass hands over freshly captured closures, so the stored
        // configuration and the actions always take the new ones. Only the
        // view tree is gated: rebuilding a tile's ~20 views and their
        // constraints because another host's probe ticked is exactly what the
        // pre-UIKit `.equatable()` tile gate existed to prevent.
        let unchanged = self.configuration?.hasSameContent(as: configuration) ?? false
        self.configuration = configuration
        pressAction = configuration.attach
        menuProvider = { [weak self] in
            guard let configuration = self?.configuration else { return nil }
            return UIMenu(children: [
                UIAction(title: configuration.duplicateAttachTitle) { _ in
                    configuration.attachNewWindow()
                },
                UIAction(title: "Delete Session…", attributes: .destructive) { _ in
                    configuration.delete()
                },
            ])
        }
        applyBorder()
        guard !unchanged else { return }
        rebuildContent()
        let running = agentRunning(configuration)
        let needsYou = agentNeedsYou(configuration)
        accessibilityLabel = accessibilitySummary(
            configuration,
            agentRunning: running,
            agentNeedsYou: needsYou
        )
        accessibilityHint = "Long press and drag to reorder within this host"
        invalidateIntrinsicContentSize()
    }

    func dragInteraction(
        _ interaction: UIDragInteraction,
        itemsForBeginning session: UIDragSession
    ) -> [UIDragItem] {
        guard let configuration else { return [] }
        let provider = NSItemProvider(object: configuration.session.name as NSString)
        let item = UIDragItem(itemProvider: provider)
        item.localObject = DragPayload(
            hostID: configuration.hostID,
            sessionName: configuration.session.name
        )
        return [item]
    }

    func dropInteraction(
        _ interaction: UIDropInteraction,
        sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
        guard accepts(session) else { return UIDropProposal(operation: .forbidden) }
        return UIDropProposal(operation: .move)
    }

    // A drop lands in the tile it is released over, so the pending
    // destination has to be visible while the finger is still down.
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
        isDropTarget = accepts(session)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        isDropTarget = false
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
        isDropTarget = false
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        isDropTarget = false
        guard let configuration,
              let item = session.items.first,
              let payload = item.localObject as? DragPayload,
              payload.hostID == configuration.hostID
        else { return }
        configuration.droppedSession(payload.sessionName)
    }

    /// Only this host's own session tiles reorder each other.
    private func accepts(_ session: UIDropSession) -> Bool {
        guard let configuration else { return false }
        return session.items.contains {
            ($0.localObject as? DragPayload)?.hostID == configuration.hostID
        }
    }

    private func applyBorder() {
        // While a compatible drag hovers, the pending destination outranks
        // selection — it is the one thing the drop needs to say.
        if isDropTarget {
            tallyBorderColor = UIKitChassis.signal2
            layer.borderWidth = 2
            return
        }
        let selected = configuration?.selected ?? false
        tallyBorderColor = selected ? UIKitChassis.signal2 : UIKitChassis.bezelHi
        layer.borderWidth = selected ? 1.5 : 1
    }

    private func rebuildContent() {
        guard let configuration else { return }
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let running = agentRunning(configuration)
        let needsYou = agentNeedsYou(configuration)
        contentStack.addArrangedSubview(makeScreen(configuration))
        contentStack.addArrangedSubview(makeUMD(
            configuration,
            agentRunning: running,
            agentNeedsYou: needsYou
        ))
        if !configuration.compact {
            contentStack.addArrangedSubview(makeSegmentStrip(configuration.session))
        }
    }

    private func makeScreen(_ configuration: FleetSessionTileConfiguration) -> UIView {
        let screen = UIView()
        screen.backgroundColor = TallyPalette.screen
        let lines = UIStackView()
        lines.axis = .vertical
        lines.alignment = .fill
        lines.spacing = 2
        let visible = configuration.lines.isEmpty
            ? ["—"]
            : Array(configuration.lines.prefix(
                configuration.compact ? 3 : configuration.lines.count
            ))
        for line in visible {
            let label = UILabel()
            label.font = UIKitChassis.monoFont(11)
            label.textColor = configuration.lines.isEmpty
                ? UIKitChassis.signal3
                : TallyPalette.miniText.withAlphaComponent(0.78)
            label.text = line.isEmpty ? " " : line
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            lines.addArrangedSubview(label)
        }
        screen.addSubview(lines)
        lines.translatesAutoresizingMaskIntoConstraints = false
        let minimum = screen.heightAnchor.constraint(
            greaterThanOrEqualToConstant: configuration.compact ? 56 : 76
        )
        NSLayoutConstraint.activate([
            lines.leadingAnchor.constraint(equalTo: screen.leadingAnchor, constant: configuration.compact ? 8 : 10),
            lines.trailingAnchor.constraint(equalTo: screen.trailingAnchor, constant: configuration.compact ? -8 : -10),
            lines.topAnchor.constraint(equalTo: screen.topAnchor, constant: configuration.compact ? 8 : 10),
            lines.bottomAnchor.constraint(lessThanOrEqualTo: screen.bottomAnchor, constant: configuration.compact ? -8 : -10),
            minimum,
        ])
        return screen
    }

    private func makeUMD(
        _ configuration: FleetSessionTileConfiguration,
        agentRunning: Bool,
        agentNeedsYou: Bool
    ) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 9
        let name = UIKitChassisLabel(
            configuration.session.name,
            size: configuration.compact ? 10 : 12
        )
        row.addArrangedSubview(name)

        let attachSlot = UIView()
        let attach = FleetBadgeView(caption: "ATTACH")
        attach.alpha = configuration.session.isAttached ? 0 : 1
        let live = FleetTallyLampView()
        live.isHidden = !configuration.session.isAttached
        attachSlot.addSubview(attach)
        attachSlot.addSubview(live)
        attach.translatesAutoresizingMaskIntoConstraints = false
        live.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            attach.leadingAnchor.constraint(equalTo: attachSlot.leadingAnchor),
            attach.trailingAnchor.constraint(equalTo: attachSlot.trailingAnchor),
            attach.topAnchor.constraint(equalTo: attachSlot.topAnchor),
            attach.bottomAnchor.constraint(equalTo: attachSlot.bottomAnchor),
            live.leadingAnchor.constraint(equalTo: attachSlot.leadingAnchor),
            live.centerYAnchor.constraint(equalTo: attachSlot.centerYAnchor),
        ])
        row.addArrangedSubview(attachSlot)
        if agentNeedsYou {
            row.addArrangedSubview(FleetTallyLampView(
                caption: "NEEDS YOU",
                color: TallyPalette.caution
            ))
        }
        row.addArrangedSubview(UIView())
        if !configuration.compact {
            let telemetry = UILabel()
            telemetry.font = UIKitChassis.monoFont(9.5)
            telemetry.textColor = UIKitChassis.signal2
            telemetry.text = telemetryText(configuration.session, agentRunning: agentRunning)
            telemetry.numberOfLines = 1
            telemetry.adjustsFontSizeToFitWidth = true
            telemetry.minimumScaleFactor = 0.8
            telemetry.textAlignment = .right
            row.addArrangedSubview(telemetry)
        }
        let wrapper = UIView()
        wrapper.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: configuration.compact ? 6 : 7),
            row.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: configuration.compact ? -6 : -7),
            row.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: configuration.compact ? 6 : 8),
            row.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -5),
        ])
        return wrapper
    }

    private func makeSegmentStrip(_ session: TmuxSession) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .fill
        row.distribution = .fillEqually
        row.spacing = 3
        for window in session.windows {
            row.addArrangedSubview(FleetWindowSegmentView(window: window, serverHost: session.serverHost))
        }
        let wrapper = UIView()
        wrapper.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 3),
            row.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -3),
            row.topAnchor.constraint(equalTo: wrapper.topAnchor),
            row.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -3),
        ])
        wrapper.isAccessibilityElement = true
        wrapper.accessibilityLabel = spineSummary(session)
        return wrapper
    }

    private func agentRunning(_ configuration: FleetSessionTileConfiguration) -> Bool {
        if configuration.attention == .busy { return true }
        guard configuration.hasLiveAgentState else { return false }
        return configuration.session.agentPanes.contains {
            AgentAttention.classifyVerified(
                title: $0.title,
                tail: [],
                agent: $0.agent
            ) == .busy
        }
    }

    private func agentNeedsYou(_ configuration: FleetSessionTileConfiguration) -> Bool {
        if case .needsYou = configuration.attention { return true }
        guard configuration.hasLiveAgentState else { return false }
        return configuration.session.agentPanes.contains {
            if case .some(.needsYou) = AgentAttention.classifyVerified(
                title: $0.title,
                tail: [],
                agent: $0.agent
            ) { return true }
            return false
        }
    }

    private func telemetryText(_ session: TmuxSession, agentRunning: Bool) -> String {
        let splits = session.paneCount > session.windowCount
        var parts = [splits ? "\(session.windowCount)W" : "\(session.windowCount) WIN"]
        if splits { parts.append("\(session.paneCount)P") }
        if session.clientCount > 0 {
            parts.append(splits
                ? "\(session.clientCount)C"
                : "\(session.clientCount) CLIENT\(session.clientCount == 1 ? "" : "S")")
        }
        var agents: [AgentKind] = []
        if let active = session.activeAgent { agents.append(active) }
        for agent in session.detectedAgents where !agents.contains(agent) { agents.append(agent) }
        for agent in agents {
            let count = session.detectedAgents.count { $0 == agent }
            parts.append(count > 1 ? "\(count)×\(agent.telemetryLabel)" : agent.telemetryLabel)
        }
        if agentRunning { parts.append("RUNNING") }
        parts.append(sessionAge(session))
        return parts.joined(separator: " · ")
    }

    private func sessionAge(_ session: TmuxSession) -> String {
        let seconds = max(0, Date().timeIntervalSince(session.created))
        if seconds >= 86_400 { return "\(Int(seconds / 86_400))d" }
        if seconds >= 3_600 { return "\(Int(seconds / 3_600))h" }
        return "\(max(1, Int(seconds / 60)))m"
    }

    private func spineSummary(_ session: TmuxSession) -> String {
        let activeWindow = session.windows.first(where: \.isActive)
        let active = activeWindow.map { "\($0.name) active" } ?? ""
        let title = activeWindow?
            .displayPaneTitle(serverHost: session.serverHost)
            .map { ", titled \($0)" } ?? ""
        return "\(session.windowCount) windows, \(session.paneCount) panes. \(active)\(title)"
    }

    private func accessibilitySummary(
        _ configuration: FleetSessionTileConfiguration,
        agentRunning: Bool,
        agentNeedsYou: Bool
    ) -> String {
        let session = configuration.session
        var parts = [session.name, session.isAttached ? "live" : "not attached"]
        if agentNeedsYou { parts.append("agent needs your input") }
        if agentRunning { parts.append("agent running") }
        parts.append("\(session.windowCount) windows and \(session.paneCount) panes")
        return parts.joined(separator: ", ")
            + (configuration.hasOpenTab
                ? ". \(configuration.openTabAccessibilityText)"
                : ". Attach")
    }
}

@MainActor
private final class FleetWindowSegmentView: UIView {
    private let bar = UIView()
    private let tick = UIView()
    private let activeColor: UIColor

    init(window: TmuxWindow, serverHost: String) {
        activeColor = window.isActive ? UIKitChassis.signal : UIKitChassis.bezelHi
        super.init(frame: .zero)
        bar.backgroundColor = activeColor
        addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.font = UIKitChassis.monoFont(8)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        let baseColor = window.isActive ? UIKitChassis.signal : UIKitChassis.signal2
        let text = NSMutableAttributedString(
            string: "\(window.index) \(window.name)".uppercased(),
            attributes: [.foregroundColor: baseColor, .kern: 0.4]
        )
        if window.paneCount > 1 {
            text.append(NSAttributedString(
                string: " · \(window.paneCount)P",
                attributes: [.foregroundColor: baseColor, .kern: 0.4]
            ))
        } else if let title = window.displayPaneTitle(serverHost: serverHost) {
            text.append(NSAttributedString(
                string: " · \(title)",
                attributes: [
                    .foregroundColor: window.isActive
                        ? UIKitChassis.signal2 : UIKitChassis.signal3,
                    .kern: 0.4,
                ]
            ))
        }
        label.attributedText = text
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false

        tick.backgroundColor = TallyPalette.caution
        tick.isHidden = !(window.hasBell || window.hasActivity)
        addSubview(tick)
        tick.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.heightAnchor.constraint(equalToConstant: 2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            tick.widthAnchor.constraint(equalToConstant: 5),
            tick.heightAnchor.constraint(equalToConstant: 5),
            tick.trailingAnchor.constraint(equalTo: trailingAnchor),
            tick.centerYAnchor.constraint(equalTo: topAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

// MARK: - Special tiles

@MainActor
private final class FleetNewSessionTileView: FleetPressView {
    private let label = UIKitChassisLabel("+ New Session", size: 11, color: UIKitChassis.signal2)
    private let dashLayer = CAShapeLayer()
    private var heightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        tallyBorderColor = .clear
        layer.borderWidth = 0
        layer.addSublayer(dashLayer)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: 138)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            heightConstraint!,
        ])
        // A CALayer stroke is a resolved CGColor: it needs re-resolving on an
        // appearance flip, which alone changes no bounds and triggers no layout.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (tile: FleetNewSessionTileView, _: UITraitCollection) in
            tile.refreshDash()
        }
    }

    func configure(hostName: String, compact: Bool, action: @escaping () -> Void) {
        pressAction = action
        heightConstraint?.constant = compact ? 92 : 138
        accessibilityLabel = "New session on \(hostName)"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dashLayer.frame = bounds
        dashLayer.path = UIBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).cgPath
        refreshDash()
    }

    private func refreshDash() {
        dashLayer.fillColor = UIColor.clear.cgColor
        dashLayer.strokeColor = UIKitChassis.bezelHi.resolvedColor(with: traitCollection).cgColor
        dashLayer.lineWidth = 1
        dashLayer.lineDashPattern = [5, 4]
    }
}

@MainActor
private final class FleetNoSignalTileView: FleetPressView {
    enum Mode {
        case unreachable
        case passphrase
        case disabled
    }

    private let content = UIStackView()
    private var screenHeightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIKitChassis.bezel
        content.axis = .vertical
        content.spacing = 0
        content.alignment = .fill
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    func configure(host: Host, mode: Mode, compact: Bool, action: @escaping () -> Void) {
        pressAction = action
        content.arrangedSubviews.forEach {
            content.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let screen = FleetHatchedView()
        let caption: String
        let ink: UIColor
        let badge: String
        switch mode {
        case .unreachable:
            caption = "No Signal"
            ink = UIKitChassis.signal3
            badge = "RECONNECT"
            accessibilityLabel = "\(host.name) unreachable. Reconnect"
        case .passphrase:
            caption = "Passphrase Required"
            ink = TallyPalette.caution
            badge = "UNLOCK"
            accessibilityLabel = "\(host.name) needs its SSH key passphrase. Unlock"
        case .disabled:
            caption = "Disabled"
            ink = UIKitChassis.signal3
            badge = "ENABLE"
            accessibilityLabel = "\(host.name) is disabled. Enable"
            accessibilityHint = "Starts monitoring this host on the deck again"
        }
        let title = UIKitChassisLabel(caption, size: 13, color: ink)
        screen.addSubview(title)
        title.translatesAutoresizingMaskIntoConstraints = false
        screenHeightConstraint = screen.heightAnchor.constraint(
            greaterThanOrEqualToConstant: compact ? 64 : 96
        )
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: screen.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: screen.centerYAnchor),
            screenHeightConstraint!,
        ])
        content.addArrangedSubview(screen)

        let hostLabel = UIKitChassisLabel(host.name, size: 12, color: UIKitChassis.signal3)
        let verdict = FleetBadgeView(caption: badge)
        let row = UIStackView(arrangedSubviews: [hostLabel, UIView(), verdict])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        let wrapper = UIView()
        wrapper.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 7),
            row.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -7),
            row.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -8),
        ])
        content.addArrangedSubview(wrapper)
    }
}

@MainActor
private final class FleetAcquiringTileView: UIKitTallyBorderedView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let screen = UIView()
    private var heightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Same chassis anatomy as every tile beside it: the screen sits inside
        // a five-point bezel frame, never painted out to the border.
        backgroundColor = UIKitChassis.bezel
        screen.backgroundColor = TallyPalette.screen
        addSubview(screen)
        screen.translatesAutoresizingMaskIntoConstraints = false
        let label = UIKitChassisLabel(
            "Acquiring signal", size: 10, color: UIKitChassis.signal3
        )
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        screen.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = screen.heightAnchor.constraint(greaterThanOrEqualToConstant: 138)
        NSLayoutConstraint.activate([
            screen.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            screen.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            screen.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            screen.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            stack.centerXAnchor.constraint(equalTo: screen.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: screen.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: screen.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: screen.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(greaterThanOrEqualTo: screen.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: screen.bottomAnchor, constant: -10),
            heightConstraint!,
        ])
        spinner.color = UIKitChassis.signal2
        spinner.startAnimating()
        isAccessibilityElement = true
        accessibilityLabel = "Acquiring signal"
    }

    func configure(compact: Bool) {
        heightConstraint?.constant = compact ? 92 : 138
    }
}

@MainActor
private final class FleetTmuxMissingTileView: UIKitTallyBorderedView {
    private var installChip: UIKitChassisChip!
    private var action: (() -> Void)?
    private var heightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        installChip = UIKitChassisChip(
            "INSTALL GUIDE",
            accessibilityLabel: "Install guide"
        ) { [weak self] in self?.action?() }
        let title = UIKitChassisLabel(
            "No tmux on host", size: 11, color: UIKitChassis.signal3
        )
        let body = UILabel()
        // A semantic role keeps Dynamic Type and the scene root's
        // iOS-on-Mac content-size override; the chassis label above it is
        // fixed chrome type and already carries `Theme.typeScale`.
        body.font = .preferredFont(forTextStyle: .footnote)
        body.adjustsFontForContentSizeCategory = true
        body.textColor = UIKitChassis.signal2
        body.text = "You can still use a plain shell — press SHELL."
        body.numberOfLines = 0
        body.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [title, body, installChip])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: 138)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightConstraint!,
        ])
        isAccessibilityElement = false
    }

    func configure(compact: Bool, action: @escaping () -> Void) {
        self.action = action
        heightConstraint?.constant = compact ? 92 : 138
    }
}

@MainActor
private final class FleetAwaitingSignalView: UIView {
    private let tile = UIKitTallyBorderedView()
    private var addChip: UIKitChassisChip!
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addChip = UIKitChassisChip(
            "ADD HOST",
            systemImage: "plus",
            prominent: true,
            accessibilityLabel: "Add host"
        ) { [weak self] in self?.action?() }
        tile.backgroundColor = UIKitChassis.bezel
        addSubview(tile)
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            tile.bottomAnchor.constraint(equalTo: bottomAnchor),
            tile.centerXAnchor.constraint(equalTo: centerXAnchor),
            tile.widthAnchor.constraint(lessThanOrEqualToConstant: 430),
            tile.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            tile.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])

        let content = UIStackView()
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = 0
        tile.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 5),
            content.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -5),
            content.topAnchor.constraint(equalTo: tile.topAnchor, constant: 5),
            content.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -5),
        ])

        let screen = FleetHatchedView()
        let title = UIKitChassisLabel(
            "Awaiting signal", size: 13, color: UIKitChassis.signal3
        )
        let body = UILabel()
        body.font = .preferredFont(forTextStyle: .footnote)
        body.adjustsFontForContentSizeCategory = true
        body.textColor = UIKitChassis.signal2
        body.text = "Every tmux session, its own window in space."
        body.textAlignment = .center
        let route = UILabel()
        route.font = UIKitChassis.monoFont(10)
        route.textColor = UIKitChassis.signal3
        route.text = "add host  ▸  bind  or  manual"
        route.textAlignment = .center
        let screenStack = UIStackView(arrangedSubviews: [title, body, route])
        screenStack.axis = .vertical
        screenStack.alignment = .center
        screenStack.spacing = 12
        screen.addSubview(screenStack)
        screenStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            screenStack.centerXAnchor.constraint(equalTo: screen.centerXAnchor),
            screenStack.centerYAnchor.constraint(equalTo: screen.centerYAnchor),
            screenStack.leadingAnchor.constraint(greaterThanOrEqualTo: screen.leadingAnchor, constant: 12),
            screenStack.trailingAnchor.constraint(lessThanOrEqualTo: screen.trailingAnchor, constant: -12),
            screen.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
        content.addArrangedSubview(screen)

        let noHosts = UIKitChassisLabel("No hosts", size: 12, color: UIKitChassis.signal3)
        let row = UIStackView(arrangedSubviews: [noHosts, UIView(), addChip])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        let rowWrapper = UIView()
        rowWrapper.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: rowWrapper.leadingAnchor, constant: 7),
            row.trailingAnchor.constraint(equalTo: rowWrapper.trailingAnchor, constant: -7),
            row.topAnchor.constraint(equalTo: rowWrapper.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: rowWrapper.bottomAnchor, constant: -8),
        ])
        content.addArrangedSubview(rowWrapper)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(addHost: @escaping () -> Void) { action = addHost }
}

// MARK: - New Session state

struct NewSessionSubmission: Equatable {
    let name: String
    let agent: AgentKind?
    let model: String?
    let initialPrompt: String
    let directory: String?
    let script: SessionScript?
}

/// Framework-independent form rules shared by the native controller and its
/// tests. The one-shot prompt is deliberately absent from preferences.
struct NewSessionFormState {
    enum LaunchMode: Hashable {
        case shell
        case agents
    }

    let host: Host
    let existingNames: [String]
    let preferences: NewSessionPreferences
    var name: String
    var launchMode: LaunchMode
    var selectedAgent: AgentKind
    var model: String
    var initialPrompt: String
    var directory: String?
    var script: SessionScript?
    var remembersLastLaunch: Bool

    init(
        host: Host,
        existingNames: [String],
        preferences: NewSessionPreferences = NewSessionPreferences()
    ) {
        self.host = host
        self.existingNames = existingNames
        self.preferences = preferences
        remembersLastLaunch = preferences.remembersLastLaunch
        let agent = preferences.rememberedAgent
        launchMode = agent == nil ? .shell : .agents
        selectedAgent = agent ?? .claudeCode
        model = agent.flatMap(preferences.rememberedModel) ?? ""
        initialPrompt = ""
        directory = host.workingDirs.first
        script = preferences.rememberedScript(for: host)
        name = TmuxProbe.uniqueSessionName(
            base: agent?.launchCommand ?? "main",
            existing: existingNames
        )
    }

    var agentToLaunch: AgentKind? {
        launchMode == .agents ? selectedAgent : nil
    }

    var modelToLaunch: String? {
        guard agentToLaunch != nil else { return nil }
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var commandPreview: String {
        guard let agentToLaunch else { return "login shell" }
        return agentToLaunch.launchCommand(model: modelToLaunch, initialPrompt: "")
    }

    mutating func selectShell() {
        select(agent: nil)
    }

    mutating func selectAgent(_ agent: AgentKind) {
        select(agent: agent)
    }

    mutating func select(agent: AgentKind?) {
        let previous = agentToLaunch
        let nameUntouched = name == prefill(for: previous)
        let modelUntouched = model == modelPrefill(for: previous)
        if let agent {
            selectedAgent = agent
            launchMode = .agents
        } else {
            launchMode = .shell
        }
        if nameUntouched { name = prefill(for: agent) }
        if modelUntouched { model = modelPrefill(for: agent) }
    }

    func savePreferences() {
        preferences.save(
            remembersLastLaunch: remembersLastLaunch,
            agent: agentToLaunch,
            model: agentToLaunch == nil ? nil : model,
            script: script,
            hostID: host.id
        )
    }

    var submission: NewSessionSubmission {
        NewSessionSubmission(
            name: name,
            agent: agentToLaunch,
            model: modelToLaunch,
            initialPrompt: initialPrompt,
            directory: directory,
            script: script
        )
    }

    var launchDetail: String {
        let remembers = host.sessionScripts.isEmpty
            ? "REMEMBER saves only the launch choice."
            : "REMEMBER saves the launch and setup-script choices."
        guard let agentToLaunch else {
            return "Creates the tmux session, then attaches to its login shell. \(remembers)"
        }
        return "Starts \(agentToLaunch.displayName) in the fresh shell. The optional prompt becomes its first message; \(remembers)"
    }

    var scriptDetail: String {
        guard let script else {
            return "Nothing extra runs. A setup script is typed into the fresh shell before the launch."
        }
        return "Types \(script.displayName) into the fresh shell first, so the launch inherits what it sets up."
    }

    var directoryDetail: String {
        guard !host.workingDirs.isEmpty else {
            return "Uses the host's login-shell home directory."
        }
        if let directory {
            return "Starts in \(directory). Choose Home to use the login shell's default."
        }
        return "Uses the host's login-shell home directory."
    }

    private func prefill(for agent: AgentKind?) -> String {
        TmuxProbe.uniqueSessionName(
            base: agent?.launchCommand ?? "main",
            existing: existingNames
        )
    }

    private func modelPrefill(for agent: AgentKind?) -> String {
        agent.flatMap(preferences.rememberedModel) ?? ""
    }
}

// MARK: - Native New Session sheet

@MainActor
final class NewSessionViewController: UIViewController,
    UITextFieldDelegate, UIGestureRecognizerDelegate
{
    static let contentMaximumWidth: CGFloat = 600
    static let outerInset: CGFloat = 18
    static let sectionSpacing: CGFloat = 18

    var onDismiss: (() -> Void)?

    private(set) var form: NewSessionFormState
    private let create: (NewSessionSubmission) -> Void
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let nameField = UITextField()
    private let modelField = UITextField()
    private let promptView = FleetPromptTextView()
    private let launchChoice = FleetLaunchChoiceView()
    private let rememberToggle = FleetToggleView(caption: "REMEMBER")
    private let commandLabel = UILabel()
    private var launchSection: FleetFormSectionView?
    private var agentFieldsRow: UIView?
    private var modelInputRow: UIStackView?
    private var modelMenuButton: UIButton?
    private var scriptButton: FleetMenuFieldButton?
    private var scriptSection: FleetFormSectionView?
    private var directoryButton: FleetMenuFieldButton?
    private var directorySection: FleetFormSectionView?
    private var createItem: UIBarButtonItem?

    init(
        host: Host,
        existingNames: [String],
        preferences: NewSessionPreferences = NewSessionPreferences(),
        create: @escaping (NewSessionSubmission) -> Void
    ) {
        form = NewSessionFormState(
            host: host,
            existingNames: existingNames,
            preferences: preferences
        )
        self.create = create
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "New Session"
        view.backgroundColor = UIKitChassis.chassis
        navigationItem.largeTitleDisplayMode = .never
        #if os(visionOS)
        navigationItem.titleView = UIKitChassisLabel("New Session", size: 12)
        #endif

        let cancel = UIBarButtonItem(
            title: "Cancel",
            style: .plain,
            target: self,
            action: #selector(cancelPressed)
        )
        cancel.tintColor = UIKitChassis.signal
        cancel.accessibilityLabel = "Cancel"
        navigationItem.leftBarButtonItem = cancel
        let createItem = UIBarButtonItem(
            title: "Create & Attach",
            style: .plain,
            target: self,
            action: #selector(createPressed)
        )
        createItem.tintColor = UIKitChassis.signal
        createItem.accessibilityLabel = "Create and attach"
        navigationItem.rightBarButtonItem = createItem
        self.createItem = createItem

        configureContent()
        renderForm()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyKeyboardContentInset(to: scrollView)
    }

    private func configureContent() {
        scrollView.alwaysBounceVertical = true
        scrollView.backgroundColor = UIKitChassis.chassis
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.contentLayoutGuide.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor
            ),
        ])
        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = Self.sectionSpacing
        scrollView.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        let fillWidth = contentStack.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -(Self.outerInset * 2)
        )
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: Self.outerInset
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -Self.outerInset
            ),
            contentStack.centerXAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.centerXAnchor
            ),
            contentStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: Self.outerInset
            ),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -Self.outerInset
            ),
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentMaximumWidth),
            fillWidth,
        ])

        contentStack.addArrangedSubview(makeTargetSection())
        contentStack.addArrangedSubview(makeIdentitySection())
        let launch = makeLaunchSection()
        launchSection = launch
        contentStack.addArrangedSubview(launch)
        if !form.host.sessionScripts.isEmpty {
            let section = makeScriptSection()
            scriptSection = section
            contentStack.addArrangedSubview(section)
        }
        let directory = makeDirectorySection()
        directorySection = directory
        contentStack.addArrangedSubview(directory)

        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        dismissTap.cancelsTouchesInView = false
        dismissTap.delegate = self
        scrollView.addGestureRecognizer(dismissTap)
    }

    private func makeTargetSection() -> UIView {
        let name = UIKitChassisLabel(form.host.name, size: 12)
        let address = UILabel()
        address.font = UIKitChassis.monoFont(10)
        address.textColor = UIKitChassis.signal2
        address.text = form.host.address
        address.numberOfLines = 1
        address.lineBreakMode = .byTruncatingTail
        let identity = UIStackView(arrangedSubviews: [name, address])
        identity.axis = .vertical
        identity.alignment = .leading
        identity.spacing = 4
        let badge = FleetBadgeView(caption: form.host.useMosh ? "MOSH" : "SSH")
        let row = UIStackView(arrangedSubviews: [identity, UIView(), badge])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        return FleetFormSectionView(title: "Target host", rows: [row])
    }

    private func makeIdentitySection() -> UIView {
        configureTextField(nameField, placeholder: "main", accessibilityLabel: "Name")
        nameField.text = form.name
        nameField.returnKeyType = .next
        nameField.addTarget(self, action: #selector(nameChanged), for: .editingChanged)
        nameField.accessibilityIdentifier = "newSession.name"
        let row = makeField(label: "Name", input: makeWell(containing: nameField))
        return FleetFormSectionView(
            title: "Session identity",
            detail: "Shown on the deck and in the terminal window's source label.",
            rows: [row]
        )
    }

    private func makeLaunchSection() -> FleetFormSectionView {
        launchChoice.onSelectShell = { [weak self] in
            self?.syncFormFromInputs()
            self?.form.selectShell()
            self?.renderForm()
        }
        launchChoice.onSelectAgent = { [weak self] agent in
            self?.syncFormFromInputs()
            self?.form.selectAgent(agent)
            self?.renderForm()
        }
        launchChoice.accessibilityIdentifier = "newSession.launchChoice"

        configureTextField(
            modelField,
            placeholder: "Agent default",
            accessibilityLabel: "Optional model"
        )
        modelField.returnKeyType = .next
        modelField.addTarget(self, action: #selector(modelChanged), for: .editingChanged)
        modelField.accessibilityIdentifier = "newSession.model"
        let modelRow = UIStackView(arrangedSubviews: [modelField])
        modelRow.axis = .horizontal
        modelRow.alignment = .center
        modelRow.spacing = 8
        modelInputRow = modelRow
        let modelWell = makeWell(containing: modelRow)

        promptView.accessibilityIdentifier = "newSession.initialPrompt"
        promptView.onTextChange = { [weak self] text in self?.form.initialPrompt = text }
        let fields = UIStackView(arrangedSubviews: [
            makeField(label: "Model (optional)", input: modelWell),
            makeField(label: "Initial prompt (optional)", input: makeWell(containing: promptView)),
        ])
        fields.axis = .vertical
        fields.alignment = .fill
        fields.spacing = 12
        fields.accessibilityIdentifier = "newSession.agentFields"
        agentFieldsRow = fields

        rememberToggle.onChange = { [weak self] value in
            self?.form.remembersLastLaunch = value
        }
        commandLabel.font = UIKitChassis.monoFont(9, weight: .medium)
        commandLabel.textColor = UIKitChassis.signal2
        commandLabel.numberOfLines = 1
        commandLabel.lineBreakMode = .byTruncatingHead
        commandLabel.textAlignment = .right
        commandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let commandCaption = UIKitChassisLabel("Command", size: 7, color: UIKitChassis.signal3)
        let commandStack = UIStackView(arrangedSubviews: [commandCaption, commandLabel])
        commandStack.axis = .vertical
        commandStack.alignment = .trailing
        commandStack.spacing = 3
        let rememberRow = UIStackView(arrangedSubviews: [rememberToggle, UIView(), commandStack])
        rememberRow.axis = .horizontal
        rememberRow.alignment = .center
        rememberRow.spacing = 12

        let section = FleetFormSectionView(
            title: "Launch",
            detail: form.launchDetail,
            rows: [launchChoice, fields, rememberRow]
        )
        section.accessibilityIdentifier = "newSession.launchSection"
        return section
    }

    private func makeScriptSection() -> FleetFormSectionView {
        let button = FleetMenuFieldButton()
        button.accessibilityLabel = "Setup script"
        button.accessibilityIdentifier = "newSession.script"
        scriptButton = button
        return FleetFormSectionView(
            title: "Setup script",
            detail: form.scriptDetail,
            rows: [makeField(label: "Runs first", input: button)]
        )
    }

    private func makeDirectorySection() -> FleetFormSectionView {
        if form.host.workingDirs.isEmpty {
            let starts = UILabel()
            starts.font = UIKitChassis.uiFont(10, weight: .semibold)
            starts.textColor = UIKitChassis.signal2
            starts.text = "Starts in"
            let home = UILabel()
            home.font = UIKitChassis.monoFont(10, weight: .medium)
            home.textColor = UIKitChassis.signal
            home.text = "HOME"
            let row = UIStackView(arrangedSubviews: [starts, UIView(), home])
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 12
            row.isAccessibilityElement = true
            row.accessibilityLabel = "Starts in, Home"
            return FleetFormSectionView(
                title: "Directory",
                detail: form.directoryDetail,
                rows: [row]
            )
        }
        let button = FleetMenuFieldButton()
        button.accessibilityLabel = "Starting directory"
        button.accessibilityIdentifier = "newSession.directory"
        directoryButton = button
        return FleetFormSectionView(
            title: "Directory",
            detail: form.directoryDetail,
            rows: [makeField(label: "Starts in", input: button)]
        )
    }

    private func renderForm() {
        nameField.text = form.name
        modelField.text = form.model
        promptView.setText(form.initialPrompt)
        launchChoice.configure(mode: form.launchMode, selectedAgent: form.selectedAgent)
        rememberToggle.setOn(form.remembersLastLaunch)
        commandLabel.text = form.commandPreview
        launchSection?.setDetail(form.launchDetail)
        if let agentFieldsRow {
            // SwiftUI removed this row entirely for SHELL. Hiding only the
            // row's contents leaves its section wrapper, 24 points of inset,
            // and the model/prompt intrinsic height in Auto Layout, producing
            // the large blank launch option reported on visionOS.
            launchSection?.setRow(agentFieldsRow, visible: form.agentToLaunch != nil)
        }
        modelField.accessibilityLabel = form.agentToLaunch.map {
            "Optional model for \($0.displayName)"
        } ?? "Optional model"
        promptView.setPlaceholder(form.agentToLaunch.map {
            "What should \($0.displayName) do?"
        } ?? "Initial prompt")
        updateModelMenu()
        updateScriptMenu()
        updateDirectoryMenu()
        scriptSection?.setDetail(form.scriptDetail)
        directorySection?.setDetail(form.directoryDetail)
        createItem?.isEnabled = form.canSubmit
    }

    private func updateModelMenu() {
        modelMenuButton?.removeFromSuperview()
        modelMenuButton = nil
        guard let agent = form.agentToLaunch else { return }
        let configured = form.host.launchModels(for: agent)
        guard !configured.isEmpty, let row = modelInputRow else { return }
        let button = UIButton(type: .custom)
        button.setImage(
            UIImage(
                systemName: "chevron.down",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 9 * Theme.typeScale,
                    weight: .semibold
                )
            ),
            for: .normal
        )
        button.tintColor = UIKitChassis.signal2
        button.backgroundColor = UIKitChassis.chassis
        button.layer.borderWidth = 1
        button.layer.borderColor = UIKitChassis.bezelHi
            .resolvedColor(with: button.traitCollection).cgColor
        button.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (button: UIButton, _: UITraitCollection) in
            button.layer.borderColor = UIKitChassis.bezelHi
                .resolvedColor(with: button.traitCollection).cgColor
        }
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = "Configured models for \(agent.displayName)"
        button.accessibilityIdentifier = "newSession.modelMenu"
        var children: [UIMenuElement] = configured.map { candidate in
            UIAction(title: candidate) { [weak self] _ in
                self?.form.model = candidate
                self?.renderForm()
            }
        }
        children.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "Agent default") { [weak self] _ in
                self?.form.model = ""
                self?.renderForm()
            },
        ]))
        button.menu = UIMenu(children: children)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 25),
            button.heightAnchor.constraint(equalToConstant: 25),
        ])
        row.addArrangedSubview(button)
        modelMenuButton = button
    }

    private func updateScriptMenu() {
        guard let scriptButton else { return }
        scriptButton.setValue(form.script?.displayName ?? "None")
        var actions: [UIMenuElement] = form.host.sessionScripts.map { script in
            UIAction(title: script.displayName) { [weak self] _ in
                self?.form.script = script
                self?.renderForm()
            }
        }
        actions.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "None") { [weak self] _ in
                self?.form.script = nil
                self?.renderForm()
            },
        ]))
        scriptButton.menu = UIMenu(children: actions)
        scriptButton.showsMenuAsPrimaryAction = true
    }

    private func updateDirectoryMenu() {
        guard let directoryButton else { return }
        directoryButton.setValue(form.directory ?? "Home")
        directoryButton.accessibilityValue = form.directory ?? "Home"
        var actions: [UIMenuElement] = form.host.workingDirs.map { directory in
            UIAction(title: directory) { [weak self] _ in
                self?.form.directory = directory
                self?.renderForm()
            }
        }
        actions.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "Home") { [weak self] _ in
                self?.form.directory = nil
                self?.renderForm()
            },
        ]))
        directoryButton.menu = UIMenu(children: actions)
        directoryButton.showsMenuAsPrimaryAction = true
    }

    private func configureTextField(
        _ field: UITextField,
        placeholder: String,
        accessibilityLabel: String
    ) {
        field.placeholder = placeholder
        field.font = UIKitChassis.monoFont(12)
        field.textColor = UIKitChassis.signal
        field.tintColor = UIKitChassis.signal
        field.backgroundColor = .clear
        field.borderStyle = .none
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.delegate = self
        field.accessibilityLabel = accessibilityLabel
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func makeWell(containing input: UIView) -> UIView {
        let well = UIKitTallyBorderedView()
        well.backgroundColor = UIKitChassis.screen
        well.addSubview(input)
        input.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: input is FleetPromptTextView ? 0 : 10),
            input.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: input is FleetPromptTextView ? 0 : -10),
            input.topAnchor.constraint(equalTo: well.topAnchor, constant: input is FleetPromptTextView ? 0 : 9),
            input.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: input is FleetPromptTextView ? 0 : -9),
        ])
        return well
    }

    private func makeField(label: String, input: UIView) -> UIView {
        let fieldLabel = UILabel()
        fieldLabel.font = UIKitChassis.uiFont(10, weight: .semibold)
        fieldLabel.textColor = UIKitChassis.signal2
        fieldLabel.text = label
        let stack = UIStackView(arrangedSubviews: [fieldLabel, input])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 7
        return stack
    }

    private func syncFormFromInputs() {
        form.name = nameField.text ?? ""
        form.model = modelField.text ?? ""
        form.initialPrompt = promptView.text
    }

    @objc private func nameChanged() {
        form.name = nameField.text ?? ""
        createItem?.isEnabled = form.canSubmit
    }

    @objc private func modelChanged() {
        form.model = modelField.text ?? ""
        commandLabel.text = form.commandPreview
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === nameField, form.agentToLaunch != nil {
            modelField.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        !(touch.view is UIControl) && !(touch.view is UITextField)
    }

    @objc private func dismissKeyboard() { view.endEditing(true) }

    @objc private func cancelPressed() { dismissSheet() }

    @objc private func createPressed() {
        syncFormFromInputs()
        guard form.canSubmit else { return }
        form.savePreferences()
        create(form.submission)
        dismissSheet()
    }

    private func dismissSheet() {
        if let onDismiss { onDismiss() }
        else { navigationController?.dismiss(animated: true) }
    }
}

@MainActor
private final class FleetFormSectionView: UIView {
    private let detailLabel = UILabel()
    private let detailContainer = UIView()
    private var managedRows: [(content: UIView, wrapper: UIView)] = []
    /// Divider `i` follows managed row `i` and precedes the next row.
    private var rowDividers: [UIView] = []

    init(title: String, detail: String? = nil, rows: [UIView]) {
        super.init(frame: .zero)
        let titleLabel = UIKitChassisLabel(title, size: 10)
        titleLabel.accessibilityTraits.insert(.header)
        let header = UIView()
        header.backgroundColor = UIKitChassis.bezel
        header.addSubview(titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 10),
            titleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -10),
        ])

        var rowViews: [UIView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let divider = UIView()
                divider.backgroundColor = UIKitChassis.bezelHi
                divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
                rowViews.append(divider)
                rowDividers.append(divider)
            }
            let wrapper = UIView()
            wrapper.backgroundColor = UIKitChassis.chassis
            wrapper.addSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 12),
                row.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -12),
                row.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 12),
                row.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -12),
            ])
            rowViews.append(wrapper)
            managedRows.append((content: row, wrapper: wrapper))
        }
        let rowsStack = UIStackView(arrangedSubviews: rowViews)
        rowsStack.axis = .vertical
        rowsStack.spacing = 0
        let cardStack = UIStackView(arrangedSubviews: [header, rowsStack])
        cardStack.axis = .vertical
        cardStack.spacing = 1
        let card = UIKitTallyBorderedView()
        card.addSubview(cardStack)
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            cardStack.topAnchor.constraint(equalTo: card.topAnchor),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        detailLabel.font = UIKitChassis.uiFont(10)
        detailLabel.textColor = UIKitChassis.signal2
        detailLabel.numberOfLines = 0
        detailContainer.addSubview(detailLabel)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            detailLabel.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 2),
            detailLabel.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -2),
            detailLabel.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            detailLabel.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
        let stack = UIStackView(arrangedSubviews: [card, detailContainer])
        stack.axis = .vertical
        stack.spacing = 8
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setDetail(detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setDetail(_ detail: String?) {
        detailLabel.text = detail
        detailContainer.isHidden = detail == nil
    }

    func setRow(_ row: UIView, visible: Bool) {
        guard let index = managedRows.firstIndex(where: { $0.content === row })
        else { return }
        managedRows[index].wrapper.isHidden = !visible
        updateDividerVisibility()
    }

    private func updateDividerVisibility() {
        for index in rowDividers.indices {
            // Keep exactly one legacy 1-point seam between adjacent visible
            // rows, even when one or more optional rows are absent.
            let hasVisibleRowBefore = !managedRows[index].wrapper.isHidden
            let hasVisibleRowAfter = managedRows[(index + 1)...]
                .contains { !$0.wrapper.isHidden }
            rowDividers[index].isHidden = !(hasVisibleRowBefore && hasVisibleRowAfter)
        }
    }
}

@MainActor
private final class FleetLaunchChoiceView: UIView {
    private static let selectionAnimationDuration: TimeInterval = 0.14

    var onSelectShell: (() -> Void)?
    var onSelectAgent: ((AgentKind) -> Void)?
    private let shell = FleetChoiceButton()
    private let agents = FleetChoiceButton()
    private var selectedAgent = AgentKind.claudeCode
    private var renderedMode: NewSessionFormState.LaunchMode?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let stack = UIStackView(arrangedSubviews: [shell, agents])
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.spacing = 1
        backgroundColor = UIKitChassis.bezelHi
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 34),
        ])
        shell.addAction(UIAction { [weak self] _ in self?.onSelectShell?() }, for: .touchUpInside)
        agents.showsMenuAsPrimaryAction = true
        isAccessibilityElement = false
        accessibilityLabel = "What to launch"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(mode: NewSessionFormState.LaunchMode, selectedAgent: AgentKind) {
        let animatesSelection = renderedMode != nil && renderedMode != mode
        renderedMode = mode
        self.selectedAgent = selectedAgent
        shell.configure(
            title: "Shell",
            selected: mode == .shell,
            showsChevron: false,
            animationDuration: animatesSelection ? Self.selectionAnimationDuration : nil
        )
        agents.configure(
            title: mode == .agents ? selectedAgent.displayName : "Agents",
            selected: mode == .agents,
            showsChevron: true,
            animationDuration: animatesSelection ? Self.selectionAnimationDuration : nil
        )
        agents.accessibilityLabel = "Agents"
        agents.accessibilityValue = mode == .agents ? selectedAgent.displayName : "Not selected"
        agents.accessibilityHint = "Choose Claude Code, Codex, or Pi"
        agents.menu = UIMenu(children: AgentKind.allCases.map { agent in
            UIAction(title: agent.displayName, state: agent == selectedAgent ? .on : .off) {
                [weak self] _ in self?.onSelectAgent?(agent)
            }
        })
    }
}

@MainActor
private final class FleetChoiceButton: UIButton {
    private let caption = UILabel()
    private let chevron = UIImageView()
    private var sourceTitle = ""
    private var selectionActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        caption.numberOfLines = 1
        caption.lineBreakMode = .byTruncatingTail
        chevron.image = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 8 * Theme.typeScale,
                weight: .semibold
            )
        )
        let stack = UIStackView(arrangedSubviews: [caption, chevron])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        layer.borderWidth = 1
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (button: FleetChoiceButton, _: UITraitCollection) in
            button.render()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(
        title: String,
        selected: Bool,
        showsChevron: Bool,
        animationDuration: TimeInterval?
    ) {
        sourceTitle = title
        selectionActive = selected
        chevron.isHidden = !showsChevron
        accessibilityLabel = title
        accessibilityTraits = selected ? [.button, .selected] : [.button]
        if let animationDuration {
            UIView.transition(
                with: self,
                duration: animationDuration,
                options: [
                    .transitionCrossDissolve,
                    .curveEaseOut,
                    .beginFromCurrentState,
                    .allowUserInteraction,
                ],
                animations: { [self] in render() }
            )
        } else {
            render()
        }
    }

    private func render() {
        let ink = selectionActive ? UIKitChassis.signal : UIKitChassis.signal2
        let scaled = 9 * Theme.typeScale
        caption.attributedText = NSAttributedString(
            string: sourceTitle.uppercased(),
            attributes: [
                .font: UIKitChassis.compressedLabelFont(9),
                .kern: scaled * 0.09,
                .foregroundColor: ink.resolvedColor(with: traitCollection),
            ]
        )
        chevron.tintColor = ink
        backgroundColor = selectionActive ? UIKitChassis.bezelHi : UIKitChassis.chassis
        layer.borderColor = (selectionActive ? UIKitChassis.signal2 : UIKitChassis.bezelHi)
            .resolvedColor(with: traitCollection).cgColor
    }
}

@MainActor
private final class FleetToggleView: UIView {
    var onChange: ((Bool) -> Void)?
    private let caption: UIKitChassisLabel
    private let track = UIKitTallyBorderedView()
    private let thumb = UIView()
    private var thumbLeading: NSLayoutConstraint?
    private var isOn = false

    init(caption: String) {
        self.caption = UIKitChassisLabel(caption, size: 9)
        super.init(frame: .zero)
        let stack = UIStackView(arrangedSubviews: [self.caption, track])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            track.widthAnchor.constraint(equalToConstant: 34),
            track.heightAnchor.constraint(equalToConstant: 18),
        ])
        track.backgroundColor = UIKitChassis.screen
        track.addSubview(thumb)
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumbLeading = thumb.leadingAnchor.constraint(equalTo: track.leadingAnchor, constant: 3)
        NSLayoutConstraint.activate([
            thumbLeading!,
            thumb.centerYAnchor.constraint(equalTo: track.centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 12),
            thumb.heightAnchor.constraint(equalToConstant: 12),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Remember launch choice"
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggle)))
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setOn(_ value: Bool) {
        isOn = value
        render()
    }

    override func accessibilityActivate() -> Bool {
        toggle()
        return true
    }

    @objc private func toggle() {
        isOn.toggle()
        render()
        onChange?(isOn)
    }

    private func render() {
        thumbLeading?.constant = isOn ? 19 : 3
        thumb.backgroundColor = isOn ? UIKitChassis.signal : UIKitChassis.signal3
        track.tallyBorderColor = isOn ? UIKitChassis.signal2 : UIKitChassis.bezelHi
        accessibilityValue = isOn ? "On" : "Off"
    }
}

@MainActor
private final class FleetMenuFieldButton: UIButton {
    private let valueLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIKitChassis.screen
        layer.borderWidth = 1
        refreshBorder()
        valueLabel.font = UIKitChassis.monoFont(12)
        valueLabel.textColor = UIKitChassis.signal
        valueLabel.numberOfLines = 1
        valueLabel.lineBreakMode = .byTruncatingTail
        let chevron = UIImageView(image: UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 9 * Theme.typeScale,
                weight: .semibold
            )
        ))
        chevron.tintColor = UIKitChassis.signal2
        let stack = UIStackView(arrangedSubviews: [valueLabel, UIView(), chevron])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (button: FleetMenuFieldButton, _: UITraitCollection) in
            button.refreshBorder()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setValue(_ value: String) { valueLabel.text = value }

    private func refreshBorder() {
        layer.borderColor = UIKitChassis.bezelHi
            .resolvedColor(with: traitCollection).cgColor
    }
}

@MainActor
private final class FleetPromptTextView: UITextView, UITextViewDelegate {
    var onTextChange: ((String) -> Void)?
    private let placeholderLabel = UILabel()

    init() {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        font = UIKitChassis.monoFont(12)
        textColor = UIKitChassis.signal
        tintColor = UIKitChassis.signal
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        textContainer.lineFragmentPadding = 0
        isScrollEnabled = true
        autocorrectionType = .default
        autocapitalizationType = .sentences
        placeholderLabel.font = UIKitChassis.monoFont(12)
        placeholderLabel.textColor = UIKitChassis.signal3
        placeholderLabel.numberOfLines = 2
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(
                equalTo: frameLayoutGuide.leadingAnchor,
                constant: 10
            ),
            placeholderLabel.trailingAnchor.constraint(
                equalTo: frameLayoutGuide.trailingAnchor,
                constant: -10
            ),
            placeholderLabel.topAnchor.constraint(
                equalTo: frameLayoutGuide.topAnchor,
                constant: 9
            ),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 58),
            heightAnchor.constraint(lessThanOrEqualToConstant: 110),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setPlaceholder(_ value: String) {
        placeholderLabel.text = value
        accessibilityLabel = "Optional initial prompt"
    }

    func setText(_ value: String) {
        guard text != value else { return }
        text = value
        placeholderLabel.isHidden = !value.isEmpty
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        onTextChange?(textView.text)
    }
}
