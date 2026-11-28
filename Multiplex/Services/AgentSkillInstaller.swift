import Foundation

/// The host sheet's INSTALL SKILL button: one throwaway SSH connection
/// using the form's (possibly unsaved) credentials, running
/// `mpx skill install --json` on the host.
///
/// It goes through the same PTY-less login shell the bridge does, not an
/// exec: an exec gets sshd's bare PATH, and would report "mpx is missing"
/// on a host where the agent browser — started through the login shell —
/// is working. Script and answer parsing live in `AgentSkillInstall`.
enum AgentSkillInstaller {
    /// From the shell opening to mpx's answer. The command itself writes two
    /// small files; the time goes to the login shell's rc files.
    static let answerDeadline: Double = 20
    /// Login-shell chatter the reader has not consumed yet; more is dropped.
    private static let maxPendingReads = 256

    static func run(host: Host, secrets: HostSecrets) async -> AgentSkillInstall.Outcome {
        let connection = SSHConnection(host: host, secrets: secrets)
        defer { Task { await connection.close() } }
        do {
            // Citadel connects can black-hole and ignore cancellation.
            try await deadlined(seconds: HostTest.connectDeadline) { try await connection.connect() }
        } catch {
            return .unreachable(HostTest.failureMessage(for: error, host: host))
        }
        let payload = AgentSkillInstall.payload(preferred: AgentBrowserLaunch.preferredCLI)
        do {
            return try await deadlined(seconds: answerDeadline) {
                try await answer(over: connection, payload: payload)
            }
        } catch is DeadlineExceeded {
            return .silent
        } catch {
            return .unreachable(HostTest.failureMessage(for: error, host: host))
        }
    }

    private enum Event: Sendable {
        case stdout(Data)
        case stderr(Data)
        case closed(String?)
    }

    private static func answer(
        over connection: SSHConnection,
        payload: String
    ) async throws -> AgentSkillInstall.Outcome {
        let (events, sink) = AsyncStream<Event>.makeStream(
            bufferingPolicy: .bufferingOldest(maxPendingReads)
        )
        try await connection.openLineChannel(
            payload: payload,
            onStdout: { sink.yield(.stdout($0)) },
            onStderr: { sink.yield(.stderr($0)) },
            onClose: { detail in
                sink.yield(.closed(detail))
                sink.finish()
            }
        )
        var buffer = AgentBrowserWire.LineBuffer()
        var stderr = ""
        var detail: String?
        for await event in events {
            switch event {
            case .stdout(let data):
                for line in buffer.append(data) {
                    if let outcome = AgentSkillInstall.outcome(fromLine: line) { return outcome }
                }
            case .stderr(let data):
                stderr = String((stderr + String(decoding: data, as: UTF8.self)).suffix(2048))
            case .closed(let reason):
                detail = reason
            }
        }
        return AgentSkillInstall.outcome(endedWith: detail, stderr: stderr)
    }

    // MARK: Wording (pure)

    /// What to tell the person when the skill is not (fully) on the host.
    /// nil for a clean install — the view lists the files instead.
    static func failureMessage(for outcome: AgentSkillInstall.Outcome, host: Host) -> String? {
        switch outcome {
        case .installed:
            return nil
        case .incomplete(_, let refused):
            guard !refused.isEmpty else {
                return String(localized: "mpx on \(host.hostname) reported nothing installed. Try again.")
            }
            return refused.map {
                String(localized: "mpx couldn't write the skill into \($0.directory): \($0.reason)")
            }.joined(separator: "\n")
        case .missingCLI:
            return String(localized: """
                mpx wasn't found on \(host.hostname). Install it there \
                (brew install multiplex-term/tap/mpx), then try again.
                """)
        case .outdatedCLI:
            return String(localized: """
                The mpx on \(host.hostname) is too old to install the skill. \
                Update it to 0.2 or later, then try again.
                """)
        case .failed(let said):
            return said.isEmpty
                ? String(localized: """
                    \(host.hostname) closed the shell before mpx answered. Try again, \
                    or run `mpx skill install` there yourself.
                    """)
                : String(localized: "mpx on \(host.hostname) couldn't install the skill: \(said)")
        case .silent:
            return String(localized: """
                No answer from mpx on \(host.hostname) after \(Int(answerDeadline)) seconds. \
                Try again, or run `mpx skill install` there yourself.
                """)
        case .unreachable(let message):
            return message
        }
    }
}
