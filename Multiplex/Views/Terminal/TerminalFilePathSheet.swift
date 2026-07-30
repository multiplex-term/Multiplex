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
    let onCopy: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The path as the sheet shows it, editable. Detection reads *rendered
    /// rows*, and a hard wrap glues a sentence's tail to the path beneath it
    /// with no space at the seam; the model strips what it can prove and the
    /// person fixes the rest here, before a viewer tab is docked at the
    /// wrong file.
    @State private var text: String

    init(
        target: TerminalPathTarget,
        hostName: String,
        onView: @escaping (TerminalPathTarget) -> Void,
        onCopy: @escaping (String) -> Void
    ) {
        self.target = target
        self.hostName = hostName
        self.onView = onView
        self.onCopy = onCopy
        _text = State(initialValue: Self.editorText(for: target))
    }

    /// What the field starts with: the classified path, plus the `:line`
    /// suffix if the press carried one — the spelling the viewer accepts
    /// back, so an untouched field re-resolves to the same target.
    private static func editorText(for target: TerminalPathTarget) -> String {
        guard let line = target.line else { return target.path }
        return "\(target.path):\(line)"
    }

    /// The edited target, or nil while the field holds nothing that
    /// classifies — VIEW goes quiet rather than opening the pressed path
    /// behind the person's back.
    private var edited: TerminalPathTarget? { TerminalPathTarget.resolve(text) }

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
                                TerminalSheetEditableValueBox(
                                    label: "PATH",
                                    value: $text,
                                    note: edited == nil
                                        ? "NOT A PATH MULTIPLEX CAN READ"
                                        : nil
                                )

                                if let line = edited?.line {
                                    HStack(spacing: 8) {
                                        ChassisLabel("LINE", size: 9, color: Theme.signal3)
                                        Text("\(line)")
                                            .font(.mono(11))
                                            .foregroundStyle(Theme.signal2)
                                    }
                                }

                                HStack(spacing: 10) {
                                    if let edited {
                                        ChassisChip("▤ VIEW", prominent: true) {
                                            onView(edited)
                                            dismiss()
                                        }
                                    }
                                    ChassisChip("COPY", systemImage: "doc.on.doc") {
                                        onCopy(text)
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
        switch edited?.base {
        case .absolute: "A path on \(hostName)"
        case .home: "In \(hostName)'s home"
        case .workingDirectory: "Relative to the pane's directory"
        case nil: "Not a usable path"
        }
    }

    private var detail: String {
        guard let edited else {
            return "The field holds nothing the viewer can resolve — a path "
                + "needs a directory in it, and no spaces. Edit it, or copy "
                + "the text if it's still useful."
        }
        var text = "VIEW opens it read-only in the file viewer, beside this "
            + "session — nothing runs, nothing is written. The path is "
            + "editable when detection caught the wrong text."
        if edited.base == .workingDirectory {
            text += " It resolves against the pane's current directory."
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
                onCopy: { controller?.copyConfirmedTarget($0) }
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
        onCopy: { _ in }
    )
    .frame(width: 720, height: 620)
    .preferredColorScheme(.dark)
}
#endif
