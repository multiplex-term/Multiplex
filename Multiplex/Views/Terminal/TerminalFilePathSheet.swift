import UIKit

// MARK: - Native file-path confirmation

/// UIKit confirmation for a filesystem path activated in terminal output.
/// It mirrors the link confirmation's trust boundary: the remote path stays
/// visible and editable, nothing executes, and VIEW only exists while the
/// edited spelling resolves to a path Multiplex can read.
@MainActor
final class TerminalFilePathSheetViewController: UIViewController {
    enum Metrics {
        static let contentMaximumWidth: CGFloat = 560
        static let outerInset: CGFloat = 18
        static let rowSpacing: CGFloat = 12
        static let actionSpacing: CGFloat = 10
    }

    private(set) var sourceTarget: TerminalPathTarget
    private(set) var hostName: String
    var onView: (TerminalPathTarget) -> Void
    var onCopy: (String) -> Void
    var onDismiss: (() -> Void)?

    private(set) var scrollView = UIScrollView()
    private(set) var rowStack = UIStackView()
    private let hostNameLabel = UILabel()
    private let lineStack = UIStackView()
    private let lineValueLabel = UILabel()
    private(set) var actionStack = UIStackView()
    private(set) var editor: UIKitTerminalEditableValueBox
    private(set) var sectionView: UIKitTallyFormSectionView!
    private var viewChip: UIKitChassisChip!
    private var copyChip: UIKitChassisChip!

    var editedText: String { editor.text }
    var editedTarget: TerminalPathTarget? { TerminalPathTarget.resolve(editor.text) }

    init(
        target: TerminalPathTarget,
        hostName: String,
        onView: @escaping (TerminalPathTarget) -> Void,
        onCopy: @escaping (String) -> Void
    ) {
        sourceTarget = target
        self.hostName = hostName
        self.onView = onView
        self.onCopy = onCopy
        editor = UIKitTerminalEditableValueBox(
            label: "PATH",
            text: Self.editorText(for: target)
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "View file"
        view.backgroundColor = UIKitChassis.chassis
        configureNavigation()
        configureContent()
        editor.onTextChange = { [weak self] _ in self?.refreshState() }
        refreshState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let navigationBar = navigationController?.navigationBar {
            UIKitChassis.configureSheetNavigationBar(navigationBar)
        }
    }

    func updateSource(target: TerminalPathTarget, hostName: String) {
        guard target != sourceTarget || hostName != self.hostName else { return }
        let targetChanged = target != sourceTarget
        sourceTarget = target
        self.hostName = hostName
        if targetChanged {
            editor.setText(Self.editorText(for: target), notify: false)
        }
        if isViewLoaded { refreshState() }
    }

    func setEditedText(_ text: String) {
        editor.setText(text)
    }

    func refreshActions(
        onView: @escaping (TerminalPathTarget) -> Void,
        onCopy: @escaping (String) -> Void
    ) {
        self.onView = onView
        self.onCopy = onCopy
    }

    static func editorText(for target: TerminalPathTarget) -> String {
        guard let line = target.line else { return target.path }
        return "\(target.path):\(line)"
    }

    private func configureNavigation() {
        navigationItem.largeTitleDisplayMode = .never
        #if os(visionOS)
        navigationItem.titleView = UIKitChassisLabel("View file", size: 12)
        #endif
        let cancel = UIBarButtonItem(
            title: "Cancel",
            style: .plain,
            target: self,
            action: #selector(cancelPressed)
        )
        cancel.tintColor = UIKitChassis.signal
        navigationItem.leftBarButtonItem = cancel
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

        let hostStack = UIStackView(arrangedSubviews: [
            UIKitChassisLabel("HOST", size: 9, color: UIKitChassis.signal3),
            hostNameLabel,
        ])
        hostStack.axis = .vertical
        hostStack.alignment = .fill
        hostStack.spacing = 4
        hostNameLabel.font = UIKitChassis.monoFont(13, weight: .semibold)
        hostNameLabel.textColor = UIKitChassis.signal
        hostNameLabel.numberOfLines = 0
        hostNameLabel.accessibilityIdentifier = "terminal.path.hostValue"

        let lineTitle = UIKitChassisLabel("LINE", size: 9, color: UIKitChassis.signal3)
        lineValueLabel.font = UIKitChassis.monoFont(11)
        lineValueLabel.textColor = UIKitChassis.signal2
        lineValueLabel.accessibilityIdentifier = "terminal.path.lineValue"
        lineStack.axis = .horizontal
        lineStack.alignment = .center
        lineStack.spacing = 8
        lineStack.addArrangedSubview(lineTitle)
        lineStack.addArrangedSubview(lineValueLabel)
        lineStack.addArrangedSubview(UIView())

        actionStack.axis = .horizontal
        actionStack.alignment = .center
        actionStack.spacing = Metrics.actionSpacing
        viewChip = UIKitChassisChip(
            "▤ VIEW",
            prominent: true,
            accessibilityLabel: "View"
        ) { [weak self] in self?.viewPressed() }
        copyChip = UIKitChassisChip(
            "COPY",
            systemImage: "doc.on.doc",
            accessibilityLabel: "Copy"
        ) { [weak self] in self?.copyPressed() }
        for chip in [viewChip, copyChip] {
            chip?.setContentHuggingPriority(.required, for: .horizontal)
            actionStack.addArrangedSubview(chip!)
        }
        // SwiftUI's HStack leaves surplus width after its ideal-size
        // children. UIStackView instead must assign that width to an
        // arranged subview; without this flexible tail it breaks the
        // section's fill constraint because both chips require hugging.
        // The result was a card only as wide as VIEW + COPY on iPhone.
        let actionSpacer = UIView()
        actionSpacer.isAccessibilityElement = false
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actionSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actionStack.addArrangedSubview(actionSpacer)

        rowStack.axis = .vertical
        rowStack.alignment = .fill
        rowStack.spacing = Metrics.rowSpacing
        rowStack.addArrangedSubview(hostStack)
        rowStack.addArrangedSubview(editor)
        rowStack.addArrangedSubview(lineStack)
        rowStack.addArrangedSubview(actionStack)

        sectionView = UIKitTallyFormSectionView(
            title: "",
            detail: nil,
            contentView: rowStack
        )
        scrollView.addSubview(sectionView)
        sectionView.translatesAutoresizingMaskIntoConstraints = false

        let fillWidth = sectionView.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -(Metrics.outerInset * 2)
        )
        // The required 560-point cap wins on wide sheets; everywhere below
        // that cap the legacy 18-point phone inset is exact.
        fillWidth.priority = UILayoutPriority(rawValue: 999)
        NSLayoutConstraint.activate([
            sectionView.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor,
                constant: Metrics.outerInset
            ),
            sectionView.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor,
                constant: -Metrics.outerInset
            ),
            sectionView.centerXAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.centerXAnchor
            ),
            sectionView.leadingAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: Metrics.outerInset
            ),
            sectionView.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -Metrics.outerInset
            ),
            sectionView.widthAnchor.constraint(
                lessThanOrEqualToConstant: Metrics.contentMaximumWidth
            ),
            fillWidth,
        ])
    }

    private func refreshState() {
        guard isViewLoaded else { return }
        let target = editedTarget
        hostNameLabel.text = hostName
        hostNameLabel.accessibilityLabel = hostName
        editor.setNote(target == nil ? "NOT A PATH MULTIPLEX CAN READ" : nil)
        lineValueLabel.text = target?.line.map(String.init)
        lineValueLabel.accessibilityLabel = target?.line.map(String.init)
        lineStack.isHidden = target?.line == nil
        viewChip.isHidden = target == nil
        sectionView.setTitle(sectionTitle(for: target))
        sectionView.setDetail(detail(for: target))
    }

    private func sectionTitle(for target: TerminalPathTarget?) -> String {
        switch target?.base {
        case .absolute: "A path on \(hostName)"
        case .home: "In \(hostName)'s home"
        case .workingDirectory: "Relative to the pane's directory"
        case nil: "Not a usable path"
        }
    }

    private func detail(for target: TerminalPathTarget?) -> String {
        guard let target else {
            return "The field holds nothing the viewer can resolve — a path "
                + "needs a directory in it, and no spaces. Edit it, or copy "
                + "the text if it's still useful."
        }
        var text = "VIEW opens it read-only in the file viewer, beside this "
            + "session — nothing runs, nothing is written. The path is "
            + "editable when detection caught the wrong text."
        if target.base == .workingDirectory {
            text += " It resolves against the pane's current directory."
        }
        return text
    }

    @objc private func cancelPressed() {
        dismissSheet()
    }

    private func viewPressed() {
        guard let target = editedTarget else { return }
        onView(target)
        dismissSheet()
    }

    private func copyPressed() {
        onCopy(editor.text)
        dismissSheet()
    }

    private func dismissSheet() {
        if let onDismiss {
            onDismiss()
        } else {
            navigationController?.dismiss(animated: true)
        }
    }
}
