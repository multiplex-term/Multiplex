import Observation
import UIKit

// MARK: - Framework-neutral form state

/// Durable manual-form state. UIKit controls resolve editable rows through
/// their stable IDs, and this value also centralizes validation/normalization
/// so Test Connection and Save can never construct different hosts.
struct AddHostFormState {
    struct WorkingDirectory: Identifiable, Equatable {
        let id: UUID
        var path: String

        init(id: UUID = UUID(), path: String) {
            self.id = id
            self.path = path
        }
    }

    struct ScriptRow: Identifiable, Equatable {
        let id: UUID
        var name: String
        var body: String

        init(_ script: SessionScript) {
            id = script.id
            name = script.name
            body = script.body
        }

        init(id: UUID = UUID(), name: String = "", body: String = "") {
            self.id = id
            self.name = name
            self.body = body
        }

        var script: SessionScript {
            SessionScript(id: id, name: name, body: body)
        }
    }

    let editing: Host?
    var name = ""
    var hostname = ""
    var port = "22"
    var username = ""
    var authMethod = Host.AuthMethod.password
    var password = ""
    var privateKey = ""
    var privateKeyConcealed = false
    var passphrase = ""
    var isEnabled = true
    var backgroundKeepAlive = false
    var sessionBackend = Host.SessionBackend.tmux
    /// Backends beyond `sessionBackend` this host also shows tiles for.
    /// ⚠ Write this and `sessionBackend` through `setBackends(enabled:default:)`
    /// — the record stores a default plus extras, so touching either alone
    /// silently changes the other.
    var secondaryBackends: Set<Host.SessionBackend> = []
    var useMosh = false
    var moshServerPath = ""
    var moshPorts = ""
    var workingDirectories: [WorkingDirectory] = []
    var newWorkingDirectory = ""
    /// A host key the person already knows, pasted before the first
    /// connection so it is *verified* rather than trusted. Raw text, parsed
    /// by `HostKeyPin(userInput:)` on the way out — deliberately not seeded
    /// from `editing`, because it is an input for something new, never an
    /// editor for what was already recorded.
    var expectedHostKey = ""
    var newSessionTmuxConf = Host.defaultNewSessionTmuxConf
    var scripts: [ScriptRow] = []
    var modelText: [AgentKind: String] = [:]

    init(
        editing: Host?,
        secrets: HostSecrets = HostSecrets(
            password: nil,
            privateKey: nil,
            passphrase: nil
        )
    ) {
        self.editing = editing
        guard let host = editing else { return }
        name = host.name
        hostname = host.hostname
        port = String(host.port)
        username = host.username
        authMethod = host.authMethod
        password = secrets.password ?? ""
        privateKey = secrets.privateKey ?? ""
        privateKeyConcealed = !privateKey.isEmpty
        passphrase = secrets.passphrase ?? ""
        isEnabled = host.isEnabled
        backgroundKeepAlive = host.backgroundKeepAlive
        sessionBackend = host.sessionBackend
        secondaryBackends = host.secondaryBackends
        useMosh = host.useMosh
        moshServerPath = host.moshServerPath ?? ""
        moshPorts = host.moshPorts ?? ""
        workingDirectories = host.workingDirs.map { WorkingDirectory(path: $0) }
        newSessionTmuxConf = host.newSessionTmuxConf
        scripts = host.sessionScripts.map(ScriptRow.init)
        for agent in AgentKind.allCases {
            let models = host.launchModels(for: agent)
            if !models.isEmpty {
                modelText[agent] = models.joined(separator: "\n")
            }
        }
    }

    var isValid: Bool {
        !hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(port) != nil
            && moshPortsAreValid
    }

    /// Empty, one port, or a low:high range. Rejecting every character except
    /// digits and one colon also keeps this remote command argument inert.
    var moshPortsAreValid: Bool {
        guard useMosh else { return true }
        let trimmed = moshPorts.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part) else { return false }
            return (1...65535).contains(value)
        }
    }

    /// The two backend fields as one value — the Backend section's two
    /// controls each move one half, and `Host.BackendSelection` is where the
    /// rule that keeps them consistent lives.
    var backendSelection: Host.BackendSelection {
        get { Host.BackendSelection(preferred: sessionBackend, also: secondaryBackends) }
        set {
            sessionBackend = newValue.preferred
            secondaryBackends = newValue.secondaries
        }
    }

    var enabledBackends: Set<Host.SessionBackend> { backendSelection.enabled }

    var testFingerprint: [String] {
        [
            hostname, port, username, authMethod.rawValue,
            password, privateKey, passphrase,
            useMosh ? "mosh" : "ssh", moshServerPath,
            sessionBackend.rawValue,
        ]
    }

    var resolvedWorkingDirectories: [String] {
        var seen = Set<String>()
        var directories: [String] = []
        let pending = newWorkingDirectory.trimmingCharacters(in: .whitespaces)
        for path in workingDirectories.map(\.path) + [pending] {
            let directory = path.trimmingCharacters(in: .whitespaces)
            if !directory.isEmpty, seen.insert(directory).inserted {
                directories.append(directory)
            }
        }
        return directories
    }

    var resolvedLaunchModels: [String: [String]] {
        var models: [String: [String]] = [:]
        for agent in AgentKind.allCases {
            models[agent.rawValue] = (modelText[agent] ?? "")
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return models
    }

    func host(liveHost: Host?) -> Host {
        var host = liveHost
            ?? editing
            ?? Host(name: "", hostname: "", username: "")
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        host.name = trimmedName.isEmpty ? hostname : trimmedName
        host.hostname = hostname.trimmingCharacters(in: .whitespaces)
        host.port = Int(port) ?? 22
        host.username = username.trimmingCharacters(in: .whitespaces)
        host.authMethod = authMethod
        host.isEnabled = isEnabled
        host.backgroundKeepAlive = backgroundKeepAlive
        host.backendSelection = backendSelection
        host.useMosh = useMosh
        let serverPath = moshServerPath.trimmingCharacters(in: .whitespaces)
        host.moshServerPath = serverPath.isEmpty ? nil : serverPath
        let ports = moshPorts.trimmingCharacters(in: .whitespaces)
        host.moshPorts = ports.isEmpty ? nil : ports
        host.workingDirs = resolvedWorkingDirectories
        host.newSessionTmuxConf = TmuxProbe.normalizedTmuxConf(newSessionTmuxConf) ?? ""
        host.sessionScripts = SessionScript.normalized(scripts.map(\.script))

        var launchModels = host.agentLaunchModels.filter {
            AgentKind(rawValue: $0.key) == nil
        }
        for (agentRaw, values) in resolvedLaunchModels {
            launchModels[agentRaw] = values
        }
        host.agentLaunchModels = Host.normalizedLaunchModels(launchModels)

        // Additive, and only when the field holds something parseable: the
        // recorded keys are not otherwise the form's to edit (FORGET writes
        // through to the store on its own), so an empty or unreadable field
        // must leave them exactly as they were.
        if let expected = HostKeyPin(userInput: expectedHostKey),
           !host.pinnedHostKeys.contains(expected.storage) {
            host.pinnedHostKeys.append(expected.storage)
        }
        return host
    }

    mutating func addWorkingDirectory() {
        let directory = newWorkingDirectory.trimmingCharacters(in: .whitespaces)
        guard !directory.isEmpty,
              !workingDirectories.contains(where: { $0.path == directory })
        else { return }
        workingDirectories.append(WorkingDirectory(path: directory))
        newWorkingDirectory = ""
    }

    mutating func moveWorkingDirectory(id: UUID, offset: Int) {
        guard let source = workingDirectories.firstIndex(where: { $0.id == id })
        else { return }
        let destination = source + offset
        guard workingDirectories.indices.contains(destination) else { return }
        workingDirectories.swapAt(source, destination)
    }

    mutating func removeWorkingDirectory(id: UUID) {
        workingDirectories.removeAll { $0.id == id }
    }

    mutating func moveScript(id: UUID, offset: Int) {
        guard let source = scripts.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard scripts.indices.contains(destination) else { return }
        scripts.swapAt(source, destination)
    }
}

// MARK: - Native controller

/// Native Add Host / Host Settings sheet. BIND and MANUAL are two durable
/// roads within one controller; editing an existing host is manual-only.
@MainActor
final class AddHostViewController: UIViewController, UITextFieldDelegate,
    UIGestureRecognizerDelegate, UIAdaptivePresentationControllerDelegate,
    AppAppearanceFollowing {
    enum Mode: Hashable {
        case bind
        case manual
    }

    enum TestState: Equatable {
        case idle
        case running
        case passed(headline: String, warnings: [String])
        case failed(String)
    }

    enum Metrics {
        static let contentMaximumWidth: CGFloat = 680
        static let outerInset: CGFloat = 18
        static let sectionSpacing: CGFloat = 18
    }

    typealias SecretWriter = (Host.AuthMethod, HostSecrets, UUID) -> Void
    typealias HostWriter = (Host, Bool) -> Void
    typealias TestRunner = (Host, HostSecrets) async -> HostTest.Outcome

    let store: HostStore
    let entitlements: EntitlementStore
    let bind: BindController
    private(set) var form: AddHostFormState
    private(set) var mode: Mode = .bind
    private(set) var testState = TestState.idle

    var onDismiss: (() -> Void)?
    /// Native DeckWindow owns the presentation queue. Interactive sheet
    /// dismissal still belongs to this controller because it enforces the
    /// bind-in-flight veto; this callback lets the owner release its slot
    /// after that dismissal completes.
    var onPresentationDismissed: (() -> Void)?
    var presentPaywallOverride: (() -> Void)?
    var appAppearance = AppAppearance.system {
        didSet { applyAppearance() }
    }
    let appAppearanceFollower = AppAppearanceFollower()

    private(set) var contentStack = UIStackView()
    private(set) var manualStack = UIStackView()
    private(set) var bindPaneController: BindPaneViewController?
    private(set) var modeChoiceBar: AddHostChoiceBar<Mode>?
    private(set) var saveItem: UIBarButtonItem?
    private(set) var cancellationItem: UIBarButtonItem!

    private(set) var nameField = UITextField()
    private(set) var hostnameField = UITextField()
    private(set) var portField = UITextField()
    private(set) var usernameField = UITextField()
    private(set) var passwordField: AddHostRevealableSecretField?
    private(set) var privateKeyView: AddHostGrowingTextView?
    private(set) var passphraseField: AddHostRevealableSecretField?
    private(set) var monitoringControl: SettingsBooleanRow?
    private(set) var backgroundKeepAliveControl: SettingsBooleanRow?
    private(set) var moshControl: SettingsBooleanRow?
    private(set) var testChip: UIKitChassisChip?
    private(set) var newWorkingDirectoryField = UITextField()
    private(set) var newSessionTmuxConfView: AddHostGrowingTextView!
    private(set) var agentModelViews: [AgentKind: AddHostGrowingTextView] = [:]

    private let scrollView = UIScrollView()
    private let activeBodyContainer = UIView()
    private let modeDetailLabel = UILabel()
    private var modeHeader: UIStackView?
    private var bindContainer: UIView?
    private var bindHeightConstraint: NSLayoutConstraint?
    private var bindElsewhereOffset: CGFloat = 0

    private var hostSection: AddHostSectionView!
    private var monitoringSection: AddHostSectionView!
    private var credentialsSection: AddHostSectionView!
    private var testSection: AddHostSectionView!
    /// Not "Host identity" — that title belongs to the address section above.
    /// This one is SSH's own term for the server's key.
    private var hostKeySection: AddHostSectionView!
    /// First tap on FORGET arms, second confirms. A modal confirmation would
    /// be the usual answer, but this sheet presents none today and an
    /// undismissed one is a known visionOS test hazard — so the confirmation
    /// lives in the row.
    private var forgetHostKeysArmed = false
    private let expectedHostKeyField = UITextField()
    private let expectedHostKeyStatus = UILabel()
    private var workingDirectoriesSection: AddHostSectionView!
    private var tmuxConfSection: AddHostSectionView!
    private var scriptsSection: AddHostSectionView!
    private var agentModelsSection: AddHostSectionView!
    private var transportSection: AddHostSectionView!
    private var backendSection: AddHostSectionView!

    private var workingDirectoryFields: [UUID: UITextField] = [:]
    private var scriptNameFields: [UUID: UITextField] = [:]
    private var scriptBodyViews: [UUID: AddHostGrowingTextView] = [:]
    private var moshServerField: UITextField?
    private var moshPortsField: UITextField?
    private var moshPortsInvalidRow: UIView?
    private var addDirectoryChip: UIKitChassisChip?

    private let secretWriter: SecretWriter?
    private let hostWriter: HostWriter?
    private let testRunner: TestRunner?
    private var testTask: Task<Void, Never>?
    private var debugScrollTask: Task<Void, Never>?
    private var observesStores = true
    private var observationGeneration = 0
    private var dismissalRequested = false
    private var pendingPaywallPresentation = false
    private var didScheduleDebugScroll = false

    init(
        store: HostStore,
        entitlements: EntitlementStore,
        bind: BindController,
        editing: Host? = nil,
        secretLoader: ((Host) -> HostSecrets)? = nil,
        secretWriter: SecretWriter? = nil,
        hostWriter: HostWriter? = nil,
        testRunner: TestRunner? = nil
    ) {
        self.store = store
        self.entitlements = entitlements
        self.bind = bind
        self.secretWriter = secretWriter
        self.hostWriter = hostWriter
        self.testRunner = testRunner
        let secrets = editing.map { host in
            secretLoader?(host) ?? HostSecrets(
                password: KeychainStore.get(for: host.id, kind: .password),
                privateKey: KeychainStore.get(for: host.id, kind: .privateKey),
                passphrase: KeychainStore.get(for: host.id, kind: .keyPassphrase)
            )
        } ?? HostSecrets(password: nil, privateKey: nil, passphrase: nil)
        form = AddHostFormState(editing: editing, secrets: secrets)
        if editing != nil { mode = .manual }
        #if DEBUG
        if editing == nil, let request = AddHostAutoOpen.requested {
            mode = request == .manual ? .manual : .bind
        }
        #endif
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        observesStores = false
        testTask?.cancel()
        debugScrollTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = form.editing == nil ? "Add Host" : "Host Settings"
        view.backgroundColor = GlassPrototype.sheetGround
        configureNavigation()
        configureScrollView()
        buildManualForm()
        if form.editing == nil { configureModeHeader() }
        showResolvedMode()
        observeStoresState()
        applyAppearance()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyAppearance()
        updateDismissPolicy()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.presentationController?.delegate = self
        drainPendingPaywall()
        scheduleDebugScrollIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateBindHeight()
        applyKeyboardContentInset(to: scrollView)
    }

    func presentationControllerShouldDismiss(
        _ presentationController: UIPresentationController
    ) -> Bool {
        resolvedMode == .bind && !bind.enrollmentInFlight
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        clearSecrets()
        prepareForRemoval()
        onPresentationDismissed?()
    }

    func prepareForRemoval() {
        observesStores = false
        testTask?.cancel()
        debugScrollTask?.cancel()
        pendingPaywallPresentation = false
        bindPaneController?.prepareForRemoval()
        clearSecrets()
    }

    func setMode(_ mode: Mode) {
        guard form.editing == nil, self.mode != mode else { return }
        view.endEditing(true)
        self.mode = mode
        modeChoiceBar?.setSelection(mode)
        modeDetailLabel.text = modeDetail
        showResolvedMode()
    }

    // MARK: Root layout and navigation

    private var resolvedMode: Mode {
        form.editing == nil ? mode : .manual
    }

    private var modeDetail: String {
        switch resolvedMode {
        case .bind:
            return "Run the mpx CLI on the machine you're adding and it offers "
                + "itself — no address, user, or key to type here. Can't "
                + "install it? Switch to MANUAL."
        case .manual:
            return "Type the SSH destination yourself. Nothing to install on the machine."
        }
    }

    private func configureNavigation() {
        navigationItem.largeTitleDisplayMode = .never
        #if os(visionOS)
        navigationItem.titleView = UIKitChassisLabel(title ?? "", size: 12)
        #endif
        cancellationItem = UIBarButtonItem(
            title: "Cancel",
            style: .plain,
            target: self,
            action: #selector(cancelPressed)
        )
        cancellationItem.tintColor = UIKitChassis.signal
        navigationItem.leftBarButtonItem = cancellationItem

        let save = UIBarButtonItem(
            title: "Save",
            style: .plain,
            target: self,
            action: #selector(savePressed)
        )
        save.accessibilityLabel = "Save"
        saveItem = save
    }

    private func configureScrollView() {
        scrollView.alwaysBounceVertical = true
        #if !os(visionOS)
        scrollView.keyboardDismissMode = .interactive
        #endif
        scrollView.backgroundColor = GlassPrototype.clearedChassis
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
        contentStack.spacing = Metrics.sectionSpacing
        scrollView.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        let fillWidth = contentStack.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -(Metrics.outerInset * 2)
        )
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: Metrics.outerInset
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -Metrics.outerInset
            ),
            contentStack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            contentStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: Metrics.outerInset
            ),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -Metrics.outerInset
            ),
            contentStack.widthAnchor.constraint(
                lessThanOrEqualToConstant: Metrics.contentMaximumWidth
            ),
            fillWidth,
        ])
    }

    private func configureModeHeader() {
        let bar = AddHostChoiceBar(
            choices: [("Bind", Mode.bind), ("Manual", Mode.manual)],
            selection: mode
        ) { [weak self] mode in
            self?.setMode(mode)
        }
        modeChoiceBar = bar
        modeDetailLabel.font = UIKitChassis.uiFont(10)
        modeDetailLabel.textColor = UIKitChassis.signal2
        modeDetailLabel.numberOfLines = 0
        modeDetailLabel.text = modeDetail

        let detailHolder = UIView()
        detailHolder.addSubview(modeDetailLabel)
        modeDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            modeDetailLabel.leadingAnchor.constraint(equalTo: detailHolder.leadingAnchor, constant: 2),
            modeDetailLabel.trailingAnchor.constraint(equalTo: detailHolder.trailingAnchor, constant: -2),
            modeDetailLabel.topAnchor.constraint(equalTo: detailHolder.topAnchor),
            modeDetailLabel.bottomAnchor.constraint(equalTo: detailHolder.bottomAnchor),
        ])
        let header = UIStackView(arrangedSubviews: [bar, detailHolder])
        header.axis = .vertical
        header.alignment = .fill
        header.spacing = 8
        header.accessibilityIdentifier = "addhost.mode"
        modeHeader = header
        contentStack.addArrangedSubview(header)
    }

    private func showResolvedMode() {
        if activeBodyContainer.superview == nil {
            contentStack.addArrangedSubview(activeBodyContainer)
        }
        activeBodyContainer.subviews.forEach { $0.removeFromSuperview() }
        let body: UIView
        switch resolvedMode {
        case .bind:
            body = bindBody()
        case .manual:
            body = manualStack
        }
        activeBodyContainer.addSubview(body)
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: activeBodyContainer.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: activeBodyContainer.trailingAnchor),
            body.topAnchor.constraint(equalTo: activeBodyContainer.topAnchor),
            body.bottomAnchor.constraint(equalTo: activeBodyContainer.bottomAnchor),
        ])
        updateNavigationItems()
        updateDismissPolicy()
        view.setNeedsLayout()
    }

    private func bindBody() -> UIView {
        if let bindContainer { return bindContainer }
        let controller = BindPaneViewController(bind: bind)
        bindPaneController = controller
        addChild(controller)
        controller.loadViewIfNeeded()
        let container = UIView()
        container.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        // The pane's own view is required-pinned to this container, and the
        // placeholder height must sit BELOW the content's standard 750
        // hugging/compression priorities: Auto Layout satisfies priorities
        // strictly, so a 999 placeholder crushes every ordinary label to zero
        // height before it would stretch by a point — only required-priority
        // content (chips, the text field) survived, which is exactly the
        // "section titles missing until an appearance flip relayouts" first
        // render (the measurement below never got a pass with real width to
        // correct it). At defaultLow the pane renders from its own intrinsic
        // height immediately and the measured constant is just a refinement.
        let height = container.heightAnchor.constraint(equalToConstant: 240)
        height.priority = .defaultLow
        bindHeightConstraint = height
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: container.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            height,
        ])
        controller.didMove(toParent: self)
        controller.contentSizeDidChange = { [weak self] in
            self?.updateBindHeight()
        }
        controller.elsewhereOffsetDidChange = { [weak self] offset in
            self?.bindElsewhereOffset = offset
        }
        bindContainer = container
        return container
    }

    private func updateBindHeight() {
        guard resolvedMode == .bind,
              let controller = bindPaneController,
              let container = bindContainer,
              container.bounds.width > 0
        else { return }
        let height = controller.fittingSize(for: container.bounds.width).height
        guard height.isFinite,
              height > 0,
              abs((bindHeightConstraint?.constant ?? 0) - height) > 0.5
        else { return }
        bindHeightConstraint?.constant = height
        scrollView.setNeedsLayout()
    }

    private func updateNavigationItems() {
        cancellationItem.title = resolvedMode == .bind ? "Done" : "Cancel"
        cancellationItem.accessibilityLabel = cancellationItem.title
        navigationItem.rightBarButtonItem = resolvedMode == .manual ? saveItem : nil
        updateSaveAvailability()
    }

    private func updateSaveAvailability() {
        let enabled = form.isValid
        saveItem?.isEnabled = enabled
        saveItem?.tintColor = enabled ? UIKitChassis.signal : UIKitChassis.signal3
        updateTestAvailability()
    }

    /// Save and the Signal check answer to the same validity, so the chip has
    /// to follow every identity/transport edit. Its enabled state is otherwise
    /// baked at `renderTestSection()` time, which never re-runs while the test
    /// state is idle — the state a brand-new (invalid) form starts in.
    private func updateTestAvailability() {
        guard let testChip else { return }
        setChip(testChip, enabled: form.isValid && testState != .running)
    }

    private func updateDismissPolicy() {
        let blocked = resolvedMode == .manual || bind.enrollmentInFlight
        isModalInPresentation = blocked
        navigationController?.isModalInPresentation = blocked
    }

    private func applyAppearance() {
        applyAppAppearance()
        // The paywall this sheet raises is a sheet-on-a-sheet with no store of
        // its own: hand the choice down so a flip reaches it too.
        presentedPaywall?.appAppearance = appAppearance
    }

    private var presentedPaywall: ProPaywallViewController? {
        (presentedViewController as? UINavigationController)?
            .viewControllers.first as? ProPaywallViewController
    }

    // MARK: Manual form construction

    private func buildManualForm() {
        manualStack.axis = .vertical
        manualStack.alignment = .fill
        manualStack.spacing = Metrics.sectionSpacing
        manualStack.accessibilityIdentifier = "addhost.manual"
        let dismissKeyboard = UITapGestureRecognizer(
            target: self,
            action: #selector(manualGroundTapped)
        )
        dismissKeyboard.cancelsTouchesInView = false
        dismissKeyboard.delegate = self
        manualStack.addGestureRecognizer(dismissKeyboard)

        hostSection = makeHostSection()
        monitoringSection = makeMonitoringSection()
        credentialsSection = AddHostSectionView(title: "Credentials", detail: nil, rows: [])
        credentialsSection.accessibilityIdentifier = "addhost.section.credentials"
        testSection = AddHostSectionView(title: "Signal check", detail: nil, rows: [])
        testSection.accessibilityIdentifier = "addhost.section.signal"
        hostKeySection = AddHostSectionView(title: "Host key", detail: nil, rows: [])
        hostKeySection.accessibilityIdentifier = "addhost.section.hostkey"
        workingDirectoriesSection = AddHostSectionView(
            title: "New session defaults",
            detail: nil,
            rows: []
        )
        workingDirectoriesSection.accessibilityIdentifier = "addhost.section.directories"
        tmuxConfSection = makeTmuxConfSection()
        scriptsSection = AddHostSectionView(
            title: "Session setup scripts",
            detail: nil,
            rows: []
        )
        scriptsSection.accessibilityIdentifier = "addhost.section.scripts"
        agentModelsSection = makeAgentModelsSection()
        transportSection = AddHostSectionView(title: "Transport", detail: nil, rows: [])
        transportSection.accessibilityIdentifier = "addhost.section.transport"
        backendSection = AddHostSectionView(title: "Backend", detail: nil, rows: [])
        backendSection.accessibilityIdentifier = "addhost.section.backend"

        // Host key sits last, after Transport. It stopped being a read-out
        // beside Signal check the moment it grew a field to type into, and it
        // is the section a person touches least — most hosts never need it,
        // because the first connection or `mpx bind` fills it in.
        [
            hostSection,
            monitoringSection,
            backendSection,
            credentialsSection,
            testSection,
            workingDirectoriesSection,
            tmuxConfSection,
            scriptsSection,
            agentModelsSection,
            transportSection,
            hostKeySection,
        ].forEach { manualStack.addArrangedSubview($0) }

        renderCredentials()
        renderTestSection()
        renderHostKeys()
        renderWorkingDirectories()
        renderScripts()
        renderTransport()
        renderBackend()
    }

    private func makeHostSection() -> AddHostSectionView {
        configureTextField(nameField, placeholder: "devbox", identifier: "addhost.name")
        nameField.accessibilityLabel = "Name"
        nameField.text = form.name
        nameField.addTarget(self, action: #selector(identityFieldChanged(_:)), for: .editingChanged)

        configureTextField(
            hostnameField,
            placeholder: "host.example.com",
            identifier: "addhost.hostname"
        )
        hostnameField.text = form.hostname
        hostnameField.accessibilityLabel = "Address"
        hostnameField.keyboardType = .URL
        hostnameField.autocorrectionType = .no
        hostnameField.autocapitalizationType = .none
        hostnameField.addTarget(self, action: #selector(identityFieldChanged(_:)), for: .editingChanged)

        configureTextField(portField, placeholder: "22", identifier: "addhost.port")
        portField.text = form.port
        portField.accessibilityLabel = "Port"
        portField.keyboardType = .numberPad
        portField.addTarget(self, action: #selector(identityFieldChanged(_:)), for: .editingChanged)

        configureTextField(usernameField, placeholder: "root", identifier: "addhost.username")
        usernameField.text = form.username
        usernameField.accessibilityLabel = "User"
        usernameField.keyboardType = .asciiCapable
        usernameField.autocorrectionType = .no
        usernameField.autocapitalizationType = .none
        usernameField.textContentType = UITextContentType(rawValue: "")
        usernameField.addTarget(self, action: #selector(identityFieldChanged(_:)), for: .editingChanged)

        let section = AddHostSectionView(
            title: "Host identity",
            detail: "The name labels this host on the deck. Address, port, and user "
                + "form the SSH destination.",
            rows: [
                AddHostFieldRow(label: "Name", inputView: nameField),
                AddHostFieldRow(label: "Address", inputView: hostnameField),
                AddHostFieldRow(label: "Port", inputView: portField),
                AddHostFieldRow(label: "User", inputView: usernameField),
            ]
        )
        section.accessibilityIdentifier = "addhost.section.host"
        return section
    }

    private func makeMonitoringSection() -> AddHostSectionView {
        let control = SettingsBooleanRow(
            title: "Connect on the deck",
            isOn: form.isEnabled,
            accessibilityHint: "Off keeps the host in the fleet without connecting to it"
        ) { [weak self] enabled in
            guard let self else { return }
            self.form.isEnabled = enabled
            self.monitoringSection.setDetail(self.monitoringDetail)
        }
        monitoringControl = control
        let keepAlive = SettingsBooleanRow(
            title: "Keep alive in background",
            isOn: form.backgroundKeepAlive,
            accessibilityHint: "Holds this host's sessions and probing open for the extra "
                + "seconds iOS grants after you leave the app"
        ) { [weak self] enabled in
            guard let self else { return }
            self.form.backgroundKeepAlive = enabled
            self.monitoringSection.setDetail(self.monitoringDetail)
        }
        backgroundKeepAliveControl = keepAlive
        let section = AddHostSectionView(
            title: "Monitoring",
            detail: monitoringDetail,
            rows: [control, keepAlive]
        )
        section.accessibilityIdentifier = "addhost.section.monitoring"
        return section
    }

    /// One caption for both switches — they answer the same question at two
    /// scales: whether the app dials this host at all, and whether it keeps
    /// doing so for a moment after you look away.
    private var monitoringDetail: String {
        let connect = form.isEnabled
            ? "The deck probes this host about every five seconds while it's in "
                + "front, and its sessions appear as live tiles."
            : "Off parks the host on the deck without dialling it: no probing, no tiles, "
                + "and widgets or Shortcuts report it as disabled. Terminal windows already "
                + "open keep running, and Signal check below still connects on demand."
        // Sized to the mechanism on purpose. iOS grants a leaving app a short
        // stretch of extra running time and nothing more; the modes that would
        // buy minutes are for apps genuinely playing audio or tracking
        // location, so the promise here stops where the grant does.
        let keepAlive = form.backgroundKeepAlive
            ? "Leaving the app holds this host's sessions and probing open for the extra "
                + "time iOS grants — tens of seconds, not minutes. Agent alerts still reach "
                + "you inside that window; after it the app suspends as usual and tabs "
                + "reattach when you come back."
            : "Background keep-alive is off: leaving the app suspends it, this host's "
                + "sessions drop, and its tabs reattach when you return."
        return connect + "\n\n" + keepAlive
    }

    private func renderCredentials() {
        let authLabel = addHostLabel(
            "Sign in with",
            font: UIKitChassis.uiFont(10, weight: .semibold),
            color: UIKitChassis.signal2
        )
        let choices = AddHostChoiceBar(
            choices: Host.AuthMethod.allCases.map { ($0.label, $0) },
            selection: form.authMethod
        ) { [weak self] method in
            guard let self else { return }
            self.updateTestSensitive { $0.authMethod = method }
            self.renderCredentials()
        }
        let authStack = UIStackView(arrangedSubviews: [authLabel, choices])
        authStack.axis = .vertical
        authStack.alignment = .fill
        authStack.spacing = 8
        var rows: [UIView] = [AddHostInsetRow(contentView: authStack)]

        switch form.authMethod {
        case .password:
            let secret = AddHostRevealableSecretField(
                title: "Password",
                prompt: "Required",
                text: form.password
            ) { [weak self] text in
                self?.updateTestSensitive { $0.password = text }
            }
            secret.textField.accessibilityIdentifier = "addhost.password"
            passwordField = secret
            rows.append(AddHostFieldRow(label: "Password", inputView: secret))
            credentialsSection.setDetail(
                "Stored in iCloud Keychain, never in the host record."
            )
        case .privateKey:
            if form.privateKeyConcealed {
                let reveal = makeConcealedPrivateKeyButton()
                rows.append(AddHostFieldRow(label: "Private key", inputView: reveal))
            } else {
                let keyView = AddHostGrowingTextView(
                    text: form.privateKey,
                    placeholder: "BEGIN OPENSSH PRIVATE KEY",
                    font: UIKitChassis.monoFont(12),
                    minimumLines: 4,
                    maximumLines: 8
                )
                keyView.accessibilityLabel = "Private key"
                keyView.accessibilityIdentifier = "addhost.privateKey"
                keyView.autocorrectionType = .no
                keyView.autocapitalizationType = .none
                keyView.textContentType = UITextContentType(rawValue: "")
                keyView.onTextChange = { [weak self] text in
                    self?.updateTestSensitive { $0.privateKey = text }
                }
                privateKeyView = keyView
                rows.append(AddHostFieldRow(label: "Private key", inputView: keyView))
            }
            let secret = AddHostRevealableSecretField(
                title: "Passphrase",
                prompt: "Optional",
                text: form.passphrase
            ) { [weak self] text in
                self?.updateTestSensitive { $0.passphrase = text }
            }
            secret.textField.accessibilityIdentifier = "addhost.passphrase"
            passphraseField = secret
            rows.append(AddHostFieldRow(label: "Passphrase", inputView: secret))
            credentialsSection.setDetail(
                "The OpenSSH key is stored in iCloud Keychain. Leave its passphrase "
                    + "blank to enter it when connecting, or save the passphrase there too."
            )
        }
        credentialsSection.setRows(rows)
    }

    private func makeConcealedPrivateKeyButton() -> UIView {
        let button = UIButton(type: .custom)
        button.backgroundColor = .clear
        button.hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        button.accessibilityLabel = "Edit private key"
        button.accessibilityHint = "Shows the saved key"
        button.accessibilityIdentifier = "addhost.privateKeyConcealed"
        let bullets = addHostLabel(
            String(repeating: "•", count: 8),
            font: UIKitChassis.monoFont(12),
            color: UIKitChassis.signal
        )
        let content = UIStackView(arrangedSubviews: [
            bullets,
            addHostFlexibleSpacer(minimumWidth: 12),
            UIKitChassisLabel("EDIT", size: 8, color: UIKitChassis.signal2),
        ])
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 12
        content.isUserInteractionEnabled = false
        button.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            content.topAnchor.constraint(equalTo: button.topAnchor),
            content.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.form.privateKeyConcealed = false
            self.renderCredentials()
        }, for: .touchUpInside)
        return button
    }

    private func makeTmuxConfSection() -> AddHostSectionView {
        let textView = AddHostGrowingTextView(
            text: form.newSessionTmuxConf,
            placeholder: "cleared — nothing applied",
            font: UIKitChassis.monoFont(12),
            minimumLines: 2,
            maximumLines: 6
        )
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.accessibilityLabel = "Options"
        textView.accessibilityIdentifier = "addhost.tmuxConf"
        textView.onTextChange = { [weak self] text in
            self?.form.newSessionTmuxConf = text
        }
        newSessionTmuxConfView = textView
        let section = AddHostSectionView(
            title: "New session tmux conf",
            detail: "One option per line, like a .tmux.conf (mouse on, history-limit "
                + "50000). Each line is applied when Multiplex creates a session with "
                + "tmux set-option -t that session. Attaching never applies anything, "
                + "and session-scoped options do not change sessions made on the host. "
                + "Hosts start with mouse on and focus-events on; clear the field to "
                + "apply nothing. Focus events and other server-scoped options still "
                + "reach the whole tmux server.",
            rows: [AddHostFieldRow(label: "Options", inputView: textView)]
        )
        section.accessibilityIdentifier = "addhost.section.tmuxConf"
        return section
    }

    private func makeAgentModelsSection() -> AddHostSectionView {
        var rows: [UIView] = []
        for agent in AgentKind.allCases {
            let textView = AddHostGrowingTextView(
                text: form.modelText[agent] ?? "",
                placeholder: modelPlaceholder(for: agent),
                font: UIKitChassis.monoFont(12),
                minimumLines: 1,
                maximumLines: 5
            )
            textView.autocorrectionType = .no
            textView.autocapitalizationType = .none
            textView.accessibilityLabel = "\(agent.displayName) models, one per line"
            textView.accessibilityIdentifier = "addhost.models.\(agent.rawValue)"
            textView.onTextChange = { [weak self] text in
                self?.form.modelText[agent] = text
            }
            agentModelViews[agent] = textView
            rows.append(AddHostFieldRow(label: agent.displayName, inputView: textView))
        }
        let section = AddHostSectionView(
            title: "Agent launch models",
            detail: "One model id per line, in picker order. New Session, the Open Agent "
                + "shortcut, and the host widget offer them as choices, passed as "
                + "--model; nothing is applied unless chosen at launch.",
            rows: rows
        )
        section.accessibilityIdentifier = "addhost.section.agentModels"
        return section
    }

    private func modelPlaceholder(for agent: AgentKind) -> String {
        switch agent {
        case .claudeCode: return "opus, sonnet, or a full model id"
        case .codex: return "model id per line"
        case .pi: return "provider/model-id per line"
        case .grok: return "grok-build, or a full model id"
        }
    }

    // MARK: Signal check

    private var testDetail: String {
        let backend = form.sessionBackend.rawValue
        return form.useMosh
            ? "Signs in over SSH with the settings above, then looks for \(backend) and "
                + "mosh-server on the host."
            : "Signs in over SSH with the settings above, then looks for \(backend) "
                + "on the host."
    }

    private func renderTestSection() {
        let chip = UIKitChassisChip(
            "TEST CONNECTION",
            accessibilityLabel: "Test connection"
        ) { [weak self] in
            self?.runTest()
        }
        testChip = chip
        updateTestAvailability()
        let testRowStack = UIStackView(arrangedSubviews: [chip, addHostFlexibleSpacer()])
        testRowStack.axis = .horizontal
        testRowStack.alignment = .center
        testRowStack.spacing = 12
        if testState == .running {
            testRowStack.addArrangedSubview(UIKitTallyLamp(
                caption: "TESTING",
                color: TallyPalette.caution
            ))
        }
        var rows: [UIView] = [AddHostInsetRow(contentView: testRowStack)]
        switch testState {
        case .idle, .running:
            break
        case .passed(let headline, let warnings):
            let connected = UIStackView(arrangedSubviews: [
                UIKitTallyLamp(caption: "CONNECTED", color: TallyPalette.ok),
                addHostLabel(
                    headline,
                    font: UIKitChassis.uiFont(11, weight: .medium),
                    color: UIKitChassis.signal
                ),
            ])
            connected.axis = .horizontal
            connected.alignment = .center
            connected.spacing = 10
            let result = UIStackView(arrangedSubviews: [connected])
            result.axis = .vertical
            result.alignment = .fill
            result.spacing = 10
            for warning in warnings {
                let warningLabel = addHostLabel(
                    warning,
                    font: UIKitChassis.uiFont(10),
                    color: UIKitChassis.signal2
                )
                let row = UIStackView(arrangedSubviews: [
                    UIKitTallyLamp(caption: "CHECK", color: TallyPalette.caution),
                    warningLabel,
                ])
                row.axis = .horizontal
                row.alignment = .top
                row.spacing = 10
                result.addArrangedSubview(row)
            }
            rows.append(AddHostInsetRow(contentView: result))
        case .failed(let message):
            let failure = UIStackView(arrangedSubviews: [
                UIKitTallyLamp(caption: "NO SIGNAL", color: TallyPalette.caution),
                addHostLabel(
                    message,
                    font: UIKitChassis.uiFont(11),
                    color: UIKitChassis.signal
                ),
            ])
            failure.axis = .horizontal
            failure.alignment = .top
            failure.spacing = 10
            rows.append(AddHostInsetRow(contentView: failure))
        }
        testSection.setDetail(testDetail)
        testSection.setRows(rows)
    }

    /// The server keys this host is checked against — written by `mpx bind`
    /// from the machine itself, or learned on the first connection.
    ///
    /// Read from the live record rather than the form: `AddHostFormState`
    /// deliberately doesn't carry `pinnedHostKeys` (its `host(liveHost:)`
    /// preserves them untouched, which `AddHostUIKitTests` pins), and forget
    /// is an immediate action rather than a pending edit.
    private var recordedHostKeys: [HostKeyPin] {
        guard let id = form.editing?.id else { return [] }
        return HostKeyPin.parse(store.host(id: id)?.pinnedHostKeys ?? [])
    }

    private var hostKeyDetail: String {
        if forgetHostKeysArmed {
            return "Tap again to forget. The next connection trusts whatever answers, and records that."
        }
        return recordedHostKeys.isEmpty
            ? "With nothing here, the first connection trusts what answers and records it. "
                + "Paste a key you already have and it is checked instead."
            : "Checked on every connection. Forget these only if you rebuilt the server."
    }

    private func renderHostKeys() {
        let pins = recordedHostKeys
        var rows: [UIView] = pins.map { pin in
            let algorithm = UIKitChassisLabel(
                pin.algorithm.uppercased(),
                size: 8,
                color: UIKitChassis.signal3
            )
            let fingerprint = addHostLabel(
                pin.fingerprint,
                font: UIKitChassis.monoFont(11),
                color: UIKitChassis.signal
            )
            let stack = UIStackView(arrangedSubviews: [algorithm, fingerprint])
            stack.axis = .vertical
            stack.alignment = .fill
            stack.spacing = 3
            return AddHostInsetRow(contentView: stack)
        }

        if !pins.isEmpty {
            let forget = UIKitChassisChip(
                forgetHostKeysArmed ? "CONFIRM FORGET" : "FORGET",
                accessibilityLabel: forgetHostKeysArmed
                    ? "Confirm forgetting recorded host keys"
                    : "Forget recorded host keys"
            ) { [weak self] in self?.forgetHostKeysTapped() }
            forget.accessibilityIdentifier = "addhost.hostkey.forget"
            let forgetRow = UIStackView(arrangedSubviews: [forget, addHostFlexibleSpacer()])
            forgetRow.axis = .horizontal
            forgetRow.alignment = .center
            forgetRow.spacing = 12
            rows.append(AddHostInsetRow(contentView: forgetRow))
        }

        rows.append(AddHostInsetRow(contentView: expectedHostKeyRow()))
        hostKeySection.setDetail(hostKeyDetail)
        hostKeySection.setRows(rows)
    }

    /// The paste target for a key learned out of band — `ssh-keyscan`, a
    /// `.pub` file, `ssh-keygen -lf`, or the `SHA256:…` a provider console
    /// shows. The field is reused across renders so typing never loses the
    /// caret, and it reports what it made of the text as you go: a
    /// fingerprint silently ignored would be worse than none at all, because
    /// the person would believe they were verified when they were not.
    private func expectedHostKeyRow() -> UIView {
        configureInlineField(
            expectedHostKeyField,
            text: form.expectedHostKey,
            placeholder: "SHA256:… or ssh-ed25519 AAAA…",
            font: UIKitChassis.monoFont(11)
        )
        expectedHostKeyField.accessibilityLabel = "Expected host key"
        expectedHostKeyField.accessibilityIdentifier = "addhost.hostkey.expected"
        expectedHostKeyField.autocorrectionType = .no
        expectedHostKeyField.autocapitalizationType = .none
        expectedHostKeyField.returnKeyType = .done
        expectedHostKeyField.delegate = self
        expectedHostKeyField.removeTarget(
            self, action: #selector(expectedHostKeyChanged), for: .editingChanged
        )
        expectedHostKeyField.addTarget(
            self, action: #selector(expectedHostKeyChanged), for: .editingChanged
        )

        expectedHostKeyStatus.font = UIKitChassis.uiFont(10)
        expectedHostKeyStatus.numberOfLines = 0
        expectedHostKeyStatus.accessibilityIdentifier = "addhost.hostkey.expectedStatus"
        updateExpectedHostKeyStatus()

        let caption = addHostLabel(
            "Expected key (optional)",
            font: UIKitChassis.uiFont(10, weight: .semibold),
            color: UIKitChassis.signal2
        )
        let stack = UIStackView(arrangedSubviews: [
            caption,
            AddHostInlineWell(contentView: expectedHostKeyField),
            expectedHostKeyStatus,
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 7
        return stack
    }

    @objc private func expectedHostKeyChanged() {
        form.expectedHostKey = expectedHostKeyField.text ?? ""
        updateExpectedHostKeyStatus()
    }

    /// Says what the text was understood as, not merely whether it parsed:
    /// someone pasting a key wants to see the digest it resolved to, because
    /// that is the value they can hold against the machine.
    private func updateExpectedHostKeyStatus() {
        let text = form.expectedHostKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            expectedHostKeyStatus.isHidden = true
            return
        }
        expectedHostKeyStatus.isHidden = false
        guard let pin = HostKeyPin(userInput: text) else {
            expectedHostKeyStatus.textColor = TallyPalette.caution
            expectedHostKeyStatus.text = "Not a host key. Paste a SHA256: fingerprint, or a "
                + "public key line from the machine's /etc/ssh."
            return
        }
        expectedHostKeyStatus.textColor = UIKitChassis.signal2
        expectedHostKeyStatus.text = pin.algorithm == HostKeyPin.anyAlgorithm
            ? "Will verify against \(pin.fingerprint)"
            : "Will verify against \(pin.algorithm) \(pin.fingerprint)"
    }

    private func forgetHostKeysTapped() {
        guard let id = form.editing?.id else { return }
        guard forgetHostKeysArmed else {
            forgetHostKeysArmed = true
            renderHostKeys()
            return
        }
        forgetHostKeysArmed = false
        // Writes straight through rather than waiting for Save: this is a
        // recovery action with its own meaning, and routing it through the
        // form would make `host(liveHost:)` start carrying pins.
        store.forgetHostKeyPins(for: id)
        renderHostKeys()
    }

    private func runTest() {
        guard form.isValid, testState != .running else { return }
        testTask?.cancel()
        testState = .running
        renderTestSection()
        let host = formHost()
        let secrets = currentSecrets
        let fingerprint = form.testFingerprint
        let runner = testRunner
        testTask = Task { [weak self] in
            let outcome: HostTest.Outcome
            if let runner {
                outcome = await runner(host, secrets)
            } else {
                outcome = await HostTest.run(host: host, secrets: secrets)
            }
            guard let self,
                  !Task.isCancelled,
                  fingerprint == self.form.testFingerprint
            else { return }
            switch outcome {
            case .connected(let report):
                var warnings: [String] = []
                if !report.multiplexerFound {
                    let backend = host.sessionBackend.rawValue
                    warnings.append(
                        "\(backend) wasn't found on the host — the deck can't list sessions "
                            + "there. Plain shells still work."
                    )
                }
                if report.moshServerFound == false {
                    warnings.append(
                        "mosh-server wasn't found — mosh attaches will fail. Install it "
                            + "on the host or set its path below."
                    )
                }
                self.testState = .passed(
                    headline: "Connected to \(host.hostname) as \(host.username).",
                    warnings: warnings
                )
            case .failed(let message):
                self.testState = .failed(message)
            }
            self.renderTestSection()
        }
    }

    private func updateTestSensitive(_ mutation: (inout AddHostFormState) -> Void) {
        let fingerprint = form.testFingerprint
        mutation(&form)
        if fingerprint != form.testFingerprint, testState != .idle {
            testTask?.cancel()
            testState = .idle
            renderTestSection()
        }
        updateSaveAvailability()
    }

    // MARK: Working directories

    private var workingDirectoriesDetail: String {
        form.workingDirectories.isEmpty
            ? "New sessions start in the host's home directory. Add paths to make them "
                + "available in New Session."
            : "The first path is the default. New Session can choose another path or "
                + "the host's home directory."
    }

    private func renderWorkingDirectories() {
        workingDirectoryFields.removeAll()
        var rows: [UIView] = []
        for directory in form.workingDirectories {
            let field = UITextField()
            configureInlineField(
                field,
                text: directory.path,
                placeholder: "Directory",
                font: UIKitChassis.monoFont(11)
            )
            field.accessibilityLabel = "Directory"
            field.accessibilityIdentifier = "addhost.directory.\(directory.id.uuidString)"
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.addAction(UIAction { [weak self, weak field] _ in
                guard let self,
                      let field,
                      let index = self.form.workingDirectories.firstIndex(
                        where: { $0.id == directory.id }
                      )
                else { return }
                self.form.workingDirectories[index].path = field.text ?? ""
            }, for: .editingChanged)
            workingDirectoryFields[directory.id] = field

            let index = form.workingDirectories.firstIndex(where: { $0.id == directory.id }) ?? 0
            let label = UIKitChassisLabel(
                directory.id == form.workingDirectories.first?.id ? "DEFAULT" : "PATH",
                size: 8,
                color: directory.id == form.workingDirectories.first?.id
                    ? UIKitChassis.signal2
                    : UIKitChassis.signal3
            )
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 54).isActive = true
            let row = UIStackView(arrangedSubviews: [
                label,
                AddHostInlineWell(contentView: field),
                AddHostIconButton(
                    systemImage: "arrow.up",
                    accessibilityLabel: "Move directory up",
                    enabled: index > 0
                ) { [weak self] in
                    self?.form.moveWorkingDirectory(id: directory.id, offset: -1)
                    self?.renderWorkingDirectories()
                },
                AddHostIconButton(
                    systemImage: "arrow.down",
                    accessibilityLabel: "Move directory down",
                    enabled: index < form.workingDirectories.count - 1
                ) { [weak self] in
                    self?.form.moveWorkingDirectory(id: directory.id, offset: 1)
                    self?.renderWorkingDirectories()
                },
                AddHostIconButton(
                    systemImage: "trash",
                    accessibilityLabel: "Delete directory"
                ) { [weak self] in
                    self?.form.removeWorkingDirectory(id: directory.id)
                    self?.renderWorkingDirectories()
                },
            ])
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 8
            rows.append(AddHostInsetRow(contentView: row))
        }

        configureInlineField(
            newWorkingDirectoryField,
            text: form.newWorkingDirectory,
            placeholder: "~/projects/app",
            font: UIKitChassis.monoFont(11)
        )
        newWorkingDirectoryField.accessibilityLabel = "Add directory"
        newWorkingDirectoryField.accessibilityIdentifier = "addhost.newDirectory"
        newWorkingDirectoryField.autocorrectionType = .no
        newWorkingDirectoryField.autocapitalizationType = .none
        newWorkingDirectoryField.returnKeyType = .done
        newWorkingDirectoryField.delegate = self
        newWorkingDirectoryField.removeTarget(
            self,
            action: #selector(newDirectoryChanged),
            for: .editingChanged
        )
        newWorkingDirectoryField.addTarget(
            self,
            action: #selector(newDirectoryChanged),
            for: .editingChanged
        )
        let add = UIKitChassisChip(
            "ADD",
            systemImage: "plus",
            accessibilityLabel: "Add directory"
        ) { [weak self] in self?.addWorkingDirectory() }
        addDirectoryChip = add
        updateAddDirectoryAvailability()
        let addRow = UIStackView(arrangedSubviews: [
            AddHostInlineWell(contentView: newWorkingDirectoryField),
            add,
        ])
        addRow.axis = .horizontal
        addRow.alignment = .center
        addRow.spacing = 8
        let addLabel = addHostLabel(
            "Add directory",
            font: UIKitChassis.uiFont(10, weight: .semibold),
            color: UIKitChassis.signal2
        )
        let addStack = UIStackView(arrangedSubviews: [addLabel, addRow])
        addStack.axis = .vertical
        addStack.alignment = .fill
        addStack.spacing = 7
        rows.append(AddHostInsetRow(contentView: addStack))
        workingDirectoriesSection.setDetail(workingDirectoriesDetail)
        workingDirectoriesSection.setRows(rows)
    }

    private func addWorkingDirectory() {
        let before = form.workingDirectories.count
        form.addWorkingDirectory()
        guard form.workingDirectories.count != before else { return }
        renderWorkingDirectories()
    }

    private func updateAddDirectoryAvailability() {
        let enabled = !form.newWorkingDirectory
            .trimmingCharacters(in: .whitespaces).isEmpty
        if let addDirectoryChip { setChip(addDirectoryChip, enabled: enabled) }
    }

    // MARK: Setup scripts

    private var scriptsDetail: String {
        form.scripts.isEmpty
            ? "New Session can type a chosen script into the fresh shell before anything "
                + "launches. Add one to make it available."
            : "New Session offers these by name; the chosen one is typed into the fresh "
                + "shell before the launch command."
    }

    private func renderScripts() {
        scriptNameFields.removeAll()
        scriptBodyViews.removeAll()
        var rows: [UIView] = []
        for script in form.scripts {
            let name = UITextField()
            configureInlineField(
                name,
                text: script.name,
                placeholder: "Name",
                font: UIKitChassis.uiFont(11, weight: .medium)
            )
            name.autocorrectionType = .no
            name.autocapitalizationType = .none
            name.accessibilityLabel = "Script name"
            name.accessibilityIdentifier = "addhost.scriptName.\(script.id.uuidString)"
            name.addAction(UIAction { [weak self, weak name] _ in
                guard let self,
                      let name,
                      let index = self.form.scripts.firstIndex(where: { $0.id == script.id })
                else { return }
                self.form.scripts[index].name = name.text ?? ""
            }, for: .editingChanged)
            scriptNameFields[script.id] = name

            let index = form.scripts.firstIndex(where: { $0.id == script.id }) ?? 0
            let header = UIStackView(arrangedSubviews: [
                AddHostInlineWell(contentView: name),
                AddHostIconButton(
                    systemImage: "arrow.up",
                    accessibilityLabel: "Move script up",
                    enabled: index > 0
                ) { [weak self] in
                    self?.form.moveScript(id: script.id, offset: -1)
                    self?.renderScripts()
                },
                AddHostIconButton(
                    systemImage: "arrow.down",
                    accessibilityLabel: "Move script down",
                    enabled: index < form.scripts.count - 1
                ) { [weak self] in
                    self?.form.moveScript(id: script.id, offset: 1)
                    self?.renderScripts()
                },
                AddHostIconButton(
                    systemImage: "trash",
                    accessibilityLabel: "Delete script"
                ) { [weak self] in
                    self?.form.scripts.removeAll { $0.id == script.id }
                    self?.renderScripts()
                },
            ])
            header.axis = .horizontal
            header.alignment = .center
            header.spacing = 8

            let body = AddHostGrowingTextView(
                text: script.body,
                placeholder: "source ~/.venv/bin/activate",
                font: UIKitChassis.monoFont(11),
                minimumLines: 2,
                maximumLines: 6
            )
            body.autocorrectionType = .no
            body.autocapitalizationType = .none
            body.accessibilityLabel = "Script commands"
            body.accessibilityIdentifier = "addhost.scriptBody.\(script.id.uuidString)"
            body.onTextChange = { [weak self] text in
                guard let self,
                      let index = self.form.scripts.firstIndex(where: { $0.id == script.id })
                else { return }
                self.form.scripts[index].body = text
            }
            scriptBodyViews[script.id] = body
            let bodyWell = AddHostInlineWell(contentView: body)
            let content = UIStackView(arrangedSubviews: [header, bodyWell])
            content.axis = .vertical
            content.alignment = .fill
            content.spacing = 8
            rows.append(AddHostInsetRow(contentView: content))
        }

        let add = UIKitChassisChip(
            "ADD SCRIPT",
            systemImage: "plus",
            accessibilityLabel: "Add script"
        ) { [weak self] in
            self?.form.scripts.append(AddHostFormState.ScriptRow())
            self?.renderScripts()
        }
        rows.append(AddHostInsetRow(contentView: addHostLeadingView(add)))
        scriptsSection.setDetail(scriptsDetail)
        scriptsSection.setRows(rows)
    }

    // MARK: Backend

    /// Every backend this host shows tiles for — the checked set.
    private var enabledBackends: Set<Host.SessionBackend> { form.enabledBackends }

    private var backendDetail: String {
        let enabled = enabledBackends
        var detail: String
        if enabled.contains(.herdr) {
            detail = "The deck monitors herdr (herdr.dev) sessions and their "
                + "agents through the herdr CLI — one tile per session, its "
                + "workspaces as the tile's window lines; a tile attaches "
                + "the full herdr client. The tmux options editor doesn't "
                + "apply to herdr sessions."
        } else {
            detail = "The deck monitors a remote tmux server — sessions, "
                + "windows, and agent panes. herdr (herdr.dev) is the "
                + "alternative for hosts that run it."
        }
        if enabled.count > 1 {
            detail += "\n\nBoth are shown, each tile marked with the backend "
                + "it came from. That \(HostGuide.secondBackendCost)."
        }
        return detail
    }

    private func renderBackend() {
        let checks = AddHostCheckBar<Host.SessionBackend>(
            // The button face uppercases; pass the natural spelling so
            // VoiceOver reads "tmux", not the letters T-M-U-X.
            choices: Host.SessionBackend.allCases.map { ($0.rawValue, $0) },
            selection: enabledBackends
        ) { [weak self] backends in
            self?.setEnabledBackends(backends)
        }
        checks.accessibilityIdentifier = "addhost.backendChecks"
        let checksLabel = addHostLabel(
            "Backends",
            font: UIKitChassis.uiFont(10, weight: .semibold),
            color: UIKitChassis.signal2
        )
        let stack = UIStackView(arrangedSubviews: [checksLabel, checks])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8

        // The default is only a question when there is more than one answer.
        // On the single-backend host — the overwhelmingly common case — the
        // section is exactly one labelled control, as it always was.
        if enabledBackends.count > 1 {
            let bar = AddHostChoiceBar<Host.SessionBackend>(
                choices: Host.SessionBackend.allCases
                    .filter(enabledBackends.contains)
                    .map { ($0.rawValue, $0) },
                selection: form.sessionBackend
            ) { [weak self] backend in
                guard let self else { return }
                // Only the DEFAULT moves — the checked set is unchanged,
                // so the old default stays checked as a secondary.
                self.updateTestSensitive { $0.backendSelection.setPreferred(backend) }
                self.renderBackend()
                self.renderTestSection()
            }
            bar.accessibilityIdentifier = "addhost.backendBar"
            let label = addHostLabel(
                "New sessions run on",
                font: UIKitChassis.uiFont(10, weight: .semibold),
                color: UIKitChassis.signal2
            )
            label.accessibilityHint =
                "The backend New Session, widgets, and Shortcuts start on "
                + "unless they name another"
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(bar)
            stack.setCustomSpacing(16, after: checks)
        }
        backendSection.setDetail(backendDetail)
        backendSection.setRows([AddHostInsetRow(contentView: stack)])
        // Only the tmux options editor is tmux-scoped (herdr has no analog
        // of tmux's targeted set-option calls; keep the stored value for a
        // later switch back rather than claiming it affects herdr).
        // Working directories apply to BOTH backends: the herdr mint roots
        // a fresh session's world by cd'ing the headless spawn, so the
        // paths here feed New Session, widgets, and Shortcuts either way.
        // Only the tmux options editor is tmux-scoped, so it survives as long
        // as tmux is one of the checked backends — a mixed host still mints
        // tmux sessions when its default says so.
        tmuxConfSection.isHidden = !enabledBackends.contains(.tmux)
    }

    /// Apply a new checked set, keeping the current default where it is still
    /// checked — `setBackends` promotes a survivor when it isn't.
    private func setEnabledBackends(_ backends: Set<Host.SessionBackend>) {
        updateTestSensitive { $0.backendSelection.setEnabled(backends) }
        renderBackend()
        renderTestSection()
    }

    // MARK: Transport

    private var moshRequiresPro: Bool {
        !entitlements.canEnableMosh(
            currentlyEnabled: form.useMosh || form.editing?.useMosh == true
        )
    }

    private var transportDetail: String {
        if form.useMosh {
            return "Terminals attach over UDP and survive roaming or sleep. SSH still "
                + "signs in, starts mosh-server, and probes the deck."
        }
        return "SSH carries both the control connection and attached terminals."
    }

    private func renderTransport() {
        moshPortsInvalidRow = nil
        let requiresPro = moshRequiresPro
        let control = SettingsBooleanRow(
            title: "Connect with mosh",
            isOn: form.useMosh,
            status: requiresPro ? "PRO" : nil,
            statusIsProminent: true,
            optimisticallyUpdates: !requiresPro,
            accessibilityHint: requiresPro ? "Requires Multiplex Pro" : nil
        ) { [weak self] enabled in
            guard let self else { return }
            if enabled && self.moshRequiresPro {
                self.presentPaywall()
                Task { @MainActor [weak self] in self?.renderTransport() }
                return
            }
            self.updateTestSensitive { $0.useMosh = enabled }
            self.renderTransport()
            self.renderTestSection()
        }
        moshControl = control
        var rows: [UIView] = [control]
        if form.useMosh {
            let server = UITextField()
            configureTextField(
                server,
                placeholder: "mosh-server",
                identifier: "addhost.moshServer"
            )
            server.text = form.moshServerPath
            server.accessibilityLabel = "mosh-server"
            server.autocorrectionType = .no
            server.autocapitalizationType = .none
            server.addTarget(self, action: #selector(moshFieldChanged(_:)), for: .editingChanged)
            moshServerField = server
            rows.append(AddHostFieldRow(label: "mosh-server", inputView: server))

            let ports = UITextField()
            configureTextField(
                ports,
                placeholder: "60000:61000",
                identifier: "addhost.moshPorts"
            )
            ports.text = form.moshPorts
            ports.accessibilityLabel = "UDP port or range"
            ports.keyboardType = .numbersAndPunctuation
            ports.autocorrectionType = .no
            ports.autocapitalizationType = .none
            ports.addTarget(self, action: #selector(moshFieldChanged(_:)), for: .editingChanged)
            moshPortsField = ports
            rows.append(AddHostFieldRow(label: "UDP port or range", inputView: ports))

            let invalid = UIStackView(arrangedSubviews: [
                UIKitTallyLamp(caption: "INVALID", color: TallyPalette.caution),
                addHostLabel(
                    "Use one port or a range from 1 to 65535.",
                    font: UIKitChassis.uiFont(10),
                    color: UIKitChassis.signal2
                ),
            ])
            invalid.axis = .horizontal
            invalid.alignment = .firstBaseline
            invalid.spacing = 10
            let invalidRow = AddHostInsetRow(contentView: invalid)
            invalidRow.isHidden = form.moshPortsAreValid
            moshPortsInvalidRow = invalidRow
            rows.append(invalidRow)
        } else {
            moshServerField = nil
            moshPortsField = nil
            moshPortsInvalidRow = nil
        }
        transportSection.setDetail(transportDetail)
        transportSection.setRows(rows)
        updateSaveAvailability()
    }

    // MARK: Observation / entitlement gates

    private func observeStoresState() {
        guard observesStores, isViewLoaded else { return }
        observationGeneration += 1
        let generation = observationGeneration
        let snapshot = withObservationTracking {
            (
                entitlements.isPro,
                bind.needsProForHostLimit,
                bind.enrollmentInFlight
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.observesStores,
                      self.observationGeneration == generation
                else { return }
                self.observeStoresState()
            }
        }
        renderStoresState(
            isPro: snapshot.0,
            needsPro: snapshot.1,
            enrollmentInFlight: snapshot.2
        )
    }

    private func renderStoresState(
        isPro: Bool,
        needsPro: Bool,
        enrollmentInFlight: Bool
    ) {
        _ = isPro
        updateDismissPolicy()
        if resolvedMode == .manual { renderTransport() }
        guard needsPro else { return }
        bind.needsProForHostLimit = false
        presentPaywall()
    }

    private func presentPaywall() {
        if let presentPaywallOverride {
            presentPaywallOverride()
            return
        }
        guard isViewLoaded, view.window != nil else {
            pendingPaywallPresentation = true
            return
        }
        // The bind flow consumes its host-limit request before it reaches here,
        // so a busy presentation slot — normally the QR scanner still animating
        // out under the confirm that raised this — must park the intent instead
        // of dropping it, then present once that modal has finished leaving.
        if let presented = presentedViewController {
            pendingPaywallPresentation = true
            presented.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in
                self?.drainPendingPaywall()
            }
            return
        }
        let controller = ProPaywallViewController(entitlements: entitlements)
        controller.appAppearance = appAppearance
        let navigation = UINavigationController(rootViewController: controller)
        controller.onDone = { [weak navigation] in navigation?.dismiss(animated: true) }
        present(navigation, animated: true)
    }

    private func drainPendingPaywall() {
        guard pendingPaywallPresentation else { return }
        pendingPaywallPresentation = false
        presentPaywall()
    }

    // MARK: Save / cancel

    private var currentSecrets: HostSecrets {
        HostSecrets(
            password: form.authMethod == .password ? form.password : nil,
            privateKey: form.authMethod == .privateKey ? form.privateKey : nil,
            passphrase: form.authMethod == .privateKey && !form.passphrase.isEmpty
                ? form.passphrase
                : nil
        )
    }

    func formHost() -> Host {
        let live = form.editing.flatMap { store.host(id: $0.id) }
        return form.host(liveHost: live)
    }

    private func persistSecrets(for host: Host) {
        let secrets = HostSecrets(
            password: form.password,
            privateKey: form.privateKey,
            passphrase: form.passphrase.isEmpty ? nil : form.passphrase
        )
        if let secretWriter {
            secretWriter(form.authMethod, secrets, host.id)
            return
        }
        switch form.authMethod {
        case .password:
            KeychainStore.set(form.password, for: host.id, kind: .password)
        case .privateKey:
            KeychainStore.set(form.privateKey, for: host.id, kind: .privateKey)
            if !form.passphrase.isEmpty {
                SSHKeyPassphraseSession.accept(
                    form.passphrase,
                    for: host.id,
                    saveToICloud: true
                )
            } else {
                SSHKeyPassphraseSession.clear(for: host.id)
            }
        }
    }

    private func save() {
        guard form.isValid else { return }
        let host = formHost()
        persistSecrets(for: host)
        let isNew = form.editing == nil
        if let hostWriter {
            hostWriter(host, isNew)
        } else if isNew {
            store.add(host)
        } else {
            store.update(host)
        }
        clearSecretsAndDismiss()
    }

    private func clearSecrets() {
        form.password = ""
        form.privateKey = ""
        form.passphrase = ""
        passwordField?.setText("")
        privateKeyView?.setText("", notify: false)
        passphraseField?.setText("")
    }

    private func clearSecretsAndDismiss() {
        guard !dismissalRequested else { return }
        dismissalRequested = true
        clearSecrets()
        bindPaneController?.prepareForRemoval()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let onDismiss {
                onDismiss()
            } else {
                navigationController?.dismiss(animated: true)
            }
        }
    }

    @objc private func cancelPressed() {
        clearSecretsAndDismiss()
    }

    @objc private func savePressed() {
        save()
    }

    // MARK: Field actions

    @objc private func identityFieldChanged(_ sender: UITextField) {
        if sender === nameField {
            form.name = sender.text ?? ""
        } else if sender === hostnameField {
            updateTestSensitive { $0.hostname = sender.text ?? "" }
        } else if sender === portField {
            updateTestSensitive { $0.port = sender.text ?? "" }
        } else if sender === usernameField {
            updateTestSensitive { $0.username = sender.text ?? "" }
        }
        updateSaveAvailability()
        if testState != .idle { renderTestSection() }
    }

    @objc private func moshFieldChanged(_ sender: UITextField) {
        if sender === moshServerField {
            updateTestSensitive { $0.moshServerPath = sender.text ?? "" }
        } else if sender === moshPortsField {
            form.moshPorts = sender.text ?? ""
            moshPortsInvalidRow?.isHidden = form.moshPortsAreValid
        }
        updateSaveAvailability()
    }

    @objc private func newDirectoryChanged() {
        form.newWorkingDirectory = newWorkingDirectoryField.text ?? ""
        updateAddDirectoryAvailability()
    }

    @objc private func manualGroundTapped() {
        view.endEditing(true)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === newWorkingDirectoryField {
            addWorkingDirectory()
        } else {
            textField.resignFirstResponder()
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        var candidate = touch.view
        while let view = candidate, view !== manualStack {
            if view is UIControl || view is UITextView || view is UIKitChassisChip {
                return false
            }
            candidate = view.superview
        }
        return true
    }

    // MARK: Helpers

    private func configureTextField(
        _ field: UITextField,
        placeholder: String,
        identifier: String
    ) {
        field.font = UIKitChassis.monoFont(12)
        field.textColor = UIKitChassis.signal
        field.tintColor = UIKitChassis.signal
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIKitChassis.signal3]
        )
        field.borderStyle = .none
        field.accessibilityIdentifier = identifier
        field.delegate = self
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureInlineField(
        _ field: UITextField,
        text: String,
        placeholder: String,
        font: UIFont
    ) {
        field.text = text
        field.font = font
        field.textColor = UIKitChassis.signal
        field.tintColor = UIKitChassis.signal
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIKitChassis.signal3]
        )
        field.borderStyle = .none
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func setChip(_ chip: UIKitChassisChip, enabled: Bool) {
        chip.isUserInteractionEnabled = enabled
        chip.alpha = enabled ? 1 : 0.45
        chip.accessibilityTraits = .button
        if !enabled { chip.accessibilityTraits.insert(.notEnabled) }
    }

    // MARK: DEBUG scrolling

    private func scheduleDebugScrollIfNeeded() {
        #if DEBUG
        guard !didScheduleDebugScroll else { return }
        let requestedSection = ProcessInfo.processInfo.environment[
            "MULTIPLEX_AUTO_HOST_SETTINGS"
        ]
        let shouldScrollModels = requestedSection == "models"
        let shouldScrollBackend = requestedSection == "backend"
        let shouldScrollDirectories = requestedSection == "directories"
        let shouldScrollElsewhere = AddHostAutoOpen.requested == .bindElsewhere
        guard shouldScrollModels || shouldScrollBackend || shouldScrollDirectories
            || shouldScrollElsewhere
        else { return }
        didScheduleDebugScroll = true
        debugScrollTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled else { return }
            let targetY: CGFloat
            if shouldScrollModels {
                targetY = self.agentModelsSection.convert(.zero, to: self.scrollView).y
            } else if shouldScrollBackend {
                // Back off the navigation bar's inset so the section header
                // and its caption clear the translucent bar in a capture.
                targetY = self.backendSection.convert(.zero, to: self.scrollView).y
                    - self.scrollView.adjustedContentInset.top
            } else if shouldScrollDirectories {
                targetY = self.workingDirectoriesSection
                    .convert(.zero, to: self.scrollView).y
                    - self.scrollView.adjustedContentInset.top
            } else if let bindContainer = self.bindContainer {
                targetY = bindContainer.convert(
                    CGPoint(x: 0, y: self.bindElsewhereOffset),
                    to: self.scrollView
                ).y
            } else {
                return
            }
            let maximum = max(
                -self.scrollView.adjustedContentInset.top,
                self.scrollView.contentSize.height - self.scrollView.bounds.height
                    + self.scrollView.adjustedContentInset.bottom
            )
            self.scrollView.setContentOffset(
                CGPoint(x: 0, y: min(maximum, max(0, targetY))),
                animated: false
            )
        }
        #endif
    }
}

// MARK: - Native TALLY form components

@MainActor
final class AddHostSectionView: UIView {
    private let detailLabel = UILabel()
    private let detailContainer = UIView()
    private let rowsStack = UIStackView()

    init(title: String, detail: String?, rows: [UIView]) {
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

        let divider = UIView()
        divider.backgroundColor = UIKitChassis.bezelHi
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        rowsStack.axis = .vertical
        rowsStack.alignment = .fill
        rowsStack.spacing = 0
        // PROTOTYPE(GLASS): explicit hairline dividers, like the New
        // Session form. The old gap trick painted this stack bezelHi
        // behind the (cleared-on-glass) rows, washing the whole form
        // body in an 11% white sheet.
        let cardStack = UIStackView(arrangedSubviews: [header, divider, rowsStack])
        cardStack.axis = .vertical
        cardStack.spacing = 0
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
        let section = UIStackView(arrangedSubviews: [card, detailContainer])
        section.axis = .vertical
        section.alignment = .fill
        section.spacing = 8
        addSubview(section)
        section.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: leadingAnchor),
            section.trailingAnchor.constraint(equalTo: trailingAnchor),
            section.topAnchor.constraint(equalTo: topAnchor),
            section.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setRows(rows)
        setDetail(detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setRows(_ rows: [UIView]) {
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let rowDivider = UIView()
                rowDivider.backgroundColor = UIKitChassis.bezelHi
                rowDivider.heightAnchor.constraint(equalToConstant: 1)
                    .isActive = true
                rowsStack.addArrangedSubview(rowDivider)
            }
            rowsStack.addArrangedSubview(row)
        }
    }

    func setDetail(_ detail: String?) {
        detailLabel.text = detail
        detailContainer.isHidden = detail == nil
    }
}

@MainActor
final class AddHostInsetRow: UIView {
    init(contentView: UIView) {
        super.init(frame: .zero)
        backgroundColor = GlassPrototype.clearedChassis
        addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

@MainActor
final class AddHostFieldRow: UIView {
    init(label: String, inputView: UIView) {
        super.init(frame: .zero)
        backgroundColor = GlassPrototype.clearedChassis
        let caption = addHostLabel(
            label,
            font: UIKitChassis.uiFont(10, weight: .semibold),
            color: UIKitChassis.signal2
        )
        let well = UIKitTallyBorderedView()
        well.backgroundColor = UIKitChassis.screen
        well.addSubview(inputView)
        inputView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inputView.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 10),
            inputView.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -10),
            inputView.topAnchor.constraint(equalTo: well.topAnchor, constant: 9),
            inputView.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -9),
        ])
        let stack = UIStackView(arrangedSubviews: [caption, well])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 7
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

@MainActor
final class AddHostInlineWell: UIKitTallyBorderedView {
    init(contentView: UIView) {
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.screen
        addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

enum AddHostChoiceMetrics {
    static let height: CGFloat = 34
    static let seam: CGFloat = 1
    static let selectionAnimationDuration: TimeInterval = 0.14
}

/// The chrome both selection bars wear: one row of equal faces over a seam
/// of `bezelHi`, lit faces animated in unless Reduce Motion is on. Subclasses
/// supply only what "selected" means and what a press does, so the two bars
/// cannot drift on the ground, the seam, or the animation.
@MainActor
class AddHostSelectionBarBase<Value: Hashable>: UIStackView {
    fileprivate let choices: [(String, Value)]
    private var buttons: [AddHostChoiceButton] = []

    fileprivate init(choices: [(String, Value)], checkable: Bool) {
        self.choices = choices
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .fill
        distribution = .fillEqually
        spacing = AddHostChoiceMetrics.seam
        backgroundColor = UIKitChassis.bezelHi
        for (index, choice) in choices.enumerated() {
            let button = AddHostChoiceButton(
                title: choice.0, index: index, checkable: checkable)
            button.addTarget(self, action: #selector(pressed(_:)), for: .touchUpInside)
            buttons.append(button)
            addArrangedSubview(button)
        }
        refresh()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("unused") }

    /// Whether this value's face is lit. Overridden; never called directly.
    fileprivate func isSelected(_ value: Value) -> Bool { false }

    /// Apply a press. Returns false when it changes nothing — an already-set
    /// single choice, or a check the minimum refuses to clear — in which case
    /// neither the animation nor the callback runs.
    fileprivate func applyPress(_ value: Value) -> Bool { false }

    /// Hand the new selection to the owner. Split from `applyPress` so the
    /// callback fires exactly once, after the faces have been told.
    fileprivate func notifyChanged() {}

    @objc private func pressed(_ sender: AddHostChoiceButton) {
        guard choices.indices.contains(sender.choiceIndex),
              applyPress(choices[sender.choiceIndex].1) else { return }
        refresh(animated: true)
        notifyChanged()
    }

    fileprivate func refresh(animated: Bool = false) {
        let changes = { [self] in
            for (index, button) in buttons.enumerated() {
                button.setSelected(isSelected(choices[index].1))
            }
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }
        UIView.animate(
            withDuration: AddHostChoiceMetrics.selectionAnimationDuration,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
            animations: changes
        )
    }
}

@MainActor
final class AddHostChoiceBar<Value: Hashable>: AddHostSelectionBarBase<Value> {
    private(set) var selection: Value
    private let changed: (Value) -> Void

    init(
        choices: [(String, Value)],
        selection: Value,
        changed: @escaping (Value) -> Void
    ) {
        self.selection = selection
        self.changed = changed
        super.init(choices: choices, checkable: false)
    }

    func setSelection(_ selection: Value) {
        guard self.selection != selection else { return }
        self.selection = selection
        refresh(animated: true)
    }

    fileprivate override func isSelected(_ value: Value) -> Bool { value == selection }

    fileprivate override func applyPress(_ value: Value) -> Bool {
        guard value != selection else { return false }
        selection = value
        return true
    }

    fileprivate override func notifyChanged() { changed(selection) }
}

/// The multi-select sibling of `AddHostChoiceBar` — same faces, same seam,
/// but any number can be lit and a lit face wears a checkmark so the two
/// bars can never be mistaken for each other at a glance.
///
/// Built for the Backend section, where a host picks which multiplexers it
/// shows. A boolean "Also show herdr sessions" switch shipped there first
/// and read badly: it presented two peers as a primary and an afterthought,
/// and it said nothing about which one a new session lands on. Checks state
/// the set; a separate single-choice bar states the default, and only when
/// there is more than one to choose from.
///
/// The last check never clears — a host with no backend has nothing to show
/// at all. Enforced by not responding rather than by disabling the face: a
/// disabled last check reads as broken, while an unresponsive one reads as
/// "this is already the minimum".
@MainActor
final class AddHostCheckBar<Value: Hashable>: AddHostSelectionBarBase<Value> {
    private(set) var selection: Set<Value>
    private let changed: (Set<Value>) -> Void

    init(
        choices: [(String, Value)],
        selection: Set<Value>,
        changed: @escaping (Set<Value>) -> Void
    ) {
        self.selection = selection
        self.changed = changed
        super.init(choices: choices, checkable: true)
    }

    fileprivate override func isSelected(_ value: Value) -> Bool {
        selection.contains(value)
    }

    fileprivate override func applyPress(_ value: Value) -> Bool {
        if selection.contains(value) {
            guard selection.count > 1 else { return false }
            selection.remove(value)
        } else {
            selection.insert(value)
        }
        return true
    }

    fileprivate override func notifyChanged() { changed(selection) }
}

@MainActor
private final class AddHostChoiceButton: UIButton {
    let choiceIndex: Int
    private let sourceTitle: String
    private let checkable: Bool
    private let visualLabel = UILabel()

    init(title: String, index: Int, checkable: Bool = false) {
        sourceTitle = title
        choiceIndex = index
        self.checkable = checkable
        super.init(frame: .zero)
        // The SwiftUI source used `.buttonStyle(.plain)`. Keep this a custom
        // button with no configuration so UIKit cannot supply a capsule or
        // tinted system background on newer OS releases.
        configuration = nil
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        accessibilityLabel = title
        accessibilityTraits = .button
        visualLabel.isUserInteractionEnabled = false
        visualLabel.isAccessibilityElement = false
        addSubview(visualLabel)
        visualLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            visualLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            visualLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: AddHostChoiceMetrics.height),
        ])
        layer.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setSelected(_ selected: Bool) {
        // PROTOTYPE(GLASS): unselected segments rest on strata over the
        // sheet's smoke, never opaque chassis.
        backgroundColor = selected
            ? UIKitChassis.bezelHi : GlassPrototype.strataChassis
        // A checkable face says so in the face itself: the two bars sit one
        // above the other in the Backend section, and without the mark a
        // multi-select bar with one item lit is indistinguishable from a
        // single-select one.
        let face = checkable && selected
            ? "✓ " + sourceTitle.uppercased()
            : sourceTitle.uppercased()
        visualLabel.attributedText = NSAttributedString(
            string: face,
            attributes: [
                .font: UIKitChassis.compressedLabelFont(9),
                .kern: CGFloat(9 * Theme.typeScale * 0.09),
            ]
        )
        visualLabel.textColor = selected ? UIKitChassis.signal : UIKitChassis.signal2
        layer.borderColor = (selected ? UIKitChassis.signal2 : UIKitChassis.bezelHi)
            .resolvedColor(with: traitCollection)
            .cgColor
        if checkable {
            accessibilityTraits.insert(.toggleButton)
        }
        accessibilityValue = checkable
            ? (selected ? "Checked" : "Unchecked")
            : (selected ? "Selected" : "Not selected")
        if selected {
            accessibilityTraits.insert(.selected)
        } else {
            accessibilityTraits.remove(.selected)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        setSelected(accessibilityTraits.contains(.selected))
    }
}

/// Multiline text input with TextField(axis: .vertical)-style growth between
/// explicit line limits and an in-well placeholder.
@MainActor
final class AddHostGrowingTextView: UITextView, UITextViewDelegate {
    var onTextChange: ((String) -> Void)?
    private let placeholderLabel = UILabel()
    private let minimumLines: Int
    private let maximumLines: Int
    private var measuredWidth: CGFloat = 0

    init(
        text: String,
        placeholder: String,
        font: UIFont,
        minimumLines: Int,
        maximumLines: Int
    ) {
        self.minimumLines = minimumLines
        self.maximumLines = maximumLines
        super.init(frame: .zero, textContainer: nil)
        self.text = text
        self.font = font
        textColor = UIKitChassis.signal
        tintColor = UIKitChassis.signal
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        isScrollEnabled = false
        delegate = self
        placeholderLabel.text = placeholder
        placeholderLabel.font = font
        placeholderLabel.textColor = UIKitChassis.signal3
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var intrinsicContentSize: CGSize {
        let lineHeight = font?.lineHeight ?? 14
        let minimum = lineHeight * CGFloat(minimumLines)
        let maximum = lineHeight * CGFloat(maximumLines)
        guard bounds.width > 0 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: minimum)
        }
        let fitting = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        return CGSize(
            width: UIView.noIntrinsicMetric,
            height: min(maximum, max(minimum, fitting.height))
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard abs(bounds.width - measuredWidth) > 0.5 else { return }
        measuredWidth = bounds.width
        refresh()
    }

    func setText(_ text: String, notify: Bool) {
        self.text = text
        refresh()
        if notify { onTextChange?(text) }
    }

    func textViewDidChange(_ textView: UITextView) {
        refresh()
        onTextChange?(textView.text)
    }

    private func refresh() {
        placeholderLabel.isHidden = !text.isEmpty
        invalidateIntrinsicContentSize()
        let maximum = (font?.lineHeight ?? 14) * CGFloat(maximumLines)
        if bounds.width > 0 {
            isScrollEnabled = sizeThatFits(
                CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
            ).height > maximum
        }
    }
}

/// App-drawn masking avoids Passwords QuickType/save prompts while retaining
/// a reveal button and refusing clipboard/selection actions when concealed.
@MainActor
final class AddHostRevealableSecretField: UIView, UITextFieldDelegate {
    let title: String
    private(set) var text: String
    private(set) var revealed = false
    private(set) var textField = SecretTextField()
    private(set) var revealButton = UIButton(type: .custom)
    var onTextChange: ((String) -> Void)?

    init(
        title: String,
        prompt: String,
        text: String,
        onTextChange: @escaping (String) -> Void
    ) {
        self.title = title
        self.text = text
        self.onTextChange = onTextChange
        super.init(frame: .zero)
        textField.font = UIKitChassis.monoFont(12)
        textField.textColor = UIKitChassis.signal
        textField.tintColor = UIKitChassis.signal
        textField.attributedPlaceholder = NSAttributedString(
            string: prompt,
            attributes: [.foregroundColor: UIKitChassis.signal3]
        )
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.smartQuotesType = .no
        textField.smartDashesType = .no
        textField.smartInsertDeleteType = .no
        textField.autocapitalizationType = .none
        textField.keyboardType = .asciiCapable
        textField.textContentType = UITextContentType(rawValue: "")
        textField.accessibilityLabel = title
        textField.delegate = self
        textField.addTarget(self, action: #selector(revealedTextChanged), for: .editingChanged)
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        revealButton.tintColor = UIKitChassis.signal2
        revealButton.hoverStyle = UIHoverStyle(
            effect: .highlight,
            shape: .rect(cornerRadius: 2)
        )
        revealButton.addTarget(self, action: #selector(toggleReveal), for: .primaryActionTriggered)
        revealButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            revealButton.widthAnchor.constraint(equalToConstant: 24),
            revealButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        let row = UIStackView(arrangedSubviews: [textField, revealButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refreshPresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setText(_ text: String) {
        self.text = text
        let desired = revealed ? text : Self.bullets(text.count)
        if textField.text != desired { textField.text = desired }
    }

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        guard !revealed else { return true }
        var characters = Array(text)
        let lower = min(range.location, characters.count)
        let upper = min(range.location + range.length, characters.count)
        characters.replaceSubrange(lower..<upper, with: Array(string))
        text = String(characters)
        textField.text = Self.bullets(characters.count)
        let caret = lower + string.count
        if let position = textField.position(from: textField.beginningOfDocument, offset: caret) {
            textField.selectedTextRange = textField.textRange(from: position, to: position)
        }
        onTextChange?(text)
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    @objc private func revealedTextChanged() {
        guard revealed else { return }
        text = textField.text ?? ""
        onTextChange?(text)
    }

    @objc private func toggleReveal() {
        revealed.toggle()
        refreshPresentation()
    }

    private func refreshPresentation() {
        textField.masksEditActions = !revealed
        textField.text = revealed ? text : Self.bullets(text.count)
        let image = UIImage(
            systemName: revealed ? "eye.slash" : "eye",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 10 * Theme.typeScale,
                weight: .semibold
            )
        )
        revealButton.setImage(image, for: .normal)
        revealButton.accessibilityLabel = revealed ? "Hide \(title)" : "Show \(title)"
    }

    private static func bullets(_ count: Int) -> String {
        String(repeating: "•", count: count)
    }
}

/// Refuses selection and clipboard actions while the app-drawn bullet mask is
/// visible. Bind Host and Manual Host share this native field.
final class SecretTextField: UITextField {
    var masksEditActions = true

    override func canPerformAction(
        _ action: Selector,
        withSender sender: Any?
    ) -> Bool {
        if masksEditActions {
            switch action {
            case #selector(copy(_:)),
                 #selector(cut(_:)),
                 #selector(select(_:)),
                 #selector(selectAll(_:)):
                return false
            default:
                break
            }
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

@MainActor
private final class AddHostIconButton: UIButton {
    private let actionHandler: () -> Void
    private let dynamicBorder = UIKitChassis.bezelHi

    init(
        systemImage: String,
        accessibilityLabel: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) {
        actionHandler = action
        super.init(frame: .zero)
        setImage(UIImage(
            systemName: systemImage,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 9 * Theme.typeScale,
                weight: .semibold
            )
        ), for: .normal)
        tintColor = enabled ? UIKitChassis.signal2 : UIKitChassis.signal3
        backgroundColor = GlassPrototype.strataChassis
        layer.borderWidth = 1
        layer.borderColor = dynamicBorder.resolvedColor(with: traitCollection).cgColor
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        self.accessibilityLabel = accessibilityLabel
        isEnabled = enabled
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 25),
            heightAnchor.constraint(equalToConstant: 25),
        ])
        addTarget(self, action: #selector(pressed), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        layer.borderColor = dynamicBorder.resolvedColor(with: traitCollection).cgColor
    }

    @objc private func pressed() {
        actionHandler()
    }
}

@MainActor
private func addHostLabel(_ text: String, font: UIFont, color: UIColor) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = font
    label.textColor = color
    label.numberOfLines = 0
    return label
}

@MainActor
private func addHostFlexibleSpacer(minimumWidth: CGFloat = 0) -> UIView {
    let spacer = UIView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    if minimumWidth > 0 {
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth).isActive = true
    }
    return spacer
}

@MainActor
private func addHostLeadingView(_ content: UIView) -> UIView {
    let holder = UIView()
    holder.addSubview(content)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
        content.topAnchor.constraint(equalTo: holder.topAnchor),
        content.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        content.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor),
    ])
    return holder
}

#if DEBUG
/// Headless Add Host routing grammar shared with DeckWindow. The sheet selects
/// the requested road and can scroll directly to the native Somewhere Else
/// bind section or launch-model editor after layout settles.
enum AddHostAutoOpen: String {
    case bind
    case bindElsewhere = "bind-elsewhere"
    case manual

    static var requested: AddHostAutoOpen? {
        ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_ADD_HOST"]
            .flatMap(Self.init(rawValue:))
    }
}
#endif
