import Foundation

/// The one exec that must never carry the POSIX PATH prelude: sshd runs exec
/// requests through the account's login shell, including fish and csh.
enum RemoteShellDiagnosis {
    static let command = "echo \"$SHELL\""

    static func shellName(from output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline)
            .lazy.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else { return nil }
        // These are remote POSIX paths, not URLs; backslashes stay literal.
        return (line as NSString).lastPathComponent
    }

    static let posixShells: Set<String> = [
        "sh", "bash", "zsh", "dash", "ash", "ksh", "mksh", "pdksh", "yash", "busybox",
    ]

    struct Rejection: Error, Equatable {
        var exitCode: Int
        var stderrHead: String
        var shellName: String?

        func message(host: Host) -> String {
            if let shellName, !posixShells.contains(shellName) {
                return String(localized: """
                    \(host.name)'s login shell is \(shellName). Multiplex's remote commands need a POSIX shell \
                    such as bash or zsh — change the account's login shell (chsh) or keep \(shellName) \
                    for interactive use only.
                    """)
            }
            let firstLine = stderrHead.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let code = String(exitCode)
            if let shellName {
                if firstLine.isEmpty {
                    return String(localized: """
                        \(host.name)'s shell (\(shellName)) rejected Multiplex's commands (exit \(code))
                        """)
                }
                return String(localized: """
                    \(host.name)'s shell (\(shellName)) rejected Multiplex's commands (exit \(code)): \(firstLine)
                    """)
            }
            if firstLine.isEmpty {
                return String(localized: "\(host.name) rejected Multiplex's commands (exit \(code))")
            }
            return String(localized: "\(host.name) rejected Multiplex's commands (exit \(code)): \(firstLine)")
        }
    }
}
