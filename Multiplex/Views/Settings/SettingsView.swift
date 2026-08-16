import Observation
import UIKit

// MARK: - Native settings screen

/// App-wide settings, rendered entirely with UIKit. Host-specific options
/// remain on the host editor.
@MainActor
final class SettingsViewController: UIViewController {
    enum Metrics {
        static let contentMaximumWidth: CGFloat = 680
        static let outerInset: CGFloat = 18
        static let sectionSpacing: CGFloat = 18
    }

    private struct ViewState {
        let appearance: AppAppearance
        let customThemes: [TerminalTheme]
        let selectedDarkID: String
        let selectedLightID: String
        let canMutateCustomThemes: Bool
        let canScheduleAgentAlerts: Bool
        let isPro: Bool
        let alertsEnabled: Bool
        let appLockEnabled: Bool
    }

    let themes: ThemeStore
    let entitlements: EntitlementStore
    let attention: AttentionCenter
    let appLock: AppLockStore

    var onDone: (() -> Void)?
    var openPrivacyPolicy: ((URL) -> Void)?
    /// Test/presentation composition seam. Production leaves this nil and
    /// receives the real native `ProPaywallViewController` below.
    var presentPaywallOverride: (() -> Void)?

    private(set) var contentStack = UIStackView()
    private(set) var appearanceChoiceBar: SettingsAppearanceChoiceBar?
    private(set) var agentAlertsControl: SettingsBooleanRow?
    private(set) var appLockControl: SettingsBooleanRow?

    private let scrollView = UIScrollView()
    private var appearanceSection: SettingsSectionView?
    private var observationGeneration = 0
    private var didRunDebugPresentation = false
    private var hasEstablishedInitialTopAlignment = false

    init(
        themes: ThemeStore,
        entitlements: EntitlementStore,
        attention: AttentionCenter,
        appLock: AppLockStore
    ) {
        self.themes = themes
        self.entitlements = entitlements
        self.attention = attention
        self.appLock = appLock
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = GlassPrototype.sheetGround
        configureNavigation()
        configureContent()
        observeStores()
        applyAppearance()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyAppearance()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        presentThemeEditorForVerificationIfRequested()
        presentLicensesForVerificationIfRequested()
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        alignInitialScrollPositionIfNeeded()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        observeStores()
    }

    private func configureNavigation() {
        navigationItem.largeTitleDisplayMode = .never
        #if os(visionOS)
        navigationItem.titleView = UIKitChassisLabel("Settings", size: 12)
        #endif
        let done = UIBarButtonItem(
            title: "Done",
            style: .plain,
            target: self,
            action: #selector(donePressed)
        )
        done.tintColor = UIKitChassis.signal
        done.accessibilityLabel = "Done"
        navigationItem.rightBarButtonItem = done
    }

    /// UIKit establishes a scroll view's resting top only after the sheet's
    /// navigation inset is known. The form is first rendered in `viewDidLoad`,
    /// so align it from the first attached layout and let later renders
    /// preserve the user's actual position.
    private func alignInitialScrollPositionIfNeeded() {
        guard !hasEstablishedInitialTopAlignment,
              view.window != nil,
              scrollView.bounds.height > 0
        else { return }
        scrollView.setContentOffset(
            CGPoint(
                x: scrollView.contentOffset.x,
                y: -scrollView.adjustedContentInset.top
            ),
            animated: false
        )
        hasEstablishedInitialTopAlignment = true
    }

    private func configureContent() {
        scrollView.alwaysBounceVertical = true
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
        let fillVisibleWidth = contentStack.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -(Metrics.outerInset * 2)
        )
        fillVisibleWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: Metrics.outerInset
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -Metrics.outerInset
            ),
            contentStack.centerXAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.centerXAnchor
            ),
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
            fillVisibleWidth,
        ])
    }

    /// Observation callbacks are one-shot. Each update takes one coherent
    /// snapshot, registers the next callback, then rebuilds the form from that
    /// snapshot. No SwiftUI state owner is needed to keep the sheet live.
    private func observeStores() {
        guard isViewLoaded else { return }
        observationGeneration += 1
        let generation = observationGeneration
        let state = withObservationTracking {
            ViewState(
                appearance: themes.appearance,
                customThemes: themes.customThemes,
                selectedDarkID: themes.selectedID,
                selectedLightID: themes.selectedLightID,
                canMutateCustomThemes: entitlements.canMutateCustomThemes,
                canScheduleAgentAlerts: entitlements.canScheduleAgentAlerts,
                isPro: entitlements.isPro,
                alertsEnabled: attention.alertsEnabled,
                appLockEnabled: appLock.isEnabled
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.observationGeneration == generation
                else { return }
                self.observeStores()
            }
        }
        render(state)
    }

    private func render(_ state: ViewState) {
        applyAppearance(state.appearance)
        let shouldPreserveOffset = hasEstablishedInitialTopAlignment
        let oldOffset = scrollView.contentOffset

        let appearance = resolvedAppearance(for: state.appearance)
        let selectedID = appearance == .light
            ? state.selectedLightID
            : state.selectedDarkID
        let selectedTheme = TerminalTheme.builtIn(id: selectedID)
            ?? state.customThemes.first(where: { $0.id == selectedID })
            ?? (appearance == .light ? .lightDefault : .tally)

        let sections = [
            makeAppearanceSection(state),
            makeCurrentThemeSection(
                theme: selectedTheme,
                choice: state.appearance,
                resolvedAppearance: appearance
            ),
            makeBuiltInThemesSection(selectedID: selectedTheme.id),
            makeCustomThemesSection(
                state: state,
                selectedTheme: selectedTheme,
                selectedID: selectedTheme.id
            ),
            makeRendererSection(),
            makeConnectionStatsSection(),
            makeAlertsSection(state),
            makeAppLockSection(state),
            makeProSection(state),
            makeAboutSection(),
            makePrivacyLink(),
        ]
        replaceContent(with: sections)

        view.layoutIfNeeded()
        guard shouldPreserveOffset else { return }
        let maximumY = max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        scrollView.setContentOffset(
            CGPoint(x: oldOffset.x, y: min(oldOffset.y, maximumY)),
            animated: false
        )
    }

    private func makeAppearanceSection(_ state: ViewState) -> UIView {
        if let appearanceSection, let appearanceChoiceBar {
            appearanceChoiceBar.setSelection(state.appearance, animated: true)
            return appearanceSection
        }
        let bar = SettingsAppearanceChoiceBar(selection: state.appearance) { [weak self] appearance in
            self?.themes.appearance = appearance
        }
        appearanceChoiceBar = bar
        let appearanceDetail: String
        if GlassPrototype.enabled {
            appearanceDetail = "System follows the device. The deck, terminal chrome, "
                + "and forms switch together. Dark and Glass share the dark terminal "
                + "theme below."
        } else {
            appearanceDetail = "System follows the device. The deck, terminal chrome, "
                + "and forms switch together; each appearance keeps its own terminal "
                + "theme below."
        }
        let section = SettingsSectionView(
            title: "Appearance",
            detail: appearanceDetail,
            rows: [SettingsInsetRow(contentView: bar)]
        )
        appearanceSection = section
        return section
    }

    /// Reuse any identical leading sections. The appearance section is the
    /// stable prefix, so a ThemeStore observation can update its selection
    /// without detaching or replacing the control that owns the transition.
    private func replaceContent(with sections: [UIView]) {
        let existing = contentStack.arrangedSubviews
        var commonPrefixCount = 0
        while commonPrefixCount < min(existing.count, sections.count),
              existing[commonPrefixCount] === sections[commonPrefixCount] {
            commonPrefixCount += 1
        }
        for view in existing.dropFirst(commonPrefixCount).reversed() {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (offset, section) in sections.dropFirst(commonPrefixCount).enumerated() {
            contentStack.insertArrangedSubview(section, at: commonPrefixCount + offset)
        }
    }

    private func makeCurrentThemeSection(
        theme: TerminalTheme,
        choice: AppAppearance,
        resolvedAppearance: ResolvedAppearance
    ) -> UIView {
        let name = UIKitChassisLabel(theme.name, size: 12)
        let surface = settingsTrackedLabel(
            "TERMINAL SURFACE",
            font: UIKitChassis.monoFont(8, weight: .medium),
            color: UIKitChassis.signal3,
            kern: 1
        )
        let identity = UIStackView(arrangedSubviews: [name, surface])
        identity.axis = .vertical
        identity.spacing = 3

        let header = UIStackView(arrangedSubviews: [
            identity,
            settingsFlexibleSpacer(),
            SettingsBadgeView("ACTIVE", prominent: true),
        ])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 12

        let body = UIStackView(arrangedSubviews: [header, UIKitThemePreviewView(theme: theme)])
        body.axis = .vertical
        body.spacing = 12
        let ownership: String
        switch choice {
        case .glass:
            ownership = "Glass shares this dark terminal theme with Dark."
        case .dark where GlassPrototype.enabled:
            ownership = "Dark shares this terminal theme with Glass."
        default:
            ownership = "This is the \(resolvedAppearance == .light ? "light" : "dark") "
                + "theme now on screen."
        }
        return SettingsSectionView(
            title: "Current theme",
            detail: "Selections apply to every terminal immediately. \(ownership)",
            rows: [SettingsInsetRow(contentView: body)]
        )
    }

    private func makeBuiltInThemesSection(selectedID: String) -> UIView {
        let rows = TerminalTheme.builtIns.map { theme in
            SettingsThemeRowView(
                theme: theme,
                isSelected: theme.id == selectedID,
                select: { [weak self] in self?.select(theme) },
                duplicate: { [weak self] in self?.duplicate(theme) }
            )
        }
        return SettingsSectionView(
            title: "Built-in themes",
            detail: "Choose a terminal palette. Press and hold a theme to duplicate it "
                + "as a custom starting point.",
            rows: rows
        )
    }

    private func makeCustomThemesSection(
        state: ViewState,
        selectedTheme: TerminalTheme,
        selectedID: String
    ) -> UIView {
        var rows: [UIView] = []
        if state.customThemes.isEmpty {
            let emptyTitle = UIKitChassisLabel(
                "No custom themes",
                size: 10,
                color: UIKitChassis.signal3
            )
            let emptyDetail = settingsLabel(
                "Start from the active palette, then tune its surface and ANSI colors.",
                font: UIKitChassis.uiFont(10),
                color: UIKitChassis.signal2
            )
            let empty = UIStackView(arrangedSubviews: [emptyTitle, emptyDetail])
            empty.axis = .vertical
            empty.spacing = 4
            rows.append(SettingsInsetRow(contentView: empty))
        } else {
            rows.append(contentsOf: state.customThemes.map { theme in
                SettingsThemeRowView(
                    theme: theme,
                    isSelected: theme.id == selectedID,
                    select: { [weak self] in self?.select(theme) },
                    edit: { [weak self] in self?.requestThemeEditor(theme) },
                    duplicate: { [weak self] in self?.duplicate(theme) },
                    delete: { [weak self] in self?.themes.remove(theme) }
                )
            })
        }

        let newTheme = UIKitChassisChip(
            "NEW THEME",
            systemImage: "plus",
            accessibilityLabel: "New theme"
        ) { [weak self] in
            self?.requestThemeEditor(selectedTheme.asCustom(named: "New Theme"))
        }
        let actionRow = UIStackView(arrangedSubviews: [newTheme, settingsFlexibleSpacer()])
        actionRow.axis = .horizontal
        actionRow.alignment = .center
        actionRow.spacing = 12
        if !state.canMutateCustomThemes {
            actionRow.addArrangedSubview(SettingsBadgeView("PRO", prominent: true))
        }
        rows.append(SettingsInsetRow(contentView: actionRow))

        let detail = state.canMutateCustomThemes
            ? "New themes begin with the active palette. Use the row menu to edit, "
                + "duplicate, or delete one."
            : "Creating, duplicating, and editing custom themes requires Multiplex Pro. "
                + "Existing themes remain selectable and deletable."
        return SettingsSectionView(title: "Your themes", detail: detail, rows: rows)
    }

    private func makeRendererSection() -> UIView {
        // Reads and writes the defaults-backed switch directly: no store
        // observes it, and the row's optimistic flip is the honest state.
        let control = SettingsBooleanRow(
            title: "Metal renderer",
            isOn: MetalRendererSetting.isEnabled
        ) { enabled in
            MetalRendererSetting.setEnabled(enabled)
        }
        return SettingsSectionView(
            title: "Terminal renderer",
            detail: "Draws terminal text on the GPU instead of CoreGraphics. "
                + "Takes effect for newly opened terminal windows.",
            rows: [control]
        )
    }

    private func makeConnectionStatsSection() -> UIView {
        // Writes through the center, not the defaults enum, so open boards,
        // rail chips, and the collectors all react to the flip immediately.
        // "Show", not "Collect" — collect reads like telemetry, and nothing
        // here leaves the device; the detail line carries the stops-measuring
        // half of the promise.
        let control = SettingsBooleanRow(
            title: "Show connection stats",
            isOn: ConnectionStatsCenter.shared.isCollecting
        ) { enabled in
            ConnectionStatsCenter.shared.setCollecting(enabled)
        }
        return SettingsSectionView(
            title: "Connection stats",
            detail: "Round-trips, echo latency, loss, and volume — numbers the "
                + "transports already compute, measured passively and kept in "
                + "memory for this session only. Nothing is stored or synced. "
                + "Off hides the rail chips and the stats board and stops "
                + "measuring. The live chip is free; the board requires Pro.",
            rows: [control]
        )
    }

    private func makeAlertsSection(_ state: ViewState) -> UIView {
        let alertsOn = state.canScheduleAgentAlerts && state.alertsEnabled
        let control = SettingsBooleanRow(
            title: "Agent alerts",
            isOn: alertsOn,
            status: state.canScheduleAgentAlerts ? nil : "PRO",
            statusIsProminent: true,
            optimisticallyUpdates: state.canScheduleAgentAlerts,
            accessibilityHint: state.canScheduleAgentAlerts
                ? nil
                : "Requires Multiplex Pro"
        ) { [weak self] enabled in
            guard let self else { return }
            if enabled && !self.entitlements.canScheduleAgentAlerts {
                self.attention.alertsEnabled = true
                self.presentPaywall()
            } else {
                self.attention.alertsEnabled = enabled
            }
            // The locked projection can remain false while the remembered
            // preference was already true, which produces no Observation
            // mutation. Re-read after this control event so its visual value
            // always comes from policy, not from the optimistic tap.
            Task { @MainActor [weak self] in self?.observeStores() }
        }
        agentAlertsControl = control
        var rows: [UIView] = [control]
        if !state.canScheduleAgentAlerts {
            rows.append(SettingsInsetRow(contentView: settingsLeadingView(UIKitChassisChip(
                "VIEW MULTIPLEX PRO",
                accessibilityLabel: "View Multiplex Pro"
            ) { [weak self] in
                self?.presentPaywall()
            })))
        }
        return SettingsSectionView(
            title: "Agent alerts",
            detail: "Posts a banner when Claude Code, Codex, or Grok Build finishes a turn, "
                + "asks a question, or wants permission in a session you are not typing in. "
                + "Multiplex must remain open. Requires Pro.",
            rows: rows
        )
    }

    private func makeAppLockSection(_ state: ViewState) -> UIView {
        let method = AppLockStore.methodName
        let control = SettingsBooleanRow(
            title: "Require \(method)",
            isOn: state.appLockEnabled,
            optimisticallyUpdates: false,
            accessibilityHint: "Locks the app behind \(method)"
        ) { [weak self] enabled in
            guard let self else { return }
            Task { @MainActor in
                await self.appLock.setEnabled(enabled)
                // Failed authentication intentionally leaves the store
                // unchanged, so Observation has no mutation to report.
                self.observeStores()
            }
        }
        appLockControl = control
        return SettingsSectionView(
            title: "App lock",
            detail: "Require \(method) when Multiplex opens or returns from the background. "
                + "The deck and every terminal stay covered until you authenticate; "
                + "connections and the wall keep running. This device only.",
            rows: [control]
        )
    }

    private func makeProSection(_ state: ViewState) -> UIView {
        let entitlementStatus = UIStackView(arrangedSubviews: [
            UIKitChassisLabel(state.isPro ? "Pro unlocked" : "Free tier", size: 11),
            settingsFlexibleSpacer(),
            SettingsBadgeView(
                state.isPro ? "UNLOCKED" : "FREE",
                prominent: state.isPro
            ),
        ])
        entitlementStatus.axis = .horizontal
        entitlementStatus.alignment = .center
        entitlementStatus.spacing = 12

        var rows: [UIView] = [SettingsInsetRow(contentView: entitlementStatus)]
        rows.append(proRow("Unlimited Hosts", state: state))
        rows.append(proRow("Mosh Transport", state: state))
        rows.append(proRow(
            "Agent Helpers",
            freeStatus: "\(EntitlementStore.dailySlashChipLimit) / DAY",
            state: state
        ))
        rows.append(proRow("Agent Alerts", state: state))
        rows.append(proRow("Connection Stats", state: state))
        rows.append(proRow("Custom Themes", state: state))
        rows.append(proRow(
            "Key Commands",
            freeStatus: "UP TO \(EntitlementStore.freeKeyCommandLimit)",
            state: state
        ))
        rows.append(SettingsInsetRow(contentView: settingsLeadingView(UIKitChassisChip(
            state.isPro ? "PRO DETAILS" : "UNLOCK MULTIPLEX PRO",
            prominent: true,
            accessibilityLabel: state.isPro ? "Pro details" : "Unlock Multiplex Pro"
        ) { [weak self] in
            self?.presentPaywall()
        })))

        #if DEBUG
        rows.append(SettingsBooleanRow(
            title: "Pro debug override",
            isOn: state.isPro,
            accessibilityLabel: "Pro unlocked debug override"
        ) { [weak self] unlocked in
            self?.entitlements.setDebugUnlocked(unlocked)
        })
        #endif

        return SettingsSectionView(
            title: "Multiplex Pro",
            detail: "Pro adds unlimited hosts, mosh, unlimited agent-helper commands, "
                + "alerts, connection stats, custom themes, and a \(KeyCommandSet.maximumCount)-command Key Commands set "
                + "(free keeps \(EntitlementStore.freeKeyCommandLimit)). SSH terminals, agent "
                + "detection, and the wall's live state stay free.",
            rows: rows
        )
    }

    private func proRow(
        _ name: String,
        freeStatus: String = "Locked",
        state: ViewState
    ) -> UIView {
        let row = UIStackView(arrangedSubviews: [
            UIKitChassisLabel(name, size: 9, color: UIKitChassis.signal2),
            settingsFlexibleSpacer(),
            SettingsBadgeView(state.isPro ? "INCLUDED" : freeStatus.uppercased()),
        ])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        return SettingsInsetRow(contentView: row)
    }

    private func makeAboutSection() -> UIView {
        let whatsNew = SettingsNavigationRow(
            title: "What’s New",
            accessibilityLabel: "What’s new"
        ) { [weak self] in
            self?.showReleaseLog()
        }
        whatsNew.accessibilityIdentifier = "settings.whatsNew"
        let licenses = SettingsNavigationRow(
            title: "Open Source Licenses",
            accessibilityLabel: "Open source licenses"
        ) { [weak self] in
            self?.showLicenses()
        }
        return SettingsSectionView(
            title: "About",
            detail: "Everything Multiplex \(ReleaseNotes.version) changed, and the "
                + "license notices for the third-party code shipped with it.",
            rows: [whatsNew, licenses]
        )
    }

    private func makePrivacyLink() -> UIView {
        let holder = UIView()
        let chip = UIKitChassisChip(
            "PRIVACY POLICY",
            systemImage: "arrow.up.right",
            accessibilityLabel: "Privacy policy"
        ) { [weak self] in
            self?.openPrivacy()
        }
        chip.accessibilityTraits = .link
        holder.addSubview(chip)
        chip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chip.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            chip.topAnchor.constraint(equalTo: holder.topAnchor),
            chip.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            chip.leadingAnchor.constraint(greaterThanOrEqualTo: holder.leadingAnchor),
            chip.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor),
        ])
        return holder
    }

    private func select(_ theme: TerminalTheme) {
        themes.select(theme, for: resolvedAppearance(for: themes.appearance))
    }

    private func duplicate(_ theme: TerminalTheme) {
        guard entitlements.canMutateCustomThemes else {
            presentPaywall()
            return
        }
        showThemeEditor(theme.asCustom(named: "\(theme.name) Copy"))
    }

    private func requestThemeEditor(_ theme: TerminalTheme) {
        guard entitlements.canMutateCustomThemes else {
            presentPaywall()
            return
        }
        showThemeEditor(theme)
    }

    private func showThemeEditor(_ theme: TerminalTheme) {
        let controller = ThemeEditorViewController(theme: theme) { [weak self] edited in
            self?.save(edited)
        }
        // Each edit lands in the open terminal windows for the appearance
        // being edited; Save keeps it (via `save`), Back restores the
        // committed selection.
        controller.onPreview = { [weak self] draft in
            guard let self else { return }
            if let draft {
                themes.preview(draft, for: resolvedAppearance(for: themes.appearance))
            } else {
                themes.endPreview()
            }
        }
        controller.followAppAppearance(themes)
        navigationController?.pushViewController(controller, animated: true)
    }

    /// The record the launch card's FULL NOTES chip leads to, reachable
    /// afterwards from here — which is what keeps a one-time modal from being
    /// the only road to it. Its own modal for the same reason the licenses
    /// page is one.
    private func showReleaseLog() {
        let controller = ReleaseLogViewController()
        controller.followAppAppearance(themes)
        let navigation = UINavigationController(rootViewController: controller)
        controller.onDone = { [weak navigation] in
            navigation?.dismiss(animated: true)
        }
        navigation.navigationBar.prefersLargeTitles = false
        navigation.view.backgroundColor = GlassPrototype.clearedChassis
        UIKitChassis.configureSheetNavigationBar(navigation.navigationBar)
        navigation.preferredContentSize = ReleaseLogViewController.preferredSheetSize
        if UIDevice.current.userInterfaceIdiom == .pad {
            navigation.modalPresentationStyle = .formSheet
        }
        present(navigation, animated: true)
    }

    /// The licenses page is its own modal, not a push: its component wall
    /// wants the license texts' authored column width (980 pt), and resizing
    /// the settings sheet mid-navigation reads as a glitch. A fresh sheet
    /// arrives at full width with the stock presentation animation.
    private func showLicenses() {
        let controller = LicensesViewController()
        controller.followAppAppearance(themes)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.navigationBar.prefersLargeTitles = false
        navigation.view.backgroundColor = GlassPrototype.clearedChassis
        UIKitChassis.configureSheetNavigationBar(navigation.navigationBar)
        // visionOS sheets honor preferredContentSize as-is; iPad needs the
        // form-sheet style for it (a page sheet's width is system-fixed).
        // iPhone's sheet ignores it either way.
        navigation.preferredContentSize = LicensesViewController.preferredSheetSize
        if UIDevice.current.userInterfaceIdiom == .pad {
            navigation.modalPresentationStyle = .formSheet
        }
        present(navigation, animated: true)
    }

    private func save(_ theme: TerminalTheme) {
        if themes.theme(id: theme.id) == nil {
            themes.add(theme)
            themes.select(theme, for: resolvedAppearance(for: themes.appearance))
        } else {
            themes.update(theme)
        }
    }

    private func presentPaywall() {
        if let presentPaywallOverride {
            presentPaywallOverride()
            return
        }
        guard presentedViewController == nil else { return }
        let controller = ProPaywallViewController(entitlements: entitlements)
        controller.followAppAppearance(themes)
        let navigation = UINavigationController(rootViewController: controller)
        controller.onDone = { [weak navigation] in
            navigation?.dismiss(animated: true)
        }
        present(navigation, animated: true)
    }

    private func openPrivacy() {
        guard let url = URL(string: "https://multiplexterm.dev/privacy") else { return }
        if let openPrivacyPolicy {
            openPrivacyPolicy(url)
        } else {
            UIApplication.shared.open(url)
        }
    }

    private func resolvedAppearance(for appearance: AppAppearance) -> ResolvedAppearance {
        if let pinned = appearance.resolvedOverride { return pinned }
        return traitCollection.userInterfaceStyle == .light ? .light : .dark
    }

    private func applyAppearance(_ appearance: AppAppearance? = nil) {
        let appearance = appearance ?? themes.appearance
        let style = appearance.interfaceStyle
        overrideUserInterfaceStyle = style
        navigationController?.overrideUserInterfaceStyle = style
        viewIfLoaded?.window?.overrideUserInterfaceStyle = style
        refreshDynamicTextColorsAfterTraitPropagation()
        if let navigationBar = navigationController?.navigationBar {
            UIKitChassis.configureSheetNavigationBar(navigationBar)
        }
        // A presented theme editor follows the store through its own
        // `followAppAppearance` link installed at presentation — no push here.
    }

    @objc private func donePressed() {
        if let onDone {
            onDone()
        } else {
            navigationController?.dismiss(animated: true)
        }
    }

    #if DEBUG
    private func presentThemeEditorForVerificationIfRequested() {
        guard !didRunDebugPresentation,
              ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_SETTINGS"] == "theme"
        else { return }
        didRunDebugPresentation = true
        let selected = themes.selected(for: resolvedAppearance(for: themes.appearance))
        showThemeEditor(selected.asCustom(named: "Tally Custom"))
    }

    private func presentLicensesForVerificationIfRequested() {
        guard !didRunDebugPresentation,
              ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_SETTINGS"] == "licenses"
        else { return }
        didRunDebugPresentation = true
        showLicenses()
    }
    #endif
}

// MARK: - Settings-native TALLY components

/// A form section with the same header, one-point row separators, card border,
/// and postscript geometry as `TallyFormSection`.
@MainActor
final class SettingsSectionView: UIView {
    let title: String

    init(title: String, detail: String?, rows: [UIView]) {
        self.title = title
        super.init(frame: .zero)

        let headerLabel = UIKitChassisLabel(title, size: 10)
        headerLabel.accessibilityTraits.insert(.header)
        let header = UIView()
        header.backgroundColor = UIKitChassis.bezel
        header.addSubview(headerLabel)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            headerLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            headerLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 10),
            headerLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -10),
        ])

        let divider = UIView()
        divider.backgroundColor = UIKitChassis.bezelHi
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let rowStack = UIStackView(arrangedSubviews: rows)
        rowStack.axis = .vertical
        rowStack.spacing = 1
        rowStack.backgroundColor = UIKitChassis.bezelHi

        let cardStack = UIStackView(arrangedSubviews: [header, divider, rowStack])
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

        let sectionStack = UIStackView(arrangedSubviews: [card])
        sectionStack.axis = .vertical
        sectionStack.spacing = 8
        if let detail {
            let detailLabel = settingsLabel(
                detail,
                font: UIKitChassis.uiFont(10),
                color: UIKitChassis.signal2
            )
            let detailHolder = UIView()
            detailHolder.addSubview(detailLabel)
            detailLabel.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                detailLabel.leadingAnchor.constraint(
                    equalTo: detailHolder.leadingAnchor,
                    constant: 2
                ),
                detailLabel.trailingAnchor.constraint(
                    equalTo: detailHolder.trailingAnchor,
                    constant: -2
                ),
                detailLabel.topAnchor.constraint(equalTo: detailHolder.topAnchor),
                detailLabel.bottomAnchor.constraint(equalTo: detailHolder.bottomAnchor),
            ])
            sectionStack.addArrangedSubview(detailHolder)
        }

        addSubview(sectionStack)
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sectionStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            sectionStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            sectionStack.topAnchor.constraint(equalTo: topAnchor),
            sectionStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

@MainActor
final class SettingsInsetRow: UIView {
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
final class SettingsNavigationRow: UIControl {
    private let action: () -> Void

    init(title: String, accessibilityLabel: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        backgroundColor = GlassPrototype.strataChassis
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        isAccessibilityElement = true
        self.accessibilityLabel = accessibilityLabel
        accessibilityTraits = .button
        addTarget(self, action: #selector(pressed), for: .touchUpInside)

        let titleLabel = UIKitChassisLabel(title, size: 10)
        let chevron = UIImageView(image: UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 9 * Theme.typeScale,
                weight: .semibold
            )
        ))
        chevron.tintColor = UIKitChassis.signal2
        chevron.contentMode = .scaleAspectFit
        chevron.isAccessibilityElement = false
        let row = UIStackView(arrangedSubviews: [
            titleLabel,
            settingsFlexibleSpacer(),
            chevron,
        ])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted
                ? UIKitChassis.bezel
                : GlassPrototype.strataChassis
        }
    }

    @objc private func pressed() {
        action()
    }
}

enum SettingsAppearanceChoiceMetrics {
    static let height: CGFloat = 34
    static let seam: CGFloat = 1
    static let selectionAnimationDuration: TimeInterval = 0.14
    static let selectionAnimationCurve = UIView.AnimationCurve.easeOut
}

@MainActor
private extension AppAppearance {
    var settingsTitle: String {
        switch self {
        case .system: "SYSTEM"
        case .light: "LIGHT"
        case .dark: "DARK"
        case .glass: "GLASS"
        }
    }
}

final class SettingsAppearanceChoiceBar: UIStackView {
    private(set) var selection: AppAppearance
    private let changed: (AppAppearance) -> Void
    private let reduceMotion: () -> Bool
    private var buttons: [UIButton] = []
    private(set) var activeSelectionAnimator: UIViewPropertyAnimator?

    init(
        selection: AppAppearance,
        reduceMotion: @escaping () -> Bool = { UIAccessibility.isReduceMotionEnabled },
        changed: @escaping (AppAppearance) -> Void
    ) {
        self.selection = selection
        self.reduceMotion = reduceMotion
        self.changed = changed
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .fill
        distribution = .fillEqually
        spacing = SettingsAppearanceChoiceMetrics.seam
        backgroundColor = UIKitChassis.bezelHi

        // PROTOTYPE(GLASS): every visionOS build adds GLASS; iOS/iPadOS keep
        // the three baseline choices.
        for appearance in AppAppearance.availableCases {
            let button = SettingsChoiceButton(
                title: appearance.settingsTitle, appearance: appearance
            )
            button.addTarget(self, action: #selector(choicePressed(_:)), for: .touchUpInside)
            addArrangedSubview(button)
            buttons.append(button)
        }
        refresh()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("unused") }

    func setSelection(_ selection: AppAppearance, animated: Bool) {
        guard self.selection != selection else { return }
        self.selection = selection
        refresh(animated: animated)
    }

    @objc private func choicePressed(_ sender: SettingsChoiceButton) {
        guard selection != sender.appearance else { return }
        selection = sender.appearance
        refresh(animated: true)
        changed(selection)
    }

    private func refresh(animated: Bool = false) {
        if activeSelectionAnimator?.state == .active {
            activeSelectionAnimator?.stopAnimation(true)
        }
        guard animated, !reduceMotion() else {
            activeSelectionAnimator = nil
            applySelection()
            return
        }
        let animator = UIViewPropertyAnimator(
            duration: SettingsAppearanceChoiceMetrics.selectionAnimationDuration,
            curve: SettingsAppearanceChoiceMetrics.selectionAnimationCurve
        ) { [weak self] in
            self?.applySelection()
        }
        activeSelectionAnimator = animator
        animator.startAnimation()
    }

    private func applySelection() {
        for case let button as SettingsChoiceButton in buttons {
            button.setSelected(button.appearance == selection)
        }
    }
}

@MainActor
private final class SettingsChoiceButton: UIButton {
    let appearance: AppAppearance
    private let sourceTitle: String
    private let chassisTitle = UILabel()

    init(title: String, appearance: AppAppearance) {
        self.appearance = appearance
        sourceTitle = title
        super.init(frame: .zero)
        // Mirrors SwiftUI's `.buttonStyle(.plain)`: no UIKit configuration
        // may contribute a native capsule or tint ground.
        configuration = nil
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        isAccessibilityElement = true
        accessibilityLabel = title.capitalized
        accessibilityTraits = .button
        chassisTitle.numberOfLines = 1
        chassisTitle.isAccessibilityElement = false
        addSubview(chassisTitle)
        chassisTitle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chassisTitle.centerXAnchor.constraint(equalTo: centerXAnchor),
            chassisTitle.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: SettingsAppearanceChoiceMetrics.height),
        ])
        layer.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setSelected(_ selected: Bool) {
        // PROTOTYPE(GLASS): resting segments are strata over the smoke like
        // every chassis control; opaque graphite otherwise.
        backgroundColor = selected ? UIKitChassis.bezelHi : GlassPrototype.strataChassis
        chassisTitle.attributedText = NSAttributedString(
            string: sourceTitle.uppercased(),
            attributes: [
                .font: UIKitChassis.compressedLabelFont(9),
                .kern: CGFloat(9 * Theme.typeScale * 0.09),
            ]
        )
        chassisTitle.textColor = selected ? UIKitChassis.signal : UIKitChassis.signal2
        layer.borderColor = (selected ? UIKitChassis.signal2 : UIKitChassis.bezelHi)
            .resolvedColor(with: traitCollection)
            .cgColor
        accessibilityValue = selected ? "Selected" : "Not selected"
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

@MainActor
final class SettingsBooleanRow: UIControl {
    private let changed: (Bool) -> Void
    private let titleLabel = UILabel()
    private let indicator = SettingsSwitchIndicator()
    private let optimisticallyUpdates: Bool
    private(set) var isOn: Bool

    init(
        title: String,
        isOn: Bool,
        status: String? = nil,
        statusIsProminent: Bool = false,
        optimisticallyUpdates: Bool = true,
        accessibilityLabel: String? = nil,
        accessibilityHint: String? = nil,
        changed: @escaping (Bool) -> Void
    ) {
        self.isOn = isOn
        self.changed = changed
        self.optimisticallyUpdates = optimisticallyUpdates
        super.init(frame: .zero)
        backgroundColor = GlassPrototype.strataChassis
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        self.accessibilityLabel = accessibilityLabel ?? title
        self.accessibilityHint = accessibilityHint
        isAccessibilityElement = true
        // The SwiftUI row represented itself to assistive technology as a real
        // `Toggle`; `.toggleButton` is UIKit's equivalent identity, so the
        // switch rotor and the spoken On/Off state survive the port.
        accessibilityTraits = [.button, .toggleButton]

        titleLabel.text = title
        titleLabel.font = UIKitChassis.uiFont(12, weight: .semibold)
        titleLabel.textColor = UIKitChassis.signal
        titleLabel.numberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.isAccessibilityElement = false

        var arranged: [UIView] = [titleLabel]
        if let status {
            arranged.append(SettingsBadgeView(status, prominent: statusIsProminent))
        }
        arranged.append(settingsFlexibleSpacer())
        arranged.append(indicator)
        let row = UIStackView(arrangedSubviews: arranged)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        addTarget(self, action: #selector(pressed), for: .touchUpInside)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var isHighlighted: Bool {
        // PROTOTYPE(GLASS): rest on strataChassis — the ground the init
        // chose — or the first tap permanently flips the row opaque.
        didSet {
            backgroundColor = isHighlighted
                ? UIKitChassis.bezel : GlassPrototype.strataChassis
        }
    }

    override func accessibilityActivate() -> Bool {
        pressed()
        return true
    }

    @objc private func pressed() {
        let requestedValue = !isOn
        if optimisticallyUpdates {
            isOn = requestedValue
            refresh(animated: true)
        }
        changed(requestedValue)
    }

    private func refresh(animated: Bool = false) {
        indicator.setOn(isOn, animated: animated)
        accessibilityValue = isOn ? "On" : "Off"
    }
}

@MainActor
private final class SettingsSwitchIndicator: UIKitTallyBorderedView {
    /// The SwiftUI switch slid its thumb with `.easeOut(duration: 0.14)`; the
    /// appearance choice bar above it still uses exactly that timing, so the
    /// two controls must not disagree.
    private static let slideDuration: TimeInterval = 0.14

    private let thumb = UIView()
    private var thumbLeading: NSLayoutConstraint!
    private var thumbTrailing: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = GlassPrototype.strataChassis
        addSubview(thumb)
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumbLeading = thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        thumbTrailing = thumb.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 20),
            thumb.widthAnchor.constraint(equalToConstant: 12),
            thumb.heightAnchor.constraint(equalToConstant: 12),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbLeading,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setOn(_ isOn: Bool, animated: Bool = false) {
        thumbLeading.isActive = false
        thumbTrailing.isActive = false
        (isOn ? thumbTrailing : thumbLeading).isActive = true
        let apply = {
            self.backgroundColor = isOn ? UIKitChassis.bezelHi : UIKitChassis.screen
            self.thumb.backgroundColor = isOn ? UIKitChassis.signal : UIKitChassis.signal3
            self.tallyBorderColor = isOn ? UIKitChassis.signal2 : UIKitChassis.bezelHi
            // The swapped constraint only moves the thumb inside an animation
            // transaction if the layout pass runs there too.
            self.layoutIfNeeded()
        }
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            apply()
            return
        }
        UIView.animate(
            withDuration: Self.slideDuration,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState],
            animations: apply
        )
    }
}

@MainActor
final class SettingsBadgeView: UIKitTallyBorderedView {
    private let contentStack = UIStackView()

    init(_ text: String, systemImage: String? = nil, prominent: Bool = false) {
        super.init(frame: .zero)
        backgroundColor = GlassPrototype.strataChassis
        tallyBorderColor = prominent ? UIKitChassis.signal2 : UIKitChassis.bezelHi

        if let systemImage {
            let image = UIImageView(image: UIImage(
                systemName: systemImage,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 9 * Theme.typeScale,
                    weight: .semibold
                )
            ))
            image.tintColor = prominent ? UIKitChassis.signal : UIKitChassis.signal2
            image.contentMode = .scaleAspectFit
            image.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                image.widthAnchor.constraint(equalToConstant: 10 * Theme.typeScale),
                image.heightAnchor.constraint(equalToConstant: 10 * Theme.typeScale),
            ])
            contentStack.addArrangedSubview(image)
        }
        if !text.isEmpty {
            contentStack.addArrangedSubview(settingsTrackedLabel(
                text,
                font: UIKitChassis.monoFont(9, weight: .semibold),
                color: prominent ? UIKitChassis.signal : UIKitChassis.signal2,
                kern: 1.1
            ))
        }
        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 5
        addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        isAccessibilityElement = true
        accessibilityLabel = text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

/// Native rendering of a terminal palette: prompt, output, cursor, and the
/// exact ANSI colors supplied by the model.
@MainActor
final class UIKitThemePreviewView: UIKitTallyBorderedView {
    private(set) var theme: TerminalTheme
    let compact: Bool
    private let promptLabel = UILabel()
    private let outputLabel = UILabel()
    private let ansiStack = UIStackView()

    init(theme: TerminalTheme, compact: Bool = false) {
        self.theme = theme
        self.compact = compact
        super.init(frame: .zero)
        tallyBorderColor = UIKitChassis.bezelHi
        isAccessibilityElement = true
        configure()
        setTheme(theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setTheme(_ theme: TerminalTheme) {
        self.theme = theme
        backgroundColor = UIColor(theme.background)
        promptLabel.attributedText = promptText(theme)
        outputLabel.attributedText = outputText(theme)
        ansiStack.arrangedSubviews.forEach {
            ansiStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let count = compact ? 8 : 16
        for index in 0..<count {
            let swatch = UIView()
            swatch.backgroundColor = UIColor(theme.safeANSI(index))
            swatch.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                swatch.widthAnchor.constraint(equalToConstant: compact ? 8 : 12),
                swatch.heightAnchor.constraint(equalToConstant: compact ? 8 : 12),
            ])
            ansiStack.addArrangedSubview(swatch)
        }
        accessibilityLabel = "Preview of the \(theme.name) terminal theme"
    }

    private func configure() {
        let size: CGFloat = compact ? 10 : 13
        promptLabel.font = UIKitChassis.monoFont(size)
        promptLabel.numberOfLines = 1
        promptLabel.lineBreakMode = .byTruncatingTail
        outputLabel.font = UIKitChassis.monoFont(size)
        outputLabel.numberOfLines = 1
        outputLabel.lineBreakMode = .byTruncatingTail
        outputLabel.isHidden = compact
        ansiStack.axis = .horizontal
        ansiStack.alignment = .center
        ansiStack.spacing = compact ? 3 : 4

        let stack = UIStackView(arrangedSubviews: [promptLabel, outputLabel, ansiStack])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = compact ? 6 : 10
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let inset: CGFloat = compact ? 10 : 16
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
    }

    private func promptText(_ theme: TerminalTheme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(settingsThemeText("demo@devbox", color: theme.safeANSI(2)))
        result.append(settingsThemeText(" ~", color: theme.safeANSI(4)))
        result.append(settingsThemeText(" $ tmux a", color: theme.foreground))
        result.append(settingsThemeText(" █", color: theme.cursor))
        return result
    }

    private func outputText(_ theme: TerminalTheme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(settingsThemeText("✓ ", color: theme.safeANSI(2)))
        result.append(settingsThemeText("attached · 3 windows", color: theme.safeANSI(8)))
        return result
    }

    private func settingsThemeText(
        _ text: String,
        color: ThemeColor
    ) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: UIKitChassis.monoFont(compact ? 10 : 13),
                .foregroundColor: UIColor(color),
            ]
        )
    }
}

@MainActor
private final class SettingsThemeRowView: UIView {
    private let theme: TerminalTheme
    private let selectControl = UIButton(type: .custom)
    private let content: SettingsThemeRowContentView
    private let menuProvider: () -> UIMenu?

    init(
        theme: TerminalTheme,
        isSelected: Bool,
        select: @escaping () -> Void,
        edit: (() -> Void)? = nil,
        duplicate: (() -> Void)? = nil,
        delete: (() -> Void)? = nil
    ) {
        self.theme = theme
        content = SettingsThemeRowContentView(theme: theme, isSelected: isSelected)
        menuProvider = {
            var actions: [UIMenuElement] = []
            if let edit {
                actions.append(UIAction(title: "Edit…") { _ in edit() })
            }
            if let duplicate {
                actions.append(UIAction(title: "Duplicate") { _ in duplicate() })
            }
            if let delete {
                actions.append(UIAction(title: "Delete", attributes: .destructive) { _ in
                    delete()
                })
            }
            return actions.isEmpty ? nil : UIMenu(children: actions)
        }
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.bezelHi

        // PROTOTYPE(GLASS): theme rows rest on strata over the smoke.
        selectControl.backgroundColor = isSelected
            ? UIKitChassis.bezel : GlassPrototype.strataChassis
        selectControl.hoverStyle = UIHoverStyle(
            effect: .highlight,
            shape: .rect(cornerRadius: 2)
        )
        selectControl.isAccessibilityElement = true
        selectControl.accessibilityLabel = "\(theme.name) theme"
        selectControl.accessibilityValue = isSelected ? "Selected" : "Not selected"
        selectControl.accessibilityTraits = .button
        if isSelected { selectControl.accessibilityTraits.insert(.selected) }
        selectControl.addAction(UIAction { _ in select() }, for: .touchUpInside)
        content.isUserInteractionEnabled = false
        selectControl.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: selectControl.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: selectControl.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: selectControl.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: selectControl.bottomAnchor, constant: -12),
        ])

        let hasVisibleActions = edit != nil || delete != nil || (duplicate != nil && !theme.isBuiltIn)
        let row = UIStackView(arrangedSubviews: [selectControl])
        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = 1
        if hasVisibleActions, let menu = menuProvider() {
            // SwiftUI's original Menu used `.buttonStyle(.plain)`: only the
            // 9/5 TALLY badge is painted, while its 44-point hit target stays
            // transparent over the row seam. A system UIButton opts into the
            // platform's native button ground on newer OS releases.
            let actionButton = UIButton(type: .custom)
            actionButton.backgroundColor = .clear
            actionButton.menu = menu
            actionButton.showsMenuAsPrimaryAction = true
            actionButton.accessibilityLabel = "Actions for \(theme.name)"
            actionButton.hoverStyle = UIHoverStyle(
                effect: .highlight,
                shape: .rect(cornerRadius: 2)
            )
            let badge = SettingsBadgeView("", systemImage: "ellipsis")
            badge.isAccessibilityElement = false
            badge.isUserInteractionEnabled = false
            actionButton.addSubview(badge)
            badge.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                badge.centerXAnchor.constraint(equalTo: actionButton.centerXAnchor),
                badge.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
            ])
            actionButton.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
                actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            ])
            row.addArrangedSubview(actionButton)
        }
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if menuProvider() != nil {
            selectControl.addInteraction(UIContextMenuInteraction(delegate: self))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

extension SettingsThemeRowView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard menuProvider() != nil else { return nil }
        return UIContextMenuConfiguration(identifier: theme.id as NSString) { [weak self] _ in
            self?.menuProvider()
        }
    }
}

@MainActor
private final class SettingsThemeRowContentView: UIView {
    private let preview: UIKitThemePreviewView
    private let identity: UIStackView
    private let selectionBadge: SettingsBadgeView
    private let layoutStack = UIStackView()
    private let topStack = UIStackView()
    private var previewWidth: NSLayoutConstraint?
    private var usesVerticalLayout = false

    init(theme: TerminalTheme, isSelected: Bool) {
        preview = UIKitThemePreviewView(theme: theme, compact: true)
        let name = UIKitChassisLabel(theme.name, size: 11)
        let kind = settingsTrackedLabel(
            theme.isBuiltIn ? "BUILT-IN PALETTE" : "CUSTOM PALETTE",
            font: UIKitChassis.monoFont(8, weight: .medium),
            color: UIKitChassis.signal3,
            kern: 1
        )
        kind.numberOfLines = 1
        identity = UIStackView(arrangedSubviews: [name, kind])
        identity.axis = .vertical
        identity.spacing = 3
        selectionBadge = SettingsBadgeView(
            isSelected ? "ACTIVE" : "SELECT",
            prominent: isSelected
        )
        super.init(frame: .zero)
        layoutStack.alignment = .center
        addSubview(layoutStack)
        layoutStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            layoutStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            layoutStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            layoutStack.topAnchor.constraint(equalTo: topAnchor),
            layoutStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        installHorizontalLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let identityWidth = identity.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize
        ).width
        let badgeWidth = selectionBadge.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize
        ).width
        // Horizontal HStack anatomy: 148-point preview, three 14-point
        // gaps, and Spacer(minLength: 12), plus the intrinsic identity/badge.
        let horizontalRequiredWidth = 148 + identityWidth + badgeWidth + 54
        let shouldUseVertical = bounds.width < horizontalRequiredWidth
        guard shouldUseVertical != usesVerticalLayout else { return }
        usesVerticalLayout = shouldUseVertical
        if shouldUseVertical {
            installVerticalLayout()
        } else {
            installHorizontalLayout()
        }
    }

    private func clearLayouts() {
        previewWidth?.isActive = false
        previewWidth = nil
        for stack in [layoutStack, topStack] {
            stack.arrangedSubviews.forEach {
                stack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
        }
    }

    private func installHorizontalLayout() {
        clearLayouts()
        layoutStack.axis = .horizontal
        layoutStack.alignment = .center
        layoutStack.spacing = 14
        layoutStack.addArrangedSubview(preview)
        layoutStack.addArrangedSubview(identity)
        let spacer = settingsFlexibleSpacer()
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 12).isActive = true
        layoutStack.addArrangedSubview(spacer)
        layoutStack.addArrangedSubview(selectionBadge)
        previewWidth = preview.widthAnchor.constraint(equalToConstant: 148)
        previewWidth?.isActive = true
    }

    private func installVerticalLayout() {
        clearLayouts()
        topStack.axis = .horizontal
        topStack.alignment = .center
        topStack.spacing = 10
        topStack.addArrangedSubview(identity)
        let spacer = settingsFlexibleSpacer()
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true
        topStack.addArrangedSubview(spacer)
        topStack.addArrangedSubview(selectionBadge)
        layoutStack.axis = .vertical
        layoutStack.alignment = .fill
        layoutStack.spacing = 10
        layoutStack.addArrangedSubview(topStack)
        layoutStack.addArrangedSubview(preview)
    }
}

private extension TerminalTheme {
    func safeANSI(_ index: Int) -> ThemeColor {
        ansi.indices.contains(index) ? ansi[index] : foreground
    }
}

@MainActor
private func settingsFlexibleSpacer() -> UIView {
    let spacer = UIView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return spacer
}

@MainActor
private func settingsLeadingView(_ content: UIView) -> UIView {
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

@MainActor
private func settingsLabel(_ text: String, font: UIFont, color: UIColor) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = font
    label.textColor = color
    label.numberOfLines = 0
    return label
}

@MainActor
private func settingsTrackedLabel(
    _ text: String,
    font: UIFont,
    color: UIColor,
    kern: CGFloat
) -> UILabel {
    let label = UILabel()
    label.attributedText = NSAttributedString(
        string: text,
        attributes: [.font: font, .foregroundColor: color, .kern: kern]
    )
    return label
}
