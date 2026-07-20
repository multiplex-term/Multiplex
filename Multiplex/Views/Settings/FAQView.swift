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
            .background(sheetGround.ignoresSafeArea())
            .navigationTitle("FAQ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #if !os(visionOS)
            .toolbarBackground(Theme.chassis, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
        }
    }

    @ViewBuilder
    private var sheetGround: some View {
        #if os(visionOS)
        Color.clear
        #else
        Theme.chassis
        #endif
    }
}

/// One FAQ entry as a Tally form section: the question is the section title,
/// the answer is prose, and an optional command sits on its own screen well
/// with a copy chip.
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
                    if let command = entry.command {
                        FAQCommandField(command: command)
                    }
                }
            }
        }
    }
}

/// A copyable command on a screen surface — monospace stays the data voice.
private struct FAQCommandField: View {
    let command: String

    @State private var copyCount = 0
    @State private var showsCopied = false

    var body: some View {
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

/// Static FAQ content. Questions render as compressed-caps section titles,
/// so keep them short enough for one line at phone-sheet width.
private struct FAQEntry: Identifiable {
    let id: String
    let question: String
    let answer: String
    var command: String?
    var postscript: String?

    static let all: [FAQEntry] = [
        FAQEntry(
            id: "claude-code-tmux-keychain",
            question: "Claude Code shows signed out in tmux",
            answer: "On a Mac host, Claude Code keeps its credentials in the "
                + "login keychain, and an SSH or tmux session never unlocks it — "
                + "no GUI login happened — so Claude Code starts as if you were "
                + "signed out even though your login is intact. Unlock the "
                + "keychain once inside the tmux session, then restart Claude "
                + "Code:",
            command: "security unlock-keychain ~/Library/Keychains/login.keychain-db",
            postscript: "The command prompts for that Mac account's login "
                + "password. The unlock holds until macOS locks the keychain "
                + "again — after a restart, or per the keychain's own lock "
                + "settings."
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
