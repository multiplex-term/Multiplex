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
        let message = HostTest.failureMessage(for: HostTest.DeadlineExceeded(), host: host())
        XCTAssertTrue(message.contains("No answer"))
        XCTAssertTrue(message.contains("devbox.example.com"))
    }

    func testUnknownDetailKeepsTheRawError() {
        let message = HostTest.connectFailureMessage("frobnication reversed", host: host())
        XCTAssertTrue(message.contains("Couldn't connect to devbox.example.com"))
        XCTAssertTrue(message.contains("frobnication reversed"))
    }
}
