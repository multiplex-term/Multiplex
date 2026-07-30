import SwiftUI

/// Confirmation for a filesystem path activated in a terminal pane — the
/// file viewer's twin of `TerminalLinkSheet`, holding the same line: pane
/// bytes are untrusted, so the resolved target is shown before anything
/// opens. The ▤ VIEW chip docks a read-only viewer tab; COPY stays the
/// answer for a path wanted elsewhere.
struct TerminalFilePathSheet: View {
    let target: TerminalPathTarget
    let hostName: String
    let onView: (TerminalPathTarget) -> Void
    let onCopy: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    TallyFormSection(sectionTitle, detail: detail) {
                        TallyFormRow {
                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ChassisLabel("HOST", size: 9, color: Theme.signal3)
                                    Text(hostName)
                                        .font(.mono(13, weight: .semibold))
                                        .foregroundStyle(Theme.signal)
                                }
                                TerminalSheetValueBox(label: "PATH", value: target.path)

                                if let line = target.line {
                                    HStack(spacing: 8) {
                                        ChassisLabel("LINE", size: 9, color: Theme.signal3)
                                        Text("\(line)")
                                            .font(.mono(11))
                                            .foregroundStyle(Theme.signal2)
                                    }
                                }

                                HStack(spacing: 10) {
                                    ChassisChip("▤ VIEW", prominent: true) {
                                        onView(target)
                                        dismiss()
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
            .navigationTitle("View file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ChassisSheetTitle("View file")
                ToolbarItem(placement: .cancellationAction) {
                    ChassisBarButton("Cancel") { dismiss() }
                }
            }
        }
    }

    private var sectionTitle: String {
        switch target.base {
        case .absolute: "A path on \(hostName)"
        case .home: "In \(hostName)'s home"
        case .workingDirectory: "Relative to the pane's directory"
        }
    }

    private var detail: String {
        var text = "VIEW opens it read-only in the file viewer, beside this "
            + "session — nothing runs, nothing is written."
        if target.base == .workingDirectory {
            text += " The path resolves against the pane's current directory."
        }
        return text
    }
}

extension View {
    /// Presents `controller`'s pending path confirmation — the sibling of
    /// `terminalLinkConfirmation`, packaged the same way for the same
    /// type-checker reason.
    func terminalPathConfirmation(
        for controller: TerminalSessionController?,
        hostName: String?,
        openViewer: ((TerminalPathTarget) -> Void)?
    ) -> some View {
        let binding = Binding<TerminalPathTarget?>(
            get: { controller?.pendingPath },
            set: { if $0 == nil { controller?.dismissPendingPath() } }
        )
        return sheet(item: binding) { target in
            TerminalFilePathSheet(
                target: target,
                hostName: hostName ?? "the host",
                onView: { openViewer?($0) },
                onCopy: { controller?.copyPendingPath() }
            )
        }
    }
}

#if DEBUG
#Preview("Path press") {
    TerminalFilePathSheet(
        target: TerminalPathTarget.resolve("Multiplex/Services/TmuxProbe.swift:42")!,
        hostName: "devbox",
        onView: { _ in },
        onCopy: {}
    )
    .frame(width: 720, height: 620)
    .preferredColorScheme(.dark)
}
#endif
