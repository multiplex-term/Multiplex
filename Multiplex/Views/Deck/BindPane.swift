import Observation
import UIKit
import os
#if os(iOS)
import VisionKit
#endif

private enum BindPaneCopy {
    static let machineDetail = "Copy a line, run it in a terminal on the machine you "
        + "want to add, then leave mpx bind running. Nothing here runs on this device."
    static let incomingEmptyDetail = "Machines running mpx bind on this network appear "
        + "here on their own. Confirm each one with the 6-digit PIN its terminal printed."
    static let incomingDiscoveredDetail = "Heard on your network. Check the address and "
        + "fingerprint against the terminal, then type its PIN."
    static let incomingPayloadDetail = "From a scanned or pasted bind code."
    static let passphraseDetail = "Optional, for every machine bound from this pane: its "
        + "SSH key is generated sealed with this passphrase, which is then saved in the "
        + "host's settings so connecting keeps working. Clear it in Host Settings to be "
        + "asked when connecting instead. Empty means the key is stored unlocked, "
        + "exactly as before."
    static let elsewhereDetail = "A machine on another network — a VPS, a box behind a "
        + "firewall — can't announce itself here. Scan the QR its terminal printed, or "
        + "have it hand you the code."
    static let pasteLead = "Paste needs the code on this device's clipboard, and mpx "
        + "never takes a clipboard unless you ask it to. Run it with --copy instead:"
    static let pastePostscript = "Over SSH that uses OSC 52, so the code lands on your "
        + "local terminal's clipboard and Universal Clipboard carries it here."
    static let pasteFailure = "The clipboard doesn’t hold a bind code. Copy the "
        + "multiplex:// line the CLI printed."
    static let footer = "Binding never sends a private key: this device makes its own key "
        + "and the machine adds the public half to authorized_keys. mpx unbind removes it."
}

private extension BindController.Pending {
    var statusCaption: String {
        switch stage {
        case .awaitingPIN: needsPIN ? "NEEDS PIN" : "READY"
        case .binding: "BINDING"
        case .enrolling: "ENROLLING"
        case .checking: "CHECKING"
        case .bound: "BOUND"
        case .failed: "FAILED"
        }
    }

    var retryLabel: String {
        if case .failed = stage { return "RETRY" }
        return "ENROLL"
    }

    var busyCaption: String {
        switch stage {
        case .binding: "Proving the PIN…"
        case .enrolling: "Enrolling this device’s key…"
        case .checking: "Checking the connection…"
        default: ""
        }
    }
}

// MARK: - Native pane controller

/// The native Bind Host task surface. `BindController` remains the authority
/// for discovery, enrollment, passphrase lifetime, and candidate state; this
/// controller observes it and keeps candidate views stable by ID so a PIN
/// keystroke never tears down the first responder.
@MainActor
final class BindPaneViewController: UIViewController {
    var elsewhereOffsetDidChange: ((CGFloat) -> Void)?
    var contentSizeDidChange: (() -> Void)?

    private(set) var pasteFailed = false
    private(set) var contentStack = UIStackView()

    private struct Snapshot: Equatable {
        var pending: [BindController.Pending]
        var keyPassphrase: String
    }

    private let bind: BindController
    private let paneView = BindPaneRootView()
    private let incomingSection = BindIncomingSectionView()
    private let passphraseField = BindRevealableSecretField()
    private let pasteFailureLabel = UILabel()
    private let pasteSlot = UIView()
    private var elsewhereSection: UIView!
    private var candidateRows: [String: BindCandidateRowView] = [:]
    private var orderedCandidateIDs: [String] = []
    private var observesBind = true

    private lazy var listeningRow = BindListeningRowView()
    private lazy var pasteTarget = BindPasteTarget { [weak self] providers in
        self?.accept(itemProviders: providers)
    }

    private static let log = Logger(
        subsystem: "app.multiplexterm.multiplex",
        category: "bind"
    )

    init(bind: BindController) {
        self.bind = bind
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        view = paneView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        paneView.backgroundColor = .clear
        paneView.surfaceVisibilityChanged = { [weak bind] isVisible in
            bind?.bindSurfaceOpen = isVisible
        }
        paneView.elsewhereOffsetDidChange = { [weak self] offset in
            self?.elsewhereOffsetDidChange?(offset)
        }

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 18
        paneView.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: paneView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: paneView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: paneView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: paneView.bottomAnchor),
        ])
        paneView.measuredContent = contentStack

        contentStack.addArrangedSubview(makeMachineSection())
        contentStack.addArrangedSubview(incomingSection)
        contentStack.addArrangedSubview(makePassphraseSection())
        elsewhereSection = makeElsewhereSection()
        elsewhereSection.accessibilityIdentifier = "bind.section.elsewhere"
        contentStack.addArrangedSubview(elsewhereSection)
        contentStack.addArrangedSubview(makeFooter())
        paneView.elsewhereView = elsewhereSection

        observeBindState()
    }

    /// Called by the representable before SwiftUI releases the child. The
    /// view-window callback normally closes the surface; this synchronous
    /// fallback also handles teardown that never gets another layout pass.
    func prepareForRemoval() {
        observesBind = false
        paneView.prepareForRemoval()
        bind.bindSurfaceOpen = false
    }

    func fittingSize(for width: CGFloat) -> CGSize {
        guard width > 0 else { return CGSize(width: max(0, width), height: 0) }
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let size = contentStack.systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: width, height: ceil(size.height))
    }

    static func incomingDetail(for pending: [BindController.Pending]) -> String {
        guard !pending.isEmpty else { return BindPaneCopy.incomingEmptyDetail }
        let hasDiscovered = pending.contains {
            if case .discovered = $0.source { return true }
            return false
        }
        return hasDiscovered
            ? BindPaneCopy.incomingDiscoveredDetail
            : BindPaneCopy.incomingPayloadDetail
    }

    /// The same parse seam used by the system paste target. Internal so its
    /// inline-failure and submission behavior can be covered without reading
    /// the process pasteboard in tests.
    func acceptPastedText(_ text: String) {
        guard let payload = BindPayload(string: text) else {
            Self.log.debug("bind paste rejected (\(text.count) chars)")
            setPasteFailed(true)
            return
        }
        setPasteFailed(false)
        bind.submit(payload: payload)
    }

    private func observeBindState() {
        guard observesBind else { return }
        let snapshot = withObservationTracking {
            Snapshot(
                pending: bind.pending,
                keyPassphrase: bind.keyPassphrase
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeBindState()
            }
        }
        render(snapshot)
    }

    private func render(_ snapshot: Snapshot) {
        passphraseField.setText(snapshot.keyPassphrase)
        incomingSection.setDetail(Self.incomingDetail(for: snapshot.pending))
        updateCandidateRows(snapshot.pending)
        paneView.contentDidChange()
        contentSizeDidChange?()
    }

    private func updateCandidateRows(_ pending: [BindController.Pending]) {
        let ids = pending.map(\.id)
        let live = Set(ids)
        for id in Array(candidateRows.keys) where !live.contains(id) {
            candidateRows.removeValue(forKey: id)?.removeFromSuperview()
        }

        for candidate in pending {
            let row: BindCandidateRowView
            if let existing = candidateRows[candidate.id] {
                row = existing
            } else {
                row = BindCandidateRowView(
                    setPIN: { [weak bind] pin in
                        bind?.setPIN(pin, for: candidate.id)
                    },
                    confirm: { [weak bind] in
                        bind?.confirm(id: candidate.id)
                    },
                    dismiss: { [weak bind] in
                        bind?.dismiss(id: candidate.id)
                    }
                )
                candidateRows[candidate.id] = row
            }
            row.apply(candidate)
        }

        if pending.isEmpty {
            let alreadyListening = incomingSection.rows.count == 1
                && incomingSection.rows[0] === listeningRow
            if !orderedCandidateIDs.isEmpty || !alreadyListening {
                incomingSection.setRows([listeningRow])
            }
        } else if ids != orderedCandidateIDs {
            incomingSection.setRows(ids.compactMap { candidateRows[$0] })
        }
        orderedCandidateIDs = ids
    }

    private func makeMachineSection() -> UIView {
        let commands = UIStackView()
        commands.axis = .vertical
        commands.spacing = 12
        for entry in HostGuide.mpxInstall {
            commands.addArrangedSubview(UIKitCopyableCommandField(
                label: entry.label,
                command: entry.command
            ))
        }
        commands.addArrangedSubview(UIKitCopyableCommandField(
            label: HostGuide.mpxBind.label,
            command: HostGuide.mpxBind.command
        ))

        let section = UIKitTallyFormSectionView(
            title: "On the machine",
            detail: BindPaneCopy.machineDetail,
            contentView: commands
        )
        section.accessibilityIdentifier = "bind.section.machine"
        return section
    }

    private func makePassphraseSection() -> UIView {
        passphraseField.onTextChange = { [weak bind] text in
            bind?.keyPassphrase = text
        }
        let section = UIKitTallyFormSectionView(
            title: "Key passphrase",
            detail: BindPaneCopy.passphraseDetail,
            contentView: passphraseField
        )
        section.accessibilityIdentifier = "bind.section.passphrase"
        return section
    }

    private func makeElsewhereSection() -> UIView {
        let lead = BindUI.label(
            BindPaneCopy.pasteLead,
            font: UIKitChassis.uiFont(11),
            color: UIKitChassis.signal2
        )
        let copy = UIKitCopyableCommandField(
            label: HostGuide.mpxBindCopy.label,
            command: HostGuide.mpxBindCopy.command
        )
        let postscript = BindUI.label(
            BindPaneCopy.pastePostscript,
            font: UIKitChassis.uiFont(10),
            color: UIKitChassis.signal3
        )

        let actions = UIStackView()
        actions.axis = .horizontal
        actions.alignment = .center
        actions.spacing = 10

        #if os(iOS)
        if DataScannerViewController.isSupported {
            let scan = UIKitChassisChip(
                "SCAN QR",
                systemImage: "qrcode.viewfinder",
                accessibilityLabel: "Scan QR code",
                action: { [weak self] in self?.presentScanner() }
            )
            scan.accessibilityIdentifier = "bind.scan"
            actions.addArrangedSubview(scan)
        }
        #endif

        pasteSlot.setContentHuggingPriority(.required, for: .horizontal)
        pasteSlot.setContentCompressionResistancePriority(.required, for: .horizontal)
        installPasteControl()
        pasteSlot.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            [weak self] (_: UIView, _: UITraitCollection) in
            self?.installPasteControl()
        }
        actions.addArrangedSubview(pasteSlot)
        actions.addArrangedSubview(UIView())

        pasteFailureLabel.font = UIKitChassis.uiFont(10)
        pasteFailureLabel.textColor = TallyPalette.caution
        pasteFailureLabel.text = BindPaneCopy.pasteFailure
        pasteFailureLabel.numberOfLines = 0
        pasteFailureLabel.isHidden = true
        pasteFailureLabel.accessibilityIdentifier = "bind.pasteFailure"

        let content = UIStackView(arrangedSubviews: [
            lead, copy, postscript, actions, pasteFailureLabel,
        ])
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = 10

        return UIKitTallyFormSectionView(
            title: "Somewhere else",
            detail: BindPaneCopy.elsewhereDetail,
            contentView: content
        )
    }

    /// `UIPasteControl` consumes its configuration at init and offers no way to
    /// re-apply one, so the chassis colors it is built with are baked for the
    /// control's lifetime — a LIGHT/DARK flip would otherwise leave the chip's
    /// ink from the old polarity. Rebuilding the control in its slot is the
    /// heal path, driven by the same trait registration the file's hand-drawn
    /// chrome uses.
    private func installPasteControl() {
        pasteSlot.subviews.forEach { $0.removeFromSuperview() }

        let pasteConfiguration = UIPasteControl.Configuration()
        pasteConfiguration.displayMode = .iconAndLabel
        #if os(iOS)
        pasteConfiguration.cornerStyle = .fixed
        pasteConfiguration.cornerRadius = 4
        #endif
        pasteConfiguration.baseBackgroundColor = UIKitChassis.bezelHi
        pasteConfiguration.baseForegroundColor = UIKitChassis.signal
        let paste = BindPasteControl(configuration: pasteConfiguration)
        paste.target = pasteTarget
        paste.accessibilityIdentifier = "bind.paste"
        paste.setContentHuggingPriority(.required, for: .horizontal)
        paste.setContentCompressionResistancePriority(.required, for: .horizontal)
        pasteSlot.addSubview(paste)
        paste.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            paste.leadingAnchor.constraint(equalTo: pasteSlot.leadingAnchor),
            paste.trailingAnchor.constraint(equalTo: pasteSlot.trailingAnchor),
            paste.topAnchor.constraint(equalTo: pasteSlot.topAnchor),
            paste.bottomAnchor.constraint(equalTo: pasteSlot.bottomAnchor),
        ])
    }

    private func makeFooter() -> UIView {
        let label = UILabel()
        label.numberOfLines = 0
        label.accessibilityLabel = BindPaneCopy.footer
        label.accessibilityIdentifier = "bind.footer"

        let attributed = NSMutableAttributedString(
            string: BindPaneCopy.footer,
            attributes: [
                .font: UIKitChassis.uiFont(10),
                .foregroundColor: UIKitChassis.signal3,
            ]
        )
        let range = (BindPaneCopy.footer as NSString).range(of: "mpx unbind")
        attributed.addAttribute(.font, value: UIKitChassis.monoFont(10), range: range)
        label.attributedText = attributed

        let container = UIView()
        container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func setPasteFailed(_ failed: Bool) {
        guard pasteFailed != failed else { return }
        pasteFailed = failed
        pasteFailureLabel.isHidden = !failed
        paneView.contentDidChange()
        contentSizeDidChange?()
        if failed {
            UIAccessibility.post(notification: .announcement, argument: BindPaneCopy.pasteFailure)
        }
    }

    private func accept(itemProviders: [NSItemProvider]) {
        Self.log.debug("bind paste control delivered \(itemProviders.count) item(s)")
        guard let provider = itemProviders.first else { return }
        provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
            guard let text = object as? String else { return }
            Task { @MainActor [weak self] in
                self?.acceptPastedText(text)
            }
        }
    }

    #if os(iOS)
    private func presentScanner() {
        guard presentedViewController == nil else { return }
        let scanner = BindScannerViewController { [weak self] payload in
            guard let self else { return }
            self.dismiss(animated: true)
            self.bind.submit(payload: payload)
        }
        let navigation = UINavigationController(rootViewController: scanner)
        navigation.navigationBar.prefersLargeTitles = false
        navigation.navigationBar.tintColor = UIKitChassis.signal
        navigation.modalPresentationStyle = .pageSheet
        present(navigation, animated: true)
    }
    #endif
}

// MARK: - Native section and row views

@MainActor
private final class BindPaneRootView: UIView {
    var surfaceVisibilityChanged: ((Bool) -> Void)?
    var elsewhereOffsetDidChange: ((CGFloat) -> Void)?
    weak var measuredContent: UIView?
    weak var elsewhereView: UIView?

    private var reportedVisible = false
    private var measuredWidth: CGFloat = 0
    private var reportedElsewhereOffset: CGFloat = -1

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let visible = window != nil
        guard visible != reportedVisible else { return }
        reportedVisible = visible
        surfaceVisibilityChanged?(visible)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - measuredWidth) > 0.5 {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        guard let elsewhereView else { return }
        let offset = elsewhereView.convert(elsewhereView.bounds.origin, to: self).y
        guard abs(offset - reportedElsewhereOffset) > 0.5 else { return }
        reportedElsewhereOffset = offset
        elsewhereOffsetDidChange?(offset)
    }

    override var intrinsicContentSize: CGSize {
        guard bounds.width > 0, let measuredContent else {
            return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
        }
        let size = measuredContent.systemLayoutSizeFitting(
            CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: UIView.noIntrinsicMetric, height: ceil(size.height))
    }

    func contentDidChange() {
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func prepareForRemoval() {
        if reportedVisible {
            reportedVisible = false
            surfaceVisibilityChanged?(false)
        }
    }
}

@MainActor
private final class BindIncomingSectionView: UIView {
    private let rowsStack = UIStackView()
    private let detailLabel = UILabel()
    private let detailContainer = UIView()

    var rows: [UIView] { rowsStack.arrangedSubviews }

    init() {
        super.init(frame: .zero)
        accessibilityIdentifier = "bind.section.incoming"

        let title = UIKitChassisLabel("Asking to bind", size: 10)
        title.accessibilityTraits.insert(.header)
        let header = UIView()
        header.backgroundColor = UIKitChassis.bezel
        header.addSubview(title)
        title.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: header.topAnchor, constant: 10),
            title.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -10),
        ])

        let divider = UIView()
        divider.backgroundColor = UIKitChassis.bezelHi
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        rowsStack.axis = .vertical
        rowsStack.spacing = 1
        rowsStack.backgroundColor = UIKitChassis.bezelHi

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
        section.spacing = 8
        addSubview(section)
        section.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: leadingAnchor),
            section.trailingAnchor.constraint(equalTo: trailingAnchor),
            section.topAnchor.constraint(equalTo: topAnchor),
            section.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setDetail(_ detail: String) {
        detailLabel.text = detail
    }

    func setRows(_ rows: [UIView]) {
        guard !sameViews(rowsStack.arrangedSubviews, rows) else { return }
        for row in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        for row in rows { rowsStack.addArrangedSubview(row) }
    }

    private func sameViews(_ lhs: [UIView], _ rhs: [UIView]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.0 === $0.1 }
    }
}

@MainActor
private final class BindListeningRowView: UIView {
    init() {
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.chassis

        let lamp = UIKitTallyLamp(caption: "LISTENING", color: TallyPalette.caution)
        let message = BindUI.label(
            "No machine has answered yet.",
            font: UIKitChassis.uiFont(11),
            color: UIKitChassis.signal2,
            lines: 1
        )
        let row = UIStackView(arrangedSubviews: [lamp, message, UIView()])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

/// One stable native candidate row. `apply` mutates labels and stage views in
/// place; the PIN field remains mounted across all awaiting/failed updates.
@MainActor
final class BindCandidateRowView: UIView {
    private let setPIN: (String) -> Void
    private let confirm: () -> Void
    private let dismiss: () -> Void

    private let nameLabel = UIKitChassisLabel("", size: 12)
    private let statusContainer = UIView()
    private let userLabel = UILabel()
    private let addressLabel = UILabel()
    private let fingerprintLabel = UILabel()
    private let errorLabel = UILabel()
    private let pinInput = BindPINInputView()
    private let boundLabel = UILabel()
    private let busyRow = UIStackView()
    private let busySpinner = UIActivityIndicatorView(style: .medium)
    private let busyLabel = UILabel()
    private let actionRow = UIStackView()
    private var dismissChip: UIKitChassisChip!
    private var confirmChip: UIKitChassisChip!
    private var canSubmit = false

    init(
        setPIN: @escaping (String) -> Void,
        confirm: @escaping () -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.setPIN = setPIN
        self.confirm = confirm
        self.dismiss = dismiss
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func apply(_ pending: BindController.Pending) {
        nameLabel.setText(pending.name)
        accessibilityLabel = "\(pending.name) is asking to bind"
        accessibilityIdentifier = "bind.candidate.\(pending.id)"

        userLabel.text = "\(pending.user.isEmpty ? "?" : pending.user) @ \(pending.name)"
        addressLabel.text = pending.addressSummary
        fingerprintLabel.text = pending.fingerprint
        fingerprintLabel.isHidden = pending.fingerprint == nil

        if case .failed(let message) = pending.stage {
            errorLabel.text = message
            errorLabel.isHidden = false
        } else {
            errorLabel.text = nil
            errorLabel.isHidden = true
        }

        pinInput.isHidden = !pending.needsPIN
        pinInput.setCandidate(name: pending.name, id: pending.id)
        pinInput.setPIN(pending.pin)

        dismissChip.accessibilityLabel = "Dismiss \(pending.name)"
        confirmChip.setContent(caption: pending.retryLabel, systemImage: nil)
        confirmChip.accessibilityLabel =
            "\(pending.retryLabel.capitalized) \(pending.name)"
        canSubmit = pending.canSubmit
        confirmChip.isProminent = pending.canSubmit
        confirmChip.isUserInteractionEnabled = pending.canSubmit
        confirmChip.alpha = pending.canSubmit ? 1 : 0.45
        confirmChip.accessibilityTraits = .button
        if !pending.canSubmit { confirmChip.accessibilityTraits.insert(.notEnabled) }

        boundLabel.isHidden = true
        busyRow.isHidden = true
        actionRow.isHidden = true
        switch pending.stage {
        case .bound:
            pinInput.resignInput()
            boundLabel.isHidden = false
        case .binding, .enrolling, .checking:
            pinInput.resignInput()
            busyLabel.text = pending.busyCaption
            busyRow.isHidden = false
            busySpinner.startAnimating()
        default:
            actionRow.isHidden = false
            busySpinner.stopAnimating()
        }

        replaceStatusView(for: pending)
    }

    private func build() {
        backgroundColor = UIKitChassis.chassis
        shouldGroupAccessibilityChildren = true
        accessibilityContainerType = .semanticGroup

        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusContainer.setContentHuggingPriority(.required, for: .horizontal)
        statusContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
        let headerSpacer = UIView()
        headerSpacer.translatesAutoresizingMaskIntoConstraints = false
        headerSpacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 4).isActive = true
        let header = UIStackView(arrangedSubviews: [
            nameLabel, headerSpacer, statusContainer,
        ])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 10

        userLabel.font = UIKitChassis.monoFont(10)
        userLabel.textColor = UIKitChassis.signal
        addressLabel.font = UIKitChassis.monoFont(10)
        addressLabel.textColor = UIKitChassis.signal2
        fingerprintLabel.font = UIKitChassis.monoFont(9)
        fingerprintLabel.textColor = UIKitChassis.signal3
        fingerprintLabel.numberOfLines = 1
        fingerprintLabel.lineBreakMode = .byTruncatingMiddle

        let identityStack = UIStackView(arrangedSubviews: [
            userLabel, addressLabel, fingerprintLabel,
        ])
        identityStack.axis = .vertical
        identityStack.alignment = .fill
        identityStack.spacing = 3
        let identity = UIKitTallyBorderedView()
        identity.backgroundColor = UIKitChassis.screen
        identity.addSubview(identityStack)
        identityStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            identityStack.leadingAnchor.constraint(equalTo: identity.leadingAnchor, constant: 9),
            identityStack.trailingAnchor.constraint(equalTo: identity.trailingAnchor, constant: -9),
            identityStack.topAnchor.constraint(equalTo: identity.topAnchor, constant: 9),
            identityStack.bottomAnchor.constraint(equalTo: identity.bottomAnchor, constant: -9),
        ])

        errorLabel.font = UIKitChassis.uiFont(10)
        errorLabel.textColor = TallyPalette.caution
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        pinInput.onChange = { [weak self] pin in self?.setPIN(pin) }
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 4).isActive = true

        dismissChip = UIKitChassisChip(
            "DISMISS",
            accessibilityLabel: "Dismiss machine",
            action: { [weak self] in self?.dismiss() }
        )
        confirmChip = UIKitChassisChip(
            "ENROLL",
            accessibilityLabel: "Enroll machine",
            action: { [weak self] in
                guard let self, self.canSubmit else { return }
                self.confirm()
            }
        )
        dismissChip.setContentHuggingPriority(.required, for: .horizontal)
        confirmChip.setContentHuggingPriority(.required, for: .horizontal)
        actionRow.addArrangedSubview(pinInput)
        actionRow.addArrangedSubview(spacer)
        actionRow.addArrangedSubview(dismissChip)
        actionRow.addArrangedSubview(confirmChip)
        actionRow.axis = .horizontal
        actionRow.alignment = .center
        actionRow.spacing = 8

        busySpinner.color = UIKitChassis.signal2
        busySpinner.transform = CGAffineTransform(scaleX: 0.65, y: 0.65)
        let spinnerSlot = UIView()
        spinnerSlot.addSubview(busySpinner)
        busySpinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spinnerSlot.widthAnchor.constraint(equalToConstant: 14),
            spinnerSlot.heightAnchor.constraint(equalToConstant: 14),
            busySpinner.centerXAnchor.constraint(equalTo: spinnerSlot.centerXAnchor),
            busySpinner.centerYAnchor.constraint(equalTo: spinnerSlot.centerYAnchor),
        ])
        busyLabel.font = UIKitChassis.uiFont(10)
        busyLabel.textColor = UIKitChassis.signal2
        busyRow.addArrangedSubview(spinnerSlot)
        busyRow.addArrangedSubview(busyLabel)
        busyRow.addArrangedSubview(UIView())
        busyRow.axis = .horizontal
        busyRow.alignment = .center
        busyRow.spacing = 10
        busyRow.isHidden = true

        boundLabel.font = UIKitChassis.uiFont(10)
        boundLabel.textColor = UIKitChassis.signal2
        boundLabel.text = "Added to the fleet — it's on the deck now."
        boundLabel.numberOfLines = 0
        boundLabel.isHidden = true

        let actionState = UIStackView(arrangedSubviews: [boundLabel, busyRow, actionRow])
        actionState.axis = .vertical
        actionState.spacing = 0

        let content = UIStackView(arrangedSubviews: [
            header, identity, errorLabel, actionState,
        ])
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = 10
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    private func replaceStatusView(for pending: BindController.Pending) {
        statusContainer.subviews.forEach { $0.removeFromSuperview() }
        let status: UIView
        switch pending.stage {
        case .bound:
            status = UIKitTallyLamp(caption: "BOUND", color: TallyPalette.ok)
        case .failed:
            status = UIKitTallyLamp(caption: "FAILED", color: TallyPalette.caution)
        default:
            if pending.isBusy {
                status = UIKitTallyLamp(
                    caption: pending.statusCaption,
                    color: TallyPalette.caution
                )
            } else {
                status = UIKitChassisLabel(
                    pending.statusCaption,
                    size: 9,
                    color: UIKitChassis.signal3
                )
            }
        }
        statusContainer.addSubview(status)
        status.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor),
            status.topAnchor.constraint(equalTo: statusContainer.topAnchor),
            status.bottomAnchor.constraint(equalTo: statusContainer.bottomAnchor),
        ])
    }
}

@MainActor
private final class BindPINInputView: UIView, UITextFieldDelegate {
    var onChange: ((String) -> Void)?

    private let field = UITextField()
    private var digitLabels: [UILabel] = []
    private var wells: [UIKitTallyBorderedView] = []
    private var pinFieldFocused = false

    init() {
        super.init(frame: .zero)
        let digits = UIStackView()
        digits.axis = .horizontal
        digits.alignment = .center
        digits.spacing = 4
        for _ in 0..<6 {
            let label = UILabel()
            label.font = UIKitChassis.monoFont(13)
            label.textAlignment = .center
            label.isAccessibilityElement = false
            let well = UIKitTallyBorderedView()
            well.backgroundColor = UIKitChassis.screen
            well.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                well.widthAnchor.constraint(equalToConstant: 17),
                well.heightAnchor.constraint(equalToConstant: 24),
                label.centerXAnchor.constraint(equalTo: well.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            ])
            digitLabels.append(label)
            wells.append(well)
            digits.addArrangedSubview(well)
        }
        addSubview(digits)
        digits.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            digits.leadingAnchor.constraint(equalTo: leadingAnchor),
            digits.trailingAnchor.constraint(equalTo: trailingAnchor),
            digits.topAnchor.constraint(equalTo: topAnchor),
            digits.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        field.keyboardType = .numberPad
        field.textContentType = .oneTimeCode
        field.font = UIKitChassis.monoFont(13)
        field.textColor = .clear
        field.tintColor = .clear
        field.backgroundColor = .clear
        field.delegate = self
        field.addTarget(self, action: #selector(editingChanged), for: .editingChanged)
        addSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        render("")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setCandidate(name: String, id: String) {
        field.accessibilityLabel = "PIN from \(name)’s terminal"
        field.accessibilityIdentifier = "bind.pin.\(id)"
    }

    func setPIN(_ pin: String) {
        if field.text != pin { field.text = pin }
        render(pin)
    }

    func resignInput() {
        field.resignFirstResponder()
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        pinFieldFocused = true
        refreshBorders()
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        pinFieldFocused = false
        refreshBorders()
    }

    @objc private func editingChanged() {
        let digits = String((field.text ?? "").filter(\.isNumber).prefix(6))
        if field.text != digits { field.text = digits }
        render(digits)
        onChange?(digits)
    }

    private func render(_ pin: String) {
        let digits = Array(pin)
        for index in digitLabels.indices {
            let filled = index < digits.count
            digitLabels[index].text = filled ? String(digits[index]) : "·"
            digitLabels[index].textColor = filled
                ? UIKitChassis.signal
                : UIKitChassis.signal3
        }
        refreshBorders()
    }

    private func refreshBorders() {
        for well in wells {
            well.tallyBorderColor = pinFieldFocused
                ? UIKitChassis.signal2
                : UIKitChassis.bezelHi
        }
    }
}

@MainActor
private final class BindRevealableSecretField: UIView, UITextFieldDelegate {
    var onTextChange: ((String) -> Void)?

    private let field = SecretTextField()
    private let revealButton = UIButton(type: .custom)
    private var text = ""
    private var revealed = false

    init() {
        super.init(frame: .zero)
        field.font = UIKitChassis.monoFont(12)
        field.textColor = UIKitChassis.signal
        field.tintColor = UIKitChassis.signal
        field.attributedPlaceholder = NSAttributedString(
            string: "Optional",
            attributes: [.foregroundColor: UIKitChassis.signal3]
        )
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.autocapitalizationType = .none
        field.keyboardType = .asciiCapable
        field.textContentType = UITextContentType(rawValue: "")
        field.accessibilityLabel = "Key passphrase"
        field.accessibilityIdentifier = "bind.keyPassphrase"
        field.delegate = self
        field.addTarget(self, action: #selector(editingChanged), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        revealButton.tintColor = UIKitChassis.signal2
        revealButton.hoverStyle = UIHoverStyle(
            effect: .highlight,
            shape: .rect(cornerRadius: 2)
        )
        revealButton.addTarget(self, action: #selector(toggleReveal), for: .primaryActionTriggered)
        NSLayoutConstraint.activate([
            revealButton.widthAnchor.constraint(equalToConstant: 24),
            revealButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        let row = UIStackView(arrangedSubviews: [field, revealButton])
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
        refreshRevealPresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setText(_ text: String) {
        self.text = text
        let desired = revealed ? text : Self.bullets(text.count)
        if field.text != desired { field.text = desired }
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
        field.text = Self.bullets(characters.count)
        let caret = lower + string.count
        if let position = field.position(from: field.beginningOfDocument, offset: caret) {
            field.selectedTextRange = field.textRange(from: position, to: position)
        }
        onTextChange?(text)
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    @objc private func editingChanged() {
        guard revealed else { return }
        text = field.text ?? ""
        onTextChange?(text)
    }

    @objc private func toggleReveal() {
        revealed.toggle()
        field.masksEditActions = !revealed
        field.text = revealed ? text : Self.bullets(text.count)
        refreshRevealPresentation()
    }

    private func refreshRevealPresentation() {
        revealButton.setImage(
            UIImage(
                systemName: revealed ? "eye.slash" : "eye",
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 10 * Theme.typeScale,
                    weight: .semibold
                )
            ),
            for: .normal
        )
        revealButton.accessibilityLabel = revealed
            ? "Hide Key passphrase"
            : "Show Key passphrase"
    }

    private static func bullets(_ count: Int) -> String {
        String(repeating: "\u{2022}", count: count)
    }
}

@MainActor
private enum BindUI {
    static func label(
        _ text: String,
        font: UIFont,
        color: UIColor,
        lines: Int = 0
    ) -> UILabel {
        let label = UILabel()
        label.font = font
        label.textColor = color
        label.text = text
        label.numberOfLines = lines
        return label
    }
}

@MainActor
private final class BindPasteControl: UIPasteControl {
    static let spokenLabel = "Paste bind code"

    /// `UIPasteControl` rewrites its accessibility label to the generic
    /// “Paste” after its target/configuration updates. VoiceOver needs the
    /// object being pasted here, so keep that semantic label authoritative
    /// at the property boundary instead of racing UIKit with another
    /// one-time assignment during layout.
    override var accessibilityLabel: String? {
        get { Self.spokenLabel }
        set { super.accessibilityLabel = Self.spokenLabel }
    }

    override init(configuration: UIPasteControl.Configuration) {
        super.init(configuration: configuration)
        super.accessibilityLabel = Self.spokenLabel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    @available(*, unavailable)
    override init(frame: CGRect) { fatalError("unused") }
}

@MainActor
private final class BindPasteTarget: NSObject, UIPasteConfigurationSupporting {
    var pasteConfiguration: UIPasteConfiguration?
    private let delivered: ([NSItemProvider]) -> Void

    init(delivered: @escaping ([NSItemProvider]) -> Void) {
        self.delivered = delivered
        pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        super.init()
    }

    func paste(itemProviders: [NSItemProvider]) {
        delivered(itemProviders)
    }
}

// MARK: - Native scanner sheet

#if os(iOS)
@MainActor
private final class BindScannerViewController: UIViewController {
    private let found: (BindPayload) -> Void
    private var scanner: DataScannerViewController?
    private var scannerDelegate: BindScannerDelegate?

    init(found: @escaping (BindPayload) -> Void) {
        self.found = found
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Scan Bind Code"
        navigationItem.largeTitleDisplayMode = .never
        let cancel = UIBarButtonItem(
            title: "Cancel",
            style: .plain,
            target: self,
            action: #selector(cancelPressed)
        )
        cancel.tintColor = UIKitChassis.signal
        cancel.accessibilityLabel = "Cancel"
        navigationItem.leftBarButtonItem = cancel

        guard DataScannerViewController.isSupported,
              DataScannerViewController.isAvailable else {
            showUnavailable()
            return
        }

        let delegate = BindScannerDelegate(found: found)
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = delegate
        scannerDelegate = delegate
        self.scanner = scanner
        addChild(scanner)
        view.addSubview(scanner.view)
        scanner.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scanner.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scanner.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scanner.view.topAnchor.constraint(equalTo: view.topAnchor),
            scanner.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        scanner.didMove(toParent: self)
        try? scanner.startScanning()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        scanner?.stopScanning()
    }

    @objc private func cancelPressed() {
        dismiss(animated: true)
    }

    private func showUnavailable() {
        view.backgroundColor = UIKitChassis.chassis
        let label = UILabel()
        label.text = "This device can’t scan. Paste the bind code instead."
        label.textColor = UIKitChassis.signal2
        label.numberOfLines = 0
        label.textAlignment = .center
        label.accessibilityIdentifier = "bind.scannerUnavailable"
        view.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.7),
        ])
    }
}

@MainActor
private final class BindScannerDelegate: NSObject, DataScannerViewControllerDelegate {
    private let found: (BindPayload) -> Void
    private var delivered = false

    init(found: @escaping (BindPayload) -> Void) {
        self.found = found
    }

    func dataScanner(
        _ dataScanner: DataScannerViewController,
        didAdd addedItems: [RecognizedItem],
        allItems: [RecognizedItem]
    ) {
        deliver(from: addedItems)
    }

    func dataScanner(
        _ dataScanner: DataScannerViewController,
        didTapOn item: RecognizedItem
    ) {
        deliver(from: [item])
    }

    private func deliver(from items: [RecognizedItem]) {
        guard !delivered else { return }
        for item in items {
            guard case .barcode(let barcode) = item,
                  let text = barcode.payloadStringValue,
                  let payload = BindPayload(string: text) else { continue }
            delivered = true
            found(payload)
            return
        }
    }
}
#endif
