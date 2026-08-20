import Observation
import UIKit

/// Native lock-screen owner, reusable directly by the UIKit scene roots.
///
/// Every scene may mount one controller, but `AppLockStore.autoUnlock()` is
/// the process-wide one-attempt authority. Consequently simultaneous scene
/// activation notifications may all arrive here while only one of them can
/// reach LocalAuthentication for a given lock.
@MainActor
final class AppLockViewController: UIViewController {
    private struct LockState {
        var isLocked: Bool
        var isAuthenticating: Bool
    }

    let lock: AppLockStore
    private let lockView = AppLockView()
    private var observesLock = true

    init(lock: AppLockStore) {
        self.lock = lock
        super.init(nibName: nil, bundle: nil)
        // Close the responder gate as soon as the native owner exists. An
        // overlay alone cannot stop a hardware keyboard from typing into a
        // first responder mounted behind it.
        TerminalFocusArbiter.inputSuppressed = lock.isLocked
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        view = lockView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        lockView.unlock = { [weak lock = lock] in
            Task { @MainActor in
                await lock?.unlock()
            }
        }
        lockView.didJoinWindow = { [weak self] in
            self?.autoUnlockIfSceneIsActive()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidActivate(_:)),
            name: UIScene.didActivateNotification,
            object: nil
        )
        observeLockState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.accessibilityViewIsModal = true
        UIAccessibility.post(
            notification: .screenChanged,
            argument: lockView.summaryAccessibilityElement
        )
        autoUnlockIfSceneIsActive()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Called by the native scene root before it releases the controller. The
    /// store remains the authority: destroying one locked scene must not
    /// unsuppress input in another still-veiled scene.
    func prepareForRemoval() {
        observesLock = false
        TerminalFocusArbiter.inputSuppressed = lock.isLocked
    }

    private func observeLockState() {
        guard observesLock else { return }
        let state = withObservationTracking {
            LockState(
                isLocked: lock.isLocked,
                isAuthenticating: lock.isAuthenticating
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeLockState()
            }
        }

        TerminalFocusArbiter.inputSuppressed = state.isLocked
        lockView.setAuthenticating(state.isAuthenticating)
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let activatedScene = notification.object as? UIWindowScene,
              activatedScene === viewIfLoaded?.window?.windowScene
        else { return }
        autoUnlockIfSceneIsActive()
    }

    private func autoUnlockIfSceneIsActive() {
        guard lock.isLocked,
              viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
        else { return }
        Task { @MainActor [weak lock = lock] in
            await lock?.autoUnlock()
        }
    }
}

/// UIKit rendering of the TALLY lock composition. Its geometry intentionally
/// mirrors the former SwiftUI stack: 20 points between the lamp, title block,
/// and action; 6 points between the title and authentication method.
@MainActor
final class AppLockView: UIView {
    enum Metrics {
        static let sectionSpacing: CGFloat = 20
        static let titleSpacing: CGFloat = 6
        static let lampSpacing: CGFloat = 5
        static let chipHorizontalPadding: CGFloat = 9
        static let chipVerticalPadding: CGFloat = 5
    }

    var unlock: @MainActor () -> Void = {}
    var didJoinWindow: @MainActor () -> Void = {}

    var summaryAccessibilityElement: UILabel { titleLabel }

    private let lampDot = UIView()
    private let lampCaption = UILabel()
    private let titleLabel = UILabel()
    private let methodLabel = UILabel()
    private let unlockButton = UIButton(type: .custom)

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { didJoinWindow() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle
        else { return }
        applyColors()
    }

    func setAuthenticating(_ authenticating: Bool) {
        unlockButton.isEnabled = !authenticating
    }

    private func build() {
        backgroundColor = TallyPalette.chassis
        accessibilityViewIsModal = true
        shouldGroupAccessibilityChildren = true

        let scale = Theme.typeScale

        lampDot.translatesAutoresizingMaskIntoConstraints = false
        lampDot.layer.cornerRadius = 3.5 * scale
        lampDot.layer.shadowOpacity = 0.7
        lampDot.layer.shadowRadius = 4
        lampDot.layer.shadowOffset = .zero
        NSLayoutConstraint.activate([
            lampDot.widthAnchor.constraint(equalToConstant: 7 * scale),
            lampDot.heightAnchor.constraint(equalToConstant: 7 * scale),
        ])

        configure(
            lampCaption,
            text: "LOCKED",
            font: .monospacedSystemFont(ofSize: 9 * scale, weight: .bold),
            kerning: 1.2,
            color: TallyPalette.caution
        )
        lampCaption.setContentCompressionResistancePriority(.required, for: .horizontal)
        lampCaption.setContentHuggingPriority(.required, for: .horizontal)

        let lamp = UIStackView(arrangedSubviews: [lampDot, lampCaption])
        lamp.axis = .horizontal
        lamp.alignment = .center
        lamp.spacing = Metrics.lampSpacing
        lamp.isAccessibilityElement = true
        lamp.accessibilityLabel = String(localized: "locked")

        configure(
            titleLabel,
            text: "MULTIPLEX",
            font: .systemFont(ofSize: 15 * scale, weight: .bold, width: .compressed),
            kerning: 15 * scale * 0.09,
            color: TallyPalette.signal
        )
        titleLabel.accessibilityLabel = String(
            localized: "Multiplex is locked. Unlock with \(AppLockStore.methodName)."
        )

        configure(
            methodLabel,
            text: "\(AppLockStore.methodName.uppercased()) REQUIRED",
            font: .monospacedSystemFont(ofSize: 9 * scale, weight: .medium),
            kerning: 1.2,
            color: TallyPalette.signal3
        )
        methodLabel.isAccessibilityElement = false

        let titleBlock = UIStackView(arrangedSubviews: [titleLabel, methodLabel])
        titleBlock.axis = .vertical
        titleBlock.alignment = .center
        titleBlock.spacing = Metrics.titleSpacing

        configureUnlockButton(scale: scale)

        let stack = UIStackView(arrangedSubviews: [lamp, titleBlock, unlockButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Metrics.sectionSpacing
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func configureUnlockButton(scale: CGFloat) {
        let title = NSAttributedString(
            string: "UNLOCK",
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 9 * scale, weight: .semibold),
                .kern: 1.1,
                .foregroundColor: TallyPalette.signal,
            ]
        )
        unlockButton.setAttributedTitle(title, for: .normal)
        unlockButton.setAttributedTitle(title, for: .disabled)
        unlockButton.contentEdgeInsets = UIEdgeInsets(
            top: Metrics.chipVerticalPadding,
            left: Metrics.chipHorizontalPadding,
            bottom: Metrics.chipVerticalPadding,
            right: Metrics.chipHorizontalPadding
        )
        unlockButton.layer.borderWidth = 1
        // The gaze/pointer highlight resolves where the effect is attached, so
        // it belongs on the control itself. Square it to the chip's own border
        // box: the default visionOS platter is heavily rounded and fights the
        // chassis geometry (the SwiftUI veil applied `chassisHover(2)` here).
        unlockButton.hoverStyle = UIHoverStyle(
            effect: .highlight,
            shape: .rect(cornerRadius: 2)
        )
        unlockButton.accessibilityLabel = String(localized: "Unlock")
        unlockButton.accessibilityHint = String(localized: "Unlocks Multiplex with \(AppLockStore.methodName)")
        unlockButton.addTarget(self, action: #selector(unlockPressed), for: .touchUpInside)
    }

    private func configure(
        _ label: UILabel,
        text: String,
        font: UIFont,
        kerning: CGFloat,
        color: UIColor
    ) {
        label.numberOfLines = 1
        label.textAlignment = .center
        label.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .kern: kerning,
                .foregroundColor: color,
            ]
        )
    }

    private func applyColors() {
        let caution = TallyPalette.caution
        backgroundColor = TallyPalette.chassis
        lampDot.backgroundColor = caution
        lampDot.layer.shadowColor = caution
            .resolvedColor(with: traitCollection).cgColor
        unlockButton.backgroundColor = TallyPalette.chassis
        unlockButton.layer.borderColor = TallyPalette.signal2
            .resolvedColor(with: traitCollection).cgColor
    }

    @objc private func unlockPressed() {
        unlock()
    }
}
