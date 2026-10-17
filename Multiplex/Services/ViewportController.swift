import Network
import Observation
import UIKit
import WebKit

/// One viewport tab's state: the WKWebView it strongly owns (so the live page
/// re-parents across merge/split exactly the way a terminal's SwiftTerm view
/// does), the load/history telemetry the rail shows, and the navigation gate.
///
/// The gate re-applies the app's link discipline per navigation: a page may
/// hop http/https freely, but every other scheme is cancelled — `multiplex:`
/// can never be navigated into, and an allowlisted external target (mailto)
/// is re-presented through the same `TerminalLinkSheet` confirmation a pane
/// press gets, never followed directly. The viewport has no script bridge and
/// no send path into any terminal; it is a monitor, not an input surface.
///
/// An AGENT tab (`agent != nil`, opened by `AgentBrowserService` for
/// `mpx browser`) is the same pane plus: helpers in an isolated content
/// world the page cannot reach (still no message handler — the page gets no
/// bridge either way), the host's own cookie jar
/// (`WKWebsiteDataStore(forIdentifier: host.id)`, never the user's), and its
/// `Agent.route` — through the host's proxy (shipping), or the DEBUG device
/// route, where navigation also passes `AgentBrowserAddressPolicy`.
///
/// Lifetime is the process, on purpose: controllers live in
/// `TerminalWorkspace` only, are created before their tab enters any route,
/// and are never persisted — the no-persistence rule ("summoned, not
/// restored") falls out of their absence after a relaunch.
@MainActor
@Observable
final class ViewportController: AuxiliaryPaneController {
    let tabID: UUID
    /// The confirmation that admitted this page.
    let offer: ViewportOffer
    /// Snapshot of the source host — the tether label and the rewrite
    /// target for addresses typed into the rail. A value copy on purpose:
    /// like a terminal's connection, the viewport keeps the record it was
    /// opened against.
    private let host: Host
    /// The source host's display name — the viewport's tether label.
    var hostName: String { host.name }

    /// What makes a viewport an agent tab.
    struct Agent {
        enum Route {
            /// Through the host (`AgentBrowserProxy`): the data store's proxy,
            /// and the device-side forward a host loopback URL needs before
            /// it loads (false when the port is busy).
            case host(ProxyConfiguration, forwardLoopback: @MainActor (URL) async -> Bool)
            /// DEBUG only: from the device's own network.
            case device
        }

        /// The agent's name for the tab (`t1`, `t2`, …).
        var handle: String
        /// Required content rules: the loopback guard on the host route,
        /// the private-network block on the device route.
        var ruleList: WKContentRuleList
        var route: Route
        /// Called once when the tab closes for real — forwards must not
        /// outlive a host's last agent tab.
        var onClose: @MainActor () -> Void
    }

    /// Non-nil for a tab `mpx browser` opened and drives.
    let agent: Agent?

    @ObservationIgnored private(set) var webView: WKWebView!
    @ObservationIgnored private var bridge: ViewportWebBridge!
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private(set) var currentURL: URL?
    private(set) var pageTitle: String?
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var canGoBack = false
    /// Where the page currently lives, kept honest across typed addresses
    /// and in-page navigation — the rail tag and the failure panel's hint
    /// both read this, never the stale admission.
    private(set) var currentReach: ViewportReach
    /// The last URL this controller was *asked* to load (admission or rail
    /// edit) — the reload target while nothing has committed yet.
    private(set) var lastRequestedURL: URL
    /// A load that ended in an error the user should see — the TALLY panel
    /// renders it with the reach verdict, instead of WebKit's blank page.
    private(set) var failure: String?
    /// A navigation the gate refused but the link discipline can explain:
    /// the pane presents the same confirmation sheet a terminal press gets.
    var externalLink: TerminalLink?

    /// The rail's compact verdict for the page on screen.
    var railTag: String {
        agent == nil ? reachTag : "AGENT · " + reachTag
    }

    private var reachTag: String {
        switch currentReach {
        case .internet: "NET"
        case .lan: "LAN"
        case .remoteLoopback: "VIA \(hostName.uppercased())"
        }
    }

    init(tabID: UUID, offer: ViewportOffer, host: Host, agent: Agent? = nil) {
        self.tabID = tabID
        self.offer = offer
        self.host = host
        self.agent = agent
        self.currentURL = offer.url
        self.currentReach = offer.reach
        self.lastRequestedURL = offer.url

        let configuration = WKWebViewConfiguration()
        // App-scoped and persistent (never shared with Safari): a dev
        // server's login survives reload. No user scripts, no message
        // handlers — pages get no bridge into the app.
        configuration.websiteDataStore = .default()
        if let agent {
            Self.configureForAgent(configuration, agent: agent, hostID: host.id)
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        if agent != nil { webView.isInspectable = true }
        #endif
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        self.webView = webView

        let bridge = ViewportWebBridge(controller: self)
        self.bridge = bridge
        webView.navigationDelegate = bridge
        webView.uiDelegate = bridge

        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncTelemetry() }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncTelemetry() }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncTelemetry() }
            },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncTelemetry() }
            },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncTelemetry() }
            },
        ]

        // An agent tab's service loads it once its store is prepared (the
        // forwards' cookie must be in the tab's own session first).
        if agent == nil { webView.load(URLRequest(url: offer.url)) }
    }

    private func syncTelemetry() {
        guard let webView else { return }
        progress = webView.estimatedProgress
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        if let url = webView.url {
            currentURL = url
            // In-page navigation can move the page between worlds (a LAN
            // dev page linking out to docs); the tag follows. A loopback
            // classification here is the rewrite's own address (a host
            // dialled by loopback) — VIA stays the honest word for it.
            currentReach = ViewportReach.classify(url) ?? currentReach
        }
        pageTitle = webView.title?.isEmpty == false ? webView.title : nil
    }

    /// The rail's readout: current host emphasized by the view; falls back
    /// to the confirmed offer before the first commit.
    var displayURL: URL { currentURL ?? offer.url }

    var tabLabel: String { TerminalRoute.viewportLabel(displayURL.absoluteString, agent: agent != nil) }

    var routeMode: TerminalRoute.Mode { .viewport(urlString: displayURL.absoluteString) }

    func reload() {
        failure = nil
        if webView.url == nil {
            // Nothing has committed yet (the first load, or a typed address
            // that failed before commit) — retry what was asked for.
            webView.load(URLRequest(url: lastRequestedURL))
        } else {
            webView.reload()
        }
    }

    /// The rail's address editor: navigate to what the user typed, or say
    /// no. Same admit path as a confirmed link (web schemes only, scheme
    /// defaulted by reach, loopback rewritten via the host) — typing is the
    /// user's own intent, so no sheet stands between.
    @discardableResult
    func navigate(toTyped input: String) -> Bool {
        guard let typed = ViewportOffer.fromTypedInput(input, host: host)
        else { return false }
        load(typed)
        return true
    }

    /// Loads an admitted offer (a typed address, or an agent's navigation).
    func load(_ offer: ViewportOffer) {
        failure = nil
        lastRequestedURL = offer.url
        currentReach = offer.reach
        currentURL = offer.url
        webView.load(URLRequest(url: offer.url))
    }

    /// Swaps an agent tab's content rules (the loopback guard follows the
    /// host's forwards). Applies to loads from now on.
    func applyAgentRuleList(_ list: WKContentRuleList) {
        let content = webView.configuration.userContentController
        content.removeAllContentRuleLists()
        content.add(list)
    }

    func stopLoading() {
        webView.stopLoading()
    }

    func goBack() {
        guard webView.canGoBack else { return }
        failure = nil
        webView.goBack()
    }

    /// SYSTEM — the handoff to the real browser, same as the link sheet's
    /// OPEN. Always available; the viewport never traps a page.
    func openInSystemBrowser() {
        UIApplication.shared.open(displayURL)
    }

    func copyURL() {
        UIPasteboard.general.string = displayURL.absoluteString
    }

    /// Wipes the viewport's browsing state — cookies, caches, and site
    /// storage. The data store is app-scoped and shared by every viewport
    /// tab (that sharing is what keeps a dev login alive across pages), so
    /// clearing is necessarily global; the confirmation that leads here
    /// says so. Reloads this page afterward, so the effect is visible
    /// exactly where it was asked for — signed out, cold cache.
    func clearBrowsingData() {
        let store = webView.configuration.websiteDataStore
        store.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// Tab is closing for real (never called on a move): stop work and break
    /// the delegate cycle so the web process can wind down.
    func shutdown() {
        agent?.onClose()
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    // Bridge callbacks -----------------------------------------------------

    fileprivate func navigationStarted() {
        failure = nil
        syncTelemetry()
    }

    fileprivate func navigationFailed(_ error: Error) {
        let nsError = error as NSError
        // A cancelled load (stop, or a policy decline mid-provisional) is
        // not a fault the panel should announce.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        // Legacy WebKit domain, code 102: "frame load interrupted by policy
        // change" — the gate above declining a navigation, not a fault.
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        failure = nsError.localizedDescription
        syncTelemetry()
    }

    /// The per-navigation gate. Web schemes render; `about:` covers blank
    /// initial frames; everything else is cancelled here and — when the link
    /// discipline has something to say about it — surfaced for confirmation.
    fileprivate func policy(for url: URL?) -> WKNavigationActionPolicy {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if case .device = agent?.route, !AgentBrowserAddressPolicy.admits(url, host: host) {
            failure = AgentBrowserAddressPolicy.blockedError(url).message
            return .cancel
        }
        if scheme == "http" || scheme == "https" || scheme == "about" {
            return .allow
        }
        if let link = TerminalLink.resolve(url.absoluteString) {
            externalLink = link
        }
        return .cancel
    }
}

extension ViewportController {
    /// The agent tab's WebKit setup: isolated helper + page console hook,
    /// the host's own data store and route, its content rules, and the
    /// scheduling policy for a tab that is not on screen.
    private static func configureForAgent(
        _ configuration: WKWebViewConfiguration,
        agent: Agent,
        hostID: UUID
    ) {
        // Random per tab, so it cannot collide with a page's own events.
        let consoleEvent = "mpx-console-" + UUID().uuidString
        let store = WKWebsiteDataStore(forIdentifier: hostID)
        if case .host(let proxy, _) = agent.route {
            // Set before the store's first load: WebKit keeps pooled
            // connections that a later proxy change does not reach.
            store.proxyConfigurations = [proxy]
        }
        configuration.websiteDataStore = store
        configuration.preferences.inactiveSchedulingPolicy = AgentBrowserService.inactiveSchedulingPolicy
        let content = configuration.userContentController
        // Helper first: it must be listening before the hook dispatches.
        content.addUserScript(WKUserScript(
            source: AgentBrowserScript.helper(consoleEvent: consoleEvent),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: AgentBrowserService.helperWorld
        ))
        content.addUserScript(WKUserScript(
            source: AgentBrowserScript.consoleHook(consoleEvent: consoleEvent),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))
        content.add(agent.ruleList)
        // WebRTC is UDP straight from the device: no proxy and no content
        // rule sees it. Agent tabs go without (best effort — page world).
        content.addUserScript(WKUserScript(
            source: AgentBrowserScript.noWebRTC,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        ))
    }
}

/// WK delegates live on this retained NSObject so the controller itself can
/// stay a plain `@Observable` class. WKWebView holds its delegates weakly;
/// the controller owns the bridge, the bridge points back weakly.
private final class ViewportWebBridge: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var controller: ViewportController?

    init(controller: ViewportController) {
        self.controller = controller
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let controller else { return decisionHandler(.cancel) }
            let url = navigationAction.request.url
            // Host route: a link or redirect to another host loopback port
            // waits for its device-side forward, then loads.
            if let url, case .host(_, let forward) = controller.agent?.route,
               AgentBrowserAddressPolicy.loopbackPort(url) != nil {
                Task { @MainActor in
                    let ready = await forward(url)
                    decisionHandler(ready ? controller.policy(for: url) : .cancel)
                }
                return
            }
            decisionHandler(controller.policy(for: url))
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated { controller?.navigationStarted() }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated { controller?.navigationFailed(error) }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated { controller?.navigationFailed(error) }
    }

    /// target=_blank and window.open land in the same viewport — one page
    /// per tab, and the popup still rides the navigation gate above.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        MainActor.assumeIsolated {
            if controller?.policy(for: navigationAction.request.url) == .allow {
                webView.load(navigationAction.request)
            }
        }
        return nil
    }
}
