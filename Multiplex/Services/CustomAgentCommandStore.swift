import Foundation
import Observation

/// Device-local custom helper commands. Agent-specific rows remain independent;
/// a shared row is mirrored with the same UUID into both profiles so either
/// editor can update it without creating divergent copies. This mirrors
/// ThemeStore: user-authored data is pretty-printed JSON in Application
/// Support, while no remote host or keychain record changes merely by editing
/// terminal UI.
@MainActor
@Observable
final class CustomAgentCommandStore {
    private(set) var commandsByAgent: [AgentKind: [CustomAgentCommand]] = [:]

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Multiplex", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            self.fileURL = directory.appendingPathComponent("agent-commands.json")
        }
        load()
    }

    func commands(for agent: AgentKind) -> [CustomAgentCommand] {
        commandsByAgent[agent] ?? []
    }

    func replace(_ commands: [CustomAgentCommand], for agent: AgentKind) {
        let previous = commandsByAgent[agent] ?? []
        let resolved = CustomAgentCommand.normalized(commands)

        setProfile(resolved, for: agent)

        // The edited profile is authoritative for every shared row it
        // previously contained. Unsharing or deleting withdraws that UUID
        // from the other profile; retained/new shared rows update in place or
        // append there. Equivalent local actions become the shared row rather
        // than producing duplicate chips with different UUIDs.
        let other = otherAgent(than: agent)
        let previousSharedIDs = Set(previous.filter(\.shared).map(\.id))
        let currentShared = resolved.filter(\.shared)
        let currentSharedIDs = Set(currentShared.map(\.id))

        var otherCommands = commandsByAgent[other] ?? []
        let withdrawnIDs = previousSharedIDs.subtracting(currentSharedIDs)
        otherCommands.removeAll { withdrawnIDs.contains($0.id) }
        for command in currentShared {
            upsertShared(command, into: &otherCommands)
        }
        setProfile(CustomAgentCommand.normalized(otherCommands), for: other)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let profiles = try? JSONDecoder().decode([Profile].self, from: data)
        else { return }

        var loaded: [AgentKind: [CustomAgentCommand]] = [:]
        for profile in profiles where loaded[profile.agent] == nil {
            let commands = CustomAgentCommand.normalized(profile.commands)
            if !commands.isEmpty { loaded[profile.agent] = commands }
        }
        commandsByAgent = loaded
        reconcileSharedCommands()
    }

    private func save() {
        let profiles = [AgentKind.claudeCode, .codex].compactMap { agent -> Profile? in
            guard let commands = commandsByAgent[agent], !commands.isEmpty else { return nil }
            return Profile(agent: agent, commands: commands)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private struct Profile: Codable {
        var agent: AgentKind
        var commands: [CustomAgentCommand]
    }

    private static let supportedAgents: [AgentKind] = [.claudeCode, .codex]

    private func otherAgent(than agent: AgentKind) -> AgentKind {
        switch agent {
        case .claudeCode: .codex
        case .codex: .claudeCode
        }
    }

    private func setProfile(_ commands: [CustomAgentCommand], for agent: AgentKind) {
        if commands.isEmpty {
            commandsByAgent.removeValue(forKey: agent)
        } else {
            commandsByAgent[agent] = commands
        }
    }

    private func upsertShared(
        _ command: CustomAgentCommand,
        into commands: inout [CustomAgentCommand]
    ) {
        if let index = commands.firstIndex(where: { $0.id == command.id }) {
            commands[index] = command
        } else if let index = commands.firstIndex(where: { $0.hasSameAction(as: command) }) {
            commands[index] = command
        } else {
            commands.append(command)
        }
    }

    /// Older or manually edited JSON may contain a shared command in only one
    /// profile. Restore the same in-memory invariant used by `replace`; the
    /// next user save persists the repaired mirror atomically.
    private func reconcileSharedCommands() {
        let sharedCommands = Self.supportedAgents.flatMap {
            (commandsByAgent[$0] ?? []).filter(\.shared)
        }
        var reconciledIDs = Set<UUID>()

        for command in sharedCommands where reconciledIDs.insert(command.id).inserted {
            for agent in Self.supportedAgents {
                var commands = commandsByAgent[agent] ?? []
                upsertShared(command, into: &commands)
                setProfile(CustomAgentCommand.normalized(commands), for: agent)
            }
        }
    }
}
