import Foundation

/// Copyable host-setup guidance shared by deck tips, FAQ, and bind surfaces.
/// It is deliberately framework-neutral: these are commands and captions, not
/// presentation, so UIKit and any future non-UI consumer share one source.
enum HostGuide {
    struct Command: Identifiable, Hashable {
        var label = ""
        var command: String

        var id: String { label + command }
    }

    /// Per-OS tmux installs. The probe already appends Homebrew//usr/local
    /// to PATH (`TmuxProbe.pathPrefix`), so a default install location
    /// lights the wall with no further host setup.
    static let tmuxInstall: [Command] = [
        Command(label: "macOS (Homebrew)", command: "brew install tmux"),
        Command(label: "Debian / Ubuntu", command: "sudo apt install tmux"),
        Command(label: "Fedora / RHEL", command: "sudo dnf install tmux"),
        Command(label: "Arch", command: "sudo pacman -S tmux"),
    ]

    /// The macOS locked-keychain fix (see `KeychainLockCheck`): unlock once
    /// in any shell on the host, then restart the signed-out agent.
    static let keychainUnlock = Command(
        command: "security unlock-keychain ~/Library/Keychains/login.keychain-db")

    /// Installing the companion CLI on the machine being bound. These are
    /// typed on a *remote* machine, so they exist to be copied out of the
    /// app — into a terminal, a note, a message — never run here.
    ///
    /// Both lines cover both platforms, which is why neither is labelled by
    /// one. The script was Linux-only in the first pass; plenty of machines
    /// worth binding are Macs reached over SSH with no Homebrew on them, and
    /// the release ships darwin archives regardless. Homebrew leads because
    /// it also handles upgrades.
    static let mpxInstall: [Command] = [
        Command(
            label: "Homebrew",
            command: "brew install multiplex-term/tap/mpx"),
        Command(
            label: "Or, macOS or Linux",
            command: "curl -fsSL https://multiplexterm.dev/install-mpx-cli | sh"),
    ]

    /// The one command the whole flow turns on.
    static let mpxBind = Command(label: "Then run", command: "mpx bind")

    /// The clipboard is opt-in in the CLI — a bind payload is
    /// credential-grade, and over Universal Clipboard it would land on every
    /// signed-in device. So Paste can only work if the machine was asked to
    /// copy, and the app has to say so rather than let someone press a
    /// button that cannot do anything.
    static let mpxBindCopy = Command(
        label: "For paste", command: "mpx bind --copy")
}
