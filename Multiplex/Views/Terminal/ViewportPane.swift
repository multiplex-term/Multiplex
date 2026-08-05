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

/// Native viewport surface. It adopts the controller-owned WKWebView instead
/// of recreating it, so merge/split keeps page state, sockets, and scroll;
/// every piece of app chrome around that page is UIKit-owned here.
@MainActor
final class ViewportPaneViewController: UIViewController,
    UIAdaptivePresentationControllerDelegate
{
    static let clearBrowsingMessage = "Clears cookies, caches, and site storage for every "
        + "viewport page — dev-server logins included. This page reloads signed out."

    private let controller: ViewportController
    private var contentSafeArea: UIEdgeInsets
    private var closeAction: () -> Void
    private var observationGeneration = 0
    private var state: ViewportPaneObservedState?
    private var failureIdentity: String?
    private var isPresentingExternalLink = false

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
        close: @escaping () -> Void
    ) {
        self.controller = controller
        self.contentSafeArea = contentSafeArea
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

    func update(contentSafeArea: UIEdgeInsets, close: @escaping () -> Void) {
        closeAction = close
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
        rootStack.addArrangedSubview(railView)
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
            accessibility: "Back"
        ) { [weak controller] in controller?.goBack() }
        backChip.accessibilityIdentifier = "viewport.back"
        reloadChip = chip(
            "",
            systemImage: "arrow.clockwise",
            accessibility: "Reload"
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
        urlButton.accessibilityHint = "Edits the address"
        urlButton.addAction(UIAction { [weak self] _ in self?.beginEditingAddress() }, for: .touchUpInside)
        urlButton.showsMenuAsPrimaryAction = false
        urlButton.menu = makeAddressMenu()
        urlButton.accessibilityIdentifier = "viewport.address"

        reachBadge.setContentHuggingPriority(.required, for: .horizontal)
        systemChip = chip("SYSTEM", accessibility: "Open in the system browser") { [weak controller] in
            controller?.openInSystemBrowser()
        }
        systemChip.accessibilityIdentifier = "viewport.system"
        closeChip = chip("CLOSE", prominent: true, accessibility: "Close viewport") { [weak self] in
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
        reloadChip.accessibilityLabel = state.isLoading ? "Stop loading" : "Reload"
        urlButton.setAttributedTitle(Self.readoutText(state.displayURL), for: .normal)
        urlButton.accessibilityLabel = state.displayURL.absoluteString
        reachBadge.setText(state.railTag)
        reachBadge.accessibilityLabel = "Reach: \(state.railTag)"
        progressLine.isHidden = !state.isLoading
        updateProgressWidth()
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
            UIAction(title: "Copy Address", image: UIImage(systemName: "doc.on.doc")) { [weak controller] _ in
                controller?.copyURL()
            },
            UIAction(
                title: "Clear Browsing Data…",
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
            "This address lives on \(hostName)'s network — "
                + "the device must share it to load the page."
        case .remoteLoopback:
            "This page rides \(hostName)'s own address. "
                + "The server must listen beyond loopback (vite --host, "
                + "-H 0.0.0.0) for anything to answer."
        }
    }

    // MARK: Native presentation

    func makeClearBrowsingDataAlert() -> UIAlertController {
        let alert = UIAlertController(
            title: "Clear Browsing Data",
            message: Self.clearBrowsingMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            self?.controller.clearBrowsingData()
            self?.presentPendingExternalLinkIfPossible()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
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
        "WEB ADDRESSES ONLY",
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
        textField.placeholder = "host:port or https://…"
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
            accessibilityLabel: "Go",
            action: submit
        )
        cancelChip = UIKitChassisChip(
            "CANCEL",
            accessibilityLabel: "Cancel address edit",
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
            accessibilityLabel: "Retry",
            action: retry
        )
        systemChip = UIKitChassisChip(
            "SYSTEM",
            accessibilityLabel: "Open in the system browser",
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
}

enum ViewportUMDAction: Equatable {
    case showDeck
    case merge(UUID)
    case close
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

        init(_ configuration: ViewportUMDConfiguration) {
            title = configuration.title
            style = configuration.style
            closeAccessibilityLabel = configuration.closeAccessibilityLabel
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
                ? configuration.deckControlLabel.capitalized : "Deck",
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

        let row: UIStackView
        switch configuration.style {
        case .regular:
            var views: [UIView] = [deckChip!, divider(), title]
            if !configuration.mergeSources.isEmpty {
                let menu = ViewportMenuButton(
                    caption: "MERGE",
                    accessibilityLabel: "Merge another window into this one",
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
            row = UIStackView(arrangedSubviews: [deckChip!, title, spacer, closeChip!])
            row.spacing = 9
        }
        row.axis = .horizontal
        row.alignment = .center
        rootView.apply(
            content: row,
            style: configuration.style,
            safeArea: configuration.contentSafeArea,
            verticalPadding: configuration.contentVerticalPadding,
            minimumHeight: configuration.minimumContentHeight
        )
        preferredContentSize = fittingContentSize()
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

@MainActor
final class ViewportUMDRootView: UIKitTallyBorderedView {
    private(set) var contentInsets = UIEdgeInsets.zero
    private var minimumHeight: CGFloat = 0
    private var spentTopStrip: CGFloat = 0
    private weak var content: UIView?
    private weak var bottomDivider: UIView?

    func apply(
        content: UIView,
        style: ViewportUMDStyle,
        safeArea: UIEdgeInsets,
        verticalPadding: CGFloat = 8,
        minimumHeight: CGFloat = 0
    ) {
        self.content?.removeFromSuperview()
        bottomDivider?.removeFromSuperview()
        self.content = content
        self.minimumHeight = minimumHeight
        self.spentTopStrip = style == .shell ? safeArea.top : 0
        backgroundColor = UIKitChassis.bezel
        switch style {
        case .regular:
            layer.borderWidth = 1
            layer.cornerRadius = 12
            layer.cornerCurve = .continuous
            clipsToBounds = true
            contentInsets = UIEdgeInsets(top: 11, left: 18, bottom: 11, right: 18)
        case .shell:
            layer.borderWidth = 0
            layer.cornerRadius = 0
            clipsToBounds = false
            // The classic window's rail spans the scene's top safe strip and
            // hands the clearance back here, exactly like `UMDBarRootView`
            // (the shell always passes top: 0).
            contentInsets = UIEdgeInsets(
                top: verticalPadding + safeArea.top,
                left: UMDBarRootView.horizontalPadding + safeArea.left,
                bottom: verticalPadding,
                right: UMDBarRootView.horizontalPadding + safeArea.right
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
            bottomDivider = divider
        }
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentInsets.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInsets.right),
            // The insets are a floor: a rail asked to match the key bar's
            // height keeps its faces the same size and centres them below
            // whatever strip it spends (`UMDBarRootView` does the same).
            content.topAnchor.constraint(
                greaterThanOrEqualTo: topAnchor,
                constant: contentInsets.top
            ),
            content.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor,
                constant: -contentInsets.bottom
            ),
            content.centerYAnchor.constraint(
                equalTo: centerYAnchor,
                constant: safeArea.top / 2
            ),
        ])
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
        // The floor applies to the band below whatever top strip the rail
        // spends, matching `UMDBarRootView.fittingSize`.
        let body = max(minimumHeight, measured.height - spentTopStrip)
        return CGSize(width: measured.width, height: body + spentTopStrip)
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
