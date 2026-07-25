import SwiftUI

/// Confirmation for a link activated in a terminal pane.
///
/// The pane never opens a link straight from the gesture, and this sheet is
/// why: the target is remote output. An OSC 8 hyperlink's label is chosen
/// independently of its destination, so the text the user pressed proves
/// nothing — this surface renders the *resolved target* and names the host on
/// its own line, which is what defeats both a mislabelled hyperlink and a
/// userinfo-padded authority (`https://github.com@evil.example/x`).
///
/// Blocked and malformed targets still get here. Saying "Multiplex won't open
/// a `file:` link" and offering COPY is a better answer than a press that
/// appears to do nothing.
struct TerminalLinkSheet: View {
    let link: TerminalLink
    let onOpen: () -> Void
    let onCopy: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    TallyFormSection(sectionTitle, detail: detail) {
                        TallyFormRow {
                            VStack(alignment: .leading, spacing: 12) {
                                if let host = link.host {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ChassisLabel("HOST", size: 9, color: Theme.signal3)
                                        Text(host)
                                            .font(.mono(13, weight: .semibold))
                                            .foregroundStyle(Theme.signal)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    ChassisLabel("TARGET", size: 9, color: Theme.signal3)
                                    Text(link.raw)
                                        .font(.mono(11))
                                        .foregroundStyle(Theme.signal2)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.screen)
                                .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))

                                HStack(spacing: 10) {
                                    if link.openableURL != nil {
                                        ChassisChip(
                                            "OPEN",
                                            systemImage: "arrow.up.forward.app",
                                            prominent: true
                                        ) {
                                            onOpen()
                                            dismiss()
                                        }
                                    }
                                    ChassisChip("COPY", systemImage: "doc.on.doc") {
                                        onCopy()
                                        dismiss()
                                    }
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
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ChassisSheetTitle(navigationTitle)
                ToolbarItem(placement: .cancellationAction) {
                    ChassisBarButton("Cancel") { dismiss() }
                }
            }
        }
    }

    private var navigationTitle: String {
        link.openableURL == nil ? "Can't open link" : "Open link"
    }

    private var sectionTitle: String {
        switch link.kind {
        case .openable: "Leaves Multiplex"
        case .blockedScheme(let scheme): "\(scheme.uppercased()) links stay here"
        case .malformed: "Not a usable address"
        }
    }

    private var detail: String {
        switch link.kind {
        case .openable:
            "This address came from the host, and a hyperlink's visible text "
                + "can differ from where it points — check the host above "
                + "before opening it outside Multiplex."
        case .blockedScheme(let scheme):
            "Multiplex opens web and mail links only. A \(scheme): link from a "
                + "remote pane would act on this device, so it is shown rather "
                + "than followed — copy it if you want it elsewhere."
        case .malformed:
            "The text looked like a link but has no address Multiplex can "
                + "open. Copy it if it's still useful."
        }
    }
}

extension View {
    /// Presents `controller`'s pending link confirmation. Packaged as one
    /// modifier because `TerminalWindowRoot`'s body is already at the Swift
    /// type-checker's ceiling — an inline `.sheet(item:)` with its binding and
    /// action closures tips the whole chain over.
    func terminalLinkConfirmation(
        for controller: TerminalSessionController?
    ) -> some View {
        let binding = Binding<TerminalLink?>(
            get: { controller?.pendingLink },
            set: { if $0 == nil { controller?.dismissPendingLink() } }
        )
        return sheet(item: binding) { link in
            TerminalLinkSheet(
                link: link,
                onOpen: { controller?.openPendingLink() },
                onCopy: { controller?.copyPendingLink() }
            )
        }
    }
}

#if DEBUG
#Preview("Openable") {
    TerminalLinkSheet(
        link: TerminalLink.resolve("https://multiplexterm.dev/docs/tmux")!,
        onOpen: {},
        onCopy: {}
    )
    .frame(width: 720, height: 640)
    .preferredColorScheme(.dark)
}

#Preview("Blocked") {
    TerminalLinkSheet(
        link: TerminalLink.resolve("file:///etc/shadow")!,
        onOpen: {},
        onCopy: {}
    )
    .frame(width: 720, height: 640)
    .preferredColorScheme(.dark)
}
#endif
