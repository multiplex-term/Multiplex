import Foundation

/// Secret-free fleet projection shared with the widget process through the
/// App Group container. The app is the single writer (publishing after
/// probes and host edits); the widget and the App-Intents host picker read.
/// Deliberately independent of the app's model types so the widget target
/// compiles none of the Host/tmux/agent dependency chain — agents travel as
/// `AgentKind.rawValue` strings (consistency is unit-tested app-side).
struct WidgetSessionState: Codable, Hashable {
    var name: String
    /// `AgentKind.rawValue` of the session's active-pane agent, if detected.
    var agentRaw: String?
    /// The window spine, in index order; `activeWindowIndex` indexes it.
    var windowNames: [String] = []
    /// Each window's active-pane title, parallel to `windowNames`. Already
    /// filtered app-side by `PaneTitleDisplay` — `""` means "nothing worth
    /// showing", so the widget never has to know what tmux seeds a pane
    /// title with (and never compiles the app's model chain to find out).
    var windowPaneTitles: [String] = []
    var activeWindowIndex: Int = 0
    /// Last visible lines of the active pane — the tile's held frame.
    var miniatureLines: [String] = []
    var createdAt: Date = .distantPast
    /// `Host.SessionBackend` raw value, when the host shows more than one.
    /// nil means "the host's default", which is what every row a
    /// single-backend host publishes means — and what every row in a file
    /// written before mixed hosts means. A row that carries one deep-links
    /// with `backend=`, so a tap can never resolve the name against the
    /// wrong multiplexer.
    var backendRaw: String?

    /// Pane title of the window an attached client is looking at. Index-guarded:
    /// legacy files carry no titles at all, and the widget must render them
    /// rather than trap.
    var activePaneTitle: String? {
        guard windowPaneTitles.indices.contains(activeWindowIndex) else { return nil }
        let title = windowPaneTitles[activeWindowIndex]
        return title.isEmpty ? nil : title
    }
}

extension WidgetSessionState {
    /// Hand-rolled: a property default does not make a non-optional key
    /// optional to Swift's synthesized decoder, so adding `windowPaneTitles`
    /// would have thrown on the `widget-state.json` an older build left behind
    /// — and a widget cannot ask the app to republish, so it would have sat
    /// blank until the user next opened Multiplex. Every field carries a
    /// default, so every key is optional here. Encoding stays synthesized.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            agentRaw: try container.decodeIfPresent(String.self, forKey: .agentRaw),
            windowNames: try container.decodeIfPresent(
                [String].self, forKey: .windowNames) ?? [],
            windowPaneTitles: try container.decodeIfPresent(
                [String].self, forKey: .windowPaneTitles) ?? [],
            activeWindowIndex: try container.decodeIfPresent(
                Int.self, forKey: .activeWindowIndex) ?? 0,
            miniatureLines: try container.decodeIfPresent(
                [String].self, forKey: .miniatureLines) ?? [],
            createdAt: try container.decodeIfPresent(
                Date.self, forKey: .createdAt) ?? .distantPast,
            backendRaw: try container.decodeIfPresent(
                String.self, forKey: .backendRaw)
        )
    }
}

struct WidgetHostState: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var address: String
    var sessions: [WidgetSessionState] = []
    /// When the app last had a live probe result for this host; nil = never.
    var probedAt: Date?
    /// Pre-configured launch models per agent raw value — what the Host
    /// widget's Model setting offers as picker rows in the widget process.
    /// Names only, no secrets. Optional-typed so files written before the
    /// field existed keep decoding (synthesized decoder; nil = none).
    var agentModels: [String: [String]]?
    /// `Host.SessionBackend` raw value ("tmux"/"herdr") — the host's
    /// DEFAULT backend, which the widget configuration's placement picker
    /// labels its rows with. Optional for the same legacy-file reason; nil
    /// reads as tmux, the app's default.
    var backendRaw: String?
    /// Every backend this host shows tiles for, default first — what the
    /// widget configuration's Backend picker offers. nil or a single entry
    /// means there is nothing to pick, and the picker stays hidden.
    var backendsRaw: [String]?
    /// The host's configured working directories, in the user's order —
    /// what the widget configuration's directory picker offers. Paths only
    /// (setup-script names and bodies still never ride widget state);
    /// optional for the same legacy-file reason.
    var workingDirs: [String]?

    /// The session the user last opened on this host (`HostStore.recentSessions`).
    /// Optional for the legacy-file reason; `backendRaw` follows the row
    /// convention.
    var lastAttached: WidgetSessionRef?

    /// Newest by creation, name-ordered on a tie. Must mirror
    /// `ExternalActionPlan.mostRecentSession` (unit-tested app-side). Only
    /// `featuredSession`'s last resort — creation order is meaningless on
    /// herdr (synthesized near-epoch dates).
    var mostRecentSession: WidgetSessionState? {
        sessions.max { lhs, rhs in
            (lhs.createdAt, lhs.name) < (rhs.createdAt, rhs.name)
        }
    }

    /// The session a widget features: its Session setting, else the last
    /// opened, else `mostRecentSession`; a stale name falls through. A row
    /// without `backendRaw` matches any ask; an explicit Backend is strict;
    /// Host Default tries the host's default namespace, then wherever the
    /// name lives (the picker lists both backends' names on a mixed host).
    func featuredSession(
        configuredName: String? = nil, configuredBackendRaw: String? = nil
    ) -> WidgetSessionState? {
        if let configuredName, configuredName != SessionTargetChoices.newSessionValue {
            let backend = configuredBackendRaw.flatMap {
                $0 == SessionTargetChoices.hostDefaultBackendValue ? nil : $0
            }
            if let match = session(named: configuredName, backendRaw: backend ?? backendRaw)
                ?? (backend == nil ? session(named: configuredName, backendRaw: nil) : nil) {
                return match
            }
        }
        if let lastAttached,
           let match = session(named: lastAttached.name, backendRaw: lastAttached.backendRaw) {
            return match
        }
        return mostRecentSession
    }

    private func session(named name: String, backendRaw: String?) -> WidgetSessionState? {
        sessions.first {
            $0.name == name
                && ($0.backendRaw == nil || backendRaw == nil || $0.backendRaw == backendRaw)
        }
    }
}

/// A session named across the App Group boundary without its content.
struct WidgetSessionRef: Codable, Hashable {
    var name: String
    var backendRaw: String?
}

struct WidgetFleetState: Codable, Hashable {
    var hosts: [WidgetHostState] = []
    var generatedAt: Date = .distantPast
}

enum SharedStateStore {
    static let appGroupID = "group.app.multiplexterm.multiplex"
    static let fileName = "widget-state.json"

    /// nil when the process lacks the App Group entitlement — every caller
    /// fails soft (the widget shows its placeholder, the picker goes empty).
    static func defaultDirectory(groupID: String = appGroupID) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    static func load(directory: URL? = nil) -> WidgetFleetState? {
        guard let dir = directory ?? defaultDirectory() else { return nil }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName))
        else { return nil }
        return try? JSONDecoder().decode(WidgetFleetState.self, from: data)
    }

    @discardableResult
    static func save(_ state: WidgetFleetState, directory: URL? = nil) -> Bool {
        guard let dir = directory ?? defaultDirectory() else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(state) else { return false }
        do {
            try data.write(to: dir.appendingPathComponent(fileName), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Per-install secret that marks a `multiplex://` URL as one of THIS
    /// app's own widget links. The scheme itself is public — any app or web
    /// page can open `multiplex://open?host=…&action=agent&prompt=…`, and a
    /// URL carries no origin — so the token is what separates a widget tap
    /// (silent, one-tap, as designed) from a link somebody else composed
    /// (confirmed in-app before anything runs). It lives in the App Group,
    /// which only this app and its widget extension can read; it is not a
    /// credential for anything else and never leaves the device.
    ///
    /// Stored in App Group defaults rather than `widget-state.json` so a
    /// republish can never drop it and stale widget timelines keep working.
    static let linkTokenKey = "MultiplexWidgetLinkToken"

    static func groupDefaults(groupID: String = appGroupID) -> UserDefaults? {
        UserDefaults(suiteName: groupID)
    }

    /// Read-only — what the widget builds links with, and what the app
    /// compares an incoming URL against.
    static func linkToken(defaults: UserDefaults? = groupDefaults()) -> String? {
        guard let value = defaults?.string(forKey: linkTokenKey), !value.isEmpty
        else { return nil }
        return value
    }

    /// App-side: mint the token once per install. Returns the existing one
    /// when there is one, so links already rendered into widget timelines
    /// stay valid.
    @discardableResult
    static func ensureLinkToken(defaults: UserDefaults? = groupDefaults()) -> String? {
        guard let defaults else { return nil }
        if let existing = linkToken(defaults: defaults) { return existing }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        defaults.set(token, forKey: linkTokenKey)
        return token
    }

    /// Deck telemetry token for an `agentRaw` value ("CLAUDE" / "CODEX" /
    /// "PI") — the widget's agent badge text. Kept in lockstep with
    /// `AgentKind.telemetryLabel` by a unit test.
    static func agentTelemetryLabel(forRaw raw: String) -> String? {
        switch raw {
        case "claudeCode": "CLAUDE"
        case "codex": "CODEX"
        case "pi": "PI"
        case "grok": "GROK"
        default: nil
        }
    }
}
