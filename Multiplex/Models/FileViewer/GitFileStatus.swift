import Foundation

/// One porcelain-v1 status entry, reduced to the letter vocabulary the
/// file viewer speaks: the deck-style badge on tree rows and the CHANGED
/// filter's population. Pure parsing of `git status --porcelain -z`.
struct GitFileStatus: Equatable {
    /// The viewer's letters, not git's: git's own U means "unmerged", but a
    /// standing column has more use for "untracked" — conflicts get the
    /// louder mark.
    enum Badge: String, Equatable {
        case modified = "M"
        case added = "A"
        case deleted = "D"
        case renamed = "R"
        case untracked = "U"
        case conflicted = "!"
    }

    /// Path relative to the repo root, exactly as git reports it.
    var path: String
    /// The rename origin, when this entry is a rename.
    var originPath: String?
    var badge: Badge

    /// Parses `git status --porcelain=v1 -z` (NUL-separated, no quoting —
    /// that is the whole point of -z). A rename entry's origin path follows
    /// the target path as its own NUL token.
    static func parse(porcelainZ text: String) -> [GitFileStatus] {
        var entries: [GitFileStatus] = []
        let tokens = text.split(separator: "\0", omittingEmptySubsequences: true)
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            // "XY PATH" — two status letters, one space, then the path.
            guard token.count >= 4 else { continue }
            let x = token[token.startIndex]
            let y = token[token.index(after: token.startIndex)]
            let path = String(token.dropFirst(3))
            var origin: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                // A rename/copy in either column carries ORIG_PATH as the
                // next -z token.
                if index < tokens.count {
                    origin = String(tokens[index])
                    index += 1
                }
            }
            guard let badge = badge(x: x, y: y) else { continue }
            entries.append(GitFileStatus(path: path, originPath: origin, badge: badge))
        }
        return entries
    }

    /// X = index status, Y = worktree status. Display collapses the pair:
    /// conflicts loudest, untracked its own thing, then whichever side
    /// moved. `!!` (ignored) is never requested and drops if it appears.
    private static func badge(x: Character, y: Character) -> Badge? {
        if x == "?" || y == "?" { return .untracked }
        if x == "!" || y == "!" { return nil }
        // Any unmerged combination: DD, AA, or anything carrying U.
        if x == "U" || y == "U" || (x == "D" && y == "D") || (x == "A" && y == "A") {
            return .conflicted
        }
        if x == "R" || x == "C" || y == "R" || y == "C" { return .renamed }
        if y == "D" || x == "D" { return .deleted }
        if x == "A" { return .added }
        // M/T on either side, and any pair porcelain grows later.
        return .modified
    }
}

/// `git diff --shortstat` reduced to the tree header's ± counts.
/// "3 files changed, 42 insertions(+), 17 deletions(-)" — every piece is
/// optional (a pure-deletion diff has no insertions clause; an empty diff
/// prints nothing at all).
struct GitShortStat: Equatable {
    var filesChanged = 0
    var insertions = 0
    var deletions = 0

    var isEmpty: Bool { filesChanged == 0 && insertions == 0 && deletions == 0 }

    static func parse(_ text: String) -> GitShortStat {
        var stat = GitShortStat()
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return stat }
        for clause in line.split(separator: ",") {
            let words = clause.split(separator: " ")
            guard let number = words.first.flatMap({ Int($0) }) else { continue }
            let clauseText = clause.lowercased()
            if clauseText.contains("file") { stat.filesChanged = number }
            else if clauseText.contains("insertion") { stat.insertions = number }
            else if clauseText.contains("deletion") { stat.deletions = number }
        }
        return stat
    }
}
