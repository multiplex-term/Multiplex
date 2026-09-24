import XCTest
@testable import Multiplex

final class HostGuideTests: XCTestCase {
    func testTmuxInstallCatalogKeepsExactLabelsCommandsAndOrder() {
        XCTAssertEqual(
            HostGuide.tmuxInstall.map { [$0.label, $0.command] },
            [
                ["macOS (Homebrew)", "brew install tmux"],
                ["Debian / Ubuntu", "sudo apt install tmux"],
                ["Fedora / RHEL", "sudo dnf install tmux"],
                ["Arch", "sudo pacman -S tmux"],
            ]
        )
    }

    func testHerdrInstallCatalogAndBackendSelection() {
        XCTAssertEqual(
            HostGuide.herdrInstall.map { [$0.label, $0.command] },
            [
                ["Homebrew", "brew install herdr"],
                [
                    "Or, macOS or Linux",
                    "curl -fsSL https://herdr.dev/install.sh | sh",
                ],
            ]
        )
        XCTAssertEqual(
            HostGuide.multiplexerInstall(for: .tmux), HostGuide.tmuxInstall)
        XCTAssertEqual(
            HostGuide.multiplexerInstall(for: .herdr), HostGuide.herdrInstall)
    }

    /// One sentence for both the dead tile's INSTALL GUIDE and the FAQ, so
    /// neither can promise a probe PATH the other denies.
    func testProbePathDetailNamesEachBackendsInstallHomes() {
        XCTAssertEqual(
            HostGuide.probePathDetail(for: .tmux),
            "Homebrew and /usr/local installs are already on the probe's PATH."
        )
        XCTAssertEqual(
            HostGuide.probePathDetail(for: .herdr),
            "Homebrew, ~/.local/bin, and ~/.cargo/bin installs are already on "
                + "the probe's PATH."
        )
    }

    func testKeychainUnlockCommandKeepsExactShellLine() {
        XCTAssertEqual(HostGuide.keychainUnlock.label, "")
        XCTAssertEqual(
            HostGuide.keychainUnlock.command,
            "security unlock-keychain ~/Library/Keychains/login.keychain-db"
        )
    }

    func testBindCatalogKeepsExactClipboardGuidance() {
        XCTAssertEqual(
            HostGuide.mpxInstall.map { [$0.label, $0.command] },
            [
                ["Homebrew", "brew install multiplex-term/tap/mpx"],
                [
                    "Or, macOS or Linux",
                    "curl -fsSL https://multiplexterm.dev/install-mpx-cli | sh",
                ],
            ]
        )
        XCTAssertEqual(HostGuide.mpxBind.label, "Then run")
        XCTAssertEqual(HostGuide.mpxBind.command, "mpx bind")
        XCTAssertEqual(HostGuide.mpxBindCopy.label, "For paste")
        XCTAssertEqual(HostGuide.mpxBindCopy.command, "mpx bind --copy")
    }

    /// The mint-failure copy names the backend, the host, the install
    /// command, and the way out — a New Session press that fails because
    /// the multiplexer isn't there must not read as a connection problem.
    func testBackendMissingMessageNamesTheBackendAndItsInstall() {
        let herdr = HostGuide.backendMissingMessage(.herdr, hostName: "devbox")
        XCTAssertTrue(herdr.hasPrefix("herdr isn’t installed on devbox"), herdr)
        XCTAssertTrue(herdr.contains("brew install herdr"), herdr)
        XCTAssertTrue(herdr.contains("Host Settings"), herdr)
        let tmux = HostGuide.backendMissingMessage(.tmux, hostName: "devbox")
        XCTAssertTrue(tmux.contains("brew install tmux"), tmux)
    }

    func testCommandIdentityIncludesBothLabelAndCommand() {
        let command = HostGuide.Command(label: "macOS", command: "brew install tmux")
        XCTAssertEqual(command.id, "macOSbrew install tmux")
    }
}
