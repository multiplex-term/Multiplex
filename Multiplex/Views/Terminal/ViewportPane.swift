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

    /// The rail's address editor, presented as a top contextual bar — the
    /// same slot Copy Mode and the jump bar use. Top on purpose: the pane
    /// opts out of SwiftUI keyboard avoidance for the terminal's sake, so a
    /// docked keyboard would cover an editor living in the bottom rail.
    @State private var editingAddress = false
    @State private var addressDraft = ""
    @State private var addressRejected = false
    @FocusState private var addressFieldFocused: Bool
    /// Clearing wipes the store every viewport shares — destructive, so it
    /// confirms (the deck's delete-action policy).
    @State private var confirmingClearBrowsingData = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.screen
                ViewportWebHost(controller: controller)
                if let failure = controller.failure {
                    failurePanel(failure)
                }
            }
            .overlay(alignment: .top) {
                if editingAddress {
                    addressEditor
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                }
            }
            rail
        }
        .background(Theme.bezel)
        .alert(
            "Clear Browsing Data",
            isPresented: $confirmingClearBrowsingData
        ) {
            Button("Clear", role: .destructive) {
                controller.clearBrowsingData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Clears cookies, caches, and site storage for every "
                    + "viewport page — dev-server logins included. "
                    + "This page reloads signed out."
            )
        }
        // A page may navigate to something the gate refuses to render
        // (mailto, a custom scheme). Same discipline as a pane press: the
        // target is shown and confirmed, never followed.
        .terminalLinkConfirmation(item: $controller.externalLink)
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
            ChassisBadge(controller.railTag)
                .fixedSize()
                .accessibilityLabel("Reach: \(controller.railTag)")
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
    /// Tap opens the address editor in the pane's top-bar slot; a long
    /// press copies. The readout itself never becomes a field — the rail
    /// stays a monitor's frame, and the editor gets the keyboard-safe slot.
    private var urlReadout: some View {
        Button {
            beginEditingAddress()
        } label: {
            Text(readoutText)
                .font(.mono(10))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chassisHover(2)
        .contextMenu {
            Button {
                controller.copyURL()
            } label: {
                Label("Copy Address", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) {
                confirmingClearBrowsingData = true
            } label: {
                Label("Clear Browsing Data…", systemImage: "trash")
            }
        }
        .accessibilityLabel(controller.displayURL.absoluteString)
        .accessibilityHint("Edits the address")
    }

    // MARK: Address editor

    private func beginEditingAddress() {
        addressDraft = controller.displayURL.absoluteString
        addressRejected = false
        editingAddress = true
        addressFieldFocused = true
    }

    private func submitAddress() {
        if controller.navigate(toTyped: addressDraft) {
            editingAddress = false
        } else {
            addressRejected = true
        }
    }

    private var addressEditor: some View {
        HStack(spacing: 12) {
            ChassisLabel("ADDRESS", size: 9, color: Theme.signal3)
            TextField("host:port or https://…", text: $addressDraft)
                .font(.mono(12))
                .foregroundStyle(Theme.signal)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($addressFieldFocused)
                .onSubmit(submitAddress)
                .onChange(of: addressDraft) { addressRejected = false }
                .frame(minWidth: 160, maxWidth: 420)
            if addressRejected {
                ChassisLabel("WEB ADDRESSES ONLY", size: 8, color: Theme.caution)
                    .fixedSize()
            }
            ChassisChip("GO", prominent: true, action: submitAddress)
                .fixedSize()
            ChassisChip("CANCEL") { editingAddress = false }
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Theme.bezel,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.bezelHi, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
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
        ChassisPanel(caption: "NO ROUTE") {
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
        .padding(20)
    }

    private var reachHint: String? {
        switch controller.currentReach {
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
    /// The file viewer shares this monitor face; only the close wording
    /// differs.
    var closeAccessibilityLabel = "Close viewport"

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
                .accessibilityLabel(closeAccessibilityLabel)
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
                .accessibilityLabel(closeAccessibilityLabel)
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
