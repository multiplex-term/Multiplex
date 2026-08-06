import Foundation

/// Deep-link builder for widget taps — the widget process's counterpart to
/// `ExternalActionURL` (which the widget can't compile without the app's
/// model chain). The formats must stay in lockstep; an app-side unit test
/// parses every builder output back into the expected `ExternalAction`.
enum WidgetLink {
    static let scheme = "multiplex"
    static let authority = "open"

    /// `backendRaw` travels raw for the same reason `model` does — the
    /// app-side parser owns validation, and an unknown token reads as the
    /// host's default. Omitting it is what every link a single-backend host
    /// builds means, so those bytes are unchanged.
    static func shellURL(
        hostID: UUID, sessionName: String? = nil, backendRaw: String? = nil
    ) -> URL {
        var items = [
            URLQueryItem(name: "host", value: hostID.uuidString),
            URLQueryItem(name: "action", value: "shell"),
        ]
        if let sessionName, !sessionName.isEmpty {
            items.append(URLQueryItem(name: "session", value: sessionName))
        }
        if let backendRaw, !backendRaw.isEmpty {
            items.append(URLQueryItem(name: "backend", value: backendRaw))
        }
        return url(queryItems: items)
    }

    /// `model` travels raw — the app-side parser owns validation (a value
    /// the launch grammar rejects reads as "agent default"), so the widget
    /// target never compiles the grammar it would need to pre-validate.
    /// `sessionName`/`placementRaw` follow the same rule: an empty session
    /// means a fresh one (the sentinel `SessionTargetChoices` hands back),
    /// and the placement token is only ever emitted alongside a session —
    /// the app-side parser defaults a bad or missing one to the tab
    /// placement and revalidates the name against the live session list.
    /// An empty `directory` is the Host Default sentinel and stays home.
    static func agentURL(
        hostID: UUID, agentRaw: String, askForPrompt: Bool, model: String? = nil,
        sessionName: String? = nil, placementRaw: String? = nil,
        directory: String? = nil, backendRaw: String? = nil
    ) -> URL {
        var items = [
            URLQueryItem(name: "host", value: hostID.uuidString),
            URLQueryItem(name: "action", value: "agent"),
            URLQueryItem(name: "agent", value: agentRaw),
        ]
        if askForPrompt {
            items.append(URLQueryItem(name: "ask", value: "1"))
        }
        if let model, !model.isEmpty {
            items.append(URLQueryItem(name: "model", value: model))
        }
        if let directory, !directory.isEmpty {
            items.append(URLQueryItem(name: "dir", value: directory))
        }
        if let sessionName, !sessionName.isEmpty {
            items.append(URLQueryItem(name: "session", value: sessionName))
            if let placementRaw, !placementRaw.isEmpty {
                items.append(URLQueryItem(name: "in", value: placementRaw))
            }
        }
        if let backendRaw, !backendRaw.isEmpty {
            items.append(URLQueryItem(name: "backend", value: backendRaw))
        }
        return url(queryItems: items)
    }

    /// The query item that says "this link came from this install's own
    /// widget". See `SharedStateStore.linkToken` — without it the app
    /// confirms the action before running it, because the scheme is open to
    /// anything that can ask iOS to open a URL.
    static let tokenItemName = "t"

    private static func url(queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = authority
        var queryItems = queryItems
        if let token = SharedStateStore.linkToken() {
            queryItems.append(URLQueryItem(name: tokenItemName, value: token))
        }
        components.queryItems = queryItems
        // These components always form a valid URL; the fallback is inert.
        return components.url ?? URL(string: "\(scheme)://\(authority)")!
    }
}
