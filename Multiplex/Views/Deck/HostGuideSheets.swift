import UIKit

/// Selectable, self-sizing command text. A label would match the pixels but
/// would lose the field's text-selection behavior.
@MainActor
private final class UIKitHostGuideCommandTextView: UITextView {
    private var measuredWidth: CGFloat = 0

    init(command: String) {
        super.init(frame: .zero, textContainer: nil)
        text = command
        font = UIKitChassis.monoFont(10)
        textColor = UIKitChassis.signal
        backgroundColor = .clear
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        dataDetectorTypes = []
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var intrinsicContentSize: CGSize {
        guard bounds.width > 0 else {
            return CGSize(width: UIView.noIntrinsicMetric, height: font?.lineHeight ?? 0)
        }
        let fitted = sizeThatFits(CGSize(
            width: bounds.width,
            height: CGFloat.greatestFiniteMagnitude
        ))
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(fitted.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard abs(bounds.width - measuredWidth) > 0.5 else { return }
        measuredWidth = bounds.width
        invalidateIntrinsicContentSize()
    }
}

/// Shared by every native guide or FAQ surface: optional source label,
/// selectable monospace command, and the square COPY chip. Repeated presses
/// restart the same 1.6-second COPIED acknowledgement window.
@MainActor
final class UIKitCopyableCommandField: UIKitTallyBorderedView {
    private let command: String
    private let writeClipboard: (String) -> Void
    private var copyChip: UIKitChassisChip!
    private var resetTask: Task<Void, Never>?

    init(
        label: String = "",
        command: String,
        writeClipboard: @escaping (String) -> Void = {
            UIPasteboard.general.string = $0
        }
    ) {
        self.command = command
        self.writeClipboard = writeClipboard
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.screen

        let fieldStack = UIStackView()
        fieldStack.axis = .vertical
        fieldStack.spacing = 6
        addSubview(fieldStack)
        fieldStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            fieldStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            fieldStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            fieldStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            fieldStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        if !label.isEmpty {
            fieldStack.addArrangedSubview(UIKitChassisLabel(
                label,
                size: 9,
                color: UIKitChassis.signal3
            ))
        }

        let commandText = UIKitHostGuideCommandTextView(command: command)
        copyChip = UIKitChassisChip(
            "COPY",
            systemImage: "doc.on.doc",
            accessibilityLabel: "Copy command",
            action: { [weak self] in self?.copyCommand() }
        )
        copyChip.setContentHuggingPriority(.required, for: .horizontal)
        copyChip.setContentCompressionResistancePriority(.required, for: .horizontal)

        let commandRow = UIStackView(arrangedSubviews: [commandText, copyChip])
        commandRow.axis = .horizontal
        commandRow.alignment = .top
        commandRow.spacing = 10
        fieldStack.addArrangedSubview(commandRow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        resetTask?.cancel()
    }

    private func copyCommand() {
        writeClipboard(command)
        copyChip.setContent(caption: "COPIED", systemImage: "checkmark")
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.copyChip.setContent(caption: "COPY", systemImage: "doc.on.doc")
        }
    }
}

// MARK: - Native guide controllers

/// Shared native shell for the deck's guide sheets. The content cap, outside
/// inset, section spacing, opaque navigation bar, Done placement, and live
/// appearance switching are the exact UIKit counterparts of the former
/// `NavigationStack` + `ScrollView` composition.
@MainActor
class UIKitHostGuideSheetViewController: UIViewController, AppAppearanceFollowing {
    static let contentMaximumWidth: CGFloat = 560
    static let outerInset: CGFloat = 18
    static let sectionSpacing: CGFloat = 18

    var onDone: (() -> Void)?
    var appAppearance = AppAppearance.system {
        didSet { applyAppAppearance() }
    }
    let appAppearanceFollower = AppAppearanceFollower()

    private let sheetTitle: String
    private let scrollView = UIScrollView()
    private(set) var contentStack = UIStackView()

    init(title: String) {
        sheetTitle = title
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = sheetTitle
        view.backgroundColor = UIKitChassis.chassis

        navigationItem.largeTitleDisplayMode = .never
        #if os(visionOS)
        navigationItem.titleView = UIKitChassisLabel(sheetTitle, size: 12)
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

        configureContent()
        applyAppAppearance()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyAppAppearance()
    }

    func addSection(_ section: UIView) {
        contentStack.addArrangedSubview(section)
    }

    func makeBodyLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = UIKitChassis.uiFont(11)
        label.textColor = UIKitChassis.signal
        label.text = text
        label.numberOfLines = 0
        return label
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
        contentStack.spacing = Self.sectionSpacing
        scrollView.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let fillVisibleWidth = contentStack.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -(Self.outerInset * 2)
        )
        fillVisibleWidth.priority = .defaultHigh
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
            contentStack.widthAnchor.constraint(
                lessThanOrEqualToConstant: Self.contentMaximumWidth
            ),
            fillVisibleWidth,
        ])
    }

    @objc private func donePressed() {
        onDone?()
    }
}

/// The NO TMUX / NO HERDR tile's INSTALL GUIDE dialog: why the wall needs
/// the host's chosen multiplexer, the install one-liners, and the reminder
/// that a plain shell already works.
@MainActor
final class TmuxInstallViewController: UIKitHostGuideSheetViewController {
    let host: Host

    private var multiplexer: String {
        host.sessionBackend.rawValue
    }

    init(host: Host) {
        self.host = host
        super.init(title: "Install \(host.sessionBackend.rawValue)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()

        let rowStack = UIStackView(arrangedSubviews: [makeBodyLabel(intro)])
        rowStack.axis = .vertical
        rowStack.spacing = 12
        for entry in HostGuide.multiplexerInstall(for: host.sessionBackend) {
            rowStack.addArrangedSubview(UIKitCopyableCommandField(
                label: entry.label,
                command: entry.command
            ))
        }

        addSection(UIKitTallyFormSectionView(
            title: "The deck runs on \(multiplexer)",
            detail: "The deck re-probes every few seconds — "
                + "session tiles light up as soon as \(multiplexer) is on "
                + "the host. Homebrew and /usr/local installs "
                + "are already on the probe's PATH.",
            contentView: rowStack
        ))
    }

    var intro: String {
        "Sessions, live tiles, and attach all come from a \(multiplexer) "
            + "server on each host, and \(host.name) doesn't have "
            + "\(multiplexer) yet. You can still use a plain shell — the "
            + "SHELL chip on the host's rail opens one. For the full deck, "
            + "install \(multiplexer) on the host:"
    }
}

/// The KEYCHAIN LOCKED tip sheet: Claude Code looks signed out on a Mac
/// host because SSH sessions never unlock the login keychain that holds its
/// credentials. Shown only after `KeychainLockCheck` confirmed the lock.
@MainActor
final class KeychainUnlockViewController: UIKitHostGuideSheetViewController {
    let host: Host
    let sessionNames: [String]

    init(host: Host, sessionNames: [String]) {
        self.host = host
        self.sessionNames = sessionNames
        super.init(title: "Keychain locked")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()

        let rowStack = UIStackView(arrangedSubviews: [makeBodyLabel(intro)])
        rowStack.axis = .vertical
        rowStack.spacing = 12
        if !sessionNames.isEmpty {
            let sessions = UILabel()
            sessions.font = UIKitChassis.monoFont(10)
            sessions.textColor = UIKitChassis.signal3
            sessions.text = "Detected in: " + sessionNames.joined(separator: " · ")
            sessions.numberOfLines = 0
            rowStack.addArrangedSubview(sessions)
        }
        rowStack.addArrangedSubview(UIKitCopyableCommandField(
            command: HostGuide.keychainUnlock.command
        ))

        addSection(UIKitTallyFormSectionView(
            title: "Claude Code shows signed out",
            detail: "The command prompts for that Mac account's "
                + "login password. The unlock holds until macOS "
                + "locks the keychain again — after a restart, "
                + "or per the keychain's own lock settings.",
            contentView: rowStack
        ))
    }

    var intro: String {
        "Claude Code on \(host.name) is waiting at its sign-in screen, but "
            + "the stored login is probably intact: on a Mac, Claude Code "
            + "keeps its credentials in the login keychain, and an SSH or "
            + "tmux session never unlocks it — no GUI login happened. "
            + "Unlock it once in any shell on \(host.name), then restart "
            + "Claude Code:"
    }
}
