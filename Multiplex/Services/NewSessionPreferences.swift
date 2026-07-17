import Foundation

/// Device-local defaults for the deck's New Session sheet. The opt-in is
/// separate from the selected agent so remembering "Shell only" is distinct
/// from not remembering a launch choice at all. The one-shot initial prompt
/// is deliberately never persisted.
struct NewSessionPreferences {
    private static let remembersLastLaunchKey = "newSession.remembersLastLaunch"
    private static let lastAgentKey = "newSession.lastAgent"

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

    func save(remembersLastLaunch: Bool, agent: AgentKind?) {
        defaults.set(remembersLastLaunch, forKey: Self.remembersLastLaunchKey)
        if remembersLastLaunch, let agent {
            defaults.set(agent.rawValue, forKey: Self.lastAgentKey)
        } else {
            // No stored value is the canonical representation of Shell only;
            // clearing it while disabled also prevents a stale agent returning
            // if the preference is enabled again later.
            defaults.removeObject(forKey: Self.lastAgentKey)
        }
    }
}
