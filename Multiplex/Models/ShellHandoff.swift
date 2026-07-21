import Foundation

/// The silent tmux handoff types its command as the login shell's first
/// stdin line — bytes that sit in the PTY queue while the shell's rc files
/// run, where any rc-time reader can steal them. oh-my-zsh's update check
/// is the common thief, in two shapes:
/// - Old versions `read -k 1` a single key: the `e` of `exec` answered the
///   prompt and the shell then ran the broken remainder (`xec tmux …`).
/// - Current versions drain every buffered byte ("input sink") before
///   blocking on `[oh-my-zsh] Would you like to update? [Y/n]` — the whole
///   command vanishes and the tab lands in a bare shell.
///
/// Two defenses, both riding the existing ECHO-off injection:
/// - `payload(for:)` prefixes a sacrificial `:` line. A single-key reader
///   consumes the one-byte no-op as its "skip" answer, a line reader
///   consumes a no-op line — either way the command line survives intact.
/// - `UpdatePromptWatch` spots the blocked update prompt in early PTY
///   output so the controller can re-type the swallowed payload; its `:`
///   answers the pending prompt and the command then attaches. This is
///   race-safe against the user answering first: the `:` line degrades to
///   a shell no-op.
enum ShellHandoff {
    /// The stdin bytes for a PTY handoff command. The leading `:` line is a
    /// POSIX no-op (also a no-op in csh); it exists only to be eaten.
    static func payload(for command: String) -> String {
        ":\n" + command + "\n"
    }

    /// Watches the first stretch of PTY output for the oh-my-zsh update
    /// prompt. Pure and chunk-boundary-safe: callers feed raw output bytes
    /// and act on the verdict. Watching ends at the first prompt match, at
    /// tmux's alternate-screen takeover (the handoff visibly succeeded), or
    /// after `scanLimit` bytes — the prompt only ever appears while rc files
    /// run, so a bounded window cannot false-positive on session output.
    struct UpdatePromptWatch {
        enum Verdict {
            /// Keep feeding output.
            case watching
            /// The update prompt is on screen and has swallowed the handoff
            /// line — re-type the payload. Terminal state; the watch is done.
            case promptDetected
            /// The handoff succeeded or the window closed; stop feeding.
            case done
        }

        /// Both prompt shapes omz has shipped, lowercased. The full phrase
        /// (not just "oh-my-zsh") so banner/MOTD mentions can't match.
        private static let promptNeedles = [
            "would you like to update? [y/n]",
            "would you like to check for updates? [y/n]",
        ]
        /// tmux enters the alternate screen when the attach lands.
        private static let attachedNeedle = "\u{1b}[?1049h"
        private static let windowLength = 256
        private static let scanLimit = 32_768

        private var window = ""
        private var scannedBytes = 0
        private var finished = false

        mutating func consume(_ bytes: some Sequence<UInt8>) -> Verdict {
            if finished { return .done }
            for byte in bytes {
                scannedBytes += 1
                // Lowercased Latin-1 keeps ESC (for the attach marker) and
                // stays a 1:1 byte→character map, so needles can't be split
                // by a decoder buffering partial UTF-8 sequences.
                let scalar = (0x41...0x5A).contains(byte) ? byte | 0x20 : byte
                window.append(Character(UnicodeScalar(scalar)))
                if window.count > Self.windowLength {
                    window.removeFirst(window.count - Self.windowLength)
                }
                if window.contains(Self.attachedNeedle) {
                    finished = true
                    return .done
                }
                if Self.promptNeedles.contains(where: window.contains) {
                    finished = true
                    return .promptDetected
                }
                if scannedBytes >= Self.scanLimit {
                    finished = true
                    return .done
                }
            }
            return .watching
        }
    }
}
