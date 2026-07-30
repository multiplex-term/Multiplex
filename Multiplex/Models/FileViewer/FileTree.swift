import Foundation

/// One remote directory entry, as the controller learned it from SFTP.
/// Pure value — Citadel types never cross into Models.
struct FileTreeEntry: Equatable, Identifiable {
    var name: String
    /// Absolute remote path.
    var path: String
    var isDirectory: Bool
    var isSymlink = false
    var size: UInt64?

    var id: String { path }
}

/// Pure tree bookkeeping: sorting, expansion → visible rows, git badges,
/// and the CHANGED flattening. The controller owns the caches; this owns
/// the rules.
enum FileTree {
    struct Row: Equatable, Identifiable {
        var entry: FileTreeEntry
        var depth: Int
        var isExpanded = false
        /// nil while a directory's children haven't been listed yet.
        var badge: GitFileStatus.Badge?
        /// A directory holding changes gets a dot, not a letter — the
        /// letter belongs to the file that earned it.
        var containsChanges = false

        var id: String { entry.path }
    }

    /// The names every code editor hides by default (VS Code's
    /// files.exclude set plus each platform's litter) — invisible to the
    /// tree everywhere: rows, the CHANGED list, and the change-dot trail,
    /// so a stray untracked .DS_Store can't light a directory whose
    /// expansion then shows nothing. Deliberately NOT all dotfiles:
    /// .gitignore, .env, .zshrc are files people open, and this is a dev
    /// tool. Content is untouched — a pressed path into .git still opens;
    /// only the tree declines to advertise it.
    static let hiddenNames: Set<String> = [
        ".git", ".svn", ".hg", "CVS", ".DS_Store", "Thumbs.db",
    ]

    static func isHidden(_ name: String) -> Bool {
        hiddenNames.contains(name)
    }

    /// A repo-relative status path touching any hidden component (the
    /// .DS_Store itself, or anything under a hidden directory).
    private static func statusIsHidden(_ path: String) -> Bool {
        path.split(separator: "/").contains { hiddenNames.contains(String($0)) }
    }

    /// Directories first, then files, case-insensitive by name — the one
    /// order every file browser owes its user.
    static func sorted(_ entries: [FileTreeEntry]) -> [FileTreeEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let byName = a.name.localizedCaseInsensitiveCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.name < b.name
        }
    }

    /// Flattens the loaded tree into visible rows: expanded directories
    /// contribute their (already listed) children; an expanded directory
    /// whose listing hasn't arrived contributes only itself.
    static func rows(
        root: String,
        children: [String: [FileTreeEntry]],
        expanded: Set<String>,
        badges: [String: GitFileStatus.Badge],
        changedDirectories: Set<String>
    ) -> [Row] {
        var rows: [Row] = []
        appendRows(
            of: root, depth: 0,
            children: children, expanded: expanded,
            badges: badges, changedDirectories: changedDirectories,
            into: &rows
        )
        return rows
    }

    private static func appendRows(
        of directory: String,
        depth: Int,
        children: [String: [FileTreeEntry]],
        expanded: Set<String>,
        badges: [String: GitFileStatus.Badge],
        changedDirectories: Set<String>,
        into rows: inout [Row]
    ) {
        guard let entries = children[directory] else { return }
        for entry in sorted(entries) where !isHidden(entry.name) {
            let isExpanded = entry.isDirectory && expanded.contains(entry.path)
            rows.append(Row(
                entry: entry,
                depth: depth,
                isExpanded: isExpanded,
                badge: entry.isDirectory ? nil : badges[entry.path],
                containsChanges: entry.isDirectory
                    && changedDirectories.contains(entry.path)
            ))
            if isExpanded {
                appendRows(
                    of: entry.path, depth: depth + 1,
                    children: children, expanded: expanded,
                    badges: badges, changedDirectories: changedDirectories,
                    into: &rows
                )
            }
        }
    }

    /// Absolute-path badge map from repo-root-relative statuses.
    static func badges(
        statuses: [GitFileStatus],
        repoRoot: String
    ) -> [String: GitFileStatus.Badge] {
        var map: [String: GitFileStatus.Badge] = [:]
        for status in statuses {
            map[join(repoRoot, status.path)] = status.badge
        }
        return map
    }

    /// Every directory that holds a change, up to (and excluding) the repo
    /// root — the tree marks the trail to what moved. Hidden-set statuses
    /// don't count: a dot must never point at a row the tree won't show.
    static func changedDirectories(
        statuses: [GitFileStatus],
        repoRoot: String
    ) -> Set<String> {
        var set: Set<String> = []
        for status in statuses where !statusIsHidden(status.path) {
            var components = status.path.split(separator: "/").dropLast()
            while !components.isEmpty {
                set.insert(join(repoRoot, components.joined(separator: "/")))
                components = components.dropLast()
            }
        }
        return set
    }

    /// The CHANGED filter's flat rows: repo-relative paths straight from
    /// porcelain, no directory nesting — the review index. Same hidden-set
    /// rule as the tree.
    static func changedRows(
        statuses: [GitFileStatus],
        repoRoot: String
    ) -> [Row] {
        statuses
            .filter { !statusIsHidden($0.path) }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
            .map { status in
                Row(
                    entry: FileTreeEntry(
                        name: status.path,
                        path: join(repoRoot, status.path),
                        isDirectory: false
                    ),
                    depth: 0,
                    badge: status.badge
                )
            }
    }

    static func join(_ directory: String, _ relative: String) -> String {
        if directory.hasSuffix("/") { return directory + relative }
        return directory + "/" + relative
    }

    /// The parent directory of an absolute path; nil at the filesystem root.
    static func parent(of path: String) -> String? {
        guard path != "/", let slash = path.lastIndex(of: "/") else { return nil }
        if slash == path.startIndex { return "/" }
        return String(path[..<slash])
    }

    static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"),
              slash != path.index(before: path.endIndex)
        else { return path }
        return String(path[path.index(after: slash)...])
    }
}
