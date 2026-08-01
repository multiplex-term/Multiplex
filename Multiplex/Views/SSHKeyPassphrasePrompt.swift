import UIKit

/// Native owner of the system credential prompt shared by the deck and
/// terminal scenes. The two affirmative actions make persistence explicit:
/// Connect Once is memory-only for this app run; Save & Connect writes the
/// synchronizable Keychain item.
@MainActor
final class SSHKeyPassphrasePromptPresenterViewController: UIViewController {
    static let titleText = "Unlock SSH Key"
    static let fieldPlaceholder = "Key passphrase"
    static let connectOnceTitle = "Connect Once"
    static let saveAndConnectTitle = "Save & Connect"
    static let cancelTitle = "Cancel"

    private(set) var currentAlertController: UIAlertController?
    private(set) var lastPresentedID: UUID?

    private var challenge: SSHKeyPassphraseChallenge?
    private var onSubmit: ((SSHKeyPassphraseChallenge, String, Bool) -> Void)?
    private var onCancel: ((SSHKeyPassphraseChallenge) -> Void)?
    private var presentationRetryWorkItem: DispatchWorkItem?

    override func loadView() {
        let hostView = UIView()
        hostView.backgroundColor = .clear
        hostView.isUserInteractionEnabled = false
        view = hostView
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        synchronizePresentation(animated: animated)
    }

    func update(
        challenge: SSHKeyPassphraseChallenge?,
        onSubmit: @escaping (SSHKeyPassphraseChallenge, String, Bool) -> Void,
        onCancel: @escaping (SSHKeyPassphraseChallenge) -> Void
    ) {
        self.challenge = challenge
        self.onSubmit = onSubmit
        self.onCancel = onCancel

        guard isViewLoaded, view.window != nil else { return }
        synchronizePresentation(animated: true)
    }

    static func message(for challenge: SSHKeyPassphraseChallenge) -> String {
        switch challenge.reason {
        case .required:
            return "The private key for “\(challenge.hostName)” is encrypted. Connect Once keeps the passphrase until Multiplex closes. Save & Connect stores it in iCloud Keychain for your other devices."
        case .incorrect:
            return "That passphrase didn't unlock the private key for “\(challenge.hostName)”. Try again. Save & Connect replaces the copy in iCloud Keychain."
        }
    }

    /// Builds the production alert. Internal visibility keeps its exact
    /// credential semantics directly testable without presenting UI.
    func makeAlert(for challenge: SSHKeyPassphraseChallenge) -> UIAlertController {
        let alert = UIAlertController(
            title: Self.titleText,
            message: Self.message(for: challenge),
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = Self.fieldPlaceholder
            field.isSecureTextEntry = true
            field.clearButtonMode = .whileEditing
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.spellCheckingType = .no
            // An empty content type opts out of the stored-Passwords link.
            // SSH-key persistence belongs exclusively to Save & Connect.
            field.textContentType = UITextContentType(rawValue: "")
            field.accessibilityLabel = Self.fieldPlaceholder
            field.accessibilityIdentifier = "sshKeyPassphrase.field"
        }

        guard let field = alert.textFields?.first else { return alert }

        let connectOnce = UIAlertAction(
            title: Self.connectOnceTitle,
            style: .default
        ) { [weak self, weak field] _ in
            guard let field else { return }
            self?.performSubmit(for: challenge, textField: field, save: false)
        }
        connectOnce.isEnabled = false

        let saveAndConnect = UIAlertAction(
            title: Self.saveAndConnectTitle,
            style: .default
        ) { [weak self, weak field] _ in
            guard let field else { return }
            self?.performSubmit(for: challenge, textField: field, save: true)
        }
        saveAndConnect.isEnabled = false

        let cancel = UIAlertAction(
            title: Self.cancelTitle,
            style: .cancel
        ) { [weak self, weak field] _ in
            self?.performCancel(for: challenge, textField: field)
        }

        alert.addAction(connectOnce)
        alert.addAction(saveAndConnect)
        alert.addAction(cancel)

        field.addAction(
            UIAction { [weak field, weak connectOnce, weak saveAndConnect] _ in
                let hasPassphrase = !(field?.text ?? "").isEmpty
                connectOnce?.isEnabled = hasPassphrase
                saveAndConnect?.isEnabled = hasPassphrase
            },
            for: .editingChanged
        )
        return alert
    }

    func performSubmit(
        for challenge: SSHKeyPassphraseChallenge,
        textField: UITextField,
        save: Bool
    ) {
        let entered = textField.text ?? ""
        // Clear before the callback. The system's save-to-Passwords heuristic
        // reads whatever remains while an alert tears down.
        textField.text = ""
        currentAlertController = nil
        onSubmit?(challenge, entered, save)
    }

    func performCancel(
        for challenge: SSHKeyPassphraseChallenge,
        textField: UITextField?
    ) {
        textField?.text = ""
        currentAlertController = nil
        onCancel?(challenge)
    }

    private func synchronizePresentation(animated: Bool) {
        guard let challenge else {
            guard let currentAlertController else { return }
            self.currentAlertController = nil
            currentAlertController.dismiss(animated: animated) { [weak self] in
                self?.synchronizePresentation(animated: animated)
            }
            return
        }

        guard challenge.id != lastPresentedID else { return }

        if let currentAlertController {
            self.currentAlertController = nil
            currentAlertController.dismiss(animated: animated) { [weak self] in
                self?.synchronizePresentation(animated: animated)
            }
            return
        }

        guard presentedViewController == nil else {
            schedulePresentationRetry(animated: animated)
            return
        }
        presentationRetryWorkItem?.cancel()
        presentationRetryWorkItem = nil
        let alert = makeAlert(for: challenge)
        currentAlertController = alert
        lastPresentedID = challenge.id
        present(alert, animated: animated)
    }

    /// An unlock failure can publish its replacement challenge while UIKit is
    /// still dismissing the previous alert. Wait for that transition instead
    /// of dropping the retry prompt at the `presentedViewController` guard.
    private func schedulePresentationRetry(animated: Bool) {
        guard presentationRetryWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            presentationRetryWorkItem = nil
            synchronizePresentation(animated: animated)
        }
        presentationRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }
}
