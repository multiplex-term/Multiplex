import Foundation
import os
import UIKit
import WebKit

/// The agent browser: lets agents on a host drive ⌗ tabs through
/// `mpx browser`, for hosts whose record has `agentBrowser` on.
///
/// One `AgentBrowserLink` per such host (its own SSH connection running
/// `mpx bridge`); requests land here, on the main actor, and act on AGENT
/// viewport tabs only — tabs this service opened, registered in
/// `TerminalWorkspace` like any viewport so merge/split/close behave the
/// same. An agent never sees or drives a tab the user opened.
///
/// Availability is the app's: links run while the app runs, and iOS
/// suspends it shortly after it leaves the screen — requests then time out
/// at the bridge, which says so to the agent.
@MainActor
final class AgentBrowserService {
    static let helperWorld = WKContentWorld.world(name: AgentBrowserScript.worldName)

    /// How WebKit schedules an agent tab that is not in a window (a
    /// background tab of its window). `.none` keeps it fully running so
    /// agent calls answer; DEBUG builds can override for the scheduling
    /// experiment with `MULTIPLEX_AGENT_INACTIVE=throttle|suspend|none`.
    static var inactiveSchedulingPolicy: WKPreferences.InactiveSchedulingPolicy {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["MULTIPLEX_AGENT_INACTIVE"] {
        case "throttle": return .throttle
        case "suspend": return .suspend
        default: return .none
        }
        #else
        return .none
        #endif
    }

    /// Agent tabs load THROUGH THE HOST (`AgentBrowserProxy`): a page sees
    /// the host's network, never the device's, and `localhost` is the
    /// host's (via loopback forwards). DEBUG builds can measure the older
    /// device route with `MULTIPLEX_AGENT_ROUTE=device`.
    static var routesViaHost: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["MULTIPLEX_AGENT_ROUTE"] != "device"
        #else
        true
        #endif
    }

    /// DEBUG: `MULTIPLEX_AGENT_BROWSER_HOST=<host name>|first` opts that host
    /// in for this launch without writing the synced record — device
    /// measurement runs against a real host the user did not switch on.
    private func debugOptedIn(_ host: Host) -> Bool {
        #if DEBUG
        guard let wanted = ProcessInfo.processInfo.environment["MULTIPLEX_AGENT_BROWSER_HOST"] else { return false }
        return wanted == "first" ? store.hosts.first?.id == host.id : host.name == wanted
        #else
        return false
        #endif
    }

    private func optedIn(_ host: Host) -> Bool {
        (host.agentBrowser || debugOptedIn(host)) && host.isEnabled
    }

    private static let log = Logger.agentBrowser

    /// Agent tabs one host may hold at once.
    static let maxTabsPerHost = 6

    private let store: HostStore
    private let workspace: TerminalWorkspace
    private let networkChanges: NetworkChangeMonitor?
    /// Everything per opted-in host lives in one slot, so a revoke drops it
    /// all at once.
    private var hosts: [UUID: HostSlot] = [:]
    /// One capture at a time, app-wide: each is a full-window render.
    private var capturing = false
    private var focusGate = AgentFocusGate()
    private nonisolated(unsafe) var foregroundObserver: NSObjectProtocol?

    private struct AgentTab {
        var handle: String
        var hostID: UUID
        var tabID: UUID
        var controller: ViewportController
    }

    private struct HostSlot {
        let link: AgentBrowserLink
        var tabs: [AgentTab] = []
        /// The tab the host's agent used last — the default target.
        var lastUsed: String?
        var nextHandle = 0
        /// Host route: the proxy, created with the host's first tab.
        var proxy: AgentBrowserProxy?
        /// Compiled content rules, keyed by what they were compiled for
        /// (the forwarded ports, or the device route's host address).
        var rules: (key: String, list: WKContentRuleList)?
    }

    init(store: HostStore, workspace: TerminalWorkspace, networkChanges: NetworkChangeMonitor? = nil) {
        self.store = store
        self.workspace = workspace
        self.networkChanges = networkChanges
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    func start() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hosts.values.forEach { $0.link.applicationWillEnterForeground() }
            }
        }
        observeHosts()
        observeNetwork()
    }

    // MARK: Links

    private func observeHosts() {
        let hosts = withObservationTracking {
            store.hosts
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeHosts() }
        }
        reconcile(hosts)
    }

    /// A network change strands every SSH socket on the old path: links
    /// redial now, proxies dial fresh for their next tunnel.
    private func observeNetwork() {
        guard let networkChanges else { return }
        let revision = withObservationTracking {
            networkChanges.reconnectRevision
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.hosts.values.forEach {
                    $0.link.networkChanged()
                    $0.proxy?.dropConnection()
                }
                self?.observeNetwork()
            }
        }
        _ = revision
    }

    /// A disabled host is never dialled on the app's own initiative — the
    /// agent browser included.
    private func reconcile(_ hosts: [Host]) {
        let wanted = Dictionary(
            hosts.filter(optedIn).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Revoked (switched off, host disabled or deleted): the host's tabs
        // and forwards go too — nothing it opened outlives its permission.
        for id in self.hosts.keys where wanted[id] == nil {
            revoke(hostID: id)
        }
        for (id, host) in wanted {
            if let slot = self.hosts[id] {
                slot.link.update(host: host)
                slot.proxy?.update(host: host)
                continue
            }
            let link = AgentBrowserLink(
                host: host,
                deviceName: BindController.deviceName
            ) { [weak self] hostID, method, params in
                guard let self else {
                    return .failure(.init(code: "disconnected", message: "Multiplex is shutting down."))
                }
                return await self.handle(hostID: hostID, method: method, params: params)
            }
            self.hosts[id] = HostSlot(link: link)
            link.start()
        }
    }

    // MARK: Requests

    /// The host, while it may still drive a browser — checked on entry and
    /// again after every wait that precedes a side effect, because the user
    /// can switch the host off while a request is in flight.
    private func authorizedHost(_ hostID: UUID) -> Host? {
        guard let host = store.host(id: hostID), optedIn(host) else { return nil }
        return host
    }

    private static let revoked = AgentBrowserError(
        code: "revoked",
        message: "The agent browser is off for this host in Multiplex."
    )

    func handle(hostID: UUID, method: String, params: JSONValue) async -> Result<JSONValue, AgentBrowserError> {
        guard let host = authorizedHost(hostID), hosts[hostID] != nil else { return .failure(Self.revoked) }
        switch method {
        case "tabs":
            var listing: [String: JSONValue] = ["tabs": .array(tabs(of: hostID).map { describe($0) })]
            if let proxy = hosts[hostID]?.proxy, !proxy.forwardedPorts.isEmpty {
                listing.merge(forwardsListing(proxy)) { $1 }
            }
            return .success(.object(listing))
        case "forward":
            return await forward(hostID: hostID, params: params)
        case "open":
            return await open(host: host, params: params)
        #if DEBUG
        case "probe":
            // The scheduling/route measurement instrument; not protocol.
            let proxy = hosts[hostID]?.proxy
            return await withTab(hostID, params) { tab in
                var probe = await AgentBrowserDriver.probe(tab.controller)
                if case .object(var fields) = probe {
                    fields["route"] = .string(Self.routesViaHost ? "host" : "device")
                    if let proxy { fields["tunnelsOpened"] = .number(Double(proxy.tunnelsOpened)) }
                    if let port = proxy?.port { fields["proxyPort"] = .number(Double(port)) }
                    probe = .object(fields)
                }
                return .success(probe)
            }
        #endif
        default:
            break
        }
        return await withTab(hostID, params) { tab in
            await self.perform(method, on: tab, host: host, params: params)
        }
    }

    private func perform(
        _ method: String,
        on tab: AgentTab,
        host: Host,
        params: JSONValue
    ) async -> Result<JSONValue, AgentBrowserError> {
        let controller = tab.controller
        switch method {
        case "navigate":
            guard let url = params["url"]?.stringValue else { return .failure(.badRequest("navigate needs a url.")) }
            switch admit(url, host: host) {
            case .failure(let error): return .failure(error)
            case .success(let offer):
                if let error = await forwardIfLoopback(offer.url, hostID: host.id) { return .failure(error) }
                controller.load(offer)
                await AgentBrowserDriver.settle(controller)
                return pageResult(tab)
            }
        case "back", "reload":
            if method == "back" { controller.goBack() } else { controller.reload() }
            await AgentBrowserDriver.settle(controller)
            return pageResult(tab)
        case "show":
            let verdict = requestFocus(host.id)
            if let refusal = verdict.refusalMessage {
                return .failure(.init(code: "focus_refused", message: refusal))
            }
            workspace.focusTab(id: tab.tabID)
            return pageResult(tab)
        case "close":
            closeTab(tab)
            return .success(.object(["closed": .string(tab.handle)]))
        case "snapshot":
            await AgentBrowserDriver.settle(controller, timeout: .seconds(10))
            return await AgentBrowserDriver.helper(controller, "snapshot", params).map { snapshot in
                var out = baseFields(tab)
                if case .object(let fields) = snapshot { out.merge(fields) { $1 } }
                return .object(out)
            }
        case "click", "press", "type", "select", "scroll":
            let result = await AgentBrowserDriver.helper(controller, method, params)
            // Only what can start a navigation waits for one to settle.
            if method != "scroll", method != "type" { await AgentBrowserDriver.settle(controller) }
            return result
        case "fill":
            let filled = await AgentBrowserDriver.helper(controller, "fill", params)
            guard case .success = filled, params["submit"]?.boolValue == true else { return filled }
            guard !Task.isCancelled, authorizedHost(host.id) != nil else { return .failure(Self.revoked) }
            let pressed = await AgentBrowserDriver.helper(controller, "press", .object(["key": .string("Enter")]))
            await AgentBrowserDriver.settle(controller)
            return pressed.flatMap { _ in filled }
        case "console":
            return await AgentBrowserDriver.helper(controller, "console", params)
        case "eval":
            guard let js = params["js"]?.stringValue else { return .failure(.badRequest("eval needs js.")) }
            return await AgentBrowserDriver.evaluate(controller, source: js)
        case "wait":
            return await wait(controller, params: params)
        case "screenshot":
            guard !capturing else {
                return .failure(.init(code: "busy", message: "Another screenshot is in progress — retry."))
            }
            capturing = true
            defer { capturing = false }
            return await AgentBrowserDriver.screenshot(controller)
        default:
            return .failure(.unknownMethod(method))
        }
    }

    private func wait(
        _ controller: ViewportController,
        params: JSONValue
    ) async -> Result<JSONValue, AgentBrowserError> {
        let text = params["text"]?.stringValue
        let selector = params["selector"]?.stringValue
        // Bounded both ways before any arithmetic: the value is the host's.
        let timeoutMs = Int(params["timeoutMs"]?.wireInteger.map { min($0, 300_000) } ?? 15_000)
        let started = ContinuousClock.now
        let deadline = started + .milliseconds(max(timeoutMs - 500, 0))
        let probe: JSONValue = .object([
            "text": text.map(JSONValue.string) ?? .null,
            "selector": selector.map(JSONValue.string) ?? .null,
        ])
        while true {
            if !controller.webView.isLoading {
                // A navigation mid-wait replaces the document; the helper
                // answers not_ready until the new one is up — keep polling.
                switch await AgentBrowserDriver.helper(controller, "find", probe) {
                case .success(.bool(true)):
                    let waited = (ContinuousClock.now - started) / .milliseconds(1)
                    return .success(.object(["found": .bool(true), "waitedMs": .number(waited.rounded())]))
                case .failure(let error) where error.code == "bad_request":
                    return .failure(error)
                default:
                    break
                }
            }
            if ContinuousClock.now >= deadline {
                let what = [text.map { "text \"\($0)\"" }, selector.map { "selector \($0)" }]
                    .compactMap { $0 }.joined(separator: " and ")
                return .failure(.timeout("\(what.isEmpty ? "The page load" : what) did not appear in time."))
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: Tabs

    private func open(host: Host, params: JSONValue) async -> Result<JSONValue, AgentBrowserError> {
        guard let input = params["url"]?.stringValue else { return .failure(.badRequest("open needs a url.")) }
        let offer: ViewportOffer
        switch admit(input, host: host) {
        case .failure(let error): return .failure(error)
        case .success(let admitted): offer = admitted
        }
        let focus = params["focus"]?.boolValue ?? false
        if params["newTab"]?.boolValue != true,
           let existing = target(host.id, named: params["tab"]?.stringValue) {
            if let error = await forwardIfLoopback(offer.url, hostID: host.id) { return .failure(error) }
            existing.controller.load(offer)
            hosts[host.id]?.lastUsed = existing.handle
            let verdict = focus ? requestFocus(host.id) : nil
            if verdict == .allow { workspace.focusTab(id: existing.tabID) }
            await AgentBrowserDriver.settle(existing.controller)
            return pageResult(existing, focus: verdict)
        }

        let session = params["session"].flatMap { value -> SessionKey? in
            guard let name = value["name"]?.stringValue, !name.isEmpty else { return nil }
            let backend = Host.SessionBackend(token: value["backend"]?.stringValue) ?? host.sessionBackend
            return SessionKey(backend: backend, name: name)
        }
        guard tabs(of: host.id).count < Self.maxTabsPerHost else {
            return .failure(.init(
                code: "too_many_tabs",
                message: "This host already has \(Self.maxTabsPerHost) agent tabs — `close` one first."
            ))
        }
        let unavailable = AgentBrowserError(
            code: "unavailable",
            message: "Multiplex could not prepare the agent tab's network route."
        )
        // Fail closed either way: without its rules a tab could reach other
        // apps' servers on the device (host route) or the LAN (device route).
        let route: ViewportController.Agent.Route
        if Self.routesViaHost {
            let proxy = hosts[host.id]?.proxy ?? AgentBrowserProxy(host: host)
            hosts[host.id]?.proxy = proxy
            guard let port = try? await proxy.start(), let configuration = proxy.configuration(port: port)
            else { return .failure(unavailable) }
            if let error = await forwardIfLoopback(offer.url, hostID: host.id) { return .failure(error) }
            route = .host(configuration, forwardLoopback: loopbackForwarder(hostID: host.id))
        } else {
            route = .device
        }
        guard let rules = await contentRules(for: host) else { return .failure(unavailable) }
        // The compiles were waits: re-check before the side effects.
        guard !Task.isCancelled, let host = authorizedHost(host.id), hosts[host.id] != nil else {
            return .failure(Self.revoked)
        }
        guard let dock = workspace.agentDockTarget(hostID: host.id, session: session) else {
            return .failure(.noWindow(hostName: host.name))
        }
        let handleNumber = (hosts[host.id]?.nextHandle ?? 0) + 1
        hosts[host.id]?.nextHandle = handleNumber
        let handle = "t\(handleNumber)"
        let tabRoute = TerminalRoute(hostID: host.id, mode: .viewport(urlString: offer.url.absoluteString))
        let hostID = host.id
        let tabID = tabRoute.id
        let controller = ViewportController(
            tabID: tabID,
            offer: offer,
            host: host,
            agent: .init(handle: handle, ruleList: rules, route: route) { [weak self] in
                self?.tabClosed(tabID, hostID: hostID)
            }
        )
        // Registered BEFORE the route sees the tab — the auxiliary rule.
        workspace.adoptAuxiliary(controller, tabID: tabID)
        let verdict = focus ? requestFocus(host.id) : nil
        dock.entry.dock(tabRoute, dock.anchorTabID, verdict == .allow)
        let tab = AgentTab(handle: handle, hostID: host.id, tabID: tabID, controller: controller)
        hosts[host.id]?.tabs.append(tab)
        hosts[host.id]?.lastUsed = handle
        Self.log.info("agent tab \(handle, privacy: .public) opened on \(host.name, privacy: .private)")
        // The forwards' cookie goes in through THIS tab's store: set on a
        // store no web view uses yet, WebKit drops it (measured on device).
        if let proxy = hosts[host.id]?.proxy {
            let cookies = controller.webView.configuration.websiteDataStore.httpCookieStore
            for cookie in proxy.forwardCookies { await cookies.setCookie(cookie) }
        }
        controller.load(offer)
        await AgentBrowserDriver.settle(controller)
        return pageResult(tab, focus: verdict)
    }

    private func withTab(
        _ hostID: UUID,
        _ params: JSONValue,
        _ body: (AgentTab) async -> Result<JSONValue, AgentBrowserError>
    ) async -> Result<JSONValue, AgentBrowserError> {
        let named = params["tab"]?.stringValue
        guard let tab = target(hostID, named: named) else {
            return .failure(named.map(AgentBrowserError.unknownTab) ?? .noTab())
        }
        hosts[hostID]?.lastUsed = tab.handle
        return await body(tab)
    }

    private func tabs(of hostID: UUID) -> [AgentTab] {
        hosts[hostID]?.tabs ?? []
    }

    private func target(_ hostID: UUID, named: String?) -> AgentTab? {
        let mine = tabs(of: hostID)
        if let named { return mine.first { $0.handle == named } }
        if let last = hosts[hostID]?.lastUsed, let tab = mine.first(where: { $0.handle == last }) { return tab }
        return mine.last
    }

    /// The tab closed for real (the user, `close`, its window): it leaves
    /// the registry, and with the host's last tab go its forwards — each is
    /// reachable by every app on the device.
    private func tabClosed(_ tabID: UUID, hostID: UUID) {
        hosts[hostID]?.tabs.removeAll { $0.tabID == tabID }
        if tabs(of: hostID).isEmpty { hosts[hostID]?.proxy?.stopForwards() }
    }

    private func loopbackForwarder(hostID: UUID) -> @MainActor (URL) async -> Bool {
        { [weak self] url in
            guard let self else { return false }
            let failure = await self.forwardIfLoopback(url, hostID: hostID)
            return failure == nil
        }
    }

    /// Host route only: a URL on the host's loopback needs the device's
    /// same port forwarded first (a real device never proxies loopback).
    private func forwardIfLoopback(_ url: URL, hostID: UUID) async -> AgentBrowserError? {
        guard Self.routesViaHost, let port = AgentBrowserAddressPolicy.loopbackPort(url) else { return nil }
        return await forward(port: port, hostID: hostID)
    }

    private func forward(port: Int, hostID: UUID) async -> AgentBrowserError? {
        guard let proxy = hosts[hostID]?.proxy else {
            return .init(code: "unavailable", message: "No host route yet.")
        }
        let before = proxy.forwardedPorts
        guard !before.contains(port) else { return nil }
        do {
            try await proxy.forward(port: port)
        } catch {
            return .init(
                code: "port_busy",
                message: "Port \(port) is already in use on the device (another app, or another host's agent tab)."
            )
        }
        guard proxy.forwardedPorts != before else { return nil }
        // The host's open tabs must let the new port through before
        // anything loads from it.
        guard let host = store.host(id: hostID), let rules = await contentRules(for: host) else {
            return .init(code: "unavailable", message: "Multiplex could not update the tab's network rules.")
        }
        tabs(of: hostID).forEach { $0.controller.applyAgentRuleList(rules) }
        return nil
    }

    /// `mpx browser forward <port>…`: host loopback ports a page reaches
    /// by `fetch`/WebSocket rather than by navigation (an API on :8000).
    private func forward(hostID: UUID, params: JSONValue) async -> Result<JSONValue, AgentBrowserError> {
        guard Self.routesViaHost else {
            return .failure(.init(
                code: "not_needed",
                message: "This device loads pages from its own network; `localhost` already means the host's address."
            ))
        }
        guard !tabs(of: hostID).isEmpty, let proxy = hosts[hostID]?.proxy else { return .failure(.noTab()) }
        guard case .array(let values) = params["ports"] ?? .null else {
            return .failure(.badRequest("forward needs ports."))
        }
        // An explicit forward sets the port's mode: `open` admits any
        // device client (cross-port requests without credentials), plain
        // restores the cookie check.
        let open = params["open"]?.boolValue == true
        for value in values {
            guard let port = value.wireInteger, (1...65535).contains(port) else {
                return .failure(.badRequest("Ports are 1–65535."))
            }
            if let error = await forward(port: Int(port), hostID: hostID) { return .failure(error) }
            proxy.setOpen(Int(port), open)
        }
        return .success(.object(forwardsListing(proxy)))
    }

    private func forwardsListing(_ proxy: AgentBrowserProxy) -> [String: JSONValue] {
        [
            "forwards": .array(proxy.forwardedPorts.map { .number(Double($0)) }),
            "open": .array(proxy.openForwardedPorts.map { .number(Double($0)) }),
        ]
    }

    private func revoke(hostID: UUID) {
        guard let slot = hosts.removeValue(forKey: hostID) else { return }
        slot.link.stop()
        slot.tabs.forEach { workspace.closeAgentTab($0.tabID) }
        slot.proxy?.stop()
    }

    private func admit(_ input: String, host: Host) -> Result<ViewportOffer, AgentBrowserError> {
        Self.routesViaHost
            ? AgentBrowserAddressPolicy.admitViaHost(input, host: host)
            : AgentBrowserAddressPolicy.admit(input, host: host)
    }

    private func closeTab(_ tab: AgentTab) {
        // The controller's shutdown reports back through `tabClosed`.
        workspace.closeAgentTab(tab.tabID)
    }

    private func baseFields(_ tab: AgentTab) -> [String: JSONValue] {
        [
            "tab": .string(tab.handle),
            "url": .string(tab.controller.displayURL.absoluteString),
            "title": .string(tab.controller.pageTitle ?? ""),
        ]
    }

    private func describe(_ tab: AgentTab) -> JSONValue {
        let webView = tab.controller.webView!
        var fields = baseFields(tab)
        fields["loading"] = .bool(webView.isLoading)
        fields["visible"] = .bool(AgentBrowserDriver.isOnScreen(webView))
        fields["active"] = .bool(hosts[tab.hostID]?.lastUsed == tab.handle)
        return .object(fields)
    }

    /// Taking the user's focus goes through the gate: never mid-typing,
    /// once per cooldown per host.
    private func requestFocus(_ hostID: UUID) -> AgentFocusGate.Verdict {
        let typing = TerminalFocusArbiter.current?.hasRecentUserInput(within: AgentFocusGate.typingQuiet) ?? false
        return focusGate.request(hostID: hostID, now: ProcessInfo.processInfo.systemUptime, userTyping: typing)
    }

    private func pageResult(
        _ tab: AgentTab,
        focus verdict: AgentFocusGate.Verdict? = nil
    ) -> Result<JSONValue, AgentBrowserError> {
        var fields = baseFields(tab)
        fields["visible"] = .bool(AgentBrowserDriver.isOnScreen(tab.controller.webView))
        fields["loadError"] = tab.controller.failure.map(JSONValue.string)
        fields["focusRefused"] = verdict?.refusalMessage.map(JSONValue.string)
        return .success(.object(fields))
    }

    // MARK: Content rules

    /// The tab's required rules: the loopback guard for the host's current
    /// forwards (host route), or the private-network block (device route).
    /// Compiled once per key, kept in the host's slot.
    private func contentRules(for host: Host) async -> WKContentRuleList? {
        let (key, json): (String, String)
        if Self.routesViaHost {
            let ports = hosts[host.id]?.proxy?.forwardedPorts ?? []
            key = "loopback:" + ports.map(String.init).joined(separator: ",")
            json = AgentBrowserAddressPolicy.loopbackRuleListJSON(forwardedPorts: ports)
        } else {
            key = "device:" + host.hostname
            json = AgentBrowserAddressPolicy.contentRuleListJSON(host: host)
        }
        if let cached = hosts[host.id]?.rules, cached.key == key { return cached.list }
        do {
            guard let list = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "agent-browser-\(host.id.uuidString)",
                encodedContentRuleList: json
            ) else { return nil }
            hosts[host.id]?.rules = (key, list)
            return list
        } catch {
            Self.log.error("agent browser rules did not compile: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
