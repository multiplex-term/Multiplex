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
    /// The inline-browser offer for this link, when it is a web page and the
    /// tab's host is known. nil keeps the sheet exactly as it always was.
    var viewport: ViewportOffer?
    let onOpen: () -> Void
    let onCopy: () -> Void
    var onOpenViewport: ((ViewportOffer) -> Void)?

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
                                    if link.openableURL != nil {
                                        ChassisChip(
                                            "OPEN",
                                            systemImage: "arrow.up.forward.app",
                                            prominent: viewport == nil || onOpenViewport == nil
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
        if let viewport, onOpenViewport != nil {
            return switch viewport.reach {
            case .internet: "A public address"
            case .lan: "On this device's network"
            case .remoteLoopback:
                "Lives on \(viewport.viaHostName ?? "the host"), not this device"
            }
        }
        return switch link.kind {
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
        return switch link.kind {
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
                viewport: ViewportOffer.make(for: link, host: viewportHost),
                onOpen: { controller?.openPendingLink() },
                onCopy: { controller?.copyPendingLink() },
                onOpenViewport: openViewport
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

#Preview("Viewport LAN") {
    TerminalLinkSheet(
        link: TerminalLink.resolve("http://192.168.1.68:5173/")!,
        viewport: ViewportOffer(
            url: URL(string: "http://192.168.1.68:5173/")!,
            reach: .lan,
            viaHostName: nil
        ),
        onOpen: {},
        onCopy: {},
        onOpenViewport: { _ in }
    )
    .frame(width: 720, height: 700)
    .preferredColorScheme(.dark)
}

#Preview("Viewport loopback") {
    TerminalLinkSheet(
        link: TerminalLink.resolve("http://localhost:5173/")!,
        viewport: ViewportOffer(
            url: URL(string: "http://100.84.2.19:5173/")!,
            reach: .remoteLoopback,
            viaHostName: "devbox"
        ),
        onOpen: {},
        onCopy: {},
        onOpenViewport: { _ in }
    )
    .frame(width: 720, height: 700)
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
