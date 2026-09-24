import Foundation

/// Pure ordering/normalization behind the working-directory pickers — the
/// Open Agent Shortcut's provider (app process, live `HostStore` dirs) and
/// the Host widget's configuration provider (widget process, snapshot
/// dirs). Lives in Shared so the widget target can offer the same rows
/// without compiling the Host model; the `"~"` and empty-value semantics
/// belong to the app-side quoting/URL layers.
enum ShortcutWorkingDirectoryOptions {
    struct Choice: Equatable {
        var value: String
        var title: String
    }

    /// The empty value is the "host default" sentinel, like
    /// `AgentModelChoices.agentDefaultValue`: the widget link builder skips
    /// it, so the launch falls to the host's first configured directory.
    static let hostDefaultValue = ""

    /// The configured dirs in the host's order — trimmed, deduped, `~`
    /// dropped — with Home (`"~"`) always last.
    static func values(configured: [String]) -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        for raw in configured {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, path != "~", seen.insert(path).inserted else { continue }
            values.append(path)
        }
        values.append("~")
        return values
    }

    /// Widget-config rows: Host Default leads (the widget sheet has no
    /// "unset" affordance once a value is picked, and a zero-item options
    /// query flash-dismisses the picker), then the configured dirs, then
    /// Home titled as such.
    static func choices(configured: [String]) -> [Choice] {
        var choices = [Choice(value: hostDefaultValue, title: String(localized: "Host Default"))]
        choices += values(configured: configured).dropLast().map {
            Choice(value: $0, title: $0)
        }
        choices.append(Choice(value: "~", title: String(localized: "Home")))
        return choices
    }
}
