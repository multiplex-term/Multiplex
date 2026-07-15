import Foundation

/// One-time bridge from the former device-local `agent-commands.json` into
/// the command configuration now carried by each synced Host record. It reads
/// both historical shapes: hostless profiles from the original global store
/// and host-scoped profiles from the short-lived local format. A scoped
/// profile (including an explicit empty one) wins over the hostless fallback.
enum CustomAgentCommandMigration {
    struct Source {
        fileprivate var profilesByKey: [ProfileKey: LegacyProfile]

        static let empty = Source(profilesByKey: [:])

        func configuration(for hostID: UUID) -> AgentCommandConfiguration {
            let profiles: [AgentCommandConfiguration.Profile] =
                CustomAgentCommandMigration.supportedAgents.compactMap {
                    agent -> AgentCommandConfiguration.Profile? in
                    let scopedKey = ProfileKey(hostID: hostID, agent: agent)
                    let fallbackKey = ProfileKey(hostID: nil, agent: agent)
                    guard let legacy = profilesByKey[scopedKey]
                        ?? profilesByKey[fallbackKey]
                    else { return nil }
                    return AgentCommandConfiguration.Profile(
                        agent: agent,
                        commands: legacy.commands,
                        builtInPlacements: legacy.builtInPlacements
                    )
                }
            return AgentCommandConfiguration(profiles: profiles)
        }
    }

    fileprivate struct ProfileKey: Hashable {
        var hostID: UUID?
        var agent: AgentKind
    }

    fileprivate struct LegacyProfile: Decodable {
        var hostID: UUID?
        var agent: AgentKind
        var commands: [CustomAgentCommand]
        var builtInPlacements: [String: AgentCommandPlacement]

        private enum CodingKeys: String, CodingKey {
            case hostID
            case agent
            case commands
            case builtInPlacements
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hostID = try container.decodeIfPresent(UUID.self, forKey: .hostID)
            agent = try container.decode(AgentKind.self, forKey: .agent)
            commands = try container.decodeIfPresent(
                [CustomAgentCommand].self,
                forKey: .commands
            ) ?? []
            builtInPlacements = try container.decodeIfPresent(
                [String: AgentCommandPlacement].self,
                forKey: .builtInPlacements
            ) ?? [:]
        }
    }

    private static let supportedAgents = AgentKind.allCases

    static func decode(_ data: Data) -> Source? {
        guard let profiles = try? JSONDecoder().decode(
            [LegacyProfile].self,
            from: data
        ) else { return nil }

        var byKey: [ProfileKey: LegacyProfile] = [:]
        for profile in profiles {
            let key = ProfileKey(hostID: profile.hostID, agent: profile.agent)
            if byKey[key] == nil { byKey[key] = profile }
        }
        return Source(profilesByKey: byKey)
    }
}
