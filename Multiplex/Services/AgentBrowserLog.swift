import os

extension Logger {
    /// Everything the agent browser logs: bridge links, the host-route
    /// proxy and forwards, agent tabs.
    static let agentBrowser = Logger(subsystem: "app.multiplexterm.multiplex", category: "agentbrowser")
}
