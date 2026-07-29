import XCTest
@testable import Multiplex

/// The Test Connection button's pure parts: the tool-sweep command, its
/// parser, and the failure wording (matched against real Citadel/NIO error
/// shapes — the classifier is substring-based on purpose).
final class HostTestTests: XCTestCase {
    private func host(
        auth: Host.AuthMethod = .password, useMosh: Bool = false, moshServerPath: String? = nil
    ) -> Host {
        var host = Host(name: "devbox", hostname: "devbox.example.com", username: "dev")
        host.authMethod = auth
        host.useMosh = useMosh
        host.moshServerPath = moshServerPath
        return host
    }

    // MARK: Tool sweep

    func testCheckCommandLooksForTmuxAndExitsZero() {
        let command = HostTest.checkCommand(for: host())
        XCTAssertTrue(command.contains("command -v tmux"))
        XCTAssertTrue(command.contains("MPXT_TMUX_OK"))
        XCTAssertFalse(command.contains("mosh"))
        // Citadel throws on a non-zero exit — "tool missing" must read as a
        // report line, never a failed connection.
        XCTAssertTrue(command.hasSuffix("true"))
    }

    func testCheckCommandChecksMoshServerAtConfiguredPath() {
        let plain = HostTest.checkCommand(for: host(useMosh: true))
        XCTAssertTrue(plain.contains("command -v 'mosh-server'"))

        let pathed = HostTest.checkCommand(
            for: host(useMosh: true, moshServerPath: "/opt/local/bin/mosh-server"))
        XCTAssertTrue(pathed.contains("command -v '/opt/local/bin/mosh-server'"))
    }

    func testParseReport() {
        XCTAssertEqual(
            HostTest.parseReport("MPXT_TMUX_OK\n", checksMosh: false),
            HostTest.Report(tmuxFound: true, moshServerFound: nil))
        XCTAssertEqual(
            HostTest.parseReport("MPXT_TMUX_MISSING\nMPXT_MOSH_OK\n", checksMosh: true),
            HostTest.Report(tmuxFound: false, moshServerFound: true))
        XCTAssertEqual(
            HostTest.parseReport("garbage\n", checksMosh: true),
            HostTest.Report(tmuxFound: false, moshServerFound: false))
    }

    // MARK: Failure wording

    func testMissingCredentialsNameTheMissingSecret() {
        XCTAssertEqual(
            HostTest.failureMessage(for: SSHConnectionError.missingCredentials, host: host()),
            "Enter a password first.")
        XCTAssertEqual(
            HostTest.failureMessage(
                for: SSHConnectionError.missingCredentials, host: host(auth: .privateKey)),
            "Paste a private key first.")
    }

    func testEncryptedKeyFailuresAskForThePassphrase() {
        XCTAssertEqual(
            HostTest.failureMessage(
                for: SSHConnectionError.keyPassphraseRequired,
                host: host(auth: .privateKey)
            ),
            "This private key is encrypted. Enter its passphrase above."
        )
        XCTAssertEqual(
            HostTest.failureMessage(
                for: SSHConnectionError.incorrectKeyPassphrase,
                host: host(auth: .privateKey)
            ),
            "That passphrase didn't unlock the private key. Try again."
        )
        XCTAssertEqual(
            SSHConnectionError.keyPassphraseRequired.keyPassphraseReason,
            .required
        )
        XCTAssertEqual(
            SSHConnectionError.incorrectKeyPassphrase.keyPassphraseReason,
            .incorrect
        )
    }

    // MARK: OpenSSH envelope

    func testOpenSSHEnvelopeDetectsEncryptedAndPlainKeys() {
        XCTAssertEqual(
            OpenSSHPrivateKeyEnvelope.encryption(in: keyEnvelope(cipher: "aes256-ctr")),
            .encrypted
        )
        XCTAssertEqual(
            OpenSSHPrivateKeyEnvelope.encryption(in: keyEnvelope(cipher: "none")),
            .unencrypted
        )
        XCTAssertNil(OpenSSHPrivateKeyEnvelope.encryption(in: "not a private key"))
    }

    func testAuthenticationBuilderUnlocksAnEncryptedED25519Key() {
        let encryptedKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBQRAFCo9
        /vv0icX60s6O6UAAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIBrez0rdYqROdkIA
        qvSrLoYFO1KVEidE4wclxivVKMbmAAAAoA9dkA6h2tAtANBP9RzyKvgrw5JKVJLVHfvZRQ
        8d3ttvy7WOs15y8lL/SdHiCyRukkKOPRd02zqx5g6WSmXZ0dKho/aMMO+58cIxsbCmMePT
        HaJvuQjIx6DIEoQyq83rQeVngk5rgvgou2jgHy/35C1AHtUysH4DIcltmrU3rvMF8i2GL4
        Od3cZL5cIOQVsmAZS6t3oL+GVeVOMFCqGFxjc=
        -----END OPENSSH PRIVATE KEY-----
        """
        let keyHost = host(auth: .privateKey)

        XCTAssertThrowsError(try SSHConnection.makeAuthenticationMethod(
            host: keyHost,
            secrets: HostSecrets(password: nil, privateKey: encryptedKey, passphrase: nil)
        )) { error in
            guard case SSHConnectionError.keyPassphraseRequired = error else {
                return XCTFail("Expected passphrase-required, got \(error)")
            }
        }
        XCTAssertThrowsError(try SSHConnection.makeAuthenticationMethod(
            host: keyHost,
            secrets: HostSecrets(
                password: nil,
                privateKey: encryptedKey,
                passphrase: "wrong"
            )
        )) { error in
            guard case SSHConnectionError.incorrectKeyPassphrase = error else {
                return XCTFail("Expected incorrect-passphrase, got \(error)")
            }
        }
        XCTAssertNoThrow(try SSHConnection.makeAuthenticationMethod(
            host: keyHost,
            secrets: HostSecrets(
                password: nil,
                privateKey: encryptedKey,
                passphrase: "example"
            )
        ))
    }

    func testProcessOnlyPassphraseOverridesAStaleKeychainValue() {
        let hostID = UUID()
        defer { SSHKeyPassphraseSession.forget(for: hostID) }
        let before = SSHKeyPassphraseSession.snapshot(for: hostID)

        SSHKeyPassphraseSession.accept("new answer", for: hostID, saveToICloud: false)

        let after = SSHKeyPassphraseSession.snapshot(for: hostID)
        XCTAssertGreaterThan(after.revision, before.revision)
        XCTAssertEqual(after.value, .value("new answer"))
        XCTAssertEqual(
            HostSecrets(password: nil, privateKey: nil, passphrase: "stale")
                .applyingSessionPassphrase(for: hostID)
                .passphrase,
            "new answer"
        )
    }

    private func keyEnvelope(cipher: String) -> String {
        var data = Data("openssh-key-v1\0".utf8)
        let length = UInt32(cipher.utf8.count)
        data.append(UInt8((length >> 24) & 0xff))
        data.append(UInt8((length >> 16) & 0xff))
        data.append(UInt8((length >> 8) & 0xff))
        data.append(UInt8(length & 0xff))
        data.append(contentsOf: cipher.utf8)
        return """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(data.base64EncodedString())
        -----END OPENSSH PRIVATE KEY-----
        """
    }

    func testAuthenticationFailureBlamesCredentialsNotTransport() {
        // Citadel: SSHClientError.allAuthenticationOptionsFailed / the
        // NIOSSH userAuthenticationFailure event both describe with
        // "authentication".
        let message = HostTest.connectFailureMessage(
            "allAuthenticationOptionsFailed", host: host())
        XCTAssertTrue(message.contains("check the user name and password"))

        let keyMessage = HostTest.connectFailureMessage(
            "allAuthenticationOptionsFailed", host: host(auth: .privateKey))
        XCTAssertTrue(keyMessage.contains("authorized_keys"))
    }

    func testConnectionRefusedNamesThePort() {
        var refused = host()
        refused.port = 2222
        let message = HostTest.connectFailureMessage(
            "NIOConnectionError: Connection refused (errno: 61)", host: refused)
        XCTAssertTrue(message.contains("port 2222"))
        XCTAssertTrue(message.contains("SSH server"))
    }

    func testDNSFailureSuggestsCheckingAddress() {
        // NIO's connection error wraps getaddrinfo results as dnsAError /
        // dnsAAAAError.
        let message = HostTest.connectFailureMessage(
            "NIOConnectionError(host: \"devbox.example.com\", dnsAError: ...)", host: host())
        XCTAssertTrue(message.contains("Couldn't find"))
        XCTAssertTrue(message.contains("devbox.example.com"))
    }

    func testDeadlineFailureMentionsReachability() {
        let message = HostTest.failureMessage(for: DeadlineExceeded(), host: host())
        XCTAssertTrue(message.contains("No answer"))
        XCTAssertTrue(message.contains("devbox.example.com"))
    }

    func testUnknownDetailKeepsTheRawError() {
        let message = HostTest.connectFailureMessage("frobnication reversed", host: host())
        XCTAssertTrue(message.contains("Couldn't connect to devbox.example.com"))
        XCTAssertTrue(message.contains("frobnication reversed"))
    }
}
