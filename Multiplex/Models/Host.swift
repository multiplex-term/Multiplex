import Foundation

/// A remote machine reachable over SSH. Secrets live in the Keychain, keyed by `id`.
struct Host: Identifiable, Codable, Hashable {
    enum AuthMethod: String, Codable, CaseIterable, Identifiable {
        case password
        case privateKey

        var id: String { rawValue }
        var label: String {
            switch self {
            case .password: "Password"
            case .privateKey: "Private key"
            }
        }
    }

    var id: UUID = UUID()
    var name: String
    var hostname: String
    var port: Int = 22
    var username: String
    var authMethod: AuthMethod = .password
    /// Attach terminals over mosh (SSP over UDP) instead of the SSH PTY.
    /// The credentials above still authenticate the SSH bootstrap that
    /// launches `mosh-server`; deck probing stays on SSH either way.
    var useMosh: Bool = false
    /// Absolute path to `mosh-server` when it isn't on the exec PATH.
    var moshServerPath: String?
    /// UDP port or range ("60000:61000") handed to `mosh-server -p`.
    var moshPorts: String?
    /// Remote directories new sessions can start in, in the user's order —
    /// the first is the default; the rest are choices in the New Session
    /// prompt. Empty means $HOME.
    var workingDirs: [String] = []
    /// Bumped on every user edit. When the same host arrives from another
    /// device via the Keychain mirror, the newer record wins.
    var updatedAt: Date = .distantPast

    var address: String {
        port == 22 ? "\(username)@\(hostname)" : "\(username)@\(hostname):\(port)"
    }
}

// Decoding lives in an extension so the memberwise initializer survives.
// Fields added after 1.0 (`updatedAt`) are optional on decode: a hosts.json
// or mirrored record written by an older build must not drop the whole list.
extension Host {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        hostname = try container.decode(String.self, forKey: .hostname)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try container.decode(String.self, forKey: .username)
        authMethod = try container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .password
        useMosh = try container.decodeIfPresent(Bool.self, forKey: .useMosh) ?? false
        moshServerPath = try container.decodeIfPresent(String.self, forKey: .moshServerPath)
        moshPorts = try container.decodeIfPresent(String.self, forKey: .moshPorts)
        workingDirs = try container.decodeIfPresent([String].self, forKey: .workingDirs) ?? []
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}
