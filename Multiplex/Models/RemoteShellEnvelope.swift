import Foundation

/// Cross-login-shell carriers for POSIX scripts. Exec owns stdin; a PTY
/// handoff must leave it connected to the terminal for tmux/herdr.
enum RemoteShellEnvelope {
    /// Always `sh`: POSIX guarantees it, and every builder is written for it.
    static let shell = "sh"

    static func format(_ payload: String) -> String {
        payload.unicodeScalars.map { scalar in
            switch scalar {
            case "'": "\\047"
            case "\\": "\\134"
            case "!": "\\041"
            case "\n": "\\012"
            case "%": "%%"
            default: String(scalar)
            }
        }.joined()
    }

    static func exec(_ payload: String) -> String {
        // An empty compound list is invalid POSIX syntax. A no-op preserves
        // the ordinary empty-exec result without adding a success tail.
        let script = payload.isEmpty ? ":" : payload
        return "printf '" + format("{\n" + script + "\n} </dev/null\n") + "' | " + shell
    }

    static func handoff(_ payload: String) -> String {
        let script: String
        if isUniversallyQuotable(payload) {
            script = payload
        } else {
            // Route arguments already contain POSIX quotes. Nesting them
            // literally in outer single quotes loses argv boundaries. Decode
            // a printf carrier INSIDE sh, then evaluate the original script.
            // Quote/dollar/backtick also need encoding here because the
            // inner printf format is double-quoted. Single \ooo escapes survive fish/csh verbatim;
            // unlike \\ or \', they have no meaning inside fish single quotes.
            // printf alone owns the substitution pipe; eval inherits the tty.
            let encoded = format(payload)
                .replacingOccurrences(of: "\"", with: "\\042")
                .replacingOccurrences(of: "$", with: "\\044")
                .replacingOccurrences(of: "`", with: "\\140")
            script = "eval \"$(printf \"" + encoded + "\")\""
        }
        return "exec " + shell + " -c '" + script + "'"
    }

    /// Eligibility for the literal handoff fast path, NOT for a printf
    /// format (which necessarily contains single backslash octal escapes).
    static func isUniversallyQuotable(_ value: String) -> Bool {
        !value.unicodeScalars.contains { "'\\!\n".unicodeScalars.contains($0) }
    }

    static func octal(_ value: String) -> String {
        value.utf8.map { String(format: "\\%03o", Int($0)) }.joined()
    }
}
