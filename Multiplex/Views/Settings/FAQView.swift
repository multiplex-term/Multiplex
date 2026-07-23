import SwiftUI
import UIKit

/// Frequently asked questions, opened from the deck's FAQ chip. Static
/// troubleshooting notes — append new entries to `FAQEntry.all`.
struct FAQView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    ForEach(FAQEntry.all) { entry in
                        FAQEntryCard(entry: entry)
                    }
                }
                .frame(maxWidth: 680)
                .padding(18)
                .frame(maxWidth: .infinity)
            }
            .chassisSheetGround()
            .navigationTitle("FAQ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ChassisSheetTitle("FAQ")
                ToolbarItem(placement: .confirmationAction) {
                    ChassisBarButton("Done") { dismiss() }
                }
            }
        }
    }
}

/// One FAQ entry as a Tally form section: the question is the section title,
/// the answer is prose, and each command sits on its own screen well with a
/// copy chip (`CopyableCommandField` — shared with the deck's guide sheets).
private struct FAQEntryCard: View {
    let entry: FAQEntry

    var body: some View {
        TallyFormSection(entry.question, detail: entry.postscript) {
            TallyFormRow {
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.answer)
                        .font(.ui(11))
                        .foregroundStyle(Theme.signal)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(entry.commands) { command in
                        CopyableCommandField(
                            label: command.label,
                            command: command.command
                        )
                    }
                }
            }
        }
    }
}

/// Static FAQ content. Questions render as compressed-caps section titles,
/// so keep them short enough for one line at phone-sheet width. Commands
/// shared with a deck tip surface live in `HostGuide` so they can't drift.
private struct FAQEntry: Identifiable {
    let id: String
    let question: String
    let answer: String
    var commands: [HostGuide.Command] = []
    var postscript: String?

    static let all: [FAQEntry] = [
        FAQEntry(
            id: "host-needs-tmux",
            question: "A host shows no tmux on the deck",
            answer: "The deck is built around a tmux server on each host — "
                + "sessions, live tiles, and attach all come from it. A host "
                + "without tmux still works as a plain shell (the SHELL chip "
                + "on its rail), it just has no session tiles. To get the "
                + "full deck, install tmux on the host:",
            commands: HostGuide.tmuxInstall,
            postscript: "The deck re-probes every few seconds and finds tmux "
                + "as soon as it lands — Homebrew and /usr/local installs "
                + "are already on the probe's PATH."
        ),
        FAQEntry(
            id: "claude-code-tmux-keychain",
            question: "Claude Code shows signed out in tmux",
            answer: "On a Mac host, Claude Code keeps its credentials in the "
                + "login keychain, and an SSH or tmux session never unlocks it — "
                + "no GUI login happened — so Claude Code starts as if you were "
                + "signed out even though your login is intact. Unlock the "
                + "keychain once inside the tmux session, then restart Claude "
                + "Code:",
            commands: [HostGuide.keychainUnlock],
            postscript: "The command prompts for that Mac account's login "
                + "password. The unlock holds until macOS locks the keychain "
                + "again — after a restart, or per the keychain's own lock "
                + "settings. When the deck detects this state it also points "
                + "here: the host's rail reads KEYCHAIN LOCKED."
        )
    ]
}

#if DEBUG
#Preview("FAQ") {
    FAQView()
        .frame(width: 720, height: 640)
        .preferredColorScheme(.dark)
}
#endif
