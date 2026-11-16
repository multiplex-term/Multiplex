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

    /// herdr installs, for hosts on the herdr backend — the two roads
    /// herdr.dev/docs/install leads with (verified 2026-08-01; its manual
    /// road lands in `~/.local/bin`, already on the probe PATH). Homebrew
    /// leads because it also handles upgrades.
    static let herdrInstall: [Command] = [
        Command(label: "Homebrew", command: "brew install herdr"),
        Command(
            label: String(localized: "Or, macOS or Linux"),
            command: "curl -fsSL https://herdr.dev/install.sh | sh"),
    ]

    /// The guide set for one host's backend — a dead tile's INSTALL GUIDE
    /// must speak the multiplexer the host is actually configured for.
    static func multiplexerInstall(for backend: Host.SessionBackend) -> [Command] {
        switch backend {
        case .tmux: tmuxInstall
        case .herdr: herdrInstall
        // Rex is never the primary: no dead tile and no failed mint speaks
        // for it, so there is no install road to hand over. (Its packages
        // also come from a per-distribution repository, not one line.)
        case .rex: []
        }
    }

    /// A mint that failed because the backend's binary isn't on the host —
    /// said the same way wherever New Session can be pressed (deck sheet,
    /// a window's + TAB, an external action), because all three fail for
    /// the one reason and the fix is the same command. It names the
    /// install road and the settings escape hatch; the probe-PATH detail
    /// stays with the tile's INSTALL GUIDE, which has room for it.
    static func backendMissingMessage(
        _ backend: Host.SessionBackend, hostName: String
    ) -> String {
        let install = multiplexerInstall(for: backend).first?.command
        var message = String(localized: """
            \(backend.rawValue) isn’t installed on \(hostName), so there’s \
            nothing to create the session with.
            """)
        if let install {
            message += String(localized: " Install it there (\(install)), ")
        } else {
            message += String(localized: " Install it there, ")
        }
        return message + String(
            localized: "or change this host’s backend in Host Settings.")
    }

    /// A mint that failed because the backend's server isn't running and
    /// Multiplex won't start it — Rex, whose server belongs to the Rex app
    /// on the host (`RexProbe`). Says what to do there instead of sending
    /// the user after the connection, which is fine.
    static func serverNotRunningMessage(
        _ backend: Host.SessionBackend, hostName: String
    ) -> String {
        // The product's name, not the binary's: this is about an app the
        // user opens, where `backendMissingMessage` is about a command.
        let name = backend == .rex ? "Rex" : backend.rawValue
        return String(localized: """
            No \(name) server is running on \(hostName), and Multiplex doesn’t \
            start one. Start \(name) there, then try again.
            """)
    }

    /// Why a default install needs no further host setup: both probes
    /// prepend these directories (`TmuxProbe.pathPrefix`,
    /// `HerdrProbe.pathPrefix`). Shared so the tile's INSTALL GUIDE and the
    /// FAQ cannot drift apart on what the probe can already find.
    static func probePathDetail(for backend: Host.SessionBackend) -> String {
        switch backend {
        case .tmux:
            String(localized:
                "Homebrew and /usr/local installs are already on the probe's PATH.")
        case .herdr:
            String(localized: """
                Homebrew, ~/.local/bin, and ~/.cargo/bin installs are already on \
                the probe's PATH.
                """)
        case .rex:
            String(localized: """
                Package installs, ~/.local/bin, and the Rex app on a Mac are \
                already on the probe's PATH.
                """)
        }
    }

    /// What showing Rex sessions means, said wherever they can be switched
    /// on — the rail's offer confirmation and Host Settings' Backend detail
    /// — so neither promises more than the app does: one terminal per tab,
    /// and new sessions only where a Rex server is already running, which
    /// is also why it is missing from the default's choices right below.
    static let rexSessionsNote = String(localized: """
        A Rex tile opens one terminal: the one its session is showing. \
        New Rex sessions need Rex already running on the host, so Rex is \
        never the default.
        """)

    /// What opting a host into a SECOND backend costs — the measured fact
    /// behind asking at all rather than escalating silently (a full second
    /// probe is ~25 KB/tick for herdr against tmux's ~3.5 KB; see
    /// `BackendDiscovery`). Shared because it is said in two places that
    /// must agree: the deck rail's offer confirmation, which is the press
    /// that spends it, and Host Settings' Backend detail, which is where it
    /// can be undone. A stale copy in either one misstates the trade.
    static let secondBackendCost = String(
        localized: "roughly doubles what this host fetches on every deck refresh")

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
            label: String(localized: "Or, macOS or Linux"),
            command: "curl -fsSL https://multiplexterm.dev/install-mpx-cli | sh"),
    ]

    /// The one command the whole flow turns on.
    static let mpxBind = Command(
        label: String(localized: "Then run"), command: "mpx bind")

    /// The clipboard is opt-in in the CLI — a bind payload is
    /// credential-grade, and over Universal Clipboard it would land on every
    /// signed-in device. So Paste can only work if the machine was asked to
    /// copy, and the app has to say so rather than let someone press a
    /// button that cannot do anything.
    static let mpxBindCopy = Command(
        label: String(localized: "For paste"), command: "mpx bind --copy")
}
