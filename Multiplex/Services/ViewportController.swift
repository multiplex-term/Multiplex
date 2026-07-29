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
/// Lifetime is the process, on purpose: controllers live in
/// `TerminalWorkspace` only, are created before their tab enters any route,
/// and are never persisted — the no-persistence rule ("summoned, not
/// restored") falls out of their absence after a relaunch.
@MainActor
@Observable
final class ViewportController {
    let tabID: UUID
    /// The confirmation that admitted this page; `offer.reachTag` rides the
    /// rail for the life of the tab.
    let offer: ViewportOffer
    /// The source host's display name — the viewport's tether label.
    let hostName: String

    @ObservationIgnored private(set) var webView: WKWebView!
    @ObservationIgnored private var bridge: ViewportWebBridge!
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private(set) var currentURL: URL?
    private(set) var pageTitle: String?
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var canGoBack = false
    /// A load that ended in an error the user should see — the TALLY panel
    /// renders it with the reach verdict, instead of WebKit's blank page.
    private(set) var failure: String?
    /// A navigation the gate refused but the link discipline can explain:
    /// the pane presents the same confirmation sheet a terminal press gets.
    var externalLink: TerminalLink?

    init(tabID: UUID, offer: ViewportOffer, hostName: String) {
        self.tabID = tabID
        self.offer = offer
        self.hostName = hostName
        self.currentURL = offer.url

        let configuration = WKWebViewConfiguration()
        // App-scoped and persistent (never shared with Safari): a dev
        // server's login survives reload. No user scripts, no message
        // handlers — pages get no bridge into the app.
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
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

        webView.load(URLRequest(url: offer.url))
    }

    private func syncTelemetry() {
        guard let webView else { return }
        progress = webView.estimatedProgress
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        if let url = webView.url { currentURL = url }
        pageTitle = webView.title?.isEmpty == false ? webView.title : nil
    }

    /// The rail's readout: current host emphasized by the view; falls back
    /// to the confirmed offer before the first commit.
    var displayURL: URL { currentURL ?? offer.url }

    func reload() {
        failure = nil
        if webView.url == nil {
            // The very first load failed — there is nothing to reload yet.
            webView.load(URLRequest(url: offer.url))
        } else {
            webView.reload()
        }
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

    /// Tab is closing for real (never called on a move): stop work and break
    /// the delegate cycle so the web process can wind down.
    func shutdown() {
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
        if scheme == "http" || scheme == "https" || scheme == "about" {
            return .allow
        }
        if let link = TerminalLink.resolve(url.absoluteString) {
            externalLink = link
        }
        return .cancel
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
            decisionHandler(
                controller?.policy(for: navigationAction.request.url) ?? .cancel
            )
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
