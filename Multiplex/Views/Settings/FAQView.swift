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
        view.backgroundColor = UIKitChassis.chassis

        navigationItem.largeTitleDisplayMode = .never
        #if os(visionOS)
        // SwiftUI's sheet title needed the same explicit TALLY ink on visionOS;
        // the native controller keeps that principal-title treatment.
        navigationItem.titleView = UIKitChassisLabel("FAQ", size: 12)
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

// MARK: - Static content

/// Questions render as compressed-caps section titles, so keep them short
/// enough for one line at phone-sheet width. Commands shared with a deck tip
/// surface live in `HostGuide` so they cannot drift.
private struct FAQEntry {
    let id: String
    let question: String
    let answer: String
    var commands: [HostGuide.Command] = []
    var postscript: String?

    static let all: [FAQEntry] = [
        FAQEntry(
            id: "host-needs-tmux",
            question: "A host shows no tmux on the deck",
            answer: "The deck is built around a tmux server on each host — "
                + "sessions, live tiles, and attach all come from it. A host "
                + "without tmux still works as a plain shell (the SHELL chip "
                + "on its rail), it just has no session tiles. To get the "
                + "full deck, install tmux on the host:",
            commands: HostGuide.tmuxInstall,
            postscript: "The deck re-probes every few seconds and finds tmux "
                + "as soon as it lands — Homebrew and /usr/local installs "
                + "are already on the probe's PATH."
        ),
        FAQEntry(
            id: "claude-code-tmux-keychain",
            question: "Claude Code shows signed out in tmux",
            answer: "On a Mac host, Claude Code keeps its credentials in the "
                + "login keychain, and an SSH or tmux session never unlocks it — "
                + "no GUI login happened — so Claude Code starts as if you were "
                + "signed out even though your login is intact. Unlock the "
                + "keychain once inside the tmux session, then restart Claude "
                + "Code:",
            commands: [HostGuide.keychainUnlock],
            postscript: "The command prompts for that Mac account's login "
                + "password. The unlock holds until macOS locks the keychain "
                + "again — after a restart, or per the keychain's own lock "
                + "settings. When the deck detects this state it also points "
                + "here: the host's rail reads KEYCHAIN LOCKED."
        )
    ]
}
