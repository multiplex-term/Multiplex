import UIKit
import WebKit

/// The WebKit half of the agent browser: calls into an agent tab's isolated
/// helper, the page-world `eval`, load waits, and screenshots. Every answer
/// is a `JSONValue` or an `AgentBrowserError`.
@MainActor
enum AgentBrowserDriver {
    /// Calls `__mpx.call(name, args)` in the helper world.
    static func helper(
        _ controller: ViewportController,
        _ name: String,
        _ args: JSONValue = .object([:])
    ) async -> Result<JSONValue, AgentBrowserError> {
        let argsJSON = String(decoding: (try? JSONEncoder().encode(args)) ?? Data("{}".utf8), as: UTF8.self)
        let raw: Any?
        do {
            raw = try await controller.webView.callAsyncJavaScript(
                AgentBrowserScript.callBody,
                arguments: ["name": name, "argsJSON": argsJSON],
                in: nil,
                contentWorld: AgentBrowserService.helperWorld
            )
        } catch {
            return .failure(.script(message(of: error)))
        }
        guard let text = raw as? String, let answer = JSONValue.parse(text) else {
            return .failure(.init(
                code: "not_ready",
                message: "The page has no document yet (still loading, or a load error) — retry after `wait`."
            ))
        }
        if let error = answer["error"] {
            return .failure(.init(
                code: error["code"]?.stringValue ?? "script_error",
                message: error["message"]?.stringValue ?? "The page helper failed."
            ))
        }
        return .success(answer["ok"] ?? .null)
    }

    /// The agent's own JavaScript, in the page world.
    static func evaluate(
        _ controller: ViewportController,
        source: String
    ) async -> Result<JSONValue, AgentBrowserError> {
        var trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(";") { trimmed.removeLast() }
        var lastError = ""
        for body in AgentBrowserScript.evalBodies(trimmed) {
            do {
                let raw = try await controller.webView.callAsyncJavaScript(
                    body, arguments: [:], in: nil, contentWorld: .page
                )
                guard let text = raw as? String, let answer = JSONValue.parse(text) else {
                    return .success(.object(["value": .null]))
                }
                if answer["undefined"] != nil { return .success(.object([:])) }
                if let size = answer["tooLarge"]?.wireInteger {
                    return .failure(.init(
                        code: "too_large",
                        message: "The result was \(size) characters; return less (slice it, or pick fields)."
                    ))
                }
                return .success(.object(["value": answer["value"] ?? .null]))
            } catch {
                lastError = message(of: error)
                // Only a parse failure earns the statement-body retry; a
                // thrown exception is the answer.
                guard lastError.contains("SyntaxError") else { break }
            }
        }
        return .failure(.script(lastError))
    }

    /// Waits for the current load to finish (or `timeout`). A just-issued
    /// load may not have flipped `isLoading` yet, hence the grace tick.
    static func settle(_ controller: ViewportController, timeout: Duration = .seconds(20)) async {
        try? await Task.sleep(for: .milliseconds(150))
        let deadline = ContinuousClock.now + timeout
        while controller.webView.isLoading, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Whether the user can see the tab: in a window, no hidden ancestor
    /// (an inactive tab's pane is hidden, not unmounted), scene in front.
    /// WebKit itself keeps such a hidden-but-mounted page fully live.
    static func isOnScreen(_ webView: WKWebView) -> Bool {
        guard let window = webView.window,
              window.windowScene?.activationState == .foregroundActive
        else { return false }
        var view: UIView? = webView
        while let current = view, current !== window {
            if current.isHidden || current.alpha == 0 { return false }
            view = current.superview
        }
        return true
    }

    /// PNG of what the tab shows. WebKit renders only what is in a window,
    /// so an off-screen tab says so instead of returning a blank image.
    static func screenshot(_ controller: ViewportController) async -> Result<JSONValue, AgentBrowserError> {
        let webView = controller.webView!
        guard webView.window != nil, webView.bounds.width > 0, webView.bounds.height > 0 else {
            return .failure(.hidden())
        }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        // `snapshotWidth` is in points; cap the OUTPUT at 1280 px so a 2–3×
        // screen does not ship a 3840 px image an agent's vision model
        // would downscale anyway.
        let scale = webView.traitCollection.displayScale
        configuration.snapshotWidth = NSNumber(value: Double(min(webView.bounds.width, 1280 / max(scale, 1))))
        do {
            let image = try await webView.takeSnapshot(configuration: configuration)
            let pixels = (width: image.size.width * image.scale, height: image.size.height * image.scale)
            // Encoding a multi-megapixel PNG is not main-actor work.
            let encoded = await Task.detached(priority: .userInitiated) {
                image.pngData()?.base64EncodedString()
            }.value
            guard let encoded else { return .failure(.script("Could not encode the capture.")) }
            return .success(.object([
                "png": .string(encoded),
                "width": .number(Double(pixels.width)),
                "height": .number(Double(pixels.height)),
            ]))
        } catch {
            return .failure(.script(message(of: error)))
        }
    }

    #if DEBUG
    /// Measurement instrument (`mpx browser probe`, DEBUG): what WebKit is doing for
    /// this tab right now — on screen or not, scene and app state, and how
    /// promptly the page's own timers and frames run.
    static func probe(_ controller: ViewportController) async -> JSONValue {
        let webView = controller.webView!
        let started = ContinuousClock.now
        let body = """
            const t0 = performance.now();
            const timer = await new Promise((r) => setTimeout(() => r(performance.now() - t0), 100));
            const frame = await Promise.race([
              new Promise((r) => requestAnimationFrame(() => r(true))),
              new Promise((r) => setTimeout(() => r(false), 500)),
            ]);
            return JSON.stringify({ timerMs: timer, frame, visibility: document.visibilityState });
            """
        var page: JSONValue = .null
        if let raw = try? await webView.callAsyncJavaScript(
            body, arguments: [:], in: nil, contentWorld: AgentBrowserService.helperWorld
        ), let text = raw as? String {
            page = JSONValue.parse(text) ?? .null
        }
        let roundTrip = (ContinuousClock.now - started) / .milliseconds(1)
        return .object([
            "inWindow": .bool(webView.window != nil),
            "onScreen": .bool(isOnScreen(webView)),
            "scene": .string(sceneState(webView.window?.windowScene)),
            "app": .string(appState()),
            "inactivePolicy": .string(policyName(webView.configuration.preferences.inactiveSchedulingPolicy)),
            "roundTripMs": .number(roundTrip.rounded()),
            "page": page,
        ])
    }

    private static func sceneState(_ scene: UIWindowScene?) -> String {
        guard let scene else { return "none" }
        switch scene.activationState {
        case .foregroundActive: return "foregroundActive"
        case .foregroundInactive: return "foregroundInactive"
        case .background: return "background"
        case .unattached: return "unattached"
        @unknown default: return "unknown"
        }
    }

    private static func appState() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private static func policyName(_ policy: WKPreferences.InactiveSchedulingPolicy) -> String {
        switch policy {
        case .none: return "none"
        case .throttle: return "throttle"
        case .suspend: return "suspend"
        @unknown default: return "unknown"
        }
    }

    #endif

    /// WebKit's exception text when there is one, else the error itself.
    private static func message(of error: Error) -> String {
        let nsError = error as NSError
        if let text = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String { return text }
        return nsError.localizedDescription
    }
}
