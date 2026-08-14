import Observation
import UIKit

// MARK: - Native UIKit screen

/// StoreKit-backed Multiplex Pro purchase surface.
///
/// Commerce remains entirely inside `EntitlementStore`; this controller owns
/// only presentation, scene-anchored purchase intent, restoration intent, and
/// a live UIKit rendering of the store's observable state.
@MainActor
final class ProPaywallViewController: UIViewController, AppAppearanceFollowing {
    enum Metrics {
        static let contentMaximumWidth: CGFloat = 620
        static let outerInset: CGFloat = 26
        static let sectionSpacing: CGFloat = 24
        static let featureSpacing: CGFloat = 18
        static let purchaseSpacing: CGFloat = 12
    }

    private struct ViewState {
        let isPro: Bool
        let productDisplayPrice: String?
        let productIsLoading: Bool
        let productLoadError: String?
        let commerceState: EntitlementStore.CommerceState
        let purchaseIsUnavailable: Bool
        let restoreIsUnavailable: Bool
        let storeEnvironmentIsSandbox: Bool
    }

    let entitlements: EntitlementStore
    var onDone: (() -> Void)?

    var appAppearance = AppAppearance.system {
        didSet { applyAppAppearance() }
    }
    let appAppearanceFollower = AppAppearanceFollower()

    private(set) var contentStack = UIStackView()
    private(set) var purchaseButton = ProPaywallPurchaseButton()
    private(set) var restoreButton = UIButton(type: .system)
    private(set) var commerceMessageLabel = UILabel()
    private(set) var unlockedRow = UIStackView()

    private let scrollView = UIScrollView()
    private var storefrontTask: Task<Void, Never>?

    init(entitlements: EntitlementStore) {
        self.entitlements = entitlements
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Pro"
        view.backgroundColor = GlassPrototype.sheetGround

        configureNavigation()
        configureContent()
        observeEntitlements()
        applyAppAppearance()

        storefrontTask = Task { @MainActor [weak entitlementStore = self.entitlements] in
            await entitlementStore?.loadStorefront()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyAppAppearance()
    }

    deinit {
        storefrontTask?.cancel()
    }

    private func configureNavigation() {
        navigationItem.largeTitleDisplayMode = .never
        #if os(visionOS)
        navigationItem.titleView = UIKitChassisLabel("Pro", size: 12)
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
        contentStack.addArrangedSubview(makeHero())
        contentStack.addArrangedSubview(makeFeatures())
        contentStack.addArrangedSubview(makePurchaseControls())

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

    private func makeHero() -> UIView {
        let brand = UIKitChassisLabel("Multiplex Pro", size: 18)

        let promise = makeLabel(
            "Buy once. Use it on iPad and Vision Pro.",
            style: .title3,
            weight: .semibold,
            color: UIKitChassis.signal
        )
        let freeTier = makeLabel(
            "The free tier stays useful: two hosts, spatial SSH terminals, "
                + "live agent detection, built-in themes and "
                + "\(EntitlementStore.dailySlashChipLimit) built-in or custom "
                + "agent-command taps each day.",
            style: .subheadline,
            color: UIKitChassis.signal2
        )

        let stack = UIStackView(arrangedSubviews: [brand, promise, freeTier])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8
        return stack
    }

    private func makeFeatures() -> UIView {
        let stack = UIStackView(arrangedSubviews: [
            makeFeature(
                "UNLIMITED HOSTS",
                "Keep your work box, homelab and servers on one live fleet wall."
            ),
            makeFeature(
                "MOSH TRANSPORT",
                "Keep terminals alive through headset sleep, network roaming and IP changes."
            ),
            makeFeature(
                "AGENT HELPERS + ALERTS",
                "Use Claude Code, Codex, and Pi quick commands without the daily "
                    + "limit, browse a Claude Code session's prompt history and jump "
                    + "its transcript back to any message, and get a banner when an "
                    + "unwatched supported session needs you."
            ),
            makeFeature(
                "CONNECTION STATS",
                "Open the fleet board behind every rail chip: round-trips, typing "
                    + "echo, mosh loss and roams, reconnects, and data volume per host."
            ),
            makeFeature(
                "CUSTOM THEMES",
                "Build and edit terminal palettes while the Tally chassis stays consistent."
            ),
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Metrics.featureSpacing
        return stack
    }

    private func makeFeature(_ title: String, _ detail: String) -> UIView {
        let check = UIImageView(image: UIImage(
            systemName: "checkmark",
            withConfiguration: UIImage.SymbolConfiguration(
                font: ProPaywallFont.font(for: .caption1, weight: .bold)
            )
        ))
        check.tintColor = UIKitChassis.signal2
        check.contentMode = .top
        check.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            check.widthAnchor.constraint(equalToConstant: 16),
            check.heightAnchor.constraint(equalToConstant: 18),
        ])

        let featureTitle = UIKitChassisLabel(title, size: 11)
        let detailLabel = makeLabel(
            detail,
            style: .subheadline,
            color: UIKitChassis.signal2
        )
        let copy = UIStackView(arrangedSubviews: [featureTitle, detailLabel])
        copy.axis = .vertical
        copy.alignment = .fill
        copy.spacing = 5

        let row = UIStackView(arrangedSubviews: [check, copy])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 12
        return row
    }

    private func makePurchaseControls() -> UIView {
        unlockedRow = makeUnlockedRow()

        purchaseButton.addTarget(
            self,
            action: #selector(purchasePressed),
            for: .touchUpInside
        )
        purchaseButton.accessibilityHint =
            "Purchases the non-consumable Multiplex Pro unlock"

        commerceMessageLabel.font = ProPaywallFont.font(for: .footnote)
        commerceMessageLabel.adjustsFontForContentSizeCategory = true
        commerceMessageLabel.numberOfLines = 0

        restoreButton.setTitleColor(UIKitChassis.signal2, for: .normal)
        restoreButton.setTitleColor(UIKitChassis.signal3, for: .disabled)
        restoreButton.titleLabel?.font = ProPaywallFont.font(for: .body)
        restoreButton.titleLabel?.adjustsFontForContentSizeCategory = true
        restoreButton.contentHorizontalAlignment = .leading
        restoreButton.addTarget(
            self,
            action: #selector(restorePressed),
            for: .touchUpInside
        )
        restoreButton.accessibilityHint =
            "Checks this Apple ID for a Multiplex Pro purchase"

        let payment = makeLabel(
            "Payment is charged to your Apple ID. No subscription.",
            style: .caption1,
            color: UIKitChassis.signal3
        )

        let controls = UIStackView(arrangedSubviews: [
            unlockedRow,
            purchaseButton,
            commerceMessageLabel,
            restoreButton,
            payment,
        ])
        controls.axis = .vertical
        controls.alignment = .fill
        controls.spacing = Metrics.purchaseSpacing

        let container = UIView()
        container.addSubview(controls)
        controls.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controls.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            controls.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func makeUnlockedRow() -> UIStackView {
        let check = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        check.tintColor = UIKitChassis.signal
        check.setContentHuggingPriority(.required, for: .horizontal)
        check.setContentCompressionResistancePriority(.required, for: .horizontal)

        let title = makeLabel(
            "Multiplex Pro is unlocked",
            style: .headline,
            weight: .semibold,
            color: UIKitChassis.signal
        )
        let detail = makeLabel(
            "This purchase is available on your devices with the same Apple ID.",
            style: .footnote,
            color: UIKitChassis.signal2
        )
        let copy = UIStackView(arrangedSubviews: [title, detail])
        copy.axis = .vertical
        copy.alignment = .fill
        copy.spacing = 2

        let row = UIStackView(arrangedSubviews: [check, copy])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.isAccessibilityElement = true
        row.accessibilityLabel = "Multiplex Pro is unlocked. "
            + "This purchase is available on your devices with the same Apple ID."
        title.isAccessibilityElement = false
        detail.isAccessibilityElement = false
        check.isAccessibilityElement = false
        return row
    }

    private func makeLabel(
        _ text: String,
        style: UIFont.TextStyle,
        weight: UIFont.Weight = .regular,
        color: UIColor
    ) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = ProPaywallFont.font(for: style, weight: weight)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    /// Observation's callback is one-shot. Re-registering after applying the
    /// latest snapshot keeps every async StoreKit transition reflected while
    /// avoiding a framework-specific state wrapper around the service.
    private func observeEntitlements() {
        let state = withObservationTracking {
            ViewState(
                isPro: entitlements.isPro,
                productDisplayPrice: entitlements.productDisplayPrice,
                productIsLoading: entitlements.productIsLoading,
                productLoadError: entitlements.productLoadError,
                commerceState: entitlements.commerceState,
                purchaseIsUnavailable: entitlements.purchaseIsUnavailable,
                restoreIsUnavailable: entitlements.restoreIsUnavailable,
                storeEnvironmentIsSandbox: entitlements.storeEnvironmentIsSandbox
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeEntitlements()
            }
        }
        render(state)
    }

    private func render(_ state: ViewState) {
        unlockedRow.isHidden = !state.isPro
        purchaseButton.isHidden = state.isPro

        let purchaseLabel = state.productDisplayPrice.map {
            "Unlock Multiplex Pro · \($0)"
        } ?? "Unlock Multiplex Pro"
        purchaseButton.setPurchaseTitle(purchaseLabel)
        purchaseButton.setPurchasing(state.commerceState == .purchasing)
        purchaseButton.isEnabled = !state.purchaseIsUnavailable

        restoreButton.setTitle(
            state.commerceState == .restoring
                ? "Restoring Purchases…"
                : "Restore Purchases",
            for: .normal
        )
        restoreButton.isEnabled = !state.restoreIsUnavailable

        let message = commerceMessage(for: state)
        commerceMessageLabel.text = message
        commerceMessageLabel.textColor = state.commerceState.isFailure
            ? TallyPalette.caution
            : UIKitChassis.signal2
        commerceMessageLabel.isHidden = message == nil
    }

    private func commerceMessage(for state: ViewState) -> String? {
        switch state.commerceState {
        case .idle:
            if state.isPro {
                return nil
            } else if state.productIsLoading {
                return "Loading the App Store price…"
            } else {
                return state.productLoadError
            }
        case .purchasing:
            return "Waiting for the App Store…"
        case .pending:
            return "Purchase pending approval. Pro unlocks automatically if approved. "
                + "If it was declined, tap Restore Purchases to check again."
        case .purchased:
            return "Purchase complete."
        case .restoring:
            return "Checking your App Store purchases…"
        case .restored:
            if state.isPro {
                return "Multiplex Pro was restored."
            }
            // Restore succeeded and genuinely found nothing. On TestFlight
            // that is the expected answer for a production purchase — the
            // test store and the App Store never share transactions — so
            // say why instead of letting the empty result read as a bug.
            if state.storeEnvironmentIsSandbox {
                return "No Multiplex Pro purchase was found for this Apple ID. "
                    + "TestFlight builds use Apple's test store, so a purchase "
                    + "made in the App Store version doesn't appear here. Pro "
                    + "can be unlocked again inside TestFlight free of charge."
            }
            return "No Multiplex Pro purchase was found for this Apple ID."
        case .failed(let message):
            return message
        }
    }

    @objc private func donePressed() {
        if let onDone {
            onDone()
        } else {
            navigationController?.dismiss(animated: true)
        }
    }

    @objc private func purchasePressed() {
        // Resolve at press time: the controller is now guaranteed to have
        // joined the exact scene StoreKit must use for confirmation.
        let presenter = ProPurchasePresenter(presenting: self)
        Task { @MainActor [weak entitlementStore = self.entitlements] in
            _ = await entitlementStore?.purchasePro(using: presenter)
        }
    }

    @objc private func restorePressed() {
        Task { @MainActor [weak entitlementStore = self.entitlements] in
            _ = await entitlementStore?.restorePurchases()
        }
    }
}

private extension EntitlementStore.CommerceState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Semantic UIKit fonts matching the SwiftUI text styles used by the original
/// paywall. Fixed chassis labels continue through `UIKitChassisLabel`.
private enum ProPaywallFont {
    static func font(
        for style: UIFont.TextStyle,
        weight: UIFont.Weight = .regular
    ) -> UIFont {
        // The base descriptor is pinned to the default category: the metrics
        // wrapper applies the live Dynamic Type scale, so a live-category
        // descriptor here would scale twice.
        let pointSize = UIFontDescriptor.preferredFontDescriptor(
            withTextStyle: style,
            compatibleWith: UITraitCollection(
                preferredContentSizeCategory: .large
            )
        ).pointSize
        return UIFontMetrics(forTextStyle: style).scaledFont(
            for: .systemFont(ofSize: pointSize, weight: weight)
        )
    }
}

/// Native counterpart of the former custom SwiftUI purchase button: one-point
/// square TALLY border, bezel ground, optional compact progress indicator,
/// localized price copy, and fixed monospace ONE-TIME channel label.
@MainActor
final class ProPaywallPurchaseButton: UIButton {
    private let contentStack = UIStackView()
    private let progress = UIActivityIndicatorView(style: .medium)
    private let purchaseTitleLabel = UILabel()
    private let oneTimeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIKitChassis.bezel
        layer.borderWidth = 1
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))

        progress.color = UIKitChassis.signal2
        progress.hidesWhenStopped = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            progress.widthAnchor.constraint(equalToConstant: 16),
            progress.heightAnchor.constraint(equalToConstant: 16),
        ])

        purchaseTitleLabel.font = ProPaywallFont.font(for: .body, weight: .semibold)
        purchaseTitleLabel.adjustsFontForContentSizeCategory = true
        purchaseTitleLabel.textColor = UIKitChassis.signal
        purchaseTitleLabel.numberOfLines = 0
        purchaseTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        oneTimeLabel.font = UIKitChassis.monoFont(9, weight: .semibold)
        oneTimeLabel.textColor = UIKitChassis.signal2
        oneTimeLabel.attributedText = NSAttributedString(
            string: "ONE-TIME",
            attributes: [.kern: CGFloat(1)]
        )
        oneTimeLabel.setContentHuggingPriority(.required, for: .horizontal)
        oneTimeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 10
        contentStack.isUserInteractionEnabled = false
        contentStack.addArrangedSubview(progress)
        contentStack.addArrangedSubview(purchaseTitleLabel)
        contentStack.addArrangedSubview(spacer)
        contentStack.addArrangedSubview(oneTimeLabel)
        addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
        refreshBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var isEnabled: Bool {
        didSet {
            if isEnabled {
                accessibilityTraits.remove(.notEnabled)
            } else {
                accessibilityTraits.insert(.notEnabled)
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshBorder()
    }

    func setPurchaseTitle(_ title: String) {
        purchaseTitleLabel.text = title
        accessibilityLabel = title
    }

    func setPurchasing(_ purchasing: Bool) {
        if purchasing {
            progress.startAnimating()
        } else {
            progress.stopAnimating()
        }
    }

    private func refreshBorder() {
        layer.borderColor = UIKitChassis.signal2
            .resolvedColor(with: traitCollection)
            .cgColor
    }
}
