import UIKit

// MARK: - Shared native target field

/// The confirmation sheets' editable target well. Terminal output is machine
/// text, so the editor deliberately disables every smart-text transformation
/// and expands from one through five lines before it scrolls.
@MainActor
final class UIKitTerminalEditableValueBox: UIKitTallyBorderedView, UITextViewDelegate {
    private static let contentInset: CGFloat = 10

    let textView = UITextView()
    var onTextChange: ((String) -> Void)?

    private let noteLabel = UIKitChassisLabel("", size: 9, color: TallyPalette.caution)
    private var textHeight: NSLayoutConstraint!

    var text: String { textView.text }

    init(label: String, text: String) {
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.screen

        let labelView = UIKitChassisLabel(label, size: 9, color: UIKitChassis.signal3)

        textView.text = text
        textView.font = UIKitChassis.monoFont(11)
        textView.textColor = UIKitChassis.signal
        textView.tintColor = UIKitChassis.signal
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.keyboardType = .URL
        textView.returnKeyType = .done
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.accessibilityLabel = label.capitalized

        noteLabel.isHidden = true

        let stack = UIStackView(arrangedSubviews: [labelView, textView, noteLabel])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 6
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false

        textHeight = textView.heightAnchor.constraint(equalToConstant: lineHeight)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Self.contentInset
            ),
            stack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Self.contentInset
            ),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.contentInset),
            stack.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -Self.contentInset
            ),
            textHeight,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateEditorHeight()
    }

    func setText(_ text: String, notify: Bool = true) {
        guard textView.text != text else { return }
        textView.text = text
        updateEditorHeight()
        if notify { onTextChange?(text) }
    }

    func setNote(_ note: String?) {
        noteLabel.setText(note ?? "")
        noteLabel.isHidden = note == nil
    }

    func textViewDidChange(_ textView: UITextView) {
        updateEditorHeight()
        onTextChange?(textView.text)
    }

    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        guard text != "\n" else {
            textView.resignFirstResponder()
            return false
        }
        return true
    }

    private var lineHeight: CGFloat {
        ceil(textView.font?.lineHeight ?? UIKitChassis.monoFont(11).lineHeight)
    }

    private func updateEditorHeight() {
        // `UIStackView` lays out its arranged subviews after this box's own
        // `layoutSubviews`. On the first presentation `textView.bounds.width`
        // is therefore still zero here, and no later pass is guaranteed. A
        // URL then stays at the seed one-line height: UIKit wraps at a hyphen
        // and everything after that break is present but clipped. Measure
        // from this box's resolved width instead — the stack's horizontal
        // insets are fixed, so this is the exact eventual editor width.
        let availableWidth = bounds.width - Self.contentInset * 2
        guard availableWidth > 0 else { return }
        let fitting = textView.sizeThatFits(
            CGSize(width: availableWidth, height: .greatestFiniteMagnitude)
        ).height
        let capped = min(max(ceil(fitting), lineHeight), lineHeight * 5)
        guard abs(textHeight.constant - capped) > 0.5 else { return }
        textHeight.constant = capped
        textView.isScrollEnabled = fitting > capped + 0.5
        invalidateIntrinsicContentSize()
    }
}

// MARK: - Native link confirmation

/// UIKit confirmation for a link activated in a terminal pane. The target is
/// remote-controlled content: this controller always exposes the resolved
/// address, names its actual host, and re-runs the allowlist after every edit
/// before enabling OPEN or VIEWPORT.
@MainActor
final class TerminalLinkSheetViewController: UIViewController {
    enum Metrics {
        static let contentMaximumWidth: CGFloat = 560
        static let outerInset: CGFloat = 18
        static let rowSpacing: CGFloat = 12
        static let actionSpacing: CGFloat = 10
    }

    private(set) var sourceLink: TerminalLink
    var viewportOffer: (TerminalLink) -> ViewportOffer?
    var onOpen: (TerminalLink) -> Void
    var onCopy: (String) -> Void
    var onOpenViewport: ((ViewportOffer) -> Void)?
    var onDismiss: (() -> Void)?

    private let scrollView = UIScrollView()
    private let rowStack = UIStackView()
    private let hostStack = UIStackView()
    private let hostNameLabel = UILabel()
    private let reachStack = UIStackView()
    private let reachLabel = UILabel()
    private let actionStack = UIStackView()
    private let actionSpacer = UIView()
    private let navigationTitleLabel = UIKitChassisLabel("Open link", size: 12)
    private let editor: UIKitTerminalEditableValueBox
    private var sectionView: UIKitTallyFormSectionView!
    private var viewportChip: UIKitChassisChip!
    private var openChip: UIKitChassisChip!
    private var copyChip: UIKitChassisChip!

    var editedText: String { editor.text }
    var editedLink: TerminalLink? { TerminalLink.resolve(editor.text) }
    var editedViewport: ViewportOffer? { editedLink.flatMap(viewportOffer) }

    init(
        link: TerminalLink,
        viewportOffer: @escaping (TerminalLink) -> ViewportOffer? = { _ in nil },
        onOpen: @escaping (TerminalLink) -> Void,
        onCopy: @escaping (String) -> Void,
        onOpenViewport: ((ViewportOffer) -> Void)? = nil
    ) {
        sourceLink = link
        self.viewportOffer = viewportOffer
        self.onOpen = onOpen
        self.onCopy = onCopy
        self.onOpenViewport = onOpenViewport
        editor = UIKitTerminalEditableValueBox(label: "TARGET", text: link.raw)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
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

    func updateSourceLink(_ link: TerminalLink) {
        guard link != sourceLink else { return }
        sourceLink = link
        editor.setText(link.raw, notify: false)
        refreshState()
    }

    func setEditedText(_ text: String) {
        editor.setText(text)
    }

    func refreshActions(
        viewportOffer: @escaping (TerminalLink) -> ViewportOffer?,
        onOpen: @escaping (TerminalLink) -> Void,
        onCopy: @escaping (String) -> Void,
        onOpenViewport: ((ViewportOffer) -> Void)?
    ) {
        self.viewportOffer = viewportOffer
        self.onOpen = onOpen
        self.onCopy = onCopy
        self.onOpenViewport = onOpenViewport
        if isViewLoaded { refreshState() }
    }

    private func configureNavigation() {
        navigationItem.largeTitleDisplayMode = .never
        #if os(visionOS)
        navigationItem.titleView = navigationTitleLabel
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

        configureHostStack()
        configureReachStack()
        configureActionStack()

        rowStack.axis = .vertical
        rowStack.alignment = .fill
        rowStack.spacing = Metrics.rowSpacing
        rowStack.addArrangedSubview(hostStack)
        rowStack.addArrangedSubview(editor)
        rowStack.addArrangedSubview(reachStack)
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
        // The 560-point cap must win on a wide sheet, but on a phone the
        // section follows SwiftUI's `.padding(18)` proposal exactly. A lower
        // priority let the row's required-size chips collapse the whole card
        // to their intrinsic action width.
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

    private func configureHostStack() {
        let label = UIKitChassisLabel("HOST", size: 9, color: UIKitChassis.signal3)
        hostNameLabel.font = UIKitChassis.monoFont(13, weight: .semibold)
        hostNameLabel.textColor = UIKitChassis.signal
        hostNameLabel.numberOfLines = 0
        hostNameLabel.accessibilityIdentifier = "terminal.link.hostValue"
        hostStack.axis = .vertical
        hostStack.alignment = .fill
        hostStack.spacing = 4
        hostStack.addArrangedSubview(label)
        hostStack.addArrangedSubview(hostNameLabel)
    }

    private func configureReachStack() {
        let label = UIKitChassisLabel("REACH", size: 9, color: UIKitChassis.signal3)
        reachLabel.font = UIKitChassis.monoFont(10)
        reachLabel.textColor = UIKitChassis.signal2
        reachLabel.numberOfLines = 0
        reachLabel.accessibilityIdentifier = "terminal.link.reachValue"
        reachStack.axis = .vertical
        reachStack.alignment = .fill
        reachStack.spacing = 4
        reachStack.addArrangedSubview(label)
        reachStack.addArrangedSubview(reachLabel)
    }

    private func configureActionStack() {
        actionStack.axis = .horizontal
        actionStack.alignment = .center
        actionStack.spacing = Metrics.actionSpacing

        viewportChip = UIKitChassisChip(
            "⌗ VIEWPORT",
            prominent: true,
            accessibilityLabel: "Viewport"
        ) { [weak self] in self?.viewportPressed() }
        openChip = UIKitChassisChip(
            "OPEN",
            systemImage: "arrow.up.forward.app",
            prominent: true,
            accessibilityLabel: "Open"
        ) { [weak self] in self?.openPressed() }
        copyChip = UIKitChassisChip(
            "COPY",
            systemImage: "doc.on.doc",
            accessibilityLabel: "Copy"
        ) { [weak self] in self?.copyPressed() }

        for chip in [viewportChip, openChip, copyChip] {
            chip?.setContentHuggingPriority(.required, for: .horizontal)
            actionStack.addArrangedSubview(chip!)
        }
        // SwiftUI's form row fills the card while its HStack content remains
        // leading-aligned. Give UIKit's stack the same flexible trailing
        // space so the chips keep their exact intrinsic widths without
        // forcing the section itself to compress.
        actionSpacer.isAccessibilityElement = false
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actionSpacer.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        actionStack.addArrangedSubview(actionSpacer)
        actionStack.setCustomSpacing(0, after: copyChip)
    }

    private func refreshState() {
        guard isViewLoaded else { return }
        let link = editedLink
        let viewport = editedViewport

        title = link?.openableURL == nil ? "Can't open link" : "Open link"
        #if os(visionOS)
        navigationTitleLabel.setText(title ?? "Open link")
        #endif

        hostNameLabel.text = link?.host
        hostNameLabel.accessibilityLabel = link?.host
        hostStack.isHidden = link?.host == nil
        editor.setNote(link == nil ? "NOT AN ADDRESS MULTIPLEX CAN READ" : nil)

        reachLabel.text = viewport.map(reachDescription)
        reachLabel.accessibilityLabel = viewport.map(reachDescription)
        reachStack.isHidden = viewport == nil

        viewportChip.isHidden = viewport == nil || onOpenViewport == nil
        if let viewport {
            viewportChip.setContent(caption: viewportChipLabel(viewport), systemImage: nil)
            viewportChip.accessibilityLabel = viewportChipLabel(viewport).capitalized
        }
        openChip.isHidden = link?.openableURL == nil
        openChip.isProminent = viewport == nil || onOpenViewport == nil

        sectionView.setTitle(sectionTitle(link: link, viewport: viewport))
        sectionView.setDetail(detail(link: link, viewport: viewport))
    }

    private func sectionTitle(
        link: TerminalLink?,
        viewport: ViewportOffer?
    ) -> String {
        if let viewport, onOpenViewport != nil {
            return switch viewport.reach {
            case .internet: "A public address"
            case .lan: "On this device's network"
            case .remoteLoopback:
                "Lives on \(viewport.viaHostName ?? "the host"), not this device"
            }
        }
        guard let link else { return "Not a usable address" }
        return switch link.kind {
        case .openable: "Leaves Multiplex"
        case .blockedScheme(let scheme): "\(scheme.uppercased()) links stay here"
        case .malformed: "Not a usable address"
        }
    }

    private func detail(
        link: TerminalLink?,
        viewport: ViewportOffer?
    ) -> String {
        if let viewport, onOpenViewport != nil {
            return switch viewport.reach {
            case .internet, .lan:
                "The viewport renders this address inside Multiplex; OPEN "
                    + "still hands it to the system browser. It came from the "
                    + "host — check the address above before opening."
            case .remoteLoopback:
                "localhost in a remote pane is the host's own loopback — an "
                    + "address this device can't dial. VIA aims the viewport "
                    + "at the address that already reaches the host; the "
                    + "server must listen beyond loopback (vite --host) to answer."
            }
        }
        guard let link else {
            return "The field holds nothing Multiplex can open — a target "
                + "needs a web or mail address. Edit it, or copy the text "
                + "if it's still useful."
        }
        return switch link.kind {
        case .openable:
            "This address came from the host, and a hyperlink's visible text "
                + "can differ from where it points — check the host above "
                + "before opening it outside Multiplex. The target is "
                + "editable when detection caught the wrong text."
        case .blockedScheme(let scheme):
            "Multiplex opens web and mail links only. A \(scheme): link from a "
                + "remote pane would act on this device, so it is shown rather "
                + "than followed — copy it if you want it elsewhere."
        case .malformed:
            "The text looked like a link but has no address Multiplex can "
                + "open. Copy it if it's still useful."
        }
    }

    private func viewportChipLabel(_ viewport: ViewportOffer) -> String {
        switch viewport.reach {
        case .internet, .lan: "⌗ VIEWPORT"
        case .remoteLoopback:
            "⌗ VIA \((viewport.viaHostName ?? "HOST").uppercased())"
        }
    }

    private func reachDescription(_ viewport: ViewportOffer) -> String {
        switch viewport.reach {
        case .internet:
            return "INTERNET — OPENS FROM THIS DEVICE"
        case .lan:
            return "LAN — DIALLED FROM THIS DEVICE, NETWORK PERMITTING"
        case .remoteLoopback:
            var rewritten = viewport.url.host() ?? ""
            if let port = viewport.url.port { rewritten += ":\(port)" }
            return "REMOTE LOOPBACK → REWRITES TO \(rewritten)"
        }
    }

    @objc private func cancelPressed() {
        dismissSheet()
    }

    private func viewportPressed() {
        guard let viewport = editedViewport, let onOpenViewport else { return }
        onOpenViewport(viewport)
        dismissSheet()
    }

    private func openPressed() {
        guard let link = editedLink, link.openableURL != nil else { return }
        onOpen(link)
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
