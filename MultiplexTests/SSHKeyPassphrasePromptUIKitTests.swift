import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class SSHKeyPassphrasePromptUIKitTests: XCTestCase {
    func testRequiredAlertPreservesCopyActionsAndCredentialFieldSemantics() {
        let challenge = makeChallenge(reason: .required)
        let controller = SSHKeyPassphrasePromptPresenterViewController()
        let alert = controller.makeAlert(for: challenge)

        XCTAssertEqual(alert.title, "Unlock SSH Key")
        XCTAssertEqual(
            alert.message,
            "The private key for “devbox” is encrypted. Connect Once keeps the passphrase "
                + "until Multiplex closes. Save & Connect stores it in iCloud Keychain "
                + "for your other devices."
        )
        XCTAssertEqual(alert.preferredStyle, .alert)
        XCTAssertEqual(alert.actions.map(\.title), [
            "Connect Once", "Save & Connect", "Cancel",
        ])
        XCTAssertEqual(alert.actions.map(\.style), [.default, .default, .cancel])

        let field = tryUnwrap(alert.textFields?.first)
        XCTAssertEqual(field.placeholder, "Key passphrase")
        XCTAssertTrue(field.isSecureTextEntry)
        XCTAssertEqual(field.textContentType?.rawValue, "")
        XCTAssertEqual(field.autocorrectionType, .no)
        XCTAssertEqual(
            field.autocapitalizationType,
            UITextAutocapitalizationType.none
        )
        XCTAssertEqual(field.accessibilityIdentifier, "sshKeyPassphrase.field")
        XCTAssertFalse(alert.actions[0].isEnabled)
        XCTAssertFalse(alert.actions[1].isEnabled)

        field.text = "sealed"
        field.sendActions(for: .editingChanged)
        XCTAssertTrue(alert.actions[0].isEnabled)
        XCTAssertTrue(alert.actions[1].isEnabled)

        field.text = ""
        field.sendActions(for: .editingChanged)
        XCTAssertFalse(alert.actions[0].isEnabled)
        XCTAssertFalse(alert.actions[1].isEnabled)
    }

    func testConnectOnceClearsFieldBeforeCallbackAndDoesNotSave() {
        let challenge = makeChallenge(reason: .required)
        let controller = SSHKeyPassphrasePromptPresenterViewController()
        let field = UITextField()
        field.text = "temporary secret"
        var submission: (UUID, String, Bool)?
        var fieldWasEmptyDuringCallback = false
        controller.update(
            challenge: challenge,
            onSubmit: { challenge, passphrase, save in
                submission = (challenge.id, passphrase, save)
                fieldWasEmptyDuringCallback = field.text == ""
            },
            onCancel: { _ in }
        )

        controller.performSubmit(for: challenge, textField: field, save: false)

        XCTAssertEqual(submission?.0, challenge.id)
        XCTAssertEqual(submission?.1, "temporary secret")
        XCTAssertEqual(submission?.2, false)
        XCTAssertTrue(fieldWasEmptyDuringCallback)
        XCTAssertEqual(field.text, "")
    }

    func testSaveAndConnectClearsFieldBeforeCallbackAndRequestsPersistence() {
        let challenge = makeChallenge(reason: .incorrect)
        let controller = SSHKeyPassphrasePromptPresenterViewController()
        let field = UITextField()
        field.text = "replacement secret"
        var submittedPassphrase: String?
        var shouldSave = false
        controller.update(
            challenge: challenge,
            onSubmit: { _, passphrase, save in
                submittedPassphrase = passphrase
                shouldSave = save
                XCTAssertEqual(field.text, "")
            },
            onCancel: { _ in }
        )

        controller.performSubmit(for: challenge, textField: field, save: true)

        XCTAssertEqual(submittedPassphrase, "replacement secret")
        XCTAssertTrue(shouldSave)
    }

    func testCancelClearsFieldBeforeCallback() {
        let challenge = makeChallenge(reason: .required)
        let controller = SSHKeyPassphrasePromptPresenterViewController()
        let field = UITextField()
        field.text = "discard me"
        var cancelledID: UUID?
        controller.update(
            challenge: challenge,
            onSubmit: { _, _, _ in XCTFail("Cancel must not submit") },
            onCancel: { cancelled in
                cancelledID = cancelled.id
                XCTAssertEqual(field.text, "")
            }
        )

        controller.performCancel(for: challenge, textField: field)

        XCTAssertEqual(cancelledID, challenge.id)
        XCTAssertEqual(field.text, "")
    }

    private func makeChallenge(
        reason: SSHKeyPassphraseChallenge.Reason
    ) -> SSHKeyPassphraseChallenge {
        SSHKeyPassphraseChallenge(
            host: Host(
                name: "devbox",
                hostname: "127.0.0.1",
                username: "dev"
            ),
            reason: reason
        )
    }

    private func tryUnwrap<T>(
        _ value: T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> T {
        guard let value else {
            XCTFail("Expected a value", file: file, line: line)
            fatalError("Test cannot continue without value")
        }
        return value
    }
}
