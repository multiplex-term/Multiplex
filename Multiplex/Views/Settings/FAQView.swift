import UIKit

// MARK: - Native UIKit screen

/// Frequently asked questions, opened from the deck's FAQ chip. The screen and
/// all of its content are UIKit.
@MainActor
final class FAQViewController: UIViewController, AppAppearanceFollowing {
    var onDone: (() -> Void)?

    var appAppearance = AppAppearance.system {
        didSet { applyAppAppearance() }
    }
    let appAppearanceFollower = AppAppearanceFollower()

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "FAQ"
        view.backgroundColor = GlassPrototype.sheetGround

        navigationItem.largeTitleDisplayMode = .never
        #if os(visionOS)
        // SwiftUI's sheet title needed the same explicit TALLY ink on visionOS;
        // the native controller keeps that principal-title treatment.
        navigationItem.titleView = UIKitChassisLabel("FAQ", size: 12)
        #endif
        let done = UIBarButtonItem(
            title: String(localized: "Done"),
            style: .plain,
            target: self,
            action: #selector(donePressed)
        )
        done.tintColor = UIKitChassis.signal
        done.accessibilityLabel = String(localized: "Done")
        navigationItem.rightBarButtonItem = done

        configureContent()
        applyAppAppearance()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyAppAppearance()
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
            // The SwiftUI sheet never scrolled horizontally; lock the content
            // guide to the visible frame before applying the 680-point cap.
            scrollView.contentLayoutGuide.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor
            ),
        ])

        contentStack.axis = .vertical
        contentStack.spacing = 18
        for entry in FAQEntry.all {
            contentStack.addArrangedSubview(makeSection(for: entry))
        }
        scrollView.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let fillVisibleWidth = contentStack.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -36
        )
        fillVisibleWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: 18
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -18
            ),
            contentStack.centerXAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.centerXAnchor
            ),
            contentStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: 18
            ),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -18
            ),
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 680),
            fillVisibleWidth,
        ])
    }

    private func makeSection(for entry: FAQEntry) -> UIView {
        let answer = UILabel()
        answer.font = UIKitChassis.uiFont(11)
        answer.textColor = UIKitChassis.signal
        answer.text = entry.answer
        answer.numberOfLines = 0

        let rowStack = UIStackView(arrangedSubviews: [answer])
        rowStack.axis = .vertical
        rowStack.spacing = 12
        if entry.offersMultiplexerInstall {
            rowStack.addArrangedSubview(FAQMultiplexerInstallView())
        }
        for command in entry.commands {
            rowStack.addArrangedSubview(UIKitCopyableCommandField(
                label: command.label,
                command: command.command
            ))
        }

        return UIKitTallyFormSectionView(
            title: entry.question,
            detail: entry.postscript,
            contentView: rowStack
        )
    }

    @objc private func donePressed() {
        if let onDone {
            onDone()
        } else {
            navigationController?.dismiss(animated: true)
        }
    }
}

// MARK: - Multiplexer install

/// The install commands for both session backends behind a tmux | herdr
/// choice bar. The backend is a per-host setting, so the FAQ cannot know
/// which one the reader needs — showing one road at a time beats stacking
/// six command fields, and the choice bar is the same control Add Host and
/// Host Settings use to pick the backend in the first place.
@MainActor
private final class FAQMultiplexerInstallView: UIView {
    private let commandStack = UIStackView()
    private let pathNote = UILabel()

    init(backend: Host.SessionBackend = .tmux) {
        super.init(frame: .zero)

        let bar = AddHostChoiceBar<Host.SessionBackend>(
            // The button face uppercases; pass the natural spelling so
            // VoiceOver reads "tmux", not the letters T-M-U-X.
            choices: Host.SessionBackend.allCases.map { ($0.rawValue, $0) },
            selection: backend
        ) { [weak self] backend in
            self?.show(backend)
        }
        bar.accessibilityIdentifier = "faq.backendBar"

        commandStack.axis = .vertical
        commandStack.spacing = 12

        pathNote.font = UIKitChassis.uiFont(10)
        pathNote.textColor = UIKitChassis.signal2
        pathNote.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [bar, commandStack, pathNote])
        stack.axis = .vertical
        stack.spacing = 12
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        show(backend)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    private func show(_ backend: Host.SessionBackend) {
        for view in commandStack.arrangedSubviews {
            commandStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for command in HostGuide.multiplexerInstall(for: backend) {
            commandStack.addArrangedSubview(UIKitCopyableCommandField(
                label: command.label,
                command: command.command
            ))
        }
        pathNote.text = HostGuide.probePathDetail(for: backend)
    }
}

// MARK: - Static content

/// Questions render as compressed-caps section titles, so keep them short
/// enough for one line at phone-sheet width. Commands shared with a deck tip
/// surface live in `HostGuide` so they cannot drift.
private struct FAQEntry {
    let id: String
    let question: String
    let answer: String
    var commands: [HostGuide.Command] = []
    /// Renders the tmux | herdr install area instead of a flat command list:
    /// the answer covers both backends, so the reader picks their host's.
    var offersMultiplexerInstall = false
    var postscript: String?

    static let all: [FAQEntry] = [
        FAQEntry(
            id: "host-needs-multiplexer",
            question: String(localized: "A host shows no tmux or herdr"),
            answer: String(localized: """
                The deck is built around a session multiplexer on each host — sessions, \
                live tiles, and attach all come from it. Each host runs one, tmux or \
                herdr, chosen in its settings under Sessions run on. A host without that \
                multiplexer still works as a plain shell (the SHELL chip on its rail), it \
                just has no session tiles. To get the full deck, install the one the host \
                is set to:
                """),
            offersMultiplexerInstall: true,
            postscript: String(localized: """
                The deck re-probes every few seconds and lights the tile as soon as the \
                multiplexer lands — no restart, and nothing to configure on the host.
                """)
        ),
        FAQEntry(
            id: "claude-code-tmux-keychain",
            question: String(localized: "Claude Code shows signed out in tmux"),
            answer: String(localized: """
                On a Mac host, Claude Code keeps its credentials in the login keychain, \
                and an SSH or tmux session never unlocks it — no GUI login happened — so \
                Claude Code starts as if you were signed out even though your login is \
                intact. Unlock the keychain once inside the tmux session, then restart \
                Claude Code:
                """),
            commands: [HostGuide.keychainUnlock],
            postscript: String(localized: """
                The command prompts for that Mac account's login password. The unlock \
                holds until macOS locks the keychain again — after a restart, or per the \
                keychain's own lock settings. When the deck detects this state it also \
                points here: the host's rail reads KEYCHAIN LOCKED.
                """)
        )
    ]
}
