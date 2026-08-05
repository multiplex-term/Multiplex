import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class AddHostFormStateTests: XCTestCase {
    func testValidationAcceptsOnlyManualDestinationAndValidMoshPorts() {
        var form = AddHostFormState(editing: nil)
        XCTAssertFalse(form.isValid)

        form.hostname = "devbox.local"
        form.username = "jhen"
        XCTAssertTrue(form.isValid)

        form.port = "not-a-port"
        XCTAssertFalse(form.isValid)
        form.port = "22"
        form.useMosh = true

        for ports in ["", "1", "65535", "60000:61000", " 60000:61000 "] {
            form.moshPorts = ports
            XCTAssertTrue(form.moshPortsAreValid, "Expected valid ports: \(ports)")
        }
        for ports in ["0", "65536", ":60000", "60000:", "1:2:3", "1;touch /tmp/x"] {
            form.moshPorts = ports
            XCTAssertFalse(form.moshPortsAreValid, "Expected invalid ports: \(ports)")
            XCTAssertFalse(form.isValid)
        }
    }

    func testHostResolutionNormalizesVisibleFieldsAndPreservesUnknownLiveState() {
        let hostID = UUID()
        var snapshot = Host(
            id: hostID,
            name: "Snapshot",
            hostname: "old.example",
            username: "old-user"
        )
        snapshot.agentLaunchModels = [
            AgentKind.codex.rawValue: ["old-model"],
            "future-agent": ["keep-verbatim", "--future-value"],
        ]
        var live = snapshot
        live.pinnedHostKeys = ["ssh-ed25519 SHA256:live"]

        var form = AddHostFormState(editing: snapshot)
        form.name = "   "
        form.hostname = "  devbox.local  "
        form.port = "2222"
        form.username = "  operator  "
        form.isEnabled = false
        form.useMosh = true
        form.moshServerPath = "  /opt/bin/mosh-server  "
        form.moshPorts = " 60000:61000 "
        form.workingDirectories = [
            .init(path: " ~/one "),
            .init(path: "~/two"),
            .init(path: "~/one"),
        ]
        form.newWorkingDirectory = " ~/three "
        form.newSessionTmuxConf = "\r\nmouse off\r\n"
        let scriptID = UUID()
        form.scripts = [
            .init(id: scriptID, name: "  Setup  ", body: "\r\necho ok\r\n"),
            .init(name: "Empty", body: "   "),
        ]
        form.modelText[.codex] = "gpt-5\ngpt-5\n --invalid\n"

        let resolved = form.host(liveHost: live)

        XCTAssertEqual(resolved.id, hostID)
        XCTAssertEqual(resolved.name, "  devbox.local  ")
        XCTAssertEqual(resolved.hostname, "devbox.local")
        XCTAssertEqual(resolved.port, 2222)
        XCTAssertEqual(resolved.username, "operator")
        XCTAssertFalse(resolved.isEnabled)
        XCTAssertTrue(resolved.useMosh)
        XCTAssertEqual(resolved.moshServerPath, "/opt/bin/mosh-server")
        XCTAssertEqual(resolved.moshPorts, "60000:61000")
        XCTAssertEqual(resolved.workingDirs, ["~/one", "~/two", "~/three"])
        XCTAssertEqual(resolved.newSessionTmuxConf, "mouse off")
        XCTAssertEqual(
            resolved.sessionScripts,
            [SessionScript(id: scriptID, name: "Setup", body: "echo ok")]
        )
        XCTAssertEqual(resolved.launchModels(for: .codex), ["gpt-5"])
        XCTAssertEqual(
            resolved.agentLaunchModels["future-agent"],
            ["keep-verbatim", "--future-value"]
        )
        XCTAssertEqual(resolved.pinnedHostKeys, ["ssh-ed25519 SHA256:live"])
    }

    func testStableRowsMoveDeleteAndFoldPendingDirectoryIntoSave() {
        var form = AddHostFormState(editing: nil)
        let first = UUID()
        let second = UUID()
        form.workingDirectories = [
            .init(id: first, path: "~/first"),
            .init(id: second, path: "~/second"),
        ]
        form.moveWorkingDirectory(id: second, offset: -1)
        XCTAssertEqual(form.workingDirectories.map(\.id), [second, first])
        form.removeWorkingDirectory(id: first)
        form.newWorkingDirectory = " ~/pending "
        XCTAssertEqual(form.resolvedWorkingDirectories, ["~/second", "~/pending"])

        let scriptOne = UUID()
        let scriptTwo = UUID()
        form.scripts = [
            .init(id: scriptOne, name: "One", body: "one"),
            .init(id: scriptTwo, name: "Two", body: "two"),
        ]
        form.moveScript(id: scriptTwo, offset: -1)
        XCTAssertEqual(form.scripts.map(\.id), [scriptTwo, scriptOne])
    }

    func testConnectionFingerprintExcludesPresentationOnlyEdits() {
        var form = AddHostFormState(editing: nil)
        let original = form.testFingerprint
        form.name = "A new label"
        form.isEnabled = false
        form.moshPorts = "60000:61000"
        form.newWorkingDirectory = "~/work"
        XCTAssertEqual(form.testFingerprint, original)

        form.hostname = "devbox.local"
        XCTAssertNotEqual(form.testFingerprint, original)
    }
}

@MainActor
final class AddHostUIKitTests: XCTestCase {
    private struct Fixture {
        let controller: AddHostViewController
        let navigation: UINavigationController
        let entitlements: EntitlementStore
        let bind: BindController
        let defaults: UserDefaults
        let defaultsDomain: String
        let directory: URL
    }

    func testAddStartsOnNativeBindRoadWithExactNavigationAndLayoutContract() {
        let fixture = makeFixture()
        defer { clean(fixture) }
        fixture.navigation.loadViewIfNeeded()
        fixture.controller.loadViewIfNeeded()
        fixture.controller.view.frame = CGRect(x: 0, y: 0, width: 720, height: 900)
        fixture.controller.view.layoutIfNeeded()

        XCTAssertEqual(fixture.controller.title, "Add Host")
        XCTAssertEqual(fixture.controller.mode, .bind)
        XCTAssertEqual(fixture.controller.navigationItem.leftBarButtonItem?.title, "Done")
        XCTAssertEqual(fixture.controller.navigationItem.leftBarButtonItem?.style, .plain)
        XCTAssertNil(fixture.controller.navigationItem.rightBarButtonItem)
        XCTAssertFalse(fixture.controller.isModalInPresentation)
        XCTAssertEqual(fixture.controller.modeChoiceBar?.arrangedSubviews.count, 2)
        XCTAssertEqual(
            descendants(of: UIButton.self, in: fixture.controller.modeChoiceBar!)
                .compactMap(\.accessibilityLabel),
            ["Bind", "Manual"]
        )
        XCTAssertEqual(
            fixture.controller.contentStack.spacing,
            AddHostViewController.Metrics.sectionSpacing
        )
        XCTAssertEqual(AddHostViewController.Metrics.outerInset, 18)
        XCTAssertEqual(AddHostViewController.Metrics.contentMaximumWidth, 680)
        XCTAssertTrue(hasContentMaximumWidthConstraint(in: fixture.controller.view))
        XCTAssertTrue(fixture.controller.children.contains {
            $0 === fixture.controller.bindPaneController
        })
        XCTAssertFalse(fixture.controller.children.contains {
            String(describing: type(of: $0)).contains("UIHostingController")
        })
        XCTAssertTrue(renderedText(in: fixture.controller.view).contains(
            "Run the mpx CLI on the machine you're adding and it offers itself — no "
                + "address, user, or key to type here. Can't install it? Switch to MANUAL."
        ))

        fixture.controller.setMode(.manual)
        XCTAssertEqual(fixture.controller.navigationItem.leftBarButtonItem?.title, "Cancel")
        XCTAssertEqual(fixture.controller.navigationItem.rightBarButtonItem?.title, "Save")
        XCTAssertEqual(fixture.controller.navigationItem.rightBarButtonItem?.style, .plain)
        XCTAssertNil(fixture.controller.navigationItem.rightBarButtonItem?.customView)
        XCTAssertTrue(fixture.controller.isModalInPresentation)
        XCTAssertEqual(sectionHeaders(in: fixture.controller.view), [
            "Host identity",
            "Monitoring",
            "Backend",
            "Credentials",
            "Signal check",
            "New session defaults",
            "New session tmux conf",
            "Session setup scripts",
            "Agent launch models",
            "Transport",
        ])
        XCTAssertEqual(fixture.controller.nameField.accessibilityLabel, "Name")
        XCTAssertEqual(fixture.controller.hostnameField.accessibilityLabel, "Address")
        XCTAssertEqual(fixture.controller.portField.accessibilityLabel, "Port")
        XCTAssertEqual(fixture.controller.usernameField.accessibilityLabel, "User")
        XCTAssertTrue(fixture.controller.manualStack.gestureRecognizers?.allSatisfy {
            $0.delegate === fixture.controller
        } ?? false)
    }

    func testHerdrBackendUpdatesSignalCopyAndHidesOnlyTheTmuxOptionsEditor() throws {
        let fixture = makeFixture()
        defer { clean(fixture) }
        fixture.controller.loadViewIfNeeded()
        fixture.controller.setMode(.manual)

        let herdr = try XCTUnwrap(
            descendants(of: UIButton.self, in: fixture.controller.view)
                // The face uppercases; the spoken label stays the natural
                // spelling so VoiceOver says "herdr", not H-E-R-D-R.
                .first { $0.accessibilityLabel == "herdr" }
        )
        herdr.sendActions(for: .touchUpInside)

        XCTAssertEqual(fixture.controller.form.sessionBackend, .herdr)
        XCTAssertTrue(renderedText(in: fixture.controller.view).contains(
            "Signs in over SSH with the settings above, then looks for herdr on the host."
        ))
        let directories = descendants(of: UIView.self, in: fixture.controller.view)
            .first { $0.accessibilityIdentifier == "addhost.section.directories" }
        let tmuxConf = descendants(of: UIView.self, in: fixture.controller.view)
            .first { $0.accessibilityIdentifier == "addhost.section.tmuxConf" }
        XCTAssertTrue(
            directories?.isHidden == false,
            "working directories root a herdr session's world too — "
                + "only the tmux options editor is tmux-scoped"
        )
        XCTAssertTrue(tmuxConf?.isHidden == true)
    }

    /// The backend bar shipped as a bare section row: it spanned the card
    /// edge to edge while every other row — the auth bar it sits above
    /// included — carries the inset row's 12 pt gutter.
    func testBackendChoiceBarSitsInTheSameInsetRowAsTheAuthChoiceBar() throws {
        let fixture = makeFixture()
        defer { clean(fixture) }
        fixture.controller.loadViewIfNeeded()
        fixture.controller.setMode(.manual)

        let bar = try XCTUnwrap(
            descendants(of: UIView.self, in: fixture.controller.view)
                .first { $0.accessibilityIdentifier == "addhost.backendBar" }
        )
        var ancestor = bar.superview
        while ancestor != nil, !(ancestor is AddHostInsetRow) {
            ancestor = ancestor?.superview
        }
        XCTAssertNotNil(ancestor, "backend bar must sit inside an inset row")
        XCTAssertTrue(renderedText(in: fixture.controller.view).contains("Sessions run on"))
    }

    func testEditingIsManualOnlyAndStoredPrivateKeyStaysConcealedUntilEdit() throws {
        var host = Host(name: "Studio", hostname: "studio.local", username: "jhen")
        host.authMethod = .privateKey
        host.useMosh = true
        let secrets = HostSecrets(
            password: nil,
            privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\nkey",
            passphrase: "sealed"
        )
        let fixture = makeFixture(editing: host, secrets: secrets)
        defer { clean(fixture) }
        fixture.navigation.loadViewIfNeeded()
        fixture.controller.loadViewIfNeeded()

        XCTAssertEqual(fixture.controller.title, "Host Settings")
        XCTAssertEqual(fixture.controller.mode, .manual)
        XCTAssertNil(fixture.controller.modeChoiceBar)
        XCTAssertEqual(fixture.controller.navigationItem.leftBarButtonItem?.title, "Cancel")
        XCTAssertEqual(fixture.controller.navigationItem.rightBarButtonItem?.title, "Save")
        XCTAssertEqual(fixture.controller.hostnameField.text, "studio.local")
        XCTAssertEqual(fixture.controller.usernameField.text, "jhen")
        XCTAssertTrue(fixture.controller.form.privateKeyConcealed)
        XCTAssertNil(fixture.controller.privateKeyView)

        let edit = try XCTUnwrap(descendants(of: UIButton.self, in: fixture.controller.view)
            .first { $0.accessibilityIdentifier == "addhost.privateKeyConcealed" })
        XCTAssertEqual(edit.accessibilityLabel, "Edit private key")
        XCTAssertTrue(renderedText(in: edit).contains("••••••••"))
        edit.sendActions(for: .touchUpInside)

        XCTAssertFalse(fixture.controller.form.privateKeyConcealed)
        XCTAssertEqual(
            fixture.controller.privateKeyView?.text,
            "-----BEGIN OPENSSH PRIVATE KEY-----\nkey"
        )
        XCTAssertEqual(fixture.controller.passphraseField?.textField.text, "••••••")
    }

    func testSecretFieldUsesAppMaskRevealAndBlocksClipboardWhileConcealed() {
        var changes: [String] = []
        let secret = AddHostRevealableSecretField(
            title: "Password",
            prompt: "Required",
            text: ""
        ) { changes.append($0) }
        let field = secret.textField

        let accepted = field.delegate?.textField?(
            field,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: "sëcret"
        )
        XCTAssertFalse(accepted ?? true)
        XCTAssertEqual(changes, ["sëcret"])
        XCTAssertEqual(field.text, "••••••")
        XCTAssertFalse(field.isSecureTextEntry)
        XCTAssertFalse(field.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)),
                                              withSender: nil))
        XCTAssertFalse(field.canPerformAction(#selector(UIResponderStandardEditActions.selectAll(_:)),
                                              withSender: nil))

        secret.revealButton.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(field.text, "sëcret")
        XCTAssertEqual(secret.revealButton.accessibilityLabel, "Hide Password")
        XCTAssertFalse(field.isSecureTextEntry)
    }

    func testSavePersistsExactNormalizedHostSecretsAndClearsVisibleSecrets() async throws {
        var writtenHost: Host?
        var wasNew: Bool?
        var writtenMethod: Host.AuthMethod?
        var writtenSecrets: HostSecrets?
        var writtenSecretHostID: UUID?
        let fixture = makeFixture(
            secretWriter: { method, secrets, hostID in
                writtenMethod = method
                writtenSecrets = secrets
                writtenSecretHostID = hostID
            },
            hostWriter: { host, isNew in
                writtenHost = host
                wasNew = isNew
            }
        )
        defer { clean(fixture) }
        fixture.controller.loadViewIfNeeded()
        fixture.controller.setMode(.manual)

        enter("  devbox.local  ", in: fixture.controller.hostnameField)
        enter("  operator  ", in: fixture.controller.usernameField)
        enter("2222", in: fixture.controller.portField)
        let password = try XCTUnwrap(fixture.controller.passwordField?.textField)
        _ = password.delegate?.textField?(
            password,
            shouldChangeCharactersIn: NSRange(location: 0, length: 0),
            replacementString: "correct horse"
        )
        enter(" ~/work ", in: fixture.controller.newWorkingDirectoryField)
        fixture.controller.newSessionTmuxConfView.setText("\r\nmouse off\r\n", notify: true)
        fixture.controller.agentModelViews[.codex]?.setText(
            "gpt-5\ngpt-5\n--invalid",
            notify: true
        )

        XCTAssertTrue(fixture.controller.saveItem?.isEnabled ?? false)
        var dismissed = false
        fixture.controller.onDismiss = { dismissed = true }
        send(fixture.controller.saveItem)

        XCTAssertEqual(wasNew, true)
        XCTAssertEqual(writtenHost?.name, "  devbox.local  ")
        XCTAssertEqual(writtenHost?.hostname, "devbox.local")
        XCTAssertEqual(writtenHost?.username, "operator")
        XCTAssertEqual(writtenHost?.port, 2222)
        XCTAssertEqual(writtenHost?.workingDirs, ["~/work"])
        XCTAssertEqual(writtenHost?.newSessionTmuxConf, "mouse off")
        XCTAssertEqual(writtenHost?.launchModels(for: .codex), ["gpt-5"])
        XCTAssertEqual(writtenMethod, .password)
        XCTAssertEqual(writtenSecrets?.password, "correct horse")
        XCTAssertEqual(writtenSecretHostID, writtenHost?.id)
        XCTAssertEqual(fixture.controller.form.password, "")
        XCTAssertEqual(fixture.controller.passwordField?.textField.text, "")
        await waitUntil("deferred dismissal") { dismissed }
    }

    func testLockedMoshRoutesToPaywallWhileExistingMoshCanBeReenabled() {
        let locked = makeFixture(isPro: false)
        defer { clean(locked) }
        locked.controller.loadViewIfNeeded()
        locked.controller.setMode(.manual)
        var lockedPaywallCount = 0
        locked.controller.presentPaywallOverride = { lockedPaywallCount += 1 }
        locked.controller.moshControl?.sendActions(for: .touchUpInside)
        XCTAssertFalse(locked.controller.form.useMosh)
        XCTAssertEqual(lockedPaywallCount, 1)

        var existingHost = Host(
            name: "Roaming",
            hostname: "roaming.local",
            username: "jhen"
        )
        existingHost.useMosh = true
        let existing = makeFixture(editing: existingHost, isPro: false)
        defer { clean(existing) }
        existing.controller.loadViewIfNeeded()
        var existingPaywallCount = 0
        existing.controller.presentPaywallOverride = { existingPaywallCount += 1 }

        existing.controller.moshControl?.sendActions(for: .touchUpInside)
        XCTAssertFalse(existing.controller.form.useMosh)
        existing.controller.moshControl?.sendActions(for: .touchUpInside)
        XCTAssertTrue(existing.controller.form.useMosh)
        XCTAssertEqual(existingPaywallCount, 0)
    }

    /// Background keep-alive is the Monitoring section's second switch: free
    /// (no paywall detour, unlike mosh), off for a host that never asked, and
    /// carried onto the saved record. Its caption states what the switch
    /// actually buys, so the sheet can't quietly start promising minutes.
    func testBackgroundKeepAliveIsAFreeMonitoringSwitchThatReachesTheRecord() throws {
        let fixture = makeFixture(isPro: false)
        defer { clean(fixture) }
        fixture.controller.loadViewIfNeeded()
        fixture.controller.setMode(.manual)
        var paywalls = 0
        fixture.controller.presentPaywallOverride = { paywalls += 1 }

        let control = try XCTUnwrap(fixture.controller.backgroundKeepAliveControl)
        XCTAssertFalse(control.isOn, "a host opts in; it never starts opted in")
        XCTAssertFalse(fixture.controller.form.backgroundKeepAlive)

        control.sendActions(for: .touchUpInside)
        XCTAssertTrue(fixture.controller.form.backgroundKeepAlive)
        XCTAssertEqual(paywalls, 0, "connection plumbing, not a Pro capability")
        XCTAssertTrue(fixture.controller.form.host(liveHost: nil).backgroundKeepAlive)

        XCTAssertTrue(
            renderedText(in: fixture.controller.view)
                .contains { $0.contains("tens of seconds") },
            "the caption must stay sized to the assertion iOS actually grants"
        )

        control.sendActions(for: .touchUpInside)
        XCTAssertFalse(fixture.controller.form.backgroundKeepAlive)
        XCTAssertFalse(fixture.controller.form.host(liveHost: nil).backgroundKeepAlive)
    }

    func testSignalCheckRendersWarningsAndRelevantEditRetiresResult() async throws {
        let fixture = makeFixture(isPro: true, testRunner: { _, _ in
            .connected(HostTest.Report(
                multiplexerFound: false,
                moshServerFound: false
            ))
        })
        defer { clean(fixture) }
        fixture.controller.loadViewIfNeeded()
        fixture.controller.setMode(.manual)
        enter("devbox.local", in: fixture.controller.hostnameField)
        enter("jhen", in: fixture.controller.usernameField)
        fixture.controller.moshControl?.sendActions(for: .touchUpInside)

        let chip = try XCTUnwrap(fixture.controller.testChip)
        XCTAssertTrue(chip.accessibilityActivate())
        await waitUntil("connection result") {
            if case .passed = fixture.controller.testState { return true }
            return false
        }
        let text = renderedText(in: fixture.controller.view)
        XCTAssertTrue(text.contains("Connected to devbox.local as jhen."))
        XCTAssertTrue(text.contains(
            "tmux wasn't found on the host — the deck can't list sessions there. "
                + "Plain shells still work."
        ))
        XCTAssertTrue(text.contains(
            "mosh-server wasn't found — mosh attaches will fail. Install it on the "
                + "host or set its path below."
        ))

        enter("other.local", in: fixture.controller.hostnameField)
        XCTAssertEqual(fixture.controller.testState, .idle)
    }

    func testBindHostLimitObservationUsesNativePaywallRoute() async {
        let fixture = makeFixture(isPro: false)
        defer { clean(fixture) }
        fixture.controller.loadViewIfNeeded()
        var paywallCount = 0
        fixture.controller.presentPaywallOverride = { paywallCount += 1 }

        fixture.bind.needsProForHostLimit = true
        await waitUntil("bind host-limit gate") {
            paywallCount == 1 && !fixture.bind.needsProForHostLimit
        }
    }

    private func makeFixture(
        editing: Host? = nil,
        secrets: HostSecrets = HostSecrets(
            password: nil,
            privateKey: nil,
            passphrase: nil
        ),
        isPro: Bool = false,
        secretWriter: AddHostViewController.SecretWriter? = nil,
        hostWriter: AddHostViewController.HostWriter? = nil,
        testRunner: AddHostViewController.TestRunner? = nil
    ) -> Fixture {
        let stem = "AddHostUIKitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: stem)!
        defaults.removePersistentDomain(forName: stem)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(stem, isDirectory: true)
        let store = HostStore(directory: directory, knownMirroredIDs: [])
        let entitlements = EntitlementStore(defaults: defaults, startStoreKit: false)
        entitlements.setDebugUnlocked(isPro)
        let bind = BindController()
        let controller = AddHostViewController(
            store: store,
            entitlements: entitlements,
            bind: bind,
            editing: editing,
            secretLoader: { _ in secrets },
            secretWriter: secretWriter,
            hostWriter: hostWriter,
            testRunner: testRunner
        )
        let navigation = UINavigationController(rootViewController: controller)
        return Fixture(
            controller: controller,
            navigation: navigation,
            entitlements: entitlements,
            bind: bind,
            defaults: defaults,
            defaultsDomain: stem,
            directory: directory
        )
    }

    private func clean(_ fixture: Fixture) {
        fixture.controller.prepareForRemoval()
        fixture.defaults.removePersistentDomain(forName: fixture.defaultsDomain)
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    private func enter(_ text: String, in field: UITextField) {
        field.text = text
        field.sendActions(for: .editingChanged)
    }

    private func send(_ item: UIBarButtonItem?) {
        guard let item, let action = item.action else {
            return XCTFail("Missing bar-button action")
        }
        UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
    }

    private func waitUntil(
        _ description: String,
        condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func sectionHeaders(in root: UIView) -> [String] {
        descendants(of: UIKitChassisLabel.self, in: root)
            .filter { $0.accessibilityTraits.contains(.header) }
            .compactMap(\.accessibilityLabel)
    }

    private func renderedText(in root: UIView) -> [String] {
        var result = descendants(of: UILabel.self, in: root).compactMap {
            $0.attributedText?.string ?? $0.text
        }
        result += descendants(of: UITextView.self, in: root).compactMap(\.text)
        return result
    }

    private func hasContentMaximumWidthConstraint(in root: UIView) -> Bool {
        allConstraints(in: root).contains { constraint in
            (constraint.firstItem as? UIStackView) != nil
                && constraint.firstAttribute == .width
                && constraint.relation == .lessThanOrEqual
                && constraint.constant == AddHostViewController.Metrics.contentMaximumWidth
        }
    }

    private func allConstraints(in view: UIView) -> [NSLayoutConstraint] {
        view.constraints + view.subviews.flatMap { allConstraints(in: $0) }
    }

    private func descendants<View: UIView>(of type: View.Type, in root: UIView) -> [View] {
        var result: [View] = []
        if let view = root as? View { result.append(view) }
        for child in root.subviews {
            result.append(contentsOf: descendants(of: type, in: child))
        }
        return result
    }

}
