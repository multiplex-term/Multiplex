import XCTest
@testable import Multiplex

final class MoshBootstrapTests: XCTestCase {
    // MARK: - Connect-line parsing

    func testParsesRealServerLine() {
        // Captured from mosh-server 1.4.0.
        let output = """
        \r

        mosh-server (mosh 1.4.0) [build mosh 1.4.0]
        MOSH CONNECT 60001 bmCuIRYJHSUF4dcm/qJt2w
        [mosh-server detached, pid = 37250]
        """
        let parsed = MoshBootstrap.parseConnect(output)
        XCTAssertEqual(parsed?.port, 60001)
        XCTAssertEqual(parsed?.key, MoshKey(base64: "bmCuIRYJHSUF4dcm/qJt2w"))
    }

    func testRejectsMalformedConnectLines() {
        XCTAssertNil(MoshBootstrap.parseConnect("MOSH CONNECT 60001")) // no key
        XCTAssertNil(MoshBootstrap.parseConnect("MOSH CONNECT abc bmCuIRYJHSUF4dcm/qJt2w")) // bad port
        XCTAssertNil(MoshBootstrap.parseConnect("MOSH CONNECT 0 bmCuIRYJHSUF4dcm/qJt2w")) // port 0
        XCTAssertNil(MoshBootstrap.parseConnect("MOSH CONNECT 60001 tooshortkey")) // bad key
        XCTAssertNil(MoshBootstrap.parseConnect("random noise")) // nothing
    }

    // MARK: - Command construction

    func testCommandDefaults() {
        let command = MoshBootstrap.command(
            serverPath: nil, ports: nil, locale: "en_US.UTF-8",
            remoteCommand: "tmux new-session -A -s 'main'"
        )
        XCTAssertTrue(command.contains("mosh-server new -c 256 -s"))
        XCTAssertTrue(command.contains("-l LANG=en_US.UTF-8"))
        XCTAssertTrue(command.contains("-- tmux new-session -A -s 'main'"))
        XCTAssertTrue(command.contains("MOSH_SERVER_NETWORK_TMOUT=3600"))
        XCTAssertTrue(command.hasSuffix("2>&1"))
        // Widens PATH like the tmux probe.
        XCTAssertTrue(command.contains("/opt/homebrew/bin"))
        XCTAssertFalse(command.contains("-p ")) // no ports by default
    }

    func testCommandHonorsCustomPathAndPorts() {
        let command = MoshBootstrap.command(
            serverPath: "/opt/mosh/bin/mosh-server", ports: "60000:61000",
            locale: "C.UTF-8", remoteCommand: nil
        )
        XCTAssertTrue(command.contains("'/opt/mosh/bin/mosh-server' new"))
        XCTAssertTrue(command.contains("-p '60000:61000'"))
        XCTAssertTrue(command.contains("-l LANG=C.UTF-8"))
        XCTAssertFalse(command.contains("--")) // no wrapped command → login shell
    }

    func testCommandCanDropSSHBind() {
        let command = MoshBootstrap.command(
            serverPath: nil, ports: nil, locale: "en_US.UTF-8",
            remoteCommand: nil, bindToSSHAddress: false
        )
        XCTAssertFalse(command.contains(" -s "))
    }

    // MARK: - Failure classification

    func testDetectsLocaleAndSSHFailures() {
        XCTAssertTrue(MoshBootstrap.mentionsLocaleFailure(
            "mosh-server needs a UTF-8 native locale to run."))
        XCTAssertTrue(MoshBootstrap.mentionsSSHConnectionFailure(
            "The SSH_CONNECTION environment variable is not set."))
        XCTAssertFalse(MoshBootstrap.mentionsLocaleFailure("MOSH CONNECT 60001 key"))
    }

    func testFailureDetailIsClippedAndDropsNoise() {
        let detail = MoshBootstrap.failureDetail("""
        mosh-server (mosh 1.4.0) [build mosh 1.4.0]
        bash: mosh-server: command not found
        [mosh-server detached, pid = 1]
        """)
        XCTAssertTrue(detail.contains("command not found"))
        XCTAssertFalse(detail.contains("mosh-server detached"))
        XCTAssertEqual(MoshBootstrap.failureDetail("   \n  "), "no output")
    }

    // MARK: - Resolution

    func testResolvesLoopbackLiteral() {
        let v4 = MoshBootstrap.resolve("127.0.0.1")
        XCTAssertEqual(v4.first?.ip, "127.0.0.1")
        XCTAssertEqual(v4.first?.isIPv6, false)

        let v6 = MoshBootstrap.resolve("::1")
        XCTAssertEqual(v6.first?.ip, "::1")
        XCTAssertEqual(v6.first?.isIPv6, true)
    }

    func testTargetBudgetMatchesAddressFamily() {
        let v4 = MoshBootstrap.Target(ip: "1.2.3.4", port: 60001, key: MoshKey(base64: "bmCuIRYJHSUF4dcm/qJt2w")!, isIPv6: false)
        let v6 = MoshBootstrap.Target(ip: "::1", port: 60001, key: MoshKey(base64: "bmCuIRYJHSUF4dcm/qJt2w")!, isIPv6: true)
        XCTAssertEqual(v4.datagramBudget, 1252 - 28)
        XCTAssertEqual(v6.datagramBudget, 1216 - 28)
    }

    func testRejectsEmbeddedTailscaleBeforeBootstrap() async {
        var host = Host(
            name: "devbox",
            hostname: "unresolvable.invalid",
            username: "dev"
        )
        host.useMosh = true
        host.useTailscale = true

        do {
            _ = try await MoshBootstrap.start(
                host: host,
                secrets: HostSecrets(
                    password: nil,
                    privateKey: nil,
                    passphrase: nil
                ),
                remoteCommand: nil
            )
            XCTFail("Expected the mutually exclusive transports to fail")
        } catch let error as MoshBootstrapError {
            guard case .tailscaleIncompatible = error else {
                return XCTFail("Expected tailscale incompatibility, got \(error)")
            }
            XCTAssertEqual(
                error.userMessage(host: host),
                "mosh can't run over the embedded Tailscale connection — turn one of them off."
            )
        } catch {
            XCTFail("Expected MoshBootstrapError, got \(error)")
        }
    }
}
