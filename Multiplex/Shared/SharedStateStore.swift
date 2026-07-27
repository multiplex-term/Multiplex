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
    var agentRaw: String? = nil
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
                Date.self, forKey: .createdAt) ?? .distantPast
        )
    }
}

struct WidgetHostState: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var address: String
    var sessions: [WidgetSessionState] = []
    /// When the app last had a live probe result for this host; nil = never.
    var probedAt: Date? = nil
    /// Pre-configured launch models per agent raw value — what the Host
    /// widget's Model setting offers as picker rows in the widget process.
    /// Names only, no secrets. Optional-typed so files written before the
    /// field existed keep decoding (synthesized decoder; nil = none).
    var agentModels: [String: [String]]? = nil

    /// The session the per-host widget features and a bare shell deep link
    /// attaches — newest by creation, name-ordered on a tie. Must mirror
    /// `ExternalActionPlan.mostRecentSessionName` (unit-tested app-side).
    var mostRecentSession: WidgetSessionState? {
        sessions.max { lhs, rhs in
            (lhs.createdAt, lhs.name) < (rhs.createdAt, rhs.name)
        }
    }
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

    /// Deck telemetry token for an `agentRaw` value ("CLAUDE" / "CODEX" /
    /// "PI") — the widget's agent badge text. Kept in lockstep with
    /// `AgentKind.telemetryLabel` by a unit test.
    static func agentTelemetryLabel(forRaw raw: String) -> String? {
        switch raw {
        case "claudeCode": "CLAUDE"
        case "codex": "CODEX"
        case "pi": "PI"
        default: nil
        }
    }
}
