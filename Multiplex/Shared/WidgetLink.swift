import Foundation

/// Deep-link builder for widget taps — the widget process's counterpart to
/// `ExternalActionURL` (which the widget can't compile without the app's
/// model chain). The formats must stay in lockstep; an app-side unit test
/// parses every builder output back into the expected `ExternalAction`.
enum WidgetLink {
    static let scheme = "multiplex"
    static let authority = "open"

    static func shellURL(hostID: UUID, sessionName: String? = nil) -> URL {
        var items = [
            URLQueryItem(name: "host", value: hostID.uuidString),
            URLQueryItem(name: "action", value: "shell"),
        ]
        if let sessionName, !sessionName.isEmpty {
            items.append(URLQueryItem(name: "session", value: sessionName))
        }
        return url(queryItems: items)
    }

    /// `model` travels raw — the app-side parser owns validation (a value
    /// the launch grammar rejects reads as "agent default"), so the widget
    /// target never compiles the grammar it would need to pre-validate.
    static func agentURL(
        hostID: UUID, agentRaw: String, askForPrompt: Bool, model: String? = nil
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
        return url(queryItems: items)
    }

    private static func url(queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = authority
        components.queryItems = queryItems
        // These components always form a valid URL; the fallback is inert.
        return components.url ?? URL(string: "\(scheme)://\(authority)")!
    }
}
