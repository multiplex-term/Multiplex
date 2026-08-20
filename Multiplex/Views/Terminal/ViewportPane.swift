import Observation
import UIKit
import WebKit

struct ViewportPaneObservedState {
    var displayURL: URL
    var railTag: String
    var isLoading: Bool
    var progress: Double
    var canGoBack: Bool
    var failure: String?
    var currentReach: ViewportReach
    var hostName: String
    var externalLink: TerminalLink?

    @MainActor
    init(controller: ViewportController) {
        displayURL = controller.displayURL
        railTag = controller.railTag
        isLoading = controller.isLoading
        progress = controller.progress
        canGoBack = controller.canGoBack
        failure = controller.failure
        currentReach = controller.currentReach
        hostName = controller.hostName
        externalLink = controller.externalLink
    }
}

/// Value snapshot consumed by visionOS's three-slab Switchboard. The floating
/// editor and destructive confirmation remain pane-owned presentations.
struct ViewportOrnamentConfiguration {
    struct RenderKey: Equatable {
        var displayURL: URL
        var railTag: String
        var isLoading: Bool
        var progress: Double
        var canGoBack: Bool
    }

    var key: RenderKey
    var goBack: () -> Void
    var reloadOrStop: () -> Void
    var editAddress: () -> Void
    var copyAddress: () -> Void
    var clearBrowsingData: () -> Void
    var openInSystemBrowser: () -> Void
}

/// Native viewport surface. It adopts the controller-owned WKWebView instead
/// of recreating it, so merge/split keeps page state, sockets, and scroll;
/// every piece of app chrome around that page is UIKit-owned here.
@MainActor
final class ViewportPaneViewController: UIViewController,
    UIAdaptivePresentationControllerDelegate
{
    static let clearBrowsingMessage = String(localized: """
        Clears cookies, caches, and site storage for every viewport page — dev-server \
        logins included. This page reloads signed out.
        """)

    private let controller: ViewportController
    private var contentSafeArea: UIEdgeInsets
    private var closeAction: () -> Void
    private var observationGeneration = 0
    private var state: ViewportPaneObservedState?
    private var failureIdentity: String?
    private var isPresentingExternalLink = false
    private let showsInWindowRail: Bool
    private var ornamentRailDidChange: () -> Void

    private let rootStack = UIStackView()
    private let pageArea = UIView()
    private let webContainer = UIView()
    private let railView = UIView()
    private let railStack = UIStackView()
    private let progressLine = UIView()
    private var progressWidth: NSLayoutConstraint!
    private var railLeading: NSLayoutConstraint!
    private var railTrailing: NSLayoutConstraint!
    private var railBottom: NSLayoutConstraint!
    private(set) var failureOverlay: ViewportFailureOverlayView?

    private(set) var backChip: UIKitChassisChip!
    private(set) var reloadChip: UIKitChassisChip!
    private(set) var urlButton = UIButton(type: .custom)
    private(set) var reachBadge = ViewportBadgeView("")
    private(set) var systemChip: UIKitChassisChip!
    private(set) var closeChip: UIKitChassisChip!
    private(set) var addressEditor: ViewportAddressEditorView?
    private(set) var editingAddress = false

    init(
        controller: ViewportController,
        contentSafeArea: UIEdgeInsets = .zero,
        showsInWindowRail: Bool = true,
        ornamentRailDidChange: @escaping () -> Void = {},
        close: @escaping () -> Void
    ) {
        self.controller = controller
        self.contentSafeArea = contentSafeArea
        self.showsInWindowRail = showsInWindowRail
        self.ornamentRailDidChange = ornamentRailDidChange
        closeAction = close
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIKitChassis.bezel
        buildHierarchy()
        adoptWebView()
        observationGeneration &+= 1
        observeAndRender(generation: observationGeneration)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateProgressWidth()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentPendingExternalLinkIfPossible()
    }

    func update(
        contentSafeArea: UIEdgeInsets,
        close: @escaping () -> Void,
        ornamentRailDidChange: @escaping () -> Void = {}
    ) {
        closeAction = close
        self.ornamentRailDidChange = ornamentRailDidChange
        if self.contentSafeArea != contentSafeArea {
            self.contentSafeArea = contentSafeArea
            if isViewLoaded { updateRailInsets() }
        }
        if isViewLoaded, controller.webView.superview !== webContainer {
            adoptWebView()
        }
    }

    func prepareForRemoval() {
        observationGeneration &+= 1
        presentedViewController?.dismiss(animated: false)
        addressEditor?.textField.resignFirstResponder()
        // Never remove the WKWebView here: a new pane owner may already have
        // adopted it during merge/split. `ViewportController.shutdown()` is
        // the only close-for-real path.
    }

    func applyObservedState(_ state: ViewportPaneObservedState) {
        render(state)
    }

    // MARK: Hierarchy + web-view adoption

    private func buildHierarchy() {
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 0
        view.addSubview(rootStack)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        pageArea.backgroundColor = UIKitChassis.screen
        pageArea.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        webContainer.backgroundColor = .clear
        pageArea.addSubview(webContainer)
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webContainer.leadingAnchor.constraint(equalTo: pageArea.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor),
            webContainer.topAnchor.constraint(equalTo: pageArea.topAnchor),
            webContainer.bottomAnchor.constraint(equalTo: pageArea.bottomAnchor),
        ])
        rootStack.addArrangedSubview(pageArea)
        buildRail()
        if showsInWindowRail {
            rootStack.addArrangedSubview(railView)
        }
    }

    func adoptWebView() {
        guard let webView = controller.webView, webView.superview !== webContainer else { return }
        webView.removeFromSuperview()
        webContainer.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
        ])
    }

    // MARK: Observation

    private func observeAndRender(generation: Int) {
        guard generation == observationGeneration else { return }
        let snapshot = withObservationTracking {
            ViewportPaneObservedState(controller: controller)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeAndRender(generation: generation)
            }
        }
        render(snapshot)
    }

    private func render(_ state: ViewportPaneObservedState) {
        self.state = state
        updateRail(state)
        updateFailure(state)
        if state.externalLink != nil { presentPendingExternalLinkIfPossible() }
    }

    // MARK: Rail

    private func buildRail() {
        railView.backgroundColor = UIKitChassis.bezel
        railStack.axis = .horizontal
        railStack.alignment = .center
        railStack.spacing = 9
        railView.addSubview(railStack)
        railStack.translatesAutoresizingMaskIntoConstraints = false
        railLeading = railStack.leadingAnchor.constraint(equalTo: railView.leadingAnchor)
        railTrailing = railStack.trailingAnchor.constraint(equalTo: railView.trailingAnchor)
        railBottom = railStack.bottomAnchor.constraint(equalTo: railView.bottomAnchor)
        NSLayoutConstraint.activate([
            railLeading,
            railTrailing,
            railStack.topAnchor.constraint(equalTo: railView.topAnchor, constant: 8),
            railBottom,
        ])
        updateRailInsets()

        let divider = UIView()
        divider.backgroundColor = UIKitChassis.bezelHi
        railView.addSubview(divider)
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: railView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: railView.trailingAnchor),
            divider.topAnchor.constraint(equalTo: railView.topAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
        progressLine.backgroundColor = TallyPalette.caution
        progressLine.isAccessibilityElement = false
        railView.addSubview(progressLine)
        progressLine.translatesAutoresizingMaskIntoConstraints = false
        progressWidth = progressLine.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            progressLine.leadingAnchor.constraint(equalTo: railView.leadingAnchor),
            progressLine.topAnchor.constraint(equalTo: railView.topAnchor),
            progressLine.heightAnchor.constraint(equalToConstant: 2),
            progressWidth,
        ])

        backChip = chip(
            "",
            systemImage: "chevron.left",
            accessibility: String(localized: "Back")
        ) { [weak controller] in controller?.goBack() }
        backChip.accessibilityIdentifier = "viewport.back"
        reloadChip = chip(
            "",
            systemImage: "arrow.clockwise",
            accessibility: String(localized: "Reload")
        ) { [weak self] in
            guard let self else { return }
            if self.state?.isLoading == true {
                self.controller.stopLoading()
            } else {
                self.controller.reload()
            }
        }
        reloadChip.accessibilityIdentifier = "viewport.reload"

        urlButton.contentHorizontalAlignment = .leading
        urlButton.titleLabel?.numberOfLines = 1
        urlButton.titleLabel?.lineBreakMode = .byTruncatingMiddle
        urlButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        urlButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        urlButton.hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        urlButton.accessibilityHint = String(localized: "Edits the address")
        urlButton.addAction(UIAction { [weak self] _ in self?.beginEditingAddress() }, for: .touchUpInside)
        urlButton.showsMenuAsPrimaryAction = false
        urlButton.menu = makeAddressMenu()
        urlButton.accessibilityIdentifier = "viewport.address"

        reachBadge.setContentHuggingPriority(.required, for: .horizontal)
        systemChip = chip(
            "SYSTEM",
            accessibility: String(localized: "Open in the system browser")
        ) { [weak controller] in
            controller?.openInSystemBrowser()
        }
        systemChip.accessibilityIdentifier = "viewport.system"
        closeChip = chip(
            "CLOSE",
            prominent: true,
            accessibility: String(localized: "Close viewport")
        ) { [weak self] in
            self?.closeAction()
        }
        closeChip.accessibilityIdentifier = "viewport.close"
        [backChip, reloadChip, urlButton, reachBadge, systemChip, closeChip]
            .forEach { railStack.addArrangedSubview($0) }
    }

    private func updateRailInsets() {
        railLeading.constant = 10 + contentSafeArea.left
        railTrailing.constant = -(10 + contentSafeArea.right)
        railBottom.constant = -(8 + contentSafeArea.bottom)
    }

    private func updateRail(_ state: ViewportPaneObservedState) {
        backChip.isUserInteractionEnabled = state.canGoBack
        backChip.alpha = state.canGoBack ? 1 : 0.45
        backChip.accessibilityTraits = state.canGoBack ? .button : [.button, .notEnabled]
        reloadChip.setContent(
            caption: "",
            systemImage: state.isLoading ? "xmark" : "arrow.clockwise"
        )
        reloadChip.accessibilityLabel = state.isLoading
            ? String(localized: "Stop loading")
            : String(localized: "Reload")
        urlButton.setAttributedTitle(Self.readoutText(state.displayURL), for: .normal)
        urlButton.accessibilityLabel = state.displayURL.absoluteString
        reachBadge.setText(state.railTag)
        reachBadge.accessibilityLabel = String(localized: "Reach: \(state.railTag)")
        progressLine.isHidden = !state.isLoading
        updateProgressWidth()
        if !showsInWindowRail { ornamentRailDidChange() }
    }

    var ornamentConfiguration: ViewportOrnamentConfiguration? {
        guard !showsInWindowRail, let state else { return nil }
        return ViewportOrnamentConfiguration(
            key: .init(
                displayURL: state.displayURL,
                railTag: state.railTag,
                isLoading: state.isLoading,
                progress: state.progress,
                canGoBack: state.canGoBack
            ),
            goBack: { [weak controller] in controller?.goBack() },
            reloadOrStop: { [weak self] in
                guard let self else { return }
                if self.state?.isLoading == true {
                    self.controller.stopLoading()
                } else {
                    self.controller.reload()
                }
            },
            editAddress: { [weak self] in self?.beginEditingAddress() },
            copyAddress: { [weak controller] in controller?.copyURL() },
            clearBrowsingData: { [weak self] in
                self?.presentClearBrowsingDataConfirmation()
            },
            openInSystemBrowser: { [weak controller] in
                controller?.openInSystemBrowser()
            }
        )
    }

    private func updateProgressWidth() {
        let rawProgress = state?.progress ?? 0
        let progress = CGFloat(min(max(rawProgress, 0), 1))
        progressWidth.constant = max(0, railView.bounds.width * progress)
    }

    static func readoutText(_ url: URL) -> NSAttributedString {
        var host = url.host() ?? url.absoluteString
        if let port = url.port { host += ":\(port)" }
        let text = NSMutableAttributedString(
            string: host,
            attributes: [
                .font: UIKitChassis.monoFont(10, weight: .semibold),
                .foregroundColor: UIKitChassis.signal,
            ]
        )
        text.append(NSAttributedString(
            string: pathAndQuery(of: url),
            attributes: [
                .font: UIKitChassis.monoFont(10),
                .foregroundColor: UIKitChassis.signal2,
            ]
        ))
        return text
    }

    static func pathAndQuery(of url: URL) -> String {
        var tail = url.path()
        if tail.isEmpty { tail = "/" }
        if let query = url.query() { tail += "?\(query)" }
        return tail
    }

    private func makeAddressMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: String(localized: "Copy Address"),
                image: UIImage(systemName: "doc.on.doc")
            ) { [weak controller] _ in
                controller?.copyURL()
            },
            UIAction(
                title: String(localized: "Clear Browsing Data…"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in self?.presentClearBrowsingDataConfirmation() },
        ])
    }

    private func chip(
        _ caption: String,
        systemImage: String? = nil,
        prominent: Bool = false,
        accessibility: String,
        action: @escaping () -> Void
    ) -> UIKitChassisChip {
        let result = UIKitChassisChip(
            caption,
            systemImage: systemImage,
            prominent: prominent,
            accessibilityLabel: accessibility,
            action: action
        )
        result.setContentHuggingPriority(.required, for: .horizontal)
        result.setContentCompressionResistancePriority(.required, for: .horizontal)
        return result
    }

    // MARK: Address editor

    func beginEditingAddress() {
        if let addressEditor {
            addressEditor.setText(controller.displayURL.absoluteString)
            addressEditor.setRejected(false)
            addressEditor.textField.becomeFirstResponder()
            return
        }
        let editor = ViewportAddressEditorView(
            text: controller.displayURL.absoluteString,
            submit: { [weak self] in self?.submitAddress() },
            cancel: { [weak self] in self?.endEditingAddress() }
        )
        addressEditor = editor
        editingAddress = true
        pageArea.addSubview(editor)
        editor.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            editor.centerXAnchor.constraint(equalTo: pageArea.centerXAnchor),
            editor.leadingAnchor.constraint(greaterThanOrEqualTo: pageArea.leadingAnchor, constant: 12),
            editor.trailingAnchor.constraint(lessThanOrEqualTo: pageArea.trailingAnchor, constant: -12),
            editor.topAnchor.constraint(equalTo: pageArea.topAnchor, constant: 12),
        ])
        pageArea.bringSubviewToFront(editor)
        DispatchQueue.main.async { [weak editor] in editor?.textField.becomeFirstResponder() }
    }

    func submitAddress() {
        guard let editor = addressEditor else { return }
        if controller.navigate(toTyped: editor.textField.text ?? "") {
            endEditingAddress()
        } else {
            editor.setRejected(true)
        }
    }

    func endEditingAddress() {
        addressEditor?.textField.resignFirstResponder()
        addressEditor?.removeFromSuperview()
        addressEditor = nil
        editingAddress = false
    }

    // MARK: Failure state

    private func updateFailure(_ state: ViewportPaneObservedState) {
        let identity = state.failure.map {
            "\($0)|\(state.currentReach)|\(state.hostName)"
        }
        guard identity != failureIdentity else { return }
        failureIdentity = identity
        failureOverlay?.removeFromSuperview()
        failureOverlay = nil
        guard let failure = state.failure else { return }
        let overlay = ViewportFailureOverlayView(
            message: failure,
            hint: Self.reachHint(state.currentReach, hostName: state.hostName),
            retry: { [weak controller] in controller?.reload() },
            openSystem: { [weak controller] in controller?.openInSystemBrowser() }
        )
        failureOverlay = overlay
        pageArea.addSubview(overlay)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: pageArea.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: pageArea.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: pageArea.bottomAnchor),
        ])
        if let addressEditor { pageArea.bringSubviewToFront(addressEditor) }
    }

    static func reachHint(_ reach: ViewportReach, hostName: String) -> String? {
        switch reach {
        case .internet:
            nil
        case .lan:
            String(localized: """
                This address lives on \(hostName)'s network — the device must share it to \
                load the page.
                """)
        case .remoteLoopback:
            String(localized: """
                This page rides \(hostName)'s own address. The server must listen beyond \
                loopback (vite --host, -H 0.0.0.0) for anything to answer.
                """)
        }
    }

    // MARK: Native presentation

    func makeClearBrowsingDataAlert() -> UIAlertController {
        let alert = UIAlertController(
            title: String(localized: "Clear Browsing Data"),
            message: Self.clearBrowsingMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: String(localized: "Clear"),
            style: .destructive
        ) { [weak self] _ in
            self?.controller.clearBrowsingData()
            self?.presentPendingExternalLinkIfPossible()
        })
        alert.addAction(UIAlertAction(
            title: String(localized: "Cancel"),
            style: .cancel
        ) { [weak self] _ in
            self?.presentPendingExternalLinkIfPossible()
        })
        return alert
    }

    func presentClearBrowsingDataConfirmation() {
        guard presentedViewController == nil else { return }
        present(makeClearBrowsingDataAlert(), animated: true)
    }

    private func presentPendingExternalLinkIfPossible() {
        guard !isPresentingExternalLink,
              presentedViewController == nil,
              viewIfLoaded?.window != nil,
              let link = controller.externalLink
        else { return }
        isPresentingExternalLink = true
        let sheet = TerminalLinkSheetViewController(
            link: link,
            onOpen: { confirmed in
                if let url = confirmed.openableURL { UIApplication.shared.open(url) }
            },
            onCopy: { UIPasteboard.general.string = $0 }
        )
        let navigation = UINavigationController(rootViewController: sheet)
        navigation.presentationController?.delegate = self
        sheet.onDismiss = { [weak self, weak navigation] in
            self?.controller.externalLink = nil
            self?.isPresentingExternalLink = false
            navigation?.dismiss(animated: true)
        }
        present(navigation, animated: true)
        // The presentation controller is created during presentation. Setting
        // the delegate only before `present` can leave the interactive swipe
        // dismissal unobserved, permanently suppressing later URL prompts.
        navigation.presentationController?.delegate = self
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        controller.externalLink = nil
        isPresentingExternalLink = false
    }
}

@MainActor
final class ViewportBadgeView: UIKitTallyBorderedView {
    private let label = UILabel()

    init(_ text: String) {
        super.init(frame: .zero)
        backgroundColor = GlassPrototype.strataChassis
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        isAccessibilityElement = true
        setText(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setText(_ text: String) {
        label.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: UIKitChassis.monoFont(9, weight: .semibold),
                .kern: 1.1,
                .foregroundColor: UIKitChassis.signal2,
            ]
        )
    }
}

@MainActor
final class ViewportAddressEditorView: UIKitTallyBorderedView, UITextFieldDelegate {
    private(set) var textField = UITextField()
    private(set) var rejectedLabel = UIKitChassisLabel(
        String(localized: "WEB ADDRESSES ONLY"),
        size: 8,
        color: TallyPalette.caution
    )
    private let submit: () -> Void
    private let cancel: () -> Void
    private(set) var goChip: UIKitChassisChip!
    private(set) var cancelChip: UIKitChassisChip!

    init(text: String, submit: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.submit = submit
        self.cancel = cancel
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.bezel
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        clipsToBounds = true

        let caption = UIKitChassisLabel("ADDRESS", size: 9, color: UIKitChassis.signal3)
        textField.text = text
        textField.placeholder = String(localized: "host:port or https://…")
        textField.font = UIKitChassis.monoFont(12)
        textField.textColor = UIKitChassis.signal
        textField.tintColor = UIKitChassis.signal
        textField.borderStyle = .none
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.keyboardType = .URL
        textField.returnKeyType = .go
        textField.delegate = self
        textField.addAction(UIAction { [weak self] _ in self?.setRejected(false) }, for: .editingChanged)
        NSLayoutConstraint.activate([
            textField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            textField.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        rejectedLabel.isHidden = true
        rejectedLabel.setContentHuggingPriority(.required, for: .horizontal)
        goChip = UIKitChassisChip(
            "GO",
            prominent: true,
            accessibilityLabel: String(localized: "Go"),
            action: submit
        )
        cancelChip = UIKitChassisChip(
            "CANCEL",
            accessibilityLabel: String(localized: "Cancel address edit"),
            action: cancel
        )
        let row = UIStackView(arrangedSubviews: [
            caption, textField, rejectedLabel, goChip, cancelChip,
        ])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
        accessibilityElements = [caption, textField, rejectedLabel, goChip!, cancelChip!]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setText(_ text: String) { textField.text = text }

    func setRejected(_ rejected: Bool) {
        rejectedLabel.isHidden = !rejected
        rejectedLabel.accessibilityElementsHidden = !rejected
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit()
        return false
    }
}

@MainActor
final class ViewportFailureOverlayView: UIView {
    private(set) var retryChip: UIKitChassisChip!
    private(set) var systemChip: UIKitChassisChip!
    private let panel = UIKitTallyBorderedView()

    init(
        message: String,
        hint: String?,
        retry: @escaping () -> Void,
        openSystem: @escaping () -> Void
    ) {
        super.init(frame: .zero)
        backgroundColor = .clear
        panel.backgroundColor = UIKitChassis.bezel
        panel.layer.cornerRadius = 12
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true

        let lamp = UIKitTallyLamp(caption: "NO ROUTE", color: TallyPalette.caution)
        let messageLabel = UILabel()
        messageLabel.text = message
        messageLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = UIKitChassis.signal2
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        let content = UIStackView(arrangedSubviews: [lamp, messageLabel])
        content.axis = .vertical
        content.alignment = .center
        content.spacing = 14
        if let hint {
            let hintLabel = UILabel()
            hintLabel.text = hint
            hintLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
            hintLabel.adjustsFontForContentSizeCategory = true
            hintLabel.textColor = UIKitChassis.signal3
            hintLabel.numberOfLines = 0
            hintLabel.textAlignment = .center
            hintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
            content.addArrangedSubview(hintLabel)
        }
        retryChip = UIKitChassisChip(
            "RETRY",
            prominent: true,
            accessibilityLabel: String(localized: "Retry"),
            action: retry
        )
        systemChip = UIKitChassisChip(
            "SYSTEM",
            accessibilityLabel: String(localized: "Open in the system browser"),
            action: openSystem
        )
        let actions = UIStackView(arrangedSubviews: [retryChip, systemChip])
        actions.axis = .horizontal
        actions.alignment = .center
        actions.spacing = 12
        let actionHost = UIView()
        actionHost.addSubview(actions)
        actions.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            actions.leadingAnchor.constraint(equalTo: actionHost.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: actionHost.trailingAnchor),
            actions.topAnchor.constraint(equalTo: actionHost.topAnchor, constant: 4),
            actions.bottomAnchor.constraint(equalTo: actionHost.bottomAnchor),
        ])
        content.addArrangedSubview(actionHost)
        panel.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 30),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -30),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 30),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -30),
        ])
        addSubview(panel)
        panel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            panel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 20),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        panel.frame.contains(point)
    }
}

// MARK: - Native auxiliary-pane UMD

enum ViewportUMDStyle: Equatable {
    /// visionOS classic window's bottom ornament row.
    case regular
    /// The adaptive single-window shell's slim full-width top row.
    case shell
}

@MainActor
struct ViewportUMDConfiguration {
    /// A file-viewer tab's reading size, in the same trailing slot the
    /// terminal's A− / A+ occupy. nil on a ⌗ viewport tab — a web page has
    /// its own zoom.
    struct TextScale {
        var scale: CGFloat
        var canDecrease: Bool
        var canIncrease: Bool
        var step: (Int) -> Void
        var reset: () -> Void
    }

    var title: String
    var mergeSources: [TerminalWorkspace.WindowEntry]
    var showDeck: () -> Void
    var merge: (UUID) -> Void
    var close: () -> Void
    var style: ViewportUMDStyle
    var deckControlLabel: String
    var contentSafeArea: UIEdgeInsets
    /// Matches `UMDBarConfiguration.contentVerticalPadding`.
    var contentVerticalPadding: CGFloat = 8
    /// Matches `UMDBarConfiguration.minimumContentHeight` — an auxiliary
    /// tab's rail must be the same band as a terminal tab's, or the pane
    /// jumps when you switch between them.
    var minimumContentHeight: CGFloat = 0
    var closeAccessibilityLabel: String
    /// nil (the default) is a rail with no reading size — every ⌗ viewport
    /// tab, and any caller that has no file viewer under it.
    var textScale: TextScale?
    /// The visionOS classic FileViewer stacks its file-local row above this
    /// unchanged window row inside one slab. Shell/iPad leave this nil.
    var fileViewer: FileViewerOrnamentConfiguration?
    /// The visionOS classic Viewport replaces this flat row with Switchboard.
    /// Shell/iPad leave this nil and retain the existing UMD.
    var viewport: ViewportOrnamentConfiguration?
}

enum ViewportUMDAction: Equatable {
    case showDeck
    case merge(UUID)
    case close
    case textScaleStep(Int)
    case textScaleReset
}

/// Native monitor face shared by viewport and file-viewer tabs. Page/file
/// actions stay in the in-window rail; this bar owns only window-level roads.
@MainActor
final class ViewportUMDViewController: UIViewController {
    private struct RenderKey: Equatable {
        private struct MergeSource: Equatable {
            let id: UUID
            let label: String
        }

        private let title: String
        private let mergeSources: [MergeSource]
        private let style: ViewportUMDStyle
        private let deckControlLabel: String?
        private let shellSafeAreaLeft: CGFloat?
        private let shellSafeAreaRight: CGFloat?
        private let shellSafeAreaTop: CGFloat?
        private let shellVerticalPadding: CGFloat?
        private let shellMinimumHeight: CGFloat?
        private let closeAccessibilityLabel: String
        private let textScale: CGFloat?
        private let textScaleEnds: [Bool]
        private let fileViewer: FileViewerOrnamentConfiguration.RenderKey?
        private let viewport: ViewportOrnamentConfiguration.RenderKey?

        init(_ configuration: ViewportUMDConfiguration) {
            title = configuration.title
            style = configuration.style
            closeAccessibilityLabel = configuration.closeAccessibilityLabel
            textScale = configuration.textScale?.scale
            textScaleEnds = configuration.textScale.map {
                [$0.canDecrease, $0.canIncrease]
            } ?? []
            fileViewer = configuration.fileViewer?.key
            viewport = configuration.viewport?.key
            switch configuration.style {
            case .regular:
                mergeSources = configuration.mergeSources.map {
                    MergeSource(id: $0.id, label: $0.label)
                }
                deckControlLabel = nil
                shellSafeAreaLeft = nil
                shellSafeAreaRight = nil
                shellSafeAreaTop = nil
                shellVerticalPadding = nil
                shellMinimumHeight = nil
            case .shell:
                mergeSources = []
                deckControlLabel = configuration.deckControlLabel
                shellSafeAreaLeft = configuration.contentSafeArea.left
                shellSafeAreaRight = configuration.contentSafeArea.right
                shellSafeAreaTop = configuration.contentSafeArea.top
                shellVerticalPadding = configuration.contentVerticalPadding
                shellMinimumHeight = configuration.minimumContentHeight
            }
        }
    }

    private var configuration: ViewportUMDConfiguration
    private(set) var rootView = ViewportUMDRootView()

    private(set) var deckChip: UIKitChassisChip?
    private(set) var titleLabel: UIKitChassisLabel?
    private(set) var mergeButton: ViewportMenuButton?
    private(set) var closeChip: UIKitChassisChip?
    private(set) var textScaleDownChip: UIKitChassisChip?
    private(set) var textScaleUpChip: UIKitChassisChip?
    private(set) var textScaleResetChip: UIKitChassisChip?
    private(set) var fileBackChip: UIKitChassisChip?
    private(set) var fileForwardChip: UIKitChassisChip?
    private(set) var fileSourceChip: UIKitChassisChip?
    private(set) var fileDiffChip: UIKitChassisChip?
    private(set) var fileSelectChip: UIKitChassisChip?
    private(set) var fileTreeChip: UIKitChassisChip?
    private(set) var fileRefreshChip: UIKitChassisChip?
    private(set) var filePathLabel: UILabel?
    private(set) var fileHostBadge: FileViewerBadgeView?

    init(configuration: ViewportUMDConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        view = rootView
        render()
    }

    func update(configuration: ViewportUMDConfiguration) {
        let needsRender = RenderKey(self.configuration) != RenderKey(configuration)
        // Keep callbacks current even when the visible chrome is semantically unchanged.
        self.configuration = configuration
        if isViewLoaded, needsRender { render() }
    }

    func perform(_ action: ViewportUMDAction) {
        switch action {
        case .showDeck: configuration.showDeck()
        case .merge(let id): configuration.merge(id)
        case .close: configuration.close()
        case .textScaleStep(let delta): configuration.textScale?.step(delta)
        case .textScaleReset: configuration.textScale?.reset()
        }
    }

    func fittingContentSize(for proposedWidth: CGFloat? = nil) -> CGSize {
        loadViewIfNeeded()
        return rootView.fittingSize(proposedWidth: proposedWidth)
    }

    private func render() {
        deckChip = chip(
            configuration.style == .shell ? configuration.deckControlLabel : "DECK",
            accessibility: configuration.style == .shell
                ? configuration.deckControlLabel.capitalized : String(localized: "Deck"),
            action: .showDeck
        )
        let title = UIKitChassisLabel(
            configuration.title,
            size: configuration.style == .shell ? 11 : 12
        )
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        titleLabel = title
        closeChip = chip(
            "CLOSE",
            prominent: true,
            accessibility: configuration.closeAccessibilityLabel,
            action: .close
        )

        let textScaleChips = makeTextScaleChips()

        let row: UIStackView
        switch configuration.style {
        case .regular:
            var views: [UIView] = [deckChip!, divider(), title]
            if let textScaleChips {
                views.append(textScaleChips)
            }
            if !configuration.mergeSources.isEmpty {
                let menu = ViewportMenuButton(
                    caption: "MERGE",
                    accessibilityLabel: String(
                        localized: "Merge another window into this one"
                    ),
                    menu: makeMergeMenu()
                )
                mergeButton = menu
                views.append(menu)
            } else {
                mergeButton = nil
            }
            views.append(divider())
            views.append(closeChip!)
            row = UIStackView(arrangedSubviews: views)
            row.spacing = 14

        case .shell:
            mergeButton = nil
            let spacer = UIView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 4).isActive = true
            var views: [UIView] = [deckChip!, title, spacer]
            if let textScaleChips {
                views.append(textScaleChips)
            }
            views.append(closeChip!)
            row = UIStackView(arrangedSubviews: views)
            row.spacing = 9
        }
        row.axis = .horizontal
        row.alignment = .center
        let fileRow = configuration.style == .regular
            ? makeFileViewerRow() : nil
        rootView.apply(
            content: row,
            upperContent: fileRow,
            showsWorkingLine: configuration.fileViewer?.key.isWorking == true,
            style: configuration.style,
            safeArea: configuration.contentSafeArea,
            verticalPadding: configuration.contentVerticalPadding,
            minimumHeight: configuration.minimumContentHeight
        )
        preferredContentSize = fittingContentSize()
    }

    private func makeFileViewerRow() -> UIView? {
        fileBackChip = nil
        fileForwardChip = nil
        fileSourceChip = nil
        fileDiffChip = nil
        fileSelectChip = nil
        fileTreeChip = nil
        fileRefreshChip = nil
        filePathLabel = nil
        fileHostBadge = nil
        guard let fileViewer = configuration.fileViewer else { return nil }
        let state = fileViewer.key
        var views: [UIView] = []

        if state.canGoBack || state.canGoForward {
            let back = fileChip(
                "◂",
                accessibility: String(localized: "Back"),
                action: fileViewer.goBack
            )
            back.accessibilityIdentifier = "fileViewer.back"
            setChipEnabled(back, state.canGoBack)
            fileBackChip = back
            let forward = fileChip(
                "▸",
                accessibility: String(localized: "Forward"),
                action: fileViewer.goForward
            )
            forward.accessibilityIdentifier = "fileViewer.forward"
            setChipEnabled(forward, state.canGoForward)
            fileForwardChip = forward
            let pair = UIStackView(arrangedSubviews: [back, forward])
            pair.axis = .horizontal
            pair.alignment = .center
            pair.spacing = 4
            views.append(pair)
        }

        if state.showsSourceDiff {
            let source = fileChip(
                "SOURCE",
                prominent: state.sourceSelected,
                accessibility: String(localized: "Show source"),
                action: fileViewer.showSource
            )
            source.accessibilityIdentifier = "fileViewer.source"
            fileSourceChip = source
            let diff = fileChip(
                "DIFF",
                prominent: !state.sourceSelected,
                accessibility: String(localized: "Show diff"),
                action: fileViewer.showDiff
            )
            diff.accessibilityIdentifier = "fileViewer.diff"
            fileDiffChip = diff
            let segment = UIStackView(arrangedSubviews: [source, diff])
            segment.axis = .horizontal
            segment.alignment = .center
            segment.spacing = 4
            segment.accessibilityLabel = String(localized: "Source or diff")
            views.append(segment)
        }

        if let caption = state.markdownSelectionCaption {
            let selected = caption == "DONE"
            let select = fileChip(
                caption,
                prominent: selected,
                accessibility: selected
                    ? String(localized: "Back to rendered markdown")
                    : String(localized: "Select source text to copy"),
                action: fileViewer.toggleMarkdownSelection
            )
            select.accessibilityIdentifier = "fileViewer.markdownSelect"
            fileSelectChip = select
            views.append(select)
        }

        let path = UILabel()
        path.numberOfLines = 1
        path.lineBreakMode = .byTruncatingHead
        path.attributedText = Self.filePathText(state.path)
        path.accessibilityLabel = state.path
        path.setContentHuggingPriority(.defaultLow, for: .horizontal)
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The slab is content-sized (it must not track the window width), so
        // the breadcrumb bounds the measurement: long paths truncate at 360
        // instead of widening the slab, while the cap yields when the window
        // row underneath is wider and the path absorbs that slack.
        let pathCap = path.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        pathCap.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            path.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            pathCap,
        ])
        filePathLabel = path
        views.append(path)

        let host = FileViewerBadgeView(state.hostName.uppercased())
        host.accessibilityLabel = String(localized: "Files on \(state.hostName)")
        host.setContentHuggingPriority(.required, for: .horizontal)
        fileHostBadge = host
        views.append(host)

        let tree = fileChip(
            state.treeCaption,
            accessibility: state.treeCaption == "HIDE"
                ? String(localized: "Hide the file tree")
                : String(localized: "Show the file tree"),
            action: fileViewer.toggleTree
        )
        tree.accessibilityIdentifier = "fileViewer.tree"
        fileTreeChip = tree
        views.append(tree)

        let refresh = fileChip(
            "REFRESH",
            accessibility: String(localized: "Refresh file viewer"),
            action: fileViewer.refresh
        )
        refresh.accessibilityIdentifier = "fileViewer.refresh"
        setChipEnabled(refresh, !state.isBusy)
        fileRefreshChip = refresh
        views.append(refresh)

        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        return row
    }

    private func fileChip(
        _ caption: String,
        prominent: Bool = false,
        accessibility: String,
        action: @escaping () -> Void
    ) -> UIKitChassisChip {
        let chip = UIKitChassisChip(
            caption,
            prominent: prominent,
            accessibilityLabel: accessibility,
            action: action
        )
        chip.setContentHuggingPriority(.required, for: .horizontal)
        chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        return chip
    }

    private static func filePathText(_ path: String) -> NSAttributedString {
        let name = FileTree.name(of: path)
        let directory = String(path.dropLast(name.count))
        let text = NSMutableAttributedString(
            string: directory,
            attributes: [
                .font: UIKitChassis.monoFont(10),
                .foregroundColor: UIKitChassis.signal3,
            ]
        )
        text.append(NSAttributedString(
            string: name,
            attributes: [
                .font: UIKitChassis.monoFont(10, weight: .semibold),
                .foregroundColor: UIKitChassis.signal,
            ]
        ))
        return text
    }

    /// Distance from the combined slab's top to the unchanged window row.
    /// The ornament layout puts this seam on the scene's bottom anchor so the
    /// new file row grows upward instead of entering the clipped lower half.
    func stackedDeckAnchorOffset(for proposedWidth: CGFloat?) -> CGFloat {
        loadViewIfNeeded()
        return rootView.stackedAnchorOffset(proposedWidth: proposedWidth)
    }

    /// A− / A+ in the trailing cluster, exactly where a terminal tab's rail
    /// carries them, on every platform. The percentage rides in front of
    /// them only once the reader has left 100% — it is the readout and the
    /// way back, and a chip that says "100%" beside a control that just
    /// moved off it would be the only state on this rail with nothing to
    /// report.
    private func makeTextScaleChips() -> UIView? {
        textScaleDownChip = nil
        textScaleUpChip = nil
        textScaleResetChip = nil
        guard let textScale = configuration.textScale else { return nil }

        var chips: [UIView] = []
        if textScale.scale != FileViewerTextScale.default {
            let label = FileViewerTextScale.percentLabel(textScale.scale)
            let reset = chip(
                label,
                accessibility: String(localized: "Text size \(label); resets to 100 percent"),
                action: .textScaleReset
            )
            reset.accessibilityIdentifier = "viewportUMD.textScaleReset"
            textScaleResetChip = reset
            chips.append(reset)
        }

        let smaller = chip(
            "A−",
            accessibility: String(localized: "Smaller text"),
            action: .textScaleStep(-1)
        )
        smaller.accessibilityIdentifier = "viewportUMD.textSmaller"
        setChipEnabled(smaller, textScale.canDecrease)
        textScaleDownChip = smaller
        chips.append(smaller)

        let larger = chip(
            "A+",
            accessibility: String(localized: "Larger text"),
            action: .textScaleStep(1)
        )
        larger.accessibilityIdentifier = "viewportUMD.textLarger"
        setChipEnabled(larger, textScale.canIncrease)
        textScaleUpChip = larger
        chips.append(larger)

        let group = UIStackView(arrangedSubviews: chips)
        group.axis = .horizontal
        group.alignment = .center
        group.spacing = 4
        group.isAccessibilityElement = false
        group.setContentHuggingPriority(.required, for: .horizontal)
        group.setContentCompressionResistancePriority(.required, for: .horizontal)
        return group
    }

    private func setChipEnabled(_ chip: UIKitChassisChip, _ enabled: Bool) {
        chip.isUserInteractionEnabled = enabled
        chip.alpha = enabled ? 1 : 0.5
        chip.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
    }

    private func chip(
        _ caption: String,
        prominent: Bool = false,
        accessibility: String,
        action: ViewportUMDAction
    ) -> UIKitChassisChip {
        UIKitChassisChip(
            caption,
            prominent: prominent,
            accessibilityLabel: accessibility,
            action: { [weak self] in self?.perform(action) }
        )
    }

    private func divider() -> UIView {
        let line = UIView()
        line.backgroundColor = UIKitChassis.bezelHi
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 18),
        ])
        return line
    }

    private func makeMergeMenu() -> UIMenu {
        UIMenu(children: configuration.mergeSources.map { source in
            UIAction(
                title: source.label,
                image: UIImage(systemName: "macwindow"),
                identifier: UIAction.Identifier("viewportUMD.merge.\(source.id.uuidString)")
            ) { [weak self] _ in self?.perform(.merge(source.id)) }
        })
    }
}

/// visionOS classic Viewport chrome. The controller is a configuration owner;
/// its three standalone slab controllers mount side-by-side in the ornament.
@MainActor
final class ViewportSwitchboardViewController: UIViewController {
    private struct RenderKey: Equatable {
        struct MergeSource: Equatable {
            var id: UUID
            var label: String
        }

        var viewport: ViewportOrnamentConfiguration.RenderKey
        var mergeSources: [MergeSource]
    }

    private var configuration: ViewportUMDConfiguration
    private var renderKey: RenderKey

    let navigateSlab = ViewportSwitchboardSlabViewController()
    let locateSlab = ViewportSwitchboardSlabViewController()
    let actSlab = ViewportSwitchboardSlabViewController()

    private(set) var deckChip: UIKitChassisChip!
    private(set) var backChip: UIKitChassisChip!
    private(set) var reloadChip: UIKitChassisChip!
    private(set) var addressButton = UIButton(type: .custom)
    private(set) var reachBadge = ViewportBadgeView("")
    private(set) var systemChip: UIKitChassisChip!
    private(set) var mergeButton: ViewportMenuButton?
    private(set) var closeChip: UIKitChassisChip!

    init(configuration: ViewportUMDConfiguration) {
        guard configuration.viewport != nil else {
            preconditionFailure("Switchboard requires viewport configuration")
        }
        self.configuration = configuration
        renderKey = Self.key(configuration)
        super.init(nibName: nil, bundle: nil)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func update(configuration: ViewportUMDConfiguration) {
        guard configuration.viewport != nil else { return }
        let nextKey = Self.key(configuration)
        let needsRender = nextKey != renderKey
        self.configuration = configuration
        renderKey = nextKey
        if needsRender { render() }
    }

    var slabControllers: [ViewportSwitchboardSlabViewController] {
        [navigateSlab, locateSlab, actSlab]
    }

    private func render() {
        guard let viewport = configuration.viewport else { return }
        deckChip = chip("DECK", accessibility: String(localized: "Deck")) { [weak self] in
            self?.configuration.showDeck()
        }
        backChip = chip(
            "",
            systemImage: "chevron.left",
            accessibility: String(localized: "Back")
        ) { [weak self] in self?.configuration.viewport?.goBack() }
        backChip.accessibilityIdentifier = "viewport.back"
        setChipEnabled(backChip, viewport.key.canGoBack)
        reloadChip = chip(
            "",
            systemImage: viewport.key.isLoading ? "xmark" : "arrow.clockwise",
            accessibility: viewport.key.isLoading
                ? String(localized: "Stop loading")
                : String(localized: "Reload")
        ) { [weak self] in self?.configuration.viewport?.reloadOrStop() }
        reloadChip.accessibilityIdentifier = "viewport.reload"
        let navigateRow = UIStackView(arrangedSubviews: [
            deckChip!, divider(), backChip!, reloadChip!,
        ])
        configure(row: navigateRow, spacing: 14)
        navigateSlab.apply(row: navigateRow)

        addressButton = UIButton(type: .custom)
        addressButton.contentHorizontalAlignment = .leading
        addressButton.titleLabel?.numberOfLines = 1
        addressButton.titleLabel?.lineBreakMode = .byTruncatingMiddle
        addressButton.setAttributedTitle(
            ViewportPaneViewController.readoutText(viewport.key.displayURL),
            for: .normal
        )
        addressButton.accessibilityLabel = viewport.key.displayURL.absoluteString
        addressButton.accessibilityHint = String(localized: "Edits the address")
        addressButton.accessibilityIdentifier = "viewport.address"
        addressButton.hoverStyle = UIHoverStyle(
            effect: .highlight,
            shape: .rect(cornerRadius: 2)
        )
        addressButton.addAction(UIAction { [weak self] _ in
            self?.configuration.viewport?.editAddress()
        }, for: .touchUpInside)
        addressButton.menu = addressMenu()
        addressButton.showsMenuAsPrimaryAction = false
        addressButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addressButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            addressButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            addressButton.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
        reachBadge = ViewportBadgeView(viewport.key.railTag)
        reachBadge.accessibilityLabel = String(localized: "Reach: \(viewport.key.railTag)")
        reachBadge.setContentHuggingPriority(.required, for: .horizontal)
        let locateRow = UIStackView(arrangedSubviews: [addressButton, reachBadge])
        configure(row: locateRow, spacing: 10)
        locateSlab.apply(
            row: locateRow,
            progress: viewport.key.isLoading ? viewport.key.progress : nil
        )

        systemChip = chip(
            "SYSTEM",
            accessibility: String(localized: "Open in the system browser")
        ) { [weak self] in
            self?.configuration.viewport?.openInSystemBrowser()
        }
        systemChip.accessibilityIdentifier = "viewport.system"
        var actViews: [UIView] = [systemChip!]
        if !configuration.mergeSources.isEmpty {
            let menu = ViewportMenuButton(
                caption: "⋯",
                accessibilityLabel: String(localized: "Merge another window into this one"),
                menu: mergeMenu()
            )
            mergeButton = menu
            actViews.append(menu)
        } else {
            mergeButton = nil
        }
        actViews.append(divider())
        closeChip = chip(
            "CLOSE",
            prominent: true,
            accessibility: configuration.closeAccessibilityLabel
        ) { [weak self] in self?.configuration.close() }
        closeChip.accessibilityIdentifier = "viewport.close"
        actViews.append(closeChip)
        let actRow = UIStackView(arrangedSubviews: actViews)
        configure(row: actRow, spacing: 14)
        actSlab.apply(row: actRow)
    }

    private func configure(row: UIStackView, spacing: CGFloat) {
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = spacing
    }

    private func chip(
        _ caption: String,
        systemImage: String? = nil,
        prominent: Bool = false,
        accessibility: String,
        action: @escaping () -> Void
    ) -> UIKitChassisChip {
        let chip = UIKitChassisChip(
            caption,
            systemImage: systemImage,
            prominent: prominent,
            accessibilityLabel: accessibility,
            action: action
        )
        chip.setContentHuggingPriority(.required, for: .horizontal)
        chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        return chip
    }

    private func setChipEnabled(_ chip: UIKitChassisChip, _ enabled: Bool) {
        chip.isUserInteractionEnabled = enabled
        chip.alpha = enabled ? 1 : 0.45
        chip.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
    }

    private func divider() -> UIView {
        let line = UIView()
        line.backgroundColor = UIKitChassis.bezelHi
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 18),
        ])
        return line
    }

    private func addressMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: String(localized: "Copy Address"),
                image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in
                self?.configuration.viewport?.copyAddress()
            },
            UIAction(
                title: String(localized: "Clear Browsing Data…"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.configuration.viewport?.clearBrowsingData()
            },
        ])
    }

    private func mergeMenu() -> UIMenu {
        UIMenu(title: String(localized: "Merge"), children: configuration.mergeSources.map { source in
            UIAction(
                title: source.label,
                image: UIImage(systemName: "macwindow"),
                identifier: UIAction.Identifier("viewportUMD.merge.\(source.id.uuidString)")
            ) { [weak self] _ in self?.configuration.merge(source.id) }
        })
    }

    private static func key(_ configuration: ViewportUMDConfiguration) -> RenderKey {
        guard let viewport = configuration.viewport else {
            preconditionFailure("Switchboard requires viewport configuration")
        }
        return RenderKey(
            viewport: viewport.key,
            mergeSources: configuration.mergeSources.map {
                .init(id: $0.id, label: $0.label)
            }
        )
    }
}

@MainActor
final class ViewportSwitchboardSlabViewController: UIViewController {
    private(set) var rootView = ViewportUMDRootView()
    private var progress: CGFloat?
    private weak var progressLine: UIView?
    private var progressWidth: NSLayoutConstraint?

    override func loadView() { view = rootView }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateProgressWidth()
    }

    func apply(row: UIView, progress: Double? = nil) {
        loadViewIfNeeded()
        self.progress = progress.map { CGFloat(min(max($0, 0), 1)) }
        rootView.apply(content: row, style: .regular, safeArea: .zero)
        progressLine = nil
        progressWidth = nil
        if self.progress != nil {
            let line = UIView()
            line.backgroundColor = TallyPalette.caution
            line.isAccessibilityElement = false
            rootView.addSubview(line)
            line.translatesAutoresizingMaskIntoConstraints = false
            let width = line.widthAnchor.constraint(equalToConstant: 0)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
                line.topAnchor.constraint(equalTo: rootView.topAnchor),
                line.heightAnchor.constraint(equalToConstant: 2),
                width,
            ])
            progressLine = line
            progressWidth = width
        }
        updateProgressWidth()
        preferredContentSize = fittingContentSize()
    }

    func fittingContentSize(for proposedWidth: CGFloat? = nil) -> CGSize {
        loadViewIfNeeded()
        return rootView.fittingSize(proposedWidth: proposedWidth)
    }

    private func updateProgressWidth() {
        progressWidth?.constant = rootView.bounds.width * (progress ?? 0)
    }
}

@MainActor
final class ViewportUMDRootView: UIKitTallyBorderedView {
    private(set) var contentInsets = UIEdgeInsets.zero
    private var minimumHeight: CGFloat = 0
    private var spentTopStrip: CGFloat = 0
    private weak var upperBand: UIView?

    func apply(
        content: UIView,
        upperContent: UIView? = nil,
        showsWorkingLine: Bool = false,
        style: ViewportUMDStyle,
        safeArea: UIEdgeInsets,
        verticalPadding: CGFloat = 8,
        minimumHeight: CGFloat = 0
    ) {
        subviews.forEach { $0.removeFromSuperview() }
        upperBand = nil
        self.minimumHeight = minimumHeight
        spentTopStrip = style == .shell ? safeArea.top : 0
        backgroundColor = UIKitChassis.bezel
        switch style {
        case .regular:
            layer.borderWidth = 1
            layer.cornerRadius = 12
            layer.cornerCurve = .continuous
            clipsToBounds = true
            contentInsets = UIEdgeInsets(top: 11, left: 18, bottom: 11, right: 18)
            if let upperContent {
                installStackedDeck(
                    upperContent: upperContent,
                    windowContent: content,
                    showsWorkingLine: showsWorkingLine
                )
            } else {
                install(
                    content,
                    in: self,
                    insets: contentInsets,
                    centerYOffset: 0
                )
            }
        case .shell:
            layer.borderWidth = 0
            layer.cornerRadius = 0
            clipsToBounds = false
            contentInsets = UIEdgeInsets(
                top: verticalPadding + safeArea.top,
                left: UMDBarRootView.horizontalPadding + safeArea.left,
                bottom: verticalPadding,
                right: UMDBarRootView.horizontalPadding + safeArea.right
            )
            install(
                content,
                in: self,
                insets: contentInsets,
                centerYOffset: safeArea.top / 2
            )
            let divider = UIView()
            divider.backgroundColor = UIKitChassis.bezelHi
            addSubview(divider)
            divider.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                divider.leadingAnchor.constraint(equalTo: leadingAnchor),
                divider.trailingAnchor.constraint(equalTo: trailingAnchor),
                divider.bottomAnchor.constraint(equalTo: bottomAnchor),
                divider.heightAnchor.constraint(equalToConstant: 1),
            ])
        }
    }

    func fittingSize(proposedWidth: CGFloat?) -> CGSize {
        let target = CGSize(
            width: proposedWidth ?? UIView.layoutFittingCompressedSize.width,
            height: UIView.layoutFittingCompressedSize.height
        )
        let horizontal: UILayoutPriority = proposedWidth == nil ? .fittingSizeLevel : .required
        let measured = systemLayoutSizeFitting(
            target,
            withHorizontalFittingPriority: horizontal,
            verticalFittingPriority: .fittingSizeLevel
        )
        let body = max(minimumHeight, measured.height - spentTopStrip)
        return CGSize(width: measured.width, height: body + spentTopStrip)
    }

    func stackedAnchorOffset(proposedWidth: CGFloat?) -> CGFloat {
        guard let upperBand else { return 0 }
        let width = proposedWidth ?? UIView.layoutFittingCompressedSize.width
        let priority: UILayoutPriority = proposedWidth == nil ? .fittingSizeLevel : .required
        let size = upperBand.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: priority,
            verticalFittingPriority: .fittingSizeLevel
        )
        return size.height + 1
    }

    private func installStackedDeck(
        upperContent: UIView,
        windowContent: UIView,
        showsWorkingLine: Bool
    ) {
        let upper = UIView()
        let window = UIView()
        upperBand = upper
        install(upperContent, in: upper, insets: contentInsets, centerYOffset: 0)
        install(windowContent, in: window, insets: contentInsets, centerYOffset: 0)
        let hairline = UIView()
        hairline.backgroundColor = UIKitChassis.bezelHi
        hairline.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let stack = UIStackView(arrangedSubviews: [upper, hairline, window])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let workingLine = UIView()
        workingLine.backgroundColor = TallyPalette.caution
        workingLine.isAccessibilityElement = false
        workingLine.isHidden = !showsWorkingLine
        addSubview(workingLine)
        workingLine.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            workingLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            workingLine.topAnchor.constraint(equalTo: topAnchor),
            workingLine.widthAnchor.constraint(equalToConstant: 90),
            workingLine.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    private func install(
        _ content: UIView,
        in host: UIView,
        insets: UIEdgeInsets,
        centerYOffset: CGFloat
    ) {
        host.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -insets.right),
            content.topAnchor.constraint(
                greaterThanOrEqualTo: host.topAnchor,
                constant: insets.top
            ),
            content.bottomAnchor.constraint(
                lessThanOrEqualTo: host.bottomAnchor,
                constant: -insets.bottom
            ),
            content.centerYAnchor.constraint(
                equalTo: host.centerYAnchor,
                constant: centerYOffset
            ),
        ])
    }
}

@MainActor
final class ViewportMenuButton: UIButton {
    private let captionLabel = UILabel()
    private let caption: String

    init(caption: String, accessibilityLabel: String, menu: UIMenu) {
        self.caption = caption
        super.init(frame: .zero)
        configuration = nil
        backgroundColor = GlassPrototype.strataChassis
        layer.borderWidth = 1
        captionLabel.isUserInteractionEnabled = false
        addSubview(captionLabel)
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            captionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        captionLabel.setContentHuggingPriority(.required, for: .horizontal)
        captionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        self.menu = menu
        showsMenuAsPrimaryAction = true
        self.accessibilityLabel = accessibilityLabel
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var intrinsicContentSize: CGSize {
        let content = captionLabel.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize
        )
        return CGSize(
            width: ceil(content.width + 18),
            height: ceil(content.height + 10)
        )
    }

    override var isHighlighted: Bool {
        // PROTOTYPE(GLASS): rest on strata over the smoke — an opaque
        // chassis reset would stamp the control after its first press.
        didSet {
            backgroundColor = isHighlighted
                ? UIKitChassis.bezelHi : GlassPrototype.strataChassis
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshColors()
    }

    private func refreshColors() {
        layer.borderColor = UIKitChassis.bezelHi
            .resolvedColor(with: traitCollection).cgColor
        captionLabel.attributedText = NSAttributedString(
            string: caption,
            attributes: [
                .font: UIKitChassis.monoFont(9, weight: .semibold),
                .kern: 1.1,
                .foregroundColor: UIKitChassis.signal2
                    .resolvedColor(with: traitCollection),
            ]
        )
    }
}
