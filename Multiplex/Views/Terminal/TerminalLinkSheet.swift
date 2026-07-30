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
///
/// Web links additionally carry a REACH row and the viewport action — the
/// inline browser. The reach verdict says which world the address lives in
/// (a pane runs on the host, so `localhost` there is the *host's* loopback),
/// and the loopback chip performs its rewrite in the open: `⌗ VIA DEVBOX`
/// says exactly what will be dialled.
struct TerminalLinkSheet: View {
    let link: TerminalLink
    /// The inline-browser offer for whatever address the sheet currently
    /// holds — asked per edit, because the target is editable and a typed
    /// change moves which world it reaches. nil keeps the sheet exactly as
    /// it always was (no viewport row, no chip).
    var viewportOffer: (TerminalLink) -> ViewportOffer? = { _ in nil }
    let onOpen: (TerminalLink) -> Void
    let onCopy: (String) -> Void
    var onOpenViewport: ((ViewportOffer) -> Void)?

    @Environment(\.dismiss) private var dismiss
    /// The target as the sheet shows it. Detection is a guess made from
    /// rendered rows — a wrapped line can glue a sentence's tail to the
    /// address below it — so the person gets the last word before anything
    /// opens. Everything below re-resolves from this, which keeps the
    /// allowlist and the host line honest about what an edit produced.
    @State private var text: String

    init(
        link: TerminalLink,
        viewportOffer: @escaping (TerminalLink) -> ViewportOffer? = { _ in nil },
        onOpen: @escaping (TerminalLink) -> Void,
        onCopy: @escaping (String) -> Void,
        onOpenViewport: ((ViewportOffer) -> Void)? = nil
    ) {
        self.link = link
        self.viewportOffer = viewportOffer
        self.onOpen = onOpen
        self.onCopy = onCopy
        self.onOpenViewport = onOpenViewport
        _text = State(initialValue: link.raw)
    }

    /// The edited target, or nil while the field holds nothing Multiplex can
    /// classify — the actions that need a link go quiet rather than acting
    /// on the pressed one behind the person's back.
    private var edited: TerminalLink? { TerminalLink.resolve(text) }
    private var viewport: ViewportOffer? { edited.flatMap(viewportOffer) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    TallyFormSection(sectionTitle, detail: detail) {
                        TallyFormRow {
                            VStack(alignment: .leading, spacing: 12) {
                                if let host = edited?.host {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ChassisLabel("HOST", size: 9, color: Theme.signal3)
                                        Text(host)
                                            .font(.mono(13, weight: .semibold))
                                            .foregroundStyle(Theme.signal)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                TerminalSheetEditableValueBox(
                                    label: "TARGET",
                                    value: $text,
                                    note: edited == nil
                                        ? "NOT AN ADDRESS MULTIPLEX CAN READ"
                                        : nil
                                )

                                if let viewport {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ChassisLabel("REACH", size: 9, color: Theme.signal3)
                                        Text(reachDescription(viewport))
                                            .font(.mono(10))
                                            .foregroundStyle(Theme.signal2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }

                                HStack(spacing: 10) {
                                    if let viewport, let onOpenViewport {
                                        ChassisChip(
                                            viewportChipLabel(viewport),
                                            prominent: true
                                        ) {
                                            onOpenViewport(viewport)
                                            dismiss()
                                        }
                                    }
                                    if let openable = edited, openable.openableURL != nil {
                                        ChassisChip(
                                            "OPEN",
                                            systemImage: "arrow.up.forward.app",
                                            prominent: viewport == nil || onOpenViewport == nil
                                        ) {
                                            onOpen(openable)
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
        edited?.openableURL == nil ? "Can't open link" : "Open link"
    }

    private var sectionTitle: String {
        if let viewport, onOpenViewport != nil {
            return switch viewport.reach {
            case .internet: "A public address"
            case .lan: "On this device's network"
            case .remoteLoopback:
                "Lives on \(viewport.viaHostName ?? "the host"), not this device"
            }
        }
        guard let edited else { return "Not a usable address" }
        return switch edited.kind {
        case .openable: "Leaves Multiplex"
        case .blockedScheme(let scheme): "\(scheme.uppercased()) links stay here"
        case .malformed: "Not a usable address"
        }
    }

    private var detail: String {
        if let viewport, onOpenViewport != nil {
            return switch viewport.reach {
            case .internet, .lan:
                "The viewport renders this address inside Multiplex; OPEN "
                    + "still hands it to the system browser. It came from the "
                    + "host — check the address above before opening."
            case .remoteLoopback:
                "localhost in a remote pane is the host's own loopback — an "
                    + "address this device can't dial. VIA aims the viewport "
                    + "at the address that already reaches the host; the "
                    + "server must listen beyond loopback (vite --host) to "
                    + "answer."
            }
        }
        guard let edited else {
            return "The field holds nothing Multiplex can open — a target "
                + "needs a web or mail address. Edit it, or copy the text "
                + "if it's still useful."
        }
        return switch edited.kind {
        case .openable:
            "This address came from the host, and a hyperlink's visible text "
                + "can differ from where it points — check the host above "
                + "before opening it outside Multiplex. The target is "
                + "editable when detection caught the wrong text."
        case .blockedScheme(let scheme):
            "Multiplex opens web and mail links only. A \(scheme): link from a "
                + "remote pane would act on this device, so it is shown rather "
                + "than followed — copy it if you want it elsewhere."
        case .malformed:
            "The text looked like a link but has no address Multiplex can "
                + "open. Copy it if it's still useful."
        }
    }

    private func viewportChipLabel(_ viewport: ViewportOffer) -> String {
        switch viewport.reach {
        case .internet, .lan:
            "⌗ VIEWPORT"
        case .remoteLoopback:
            "⌗ VIA \((viewport.viaHostName ?? "HOST").uppercased())"
        }
    }

    private func reachDescription(_ viewport: ViewportOffer) -> String {
        switch viewport.reach {
        case .internet:
            return "INTERNET — OPENS FROM THIS DEVICE"
        case .lan:
            return "LAN — DIALLED FROM THIS DEVICE, NETWORK PERMITTING"
        case .remoteLoopback:
            var rewritten = viewport.url.host() ?? ""
            if let port = viewport.url.port { rewritten += ":\(port)" }
            return "REMOTE LOOPBACK → REWRITES TO \(rewritten)"
        }
    }
}

/// The confirm sheets' boxed value — the resolved target in the mono data
/// voice on a screen inset. One spelling for the link sheet's TARGET and
/// the path sheet's PATH, so the two deliberate twins can't drift.
struct TerminalSheetValueBox: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ChassisLabel(label, size: 9, color: Theme.signal3)
            Text(value)
                .font(.mono(11))
                .foregroundStyle(Theme.signal2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.screen)
        .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
    }
}

/// The confirm sheets' editable target — the same screen well as
/// `TerminalSheetValueBox`, with the value as a real field.
///
/// Detection is a guess made from *rendered rows*, and a hard wrap leaves no
/// space at the seam: a sentence ending in `.` above a path or URL reaches
/// the matcher glued to it. The model trims what it can prove
/// (`TerminalPathTarget.strippingWrappedProseHead`); the rest is the
/// person's to fix here, before anything opens. Keyboard behavior is the
/// address kind: no autocorrection, no autocapitalization, no smart quotes —
/// a target is machine text.
struct TerminalSheetEditableValueBox: View {
    let label: String
    @Binding var value: String
    /// Caps note under the field when what it holds resolves to nothing —
    /// the actions go quiet, and this says why.
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChassisLabel(label, size: 9, color: Theme.signal3)
            TextField("", text: $value, axis: .vertical)
                .font(.mono(11))
                .foregroundStyle(Theme.signal)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .submitLabel(.done)
            if let note {
                ChassisLabel(note, size: 9, color: Theme.caution)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.screen)
        .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
    }
}

extension View {
    /// Presents `controller`'s pending link confirmation. Packaged as one
    /// modifier because `TerminalWindowRoot`'s body is already at the Swift
    /// type-checker's ceiling — an inline `.sheet(item:)` with its binding and
    /// action closures tips the whole chain over.
    ///
    /// `viewportHost` is the active tab's host record — it names the rewrite
    /// target for a remote-loopback address, so the offer is computed against
    /// the machine whose pane printed the URL. `openViewport` docks the
    /// confirmed page as a tab beside that pane.
    func terminalLinkConfirmation(
        for controller: TerminalSessionController?,
        viewportHost: Host? = nil,
        openViewport: ((ViewportOffer) -> Void)? = nil
    ) -> some View {
        let binding = Binding<TerminalLink?>(
            get: { controller?.pendingLink },
            set: { if $0 == nil { controller?.dismissPendingLink() } }
        )
        return sheet(item: binding) { link in
            TerminalLinkSheet(
                link: link,
                viewportOffer: { ViewportOffer.make(for: $0, host: viewportHost) },
                onOpen: { controller?.openConfirmedLink($0) },
                onCopy: { controller?.copyConfirmedTarget($0) },
                onOpenViewport: openViewport
            )
        }
    }

    /// The binding-backed spelling, for panes that confirm a link without a
    /// session controller (a viewport's refused navigation, a markdown
    /// link) — same sheet, same open/copy actions, no viewport row.
    func terminalLinkConfirmation(item: Binding<TerminalLink?>) -> some View {
        sheet(item: item) { link in
            TerminalLinkSheet(
                link: link,
                onOpen: { confirmed in
                    if let url = confirmed.openableURL { UIApplication.shared.open(url) }
                },
                onCopy: { UIPasteboard.general.string = $0 }
            )
        }
    }
}

#if DEBUG
#Preview("Openable") {
    TerminalLinkSheet(
        link: TerminalLink.resolve("https://multiplexterm.dev/docs/tmux")!,
        onOpen: { _ in },
        onCopy: { _ in }
    )
    .frame(width: 720, height: 640)
    .preferredColorScheme(.dark)
}

#Preview("Viewport LAN") {
    TerminalLinkSheet(
        link: TerminalLink.resolve("http://192.168.1.68:5173/")!,
        viewportOffer: { link in
            link.openableURL.map {
                ViewportOffer(url: $0, reach: .lan, viaHostName: nil)
            }
        },
        onOpen: { _ in },
        onCopy: { _ in },
        onOpenViewport: { _ in }
    )
    .frame(width: 720, height: 700)
    .preferredColorScheme(.dark)
}

#Preview("Viewport loopback") {
    TerminalLinkSheet(
        link: TerminalLink.resolve("http://localhost:5173/")!,
        viewportOffer: { _ in
            ViewportOffer(
                url: URL(string: "http://100.84.2.19:5173/")!,
                reach: .remoteLoopback,
                viaHostName: "devbox"
            )
        },
        onOpen: { _ in },
        onCopy: { _ in },
        onOpenViewport: { _ in }
    )
    .frame(width: 720, height: 700)
    .preferredColorScheme(.dark)
}

#Preview("Blocked") {
    TerminalLinkSheet(
        link: TerminalLink.resolve("file:///etc/shadow")!,
        onOpen: { _ in },
        onCopy: { _ in }
    )
    .frame(width: 720, height: 640)
    .preferredColorScheme(.dark)
}
#endif
