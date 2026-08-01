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

    func testCommandIdentityIncludesBothLabelAndCommand() {
        let command = HostGuide.Command(label: "macOS", command: "brew install tmux")
        XCTAssertEqual(command.id, "macOSbrew install tmux")
    }

    func testKeychainTipRequestSnapshotsHostSessionsAndUsesHostIdentity() {
        let id = UUID()
        var host = Host(
            id: id,
            name: "studio",
            hostname: "studio.local",
            username: "jhen"
        )
        var sessions = ["main", "agent"]

        let request = KeychainTipRequest(host: host, sessionNames: sessions)
        host.name = "changed later"
        sessions.removeAll()

        XCTAssertEqual(request.id, id)
        XCTAssertEqual(request.host.name, "studio")
        XCTAssertEqual(request.sessionNames, ["main", "agent"])
    }
}
