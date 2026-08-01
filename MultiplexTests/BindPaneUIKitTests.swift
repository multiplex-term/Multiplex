import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class BindPaneUIKitTests: XCTestCase {
    func testNativePanePreservesSectionsCommandsPasteAndAccessibility() {
        let bind = BindController()
        let controller = BindPaneViewController(bind: bind)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 640, height: 1_400)
        controller.view.layoutIfNeeded()

        let headers = descendants(of: UIKitChassisLabel.self, in: controller.view)
            .filter { $0.accessibilityTraits.contains(.header) }
            .compactMap(\.accessibilityLabel)
        XCTAssertEqual(headers, [
            "On the machine", "Asking to bind", "Key passphrase", "Somewhere else",
        ])

        let commands = descendants(of: UITextView.self, in: controller.view)
            .compactMap(\.text)
        XCTAssertEqual(
            commands,
            HostGuide.mpxInstall.map(\.command) + [
                HostGuide.mpxBind.command,
                HostGuide.mpxBindCopy.command,
            ]
        )

        let text = renderedText(in: controller.view)
        XCTAssertTrue(text.contains("No machine has answered yet."))
        XCTAssertTrue(text.contains(
            "Machines running mpx bind on this network appear here on their own. "
                + "Confirm each one with the 6-digit PIN its terminal printed."
        ))
        XCTAssertTrue(text.contains(
            "Binding never sends a private key: this device makes its own key and the "
                + "machine adds the public half to authorized_keys. mpx unbind removes it."
        ))

        let paste = descendants(of: UIPasteControl.self, in: controller.view).first
        XCTAssertEqual(paste?.accessibilityLabel, "Paste bind code")
        XCTAssertEqual(paste?.accessibilityIdentifier, "bind.paste")
        XCTAssertNotNil(paste?.target)

        // UIKit normally reapplies its generic “Paste” label when the paste
        // target/configuration changes. The bind-specific semantic label is
        // an invariant, not a setup-time value that UIKit can overwrite.
        paste?.accessibilityLabel = "Paste"
        paste?.layoutIfNeeded()
        XCTAssertEqual(paste?.accessibilityLabel, "Paste bind code")

        let secret = descendants(of: SecretTextField.self, in: controller.view).first {
            $0.accessibilityIdentifier == "bind.keyPassphrase"
        }
        XCTAssertNotNil(secret)
        XCTAssertEqual(secret?.accessibilityLabel, "Key passphrase")

        let fitting = controller.fittingSize(for: 640)
        XCTAssertEqual(fitting.width, 640)
        XCTAssertGreaterThan(fitting.height, 0)
        XCTAssertEqual(controller.contentStack.spacing, 18)
    }

    func testPasteFailureIsInlineAndValidPayloadAddsCandidate() async {
        let bind = BindController()
        let controller = BindPaneViewController(bind: bind)
        controller.loadViewIfNeeded()

        controller.acceptPastedText("not a bind code")
        XCTAssertTrue(controller.pasteFailed)
        let failure = descendants(of: UILabel.self, in: controller.view).first {
            $0.accessibilityIdentifier == "bind.pasteFailure"
        }
        XCTAssertEqual(
            failure?.text,
            "The clipboard doesn’t hold a bind code. Copy the multiplex:// line the CLI printed."
        )
        XCTAssertFalse(failure?.isHidden ?? true)

        let url = makeBindURL(name: "remote-box")
        controller.acceptPastedText(url)
        XCTAssertFalse(controller.pasteFailed)
        XCTAssertEqual(bind.pending.map(\.name), ["remote-box"])

        await waitUntil("payload candidate renders") {
            self.descendants(of: BindCandidateRowView.self, in: controller.view).count == 1
        }
        XCTAssertEqual(
            BindPaneViewController.incomingDetail(for: bind.pending),
            "From a scanned or pasted bind code."
        )
        XCTAssertTrue(renderedText(in: controller.view).contains("REMOTE-BOX"))
    }

    func testPassphraseMasksRevealsWritesControllerAndClearsOnRemoval() {
        let bind = BindController()
        bind.bindSurfaceOpen = true
        let controller = BindPaneViewController(bind: bind)
        controller.loadViewIfNeeded()

        let field = descendants(of: SecretTextField.self, in: controller.view).first {
            $0.accessibilityIdentifier == "bind.keyPassphrase"
        }
        guard let field else { return XCTFail("Missing native passphrase field") }
        let accepted = field.delegate?.textField?(
            field,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: "sealed"
        )
        XCTAssertFalse(accepted ?? true)
        XCTAssertEqual(bind.keyPassphrase, "sealed")
        XCTAssertEqual(field.text, "••••••")
        XCTAssertFalse(field.isSecureTextEntry)

        let reveal = descendants(of: UIButton.self, in: controller.view).first {
            $0.accessibilityLabel == "Show Key passphrase"
        }
        XCTAssertNotNil(reveal)
        reveal?.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(field.text, "sealed")
        XCTAssertEqual(reveal?.accessibilityLabel, "Hide Key passphrase")

        controller.prepareForRemoval()
        XCTAssertFalse(bind.bindSurfaceOpen)
        XCTAssertEqual(bind.keyPassphrase, "")
    }

    func testCandidateRowKeepsPINFieldAndRendersEveryStage() throws {
        let announcement = try XCTUnwrap(BindAnnouncement(txt: [
            "v": "1",
            "spub": base64URL(Data(repeating: 7, count: 32)),
            "name": "devbox",
            "user": "jhen",
            "sshport": "2222",
            "fp": "ssh-ed25519 SHA256:abc",
        ]))
        var submittedPIN = ""
        var confirmCount = 0
        var dismissCount = 0
        let row = BindCandidateRowView(
            setPIN: { submittedPIN = $0 },
            confirm: { confirmCount += 1 },
            dismiss: { dismissCount += 1 }
        )
        var pending = BindController.Pending(source: .discovered(announcement))
        row.apply(pending)
        row.layoutIfNeeded()

        XCTAssertEqual(row.accessibilityLabel, "devbox is asking to bind")
        XCTAssertTrue(renderedText(in: row).contains("NEEDS PIN"))
        XCTAssertTrue(renderedText(in: row).contains("jhen @ devbox"))
        XCTAssertTrue(renderedText(in: row).contains("ssh :2222"))
        XCTAssertTrue(renderedText(in: row).contains("ssh-ed25519 SHA256:abc"))

        let pin = descendants(of: UITextField.self, in: row).first {
            $0.accessibilityIdentifier == "bind.pin.\(announcement.id)"
        }
        XCTAssertEqual(pin?.accessibilityLabel, "PIN from devbox’s terminal")
        let initialPinField = pin
        pin?.text = "12x34567"
        pin?.sendActions(for: .editingChanged)
        XCTAssertEqual(submittedPIN, "123456")

        let enroll = descendants(of: UIKitChassisChip.self, in: row).first {
            $0.accessibilityLabel == "Enroll devbox"
        }
        XCTAssertNotNil(enroll)
        XCTAssertTrue(enroll?.accessibilityTraits.contains(.notEnabled) ?? false)

        pending.pin = "123456"
        row.apply(pending)
        XCTAssertTrue(initialPinField === descendants(of: UITextField.self, in: row).first {
            $0.accessibilityIdentifier == "bind.pin.\(announcement.id)"
        })
        XCTAssertFalse(enroll?.accessibilityTraits.contains(.notEnabled) ?? true)
        XCTAssertEqual(enroll?.alpha, 1)
        XCTAssertTrue(enroll?.accessibilityActivate() ?? false)
        XCTAssertEqual(confirmCount, 1)

        let dismiss = descendants(of: UIKitChassisChip.self, in: row).first {
            $0.accessibilityLabel == "Dismiss devbox"
        }
        XCTAssertTrue(dismiss?.accessibilityActivate() ?? false)
        XCTAssertEqual(dismissCount, 1)

        pending.stage = .binding
        row.apply(pending)
        XCTAssertTrue(renderedText(in: row).contains("Proving the PIN…"))
        pending.stage = .enrolling
        row.apply(pending)
        XCTAssertTrue(renderedText(in: row).contains("Enrolling this device’s key…"))
        pending.stage = .checking
        row.apply(pending)
        XCTAssertTrue(renderedText(in: row).contains("Checking the connection…"))
        pending.stage = .failed("That PIN was refused.")
        row.apply(pending)
        XCTAssertTrue(renderedText(in: row).contains("That PIN was refused."))
        XCTAssertTrue(renderedText(in: row).contains("RETRY"))
        pending.stage = .bound
        row.apply(pending)
        XCTAssertTrue(renderedText(in: row).contains(
            "Added to the fleet — it's on the deck now."
        ))
    }

    private func makeBindURL(name: String) -> String {
        var bytes = Data([BindWire.payloadVersion, 0])
        bytes.append(Data(repeating: 1, count: 32))
        bytes.append(Data(repeating: 2, count: 16))
        bytes.append(contentsOf: [0x9C, 0x40])
        bytes.append(0)
        let nameBytes = Data(name.utf8)
        bytes.append(UInt8(nameBytes.count))
        bytes.append(nameBytes)
        return BindWire.urlPrefix + base64URL(bytes)
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func waitUntil(
        _ description: String,
        condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func renderedText(in root: UIView) -> [String] {
        var result: [String] = []
        if let label = root as? UILabel {
            if let text = label.text { result.append(text) }
            else if let text = label.attributedText?.string { result.append(text) }
        }
        if let textView = root as? UITextView, let text = textView.text {
            result.append(text)
        }
        for child in root.subviews {
            result.append(contentsOf: renderedText(in: child))
        }
        return result
    }

    private func descendants<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        var result: [T] = root is T ? [root as! T] : []
        for child in root.subviews {
            result.append(contentsOf: descendants(of: type, in: child))
        }
        return result
    }
}
