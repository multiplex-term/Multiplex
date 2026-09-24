import Foundation

/// Device-local defaults for the deck's New Session sheet. The opt-in is
/// separate from the selected agent so remembering "Shell only" is distinct
/// from not remembering a launch choice at all. The one-shot initial prompt
/// is deliberately never persisted.
///
/// The same single opt-in also covers the setup-script choice — per host,
/// because script ids are host-scoped — and the model override — per agent,
/// because a model belongs to the agent, not the host. While it is on, the
/// remembered script is what pickerless creation paths (+ TAB, widgets) and
/// Open Agent's Shortcut default type into fresh sessions, and + TAB's agent
/// variants inherit the remembered model; off means those paths type nothing
/// unless the Shortcut explicitly selects a script. External actions never
/// inherit the remembered model — an automation carries its own or gets the
/// agent default.
struct NewSessionPreferences {
    private static let remembersLastLaunchKey = "newSession.remembersLastLaunch"
    private static let lastAgentKey = "newSession.lastAgent"
    private static let lastScriptsKey = "newSession.lastScripts"
    private static let lastModelsKey = "newSession.lastModels"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var remembersLastLaunch: Bool {
        defaults.bool(forKey: Self.remembersLastLaunchKey)
    }

    /// `nil` means "Shell only" when remembering is enabled. Callers also
    /// inspect `remembersLastLaunch` to distinguish the disabled state.
    var rememberedAgent: AgentKind? {
        guard remembersLastLaunch,
              let rawValue = defaults.string(forKey: Self.lastAgentKey)
        else { return nil }
        return AgentKind(rawValue: rawValue)
    }

    /// The remembered `--model` override, per agent — models belong to the
    /// agent, not the host, so one choice follows Claude Code (or Codex, or
    /// Pi) across the fleet. Stored as typed; the launch grammar re-validates
    /// at composition, so a stale value fails soft to the agent default while
    /// staying visible in the sheet's field for the user to fix.
    func rememberedModel(for agent: AgentKind) -> String? {
        guard remembersLastLaunch,
              let stored = defaults.dictionary(forKey: Self.lastModelsKey),
              let model = stored[agent.rawValue] as? String,
              !model.isEmpty
        else { return nil }
        return model
    }

    /// The host's remembered setup script, resolved against its current
    /// list. `nil` means NONE — an absent entry and a remembered id whose
    /// script was since deleted or unsynced read the same way, silently.
    func rememberedScript(for host: Host) -> SessionScript? {
        guard remembersLastLaunch,
              let stored = defaults.dictionary(forKey: Self.lastScriptsKey),
              let rawValue = stored[host.id.uuidString] as? String,
              let scriptID = UUID(uuidString: rawValue)
        else { return nil }
        return host.sessionScripts.first { $0.id == scriptID }
    }

    func save(
        remembersLastLaunch: Bool, agent: AgentKind?, model: String?,
        script: SessionScript?, hostID: UUID
    ) {
        defaults.set(remembersLastLaunch, forKey: Self.remembersLastLaunchKey)
        if remembersLastLaunch, let agent {
            defaults.set(agent.rawValue, forKey: Self.lastAgentKey)
        } else {
            // No stored value is the canonical representation of Shell only;
            // clearing it while disabled also prevents a stale agent returning
            // if the preference is enabled again later.
            defaults.removeObject(forKey: Self.lastAgentKey)
        }

        // Same policy per host for the script: no entry is the canonical
        // NONE, and turning remembering off forgets every host's choice.
        var scripts = remembersLastLaunch
            ? (defaults.dictionary(forKey: Self.lastScriptsKey) as? [String: String]) ?? [:]
            : [:]
        if remembersLastLaunch, let script {
            scripts[hostID.uuidString] = script.id.uuidString
        } else {
            scripts.removeValue(forKey: hostID.uuidString)
        }
        if scripts.isEmpty {
            defaults.removeObject(forKey: Self.lastScriptsKey)
        } else {
            defaults.set(scripts, forKey: Self.lastScriptsKey)
        }

        // And per agent for the model. A shell-only submit (agent nil) says
        // nothing about models, so other agents' entries survive it; an
        // agent submitted with an empty field explicitly forgets its entry.
        var models = remembersLastLaunch
            ? (defaults.dictionary(forKey: Self.lastModelsKey) as? [String: String]) ?? [:]
            : [:]
        if let agent {
            let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if remembersLastLaunch, !trimmed.isEmpty {
                models[agent.rawValue] = trimmed
            } else {
                models.removeValue(forKey: agent.rawValue)
            }
        }
        if models.isEmpty {
            defaults.removeObject(forKey: Self.lastModelsKey)
        } else {
            defaults.set(models, forKey: Self.lastModelsKey)
        }
    }
}
