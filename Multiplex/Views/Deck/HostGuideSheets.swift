import SwiftUI
import UIKit

/// Copyable host-setup guidance shared by the deck's tip surfaces and the
/// FAQ, so the instructions can never drift apart between them: the NO TMUX
/// tile's install guide and the rail's KEYCHAIN LOCKED unlock tip.
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
}

/// A copyable command on a screen surface — monospace stays the data voice.
/// The optional caps label names the platform/variant a command applies to.
struct CopyableCommandField: View {
    var label = ""
    let command: String

    @State private var copyCount = 0
    @State private var showsCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !label.isEmpty {
                ChassisLabel(label, size: 9, color: Theme.signal3)
            }
            HStack(alignment: .top, spacing: 10) {
                Text(command)
                    .font(.mono(10))
                    .foregroundStyle(Theme.signal)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                Button {
                    UIPasteboard.general.string = command
                    copyCount += 1
                } label: {
                    ChassisBadge(
                        showsCopied ? "COPIED" : "COPY",
                        systemImage: showsCopied ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.plain)
                .chassisHover(2)
                .accessibilityLabel("Copy command")
            }
        }
        .padding(10)
        .background(Theme.screen)
        .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
        .task(id: copyCount) {
            guard copyCount > 0 else { return }
            showsCopied = true
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled { showsCopied = false }
        }
    }
}

/// The NO TMUX tile's INSTALL GUIDE dialog: why the wall needs tmux, the
/// per-OS one-liners, and the reminder that a plain shell already works.
struct TmuxInstallSheet: View {
    let host: Host

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    TallyFormSection(
                        "The deck runs on tmux",
                        detail: "The deck re-probes every few seconds — "
                            + "session tiles light up as soon as tmux is on "
                            + "the host. Homebrew and /usr/local installs "
                            + "are already on the probe's PATH."
                    ) {
                        TallyFormRow {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(intro)
                                    .font(.ui(11))
                                    .foregroundStyle(Theme.signal)
                                    .fixedSize(horizontal: false, vertical: true)
                                ForEach(HostGuide.tmuxInstall) { entry in
                                    CopyableCommandField(
                                        label: entry.label,
                                        command: entry.command
                                    )
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 560)
                .padding(18)
                .frame(maxWidth: .infinity)
            }
            .chassisSheetGround()
            .navigationTitle("Install tmux")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ChassisSheetTitle("Install tmux")
                ToolbarItem(placement: .confirmationAction) {
                    ChassisBarButton("Done") { dismiss() }
                }
            }
        }
    }

    private var intro: String {
        "Sessions, live tiles, and attach all come from a tmux server on "
            + "each host, and \(host.name) doesn't have tmux yet. You can "
            + "still use a plain shell — the SHELL chip on the host's rail "
            + "opens one. For the full deck, install tmux on the host:"
    }
}

/// A pressed KEYCHAIN LOCKED status, snapshotted at tap time (same
/// discipline as the deck's `UnreachableNotice`) so a background probe
/// clearing the notice can't yank the sheet's content mid-read. Shared by
/// the deck rail and the terminal window's status chip.
struct KeychainTipRequest: Identifiable {
    let host: Host
    let sessionNames: [String]

    var id: UUID { host.id }
}

/// The KEYCHAIN LOCKED tip sheet: Claude Code looks signed out on a Mac
/// host because SSH sessions never unlock the login keychain that holds its
/// credentials. Shown only after `KeychainLockCheck` confirmed the lock.
struct KeychainUnlockSheet: View {
    let host: Host
    let sessionNames: [String]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    TallyFormSection(
                        "Claude Code shows signed out",
                        detail: "The command prompts for that Mac account's "
                            + "login password. The unlock holds until macOS "
                            + "locks the keychain again — after a restart, "
                            + "or per the keychain's own lock settings."
                    ) {
                        TallyFormRow {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(intro)
                                    .font(.ui(11))
                                    .foregroundStyle(Theme.signal)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !sessionNames.isEmpty {
                                    Text("Detected in: "
                                        + sessionNames.joined(separator: " · "))
                                        .font(.mono(10))
                                        .foregroundStyle(Theme.signal3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                CopyableCommandField(
                                    command: HostGuide.keychainUnlock.command
                                )
                            }
                        }
                    }
                }
                .frame(maxWidth: 560)
                .padding(18)
                .frame(maxWidth: .infinity)
            }
            .chassisSheetGround()
            .navigationTitle("Keychain locked")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ChassisSheetTitle("Keychain locked")
                ToolbarItem(placement: .confirmationAction) {
                    ChassisBarButton("Done") { dismiss() }
                }
            }
        }
    }

    private var intro: String {
        "Claude Code on \(host.name) is waiting at its sign-in screen, but "
            + "the stored login is probably intact: on a Mac, Claude Code "
            + "keeps its credentials in the login keychain, and an SSH or "
            + "tmux session never unlocks it — no GUI login happened. "
            + "Unlock it once in any shell on \(host.name), then restart "
            + "Claude Code:"
    }
}

#if DEBUG
#Preview("Install tmux") {
    TmuxInstallSheet(
        host: Host(name: "devbox", hostname: "127.0.0.1", username: "dev")
    )
    .frame(width: 720, height: 640)
    .preferredColorScheme(.dark)
}

#Preview("Keychain locked") {
    KeychainUnlockSheet(
        host: Host(name: "studio", hostname: "studio.local", username: "jhen"),
        sessionNames: ["main", "agent"]
    )
    .frame(width: 720, height: 640)
    .preferredColorScheme(.dark)
}
#endif
