import Foundation

/// When an agent may bring its tab to the front (`show`, `open --focus`).
///
/// Taking the user's focus is the one agent action that interrupts them —
/// and the one a compromised host could repeat to put a phishing page in
/// front of them. So it is never granted while they are typing, and at most
/// once per `cooldown` per host. A refusal is an answer, not an error the
/// agent should retry around: the tab still exists and still works behind.
/// Pure.
struct AgentFocusGate: Equatable {
    static let cooldown: TimeInterval = 30
    /// Keystrokes this recent mean the user is mid-thought.
    static let typingQuiet: Duration = .seconds(5)

    enum Verdict: Equatable {
        case allow
        case userTyping
        /// Seconds until this host may take focus again.
        case coolingDown(TimeInterval)

        var refusalMessage: String? {
            switch self {
            case .allow:
                nil
            case .userTyping:
                "The user is typing, so the tab stayed behind. It still works there; "
                    + "ask them to look when they are free."
            case .coolingDown(let wait):
                "This host already took the user's focus in the last \(Int(AgentFocusGate.cooldown)) s; "
                    + "the tab stayed behind (try again in \(Int(wait.rounded(.up))) s, or ask the user)."
            }
        }
    }

    private var lastGranted: [UUID: TimeInterval] = [:]

    /// Decides, and records a grant.
    mutating func request(hostID: UUID, now: TimeInterval, userTyping: Bool) -> Verdict {
        if userTyping { return .userTyping }
        if let last = lastGranted[hostID], now - last < Self.cooldown {
            return .coolingDown(Self.cooldown - (now - last))
        }
        lastGranted[hostID] = now
        return .allow
    }
}
