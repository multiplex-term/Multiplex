import Foundation

/// One named setup script for a host. When a new session is created, the
/// chosen script is typed into the fresh login shell before the optional
/// agent launch line, so whatever it sets up (nvm, a virtualenv, sourced
/// secrets) is live for the launch — and for the shell when nothing
/// launches. Typing is sequential, never gated: the launch line still runs
/// when the script fails, with the failure visible above it. Attaching to
/// an existing session never types anything.
///
/// Scripts are part of the Codable `Host` record, so they follow the host
/// across devices through the synchronizable Keychain mirror. They never
/// enter the widget projection.
struct SessionScript: Identifiable, Hashable {
    /// Menu rows and captions keep at most this many characters of a
    /// nameless script's first line.
    private static let maximumFallbackNameLength = 36

    var id: UUID = UUID()
    /// Optional label; `displayName` falls back to the body's first line.
    var name: String = ""
    var body: String = ""

    /// The canonical bytes persisted and typed — the custom-command policy:
    /// normalize pasted Windows/classic-Mac line endings, strip invisible
    /// terminal controls (especially tmux's Ctrl-B prefix), keep interior
    /// tabs and newlines, trim only the outside.
    var normalizedBody: String {
        let normalizedLineEndings = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let safeText = normalizedLineEndings.unicodeScalars.reduce(into: "") {
            result, scalar in
            let allowedControl = scalar.value == 0x09 || scalar.value == 0x0A
            if allowedControl || !CharacterSet.controlCharacters.contains(scalar) {
                result.append(Character(scalar))
            }
        }
        return safeText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Picker and row title: the trimmed name, or the body's first line
    /// truncated when the name is blank — a fragment beats an unlabeled row.
    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { return trimmedName }
        let firstLine = normalizedBody
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        let collapsed = firstLine
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "Script" }
        guard collapsed.count > Self.maximumFallbackNameLength else { return collapsed }
        return String(collapsed.prefix(Self.maximumFallbackNameLength - 1)) + "…"
    }

    /// Resolve editor rows before persistence: canonicalize bodies, trim
    /// names, drop rows with nothing to type, and keep ids unique. Ids are
    /// load-bearing — the remembered-selection memory points at them — so
    /// normalization never reminted an id.
    static func normalized(_ scripts: [SessionScript]) -> [SessionScript] {
        var seenIDs = Set<UUID>()
        var result: [SessionScript] = []
        for var script in scripts {
            let body = script.normalizedBody
            guard !body.isEmpty, seenIDs.insert(script.id).inserted else { continue }
            script.body = body
            script.name = script.name.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(script)
        }
        return result
    }
}

// Decoding lives in an extension so the memberwise initializer survives.
// Every field is optional on decode — a record written by a newer schema on
// another device must not drop the whole host list.
extension SessionScript: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
    }
}
