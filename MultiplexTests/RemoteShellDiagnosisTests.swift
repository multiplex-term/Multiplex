import XCTest
@testable import Multiplex

final class RemoteShellDiagnosisTests: XCTestCase {
    private let host = Host(name: "devbox", hostname: "devbox.example.com", username: "dev")

    func testCommandParsesWithoutThePOSIXPrelude() {
        XCTAssertEqual(RemoteShellDiagnosis.command, "echo \"$SHELL\"")
        XCTAssertFalse(RemoteShellDiagnosis.command.contains("PATH="))
        XCTAssertFalse(RemoteShellDiagnosis.command.contains(";"))
    }

    func testShellNameUsesFirstNonemptyTrimmedLine() {
        XCTAssertEqual(RemoteShellDiagnosis.shellName(from: "/usr/bin/fish\n"), "fish")
        XCTAssertEqual(RemoteShellDiagnosis.shellName(from: "/bin/zsh"), "zsh")
        XCTAssertEqual(RemoteShellDiagnosis.shellName(from: "\n \t\n  /bin/bash \r\n/bin/fish\n"), "bash")
        XCTAssertEqual(RemoteShellDiagnosis.shellName(from: "fish"), "fish")
        XCTAssertNil(RemoteShellDiagnosis.shellName(from: ""))
        XCTAssertNil(RemoteShellDiagnosis.shellName(from: " \t\r\n  \n"))
    }

    func testOddPathsUsePOSIXComponentsRatherThanURLOrWindowsRules() {
        XCTAssertEqual(RemoteShellDiagnosis.shellName(from: "C:/shells/nu\n"), "nu")
        XCTAssertEqual(RemoteShellDiagnosis.shellName(from: #"C:\shells\fish.exe"#), #"C:\shells\fish.exe"#)
        XCTAssertEqual(RemoteShellDiagnosis.shellName(from: "/opt/odd shells/my shell"), "my shell")
    }

    func testNonPOSIXShellNamesTheFixInsteadOfTheExitCode() {
        for shell in ["fish", "tcsh", "csh", "nu"] {
            let rejection = RemoteShellDiagnosis.Rejection(
                exitCode: shell == "fish" ? 127 : 1,
                stderrHead: "parse error\nmore detail",
                shellName: shell
            )
            XCTAssertEqual(rejection.message(host: host), """
                devbox's login shell is \(shell), so Multiplex runs its commands through sh — \
                check that sh and printf work on the host (exit \(shell == "fish" ? 127 : 1)).
                """)
        }
    }

    func testEveryPOSIXShellUsesTheRejectionWording() {
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ash", "ksh", "mksh", "pdksh", "yash", "busybox"]
        XCTAssertEqual(RemoteShellDiagnosis.posixShells, shells)
        for shell in shells {
            let rejection = RemoteShellDiagnosis.Rejection(exitCode: 127, stderrHead: "", shellName: shell)
            XCTAssertEqual(
                rejection.message(host: host),
                "devbox's shell (\(shell)) rejected Multiplex's commands (exit 127)"
            )
        }
    }

    func testPOSIXRejectionShowsOnlyTheFirstStderrLine() {
        let rejection = RemoteShellDiagnosis.Rejection(
            exitCode: 127, stderrHead: "  restricted command\nsecond line\n", shellName: "zsh")
        XCTAssertEqual(
            rejection.message(host: host),
            "devbox's shell (zsh) rejected Multiplex's commands (exit 127): restricted command"
        )
    }

    func testUnknownShellShowsOnlyTheFirstStderrLine() {
        let rejection = RemoteShellDiagnosis.Rejection(
            exitCode: 1, stderrHead: "\n  Permission denied\nsecond line\n", shellName: nil)
        XCTAssertEqual(
            rejection.message(host: host),
            "devbox rejected Multiplex's commands (exit 1): Permission denied"
        )
    }

    func testEmptyStderrOmitsTheColonForKnownAndUnknownShells() {
        for stderr in ["", " \n\t"] {
            for shell: String? in ["zsh", nil] {
                let rejection = RemoteShellDiagnosis.Rejection(exitCode: 127, stderrHead: stderr, shellName: shell)
                let subject = shell == nil ? "devbox" : "devbox's shell (zsh)"
                XCTAssertEqual(rejection.message(host: host), "\(subject) rejected Multiplex's commands (exit 127)")
            }
        }
    }

    func testExitCodeIsNotLocaleGrouped() {
        let rejection = RemoteShellDiagnosis.Rejection(exitCode: 1234, stderrHead: "", shellName: nil)
        XCTAssertEqual(rejection.message(host: host), "devbox rejected Multiplex's commands (exit 1234)")
    }

    func testRejectionEqualityRetainsTheDiagnosisAndOriginalFailure() {
        let rejection = RemoteShellDiagnosis.Rejection(exitCode: 127, stderrHead: "parse error", shellName: "fish")
        XCTAssertEqual(rejection, .init(exitCode: 127, stderrHead: "parse error", shellName: "fish"))
        XCTAssertNotEqual(rejection, .init(exitCode: 1, stderrHead: "parse error", shellName: "fish"))
        XCTAssertNotEqual(rejection, .init(exitCode: 127, stderrHead: "other error", shellName: "fish"))
        XCTAssertNotEqual(rejection, .init(exitCode: 127, stderrHead: "parse error", shellName: nil))
    }
}
