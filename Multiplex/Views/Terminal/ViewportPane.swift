import SwiftUI
import WebKit

/// One viewport tab's surface: the page above, the TALLY rail below.
///
/// The page is screen content — it may be bright inside the dark chassis,
/// exactly like a light terminal theme. The rail keeps the confirmed
/// verdict visible for the life of the tab (monospace URL, host emphasized,
/// the REACH tag that admitted it) and carries the only controls a monitor
/// needs: back, reload/stop, the SYSTEM handoff, and CLOSE. A caution
/// hairline sweeps its top edge while loading — the rail's only motion,
/// never red.
struct ViewportPane: View {
    @Bindable var controller: ViewportController
    var contentSafeArea = EdgeInsets()
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.screen
                ViewportWebHost(controller: controller)
                if let failure = controller.failure {
                    failurePanel(failure)
                }
            }
            rail
        }
        .background(Theme.bezel)
        // A page may navigate to something the gate refuses to render
        // (mailto, a custom scheme). Same discipline as a pane press: the
        // target is shown and confirmed, never followed.
        .sheet(item: $controller.externalLink) { link in
            TerminalLinkSheet(
                link: link,
                onOpen: {
                    if let url = link.openableURL { UIApplication.shared.open(url) }
                },
                onCopy: { UIPasteboard.general.string = link.raw }
            )
        }
    }

    // MARK: Rail

    private var rail: some View {
        HStack(spacing: 9) {
            ChassisChip("", systemImage: "chevron.left") { controller.goBack() }
                .disabled(!controller.canGoBack)
                .opacity(controller.canGoBack ? 1 : 0.45)
                .accessibilityLabel("Back")
            ChassisChip(
                "",
                systemImage: controller.isLoading ? "xmark" : "arrow.clockwise"
            ) {
                controller.isLoading ? controller.stopLoading() : controller.reload()
            }
            .accessibilityLabel(controller.isLoading ? "Stop loading" : "Reload")
            urlReadout
            ChassisBadge(controller.offer.reachTag)
                .fixedSize()
                .accessibilityLabel("Reach: \(controller.offer.reachTag)")
            ChassisChip("SYSTEM") { controller.openInSystemBrowser() }
                .fixedSize()
                .accessibilityLabel("Open in the system browser")
            ChassisChip("CLOSE", prominent: true, action: close)
                .fixedSize()
                .accessibilityLabel("Close viewport")
        }
        .padding(.leading, 10 + contentSafeArea.leading)
        .padding(.trailing, 10 + contentSafeArea.trailing)
        .padding(.top, 8)
        .padding(.bottom, 8 + contentSafeArea.bottom)
        .background(Theme.bezel)
        .overlay(alignment: .top) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.bezelHi).frame(height: 1)
                if controller.isLoading {
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(Theme.caution)
                            .frame(
                                width: max(
                                    0,
                                    geometry.size.width * controller.progress
                                ),
                                height: 2
                            )
                    }
                    .frame(height: 2)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    /// Monospace readout, host bright, the rest dim — the identity voice.
    /// The address is data, not an omnibox: it is never editable in place,
    /// and a long press copies it.
    private var urlReadout: some View {
        Text(readoutText)
            .font(.mono(10))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button {
                    controller.copyURL()
                } label: {
                    Label("Copy Address", systemImage: "doc.on.doc")
                }
            }
            .accessibilityLabel(controller.displayURL.absoluteString)
    }

    private var readoutText: AttributedString {
        let url = controller.displayURL
        var host = AttributedString(url.host() ?? url.absoluteString)
        if let port = url.port { host += AttributedString(":\(port)") }
        host.foregroundColor = Theme.signal
        host.font = .mono(10, weight: .semibold)
        var rest = AttributedString(pathAndQuery(of: url))
        rest.foregroundColor = Theme.signal2
        return host + rest
    }

    private func pathAndQuery(of url: URL) -> String {
        var tail = url.path()
        if tail.isEmpty { tail = "/" }
        if let query = url.query() { tail += "?\(query)" }
        return tail
    }

    // MARK: Failure

    /// WebKit's blank error page never appears — the chassis says what
    /// happened and, when the address lives on the host's network, whose
    /// network that is.
    private func failurePanel(_ message: String) -> some View {
        VStack(spacing: 14) {
            TallyLamp(caption: "NO ROUTE", color: Theme.caution)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.signal2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let hint = reachHint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(Theme.signal3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            HStack(spacing: 12) {
                ChassisChip("RETRY", prominent: true) { controller.reload() }
                ChassisChip("SYSTEM") { controller.openInSystemBrowser() }
            }
            .padding(.top, 4)
        }
        .padding(30)
        .background(Theme.bezel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.bezelHi, lineWidth: 1))
        .padding(20)
    }

    private var reachHint: String? {
        switch controller.offer.reach {
        case .internet:
            return nil
        case .lan:
            return "This address lives on \(controller.hostName)'s network — "
                + "the device must share it to load the page."
        case .remoteLoopback:
            return "This page rides \(controller.hostName)'s own address. "
                + "The server must listen beyond loopback (vite --host, "
                + "-H 0.0.0.0) for anything to answer."
        }
    }
}

/// Adopts the controller-owned WKWebView the way `SwiftTermView` adopts its
/// terminal view: `removeFromSuperview` + re-pin, so a tab moving between
/// windows (merge/split) keeps the live page, its scroll position, and any
/// open sockets. The controller outlives every window the tab passes
/// through; this representable only hosts.
private struct ViewportWebHost: UIViewRepresentable {
    let controller: ViewportController

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        adopt(into: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if controller.webView.superview !== container {
            adopt(into: container)
        }
    }

    private func adopt(into container: UIView) {
        guard let webView = controller.webView else { return }
        webView.removeFromSuperview()
        container.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// The window chrome while a viewport tab is on screen — the UMD's viewport
/// face. A page needs none of the terminal's controls (keys, FILE, TMUX,
/// DETACH), so the row carries only what a monitor's frame owes the window:
/// DECK, the source label, MERGE (the road home for a split-out page), and
/// CLOSE. The rail below the page owns everything page-scoped.
struct ViewportUMD: View {
    enum Style {
        /// visionOS classic window's bottom ornament row.
        case regular
        /// The single-window shell's slim full-width top row.
        case shell
    }

    var title: String
    var mergeSources: [TerminalWorkspace.WindowEntry]
    var showDeck: () -> Void
    var merge: (UUID) -> Void
    var close: () -> Void
    var style: Style = .regular
    var deckControlLabel = "DECK"
    var contentSafeArea = EdgeInsets()

    @ViewBuilder
    var body: some View {
        switch style {
        case .regular: regularBar
        case .shell: shellBar
        }
    }

    private var regularBar: some View {
        HStack(spacing: 14) {
            ChassisChip("DECK", action: showDeck)
            divider
            ChassisLabel(title, size: 12)
            if !mergeSources.isEmpty {
                mergeMenu
            }
            divider
            ChassisChip("CLOSE", prominent: true, action: close)
                .accessibilityLabel("Close viewport")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Theme.bezel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.bezelHi, lineWidth: 1))
    }

    private var shellBar: some View {
        HStack(spacing: 9) {
            ChassisChip(deckControlLabel, action: showDeck)
                .fixedSize()
            ChassisLabel(title, size: 11)
                .layoutPriority(1)
            Spacer(minLength: 4)
            ChassisChip("CLOSE", prominent: true, action: close)
                .fixedSize()
                .accessibilityLabel("Close viewport")
        }
        .padding(.leading, 10 + contentSafeArea.leading)
        .padding(.trailing, 10 + contentSafeArea.trailing)
        .padding(.vertical, 8)
        .background(Theme.bezel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.bezelHi).frame(height: 1)
        }
    }

    private var mergeMenu: some View {
        Menu {
            ForEach(mergeSources) { entry in
                Button {
                    merge(entry.id)
                } label: {
                    Label(entry.label, systemImage: "macwindow")
                }
            }
        } label: {
            ChassisBadge("MERGE")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .chassisHover(2)
        .accessibilityLabel("Merge another window into this one")
    }

    private var divider: some View {
        Rectangle().fill(Theme.bezelHi).frame(width: 1, height: 18)
    }
}

#if DEBUG
#Preview("Viewport UMD") {
    VStack(spacing: 20) {
        ViewportUMD(
            title: "⌗ 5173 · devbox",
            mergeSources: [],
            showDeck: {},
            merge: { _ in },
            close: {}
        )
        ViewportUMD(
            title: "⌗ 5173 · devbox",
            mergeSources: [],
            showDeck: {},
            merge: { _ in },
            close: {},
            style: .shell,
            deckControlLabel: "WALL"
        )
        .frame(width: 500)
    }
    .padding()
    .background(Theme.chassis)
}
#endif
