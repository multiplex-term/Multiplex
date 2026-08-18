import Foundation

/// Which platforms a release note is true for. Resolved by the view (the
/// models layer imports no UIKit), the way `TerminalGuideContext` already is.
enum ReleaseNotePlatform: CaseIterable, Equatable {
    case phone
    case pad
    case vision

    static let all: Set<ReleaseNotePlatform> = Set(allCases)
    static let iOS: Set<ReleaseNotePlatform> = [.phone, .pad]
}

/// The banks the full record is grouped into, in reading order.
enum ReleaseNoteBank: CaseIterable, Equatable {
    case backends
    case terminal
    case away
    case appearance
    case elsewhere

    var title: String {
        switch self {
        case .backends: String(localized: "BACKENDS")
        case .terminal: String(localized: "TERMINAL")
        case .away: String(localized: "WHILE YOU’RE AWAY")
        case .appearance: String(localized: "APPEARANCE")
        case .elsewhere: String(localized: "ELSEWHERE")
        }
    }
}

/// One change, as the full record states it.
struct ReleaseNoteEntry: Equatable {
    let id: String
    let bank: ReleaseNoteBank
    let title: String
    let body: String
    /// Shown only where the change is platform-scoped — an entry every
    /// platform gets would spend a row saying so.
    let tag: String?
    let platforms: Set<ReleaseNotePlatform>
    /// Short noun phrase for the card's "also in" line. Entries without one
    /// are still counted there, just not named.
    let mention: String?
}

/// One row of the launch card. It summarises one or more entries of the full
/// record, and `covers` is what keeps the card's "also" line from re-naming
/// something the card already said.
struct ReleaseNoteHighlight: Equatable {
    let id: String
    let covers: Set<String>
    let title: String
    let body: String
    let tag: String?
    let platforms: Set<ReleaseNotePlatform>
}

/// One release's record: its promise line, every entry, and the card rows
/// that summarise them. `ReleaseNotes.releases` keeps one per release the
/// full log still carries, so a reader updating across two releases at once
/// is shown the newest card and misses neither record.
struct ReleaseNotesRelease: Equatable {
    let version: String
    /// The one sentence the release notes already lead with.
    let promise: String
    let entries: [ReleaseNoteEntry]
    /// Order matters: the card takes the first `ReleaseNotes.highlightCount`
    /// that this platform gets, so each device's fourth row is the one that
    /// is actually about it.
    let highlights: [ReleaseNoteHighlight]

    func entries(for platform: ReleaseNotePlatform) -> [ReleaseNoteEntry] {
        entries.filter { $0.platforms.contains(platform) }
    }

    /// The full record, grouped. A bank with nothing on this platform is
    /// dropped whole — an empty APPEARANCE header on iPad would be a heading
    /// for nothing.
    func banks(
        for platform: ReleaseNotePlatform
    ) -> [(bank: ReleaseNoteBank, entries: [ReleaseNoteEntry])] {
        let visible = entries(for: platform)
        return ReleaseNoteBank.allCases.compactMap { bank in
            let banked = visible.filter { $0.bank == bank }
            return banked.isEmpty ? nil : (bank, banked)
        }
    }

    func highlights(for platform: ReleaseNotePlatform) -> [ReleaseNoteHighlight] {
        Array(
            highlights
                .filter { $0.platforms.contains(platform) }
                .prefix(ReleaseNotes.highlightCount)
        )
    }

    /// What the card admits it is leaving out: the first three unshown changes
    /// by name, then a count of the rest. Derived rather than authored, so it
    /// can never drift from what the card above it is actually showing.
    func alsoLine(for platform: ReleaseNotePlatform) -> String? {
        let shown = highlights(for: platform).reduce(into: Set<String>()) {
            $0.formUnion($1.covers)
        }
        let remaining = entries(for: platform).filter { !shown.contains($0.id) }
        guard !remaining.isEmpty else { return nil }

        let named = remaining.compactMap(\.mention).prefix(3)
        let unnamed = remaining.count - named.count
        guard !named.isEmpty else {
            let noun = unnamed == 1
                ? String(localized: "change")
                : String(localized: "changes")
            return String(localized: "Also in \(version): \(unnamed) more \(noun).")
        }

        var sentence = String(localized: "Also in \(version): ")
            + Self.listed(Array(named), closing: unnamed == 0)
        if unnamed > 0 {
            sentence += String(localized: " — and \(unnamed) more.")
        }
        return sentence
    }

    /// "a, b, and c" when the list ends the sentence; "a, b, c" when a count
    /// is about to follow it.
    private static func listed(_ items: [String], closing: Bool) -> String {
        let comma = String(localized: ", ")
        guard closing, items.count > 1 else { return items.joined(separator: comma) }
        guard items.count > 2 else {
            return items[0] + String(localized: " and \(items[1]).")
        }
        return items.dropLast().joined(separator: comma)
            + String(localized: ", and \(items[items.count - 1]).")
    }
}

/// What each release changed, said once. The launch card renders the newest
/// release's `highlights`; the full record renders every release's `banks`,
/// newest first. Both filter by platform, so GLASS is never promised to an
/// iPad and background keep-alive never to a Vision Pro.
///
/// Reconciled with `fastlane/metadata/*/release_notes_*.txt` whenever it
/// changes — same release, same words (docs/agents/release-and-metadata.md).
enum ReleaseNotes {
    /// Newest first. The launch card speaks only for the first; the log
    /// carries them all.
    static let releases: [ReleaseNotesRelease] = [v131, v13]

    /// The release the launch card announces.
    static var current: ReleaseNotesRelease { releases[0] }

    /// Deliberately not the running build's `CFBundleShortVersionString`:
    /// this moves only when new notes are written, so a patch build without
    /// notes of its own cannot present itself as a release that has some.
    static var version: String { current.version }

    static var promise: String { current.promise }

    /// The card is a five-second read. Four rows is what fits every device
    /// without scrolling; the rest is one press away.
    static let highlightCount = 4

    static var allEntries: [ReleaseNoteEntry] { current.entries }
    static var allHighlights: [ReleaseNoteHighlight] { current.highlights }

    static func entries(for platform: ReleaseNotePlatform) -> [ReleaseNoteEntry] {
        current.entries(for: platform)
    }

    static func banks(
        for platform: ReleaseNotePlatform
    ) -> [(bank: ReleaseNoteBank, entries: [ReleaseNoteEntry])] {
        current.banks(for: platform)
    }

    static func highlights(for platform: ReleaseNotePlatform) -> [ReleaseNoteHighlight] {
        current.highlights(for: platform)
    }

    static func alsoLine(for platform: ReleaseNotePlatform) -> String? {
        current.alsoLine(for: platform)
    }

    // MARK: - 1.3.1

    private static let v131 = ReleaseNotesRelease(
        version: "1.3.1",
        promise: String(localized: """
            Pictures in your READMEs, file paths that work in split panes, and a \
            cleanup pass over selection, scrolling and mosh.
            """),
        entries: [
            // MARK: Terminal
            ReleaseNoteEntry(
                id: "mdimages",
                bank: .terminal,
                title: String(localized: "Pictures in your READMEs"),
                body: String(localized: """
                    In a rendered document the “image: …” placeholder is a link — press it \
                    and the picture appears in the text column. Press the caption to hide \
                    it, tap for full-screen zoom; web-hosted images stay behind the link \
                    confirmation, which now offers a docked ⌗ viewport.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: nil
            ),
            ReleaseNoteEntry(
                id: "splitpaths",
                bank: .terminal,
                title: String(localized: "File paths work in split panes"),
                body: String(localized: """
                    A path wrapped at a pane border is stitched back together, a match \
                    never picks up the neighbouring pane's text, and a relative path \
                    resolves against the pane you pressed.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: nil
            ),
            ReleaseNoteEntry(
                id: "selectanchor",
                bank: .terminal,
                title: String(localized: "Selection stays where you pressed"),
                body: String(localized: """
                    The SELECT block and the SELECT TEXT bar could drift a keyboard height \
                    up — or off screen — on mosh tabs and in scrolled-back terminals. Both \
                    anchor to the press now, and with a second client attached the \
                    selection waits for the shared geometry to settle.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: String(localized: "selection that stays put")
            ),
            ReleaseNoteEntry(
                id: "moshscrollback",
                bank: .terminal,
                title: String(localized: "mosh tabs keep one screen"),
                body: String(localized: """
                    mosh syncs one live screen, but stale frames were archived above it on \
                    every keyboard show and hide. The junk scroll area is gone; only the \
                    live screen remains.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: String(localized: "mosh scrollback cleaned up")
            ),
            ReleaseNoteEntry(
                id: "tmuxfixes",
                bank: .terminal,
                title: String(localized: "Split shortcuts and pane directories"),
                body: String(localized: """
                    The tmux split shortcuts no longer type a stray % on iPad, and the File \
                    Viewer opens in the pressed pane's working directory on tmux and herdr \
                    alike.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: String(localized: "split-shortcut and pane-directory fixes")
            ),
            ReleaseNoteEntry(
                id: "ornaments",
                bank: .terminal,
                title: String(localized: "Bars float below the window"),
                body: String(localized: """
                    The bottom bars of ▤ File Viewer and ⌗ viewport tabs sit outside the \
                    window, clear of the resize corners, holding their size as the window \
                    resizes.
                    """),
                tag: "Vision Pro",
                platforms: [.vision],
                mention: nil
            ),
            ReleaseNoteEntry(
                id: "keyrail",
                bank: .terminal,
                title: String(localized: "The key rail meets the window's edge"),
                body: String(localized: """
                    On iPad the rail runs to the window's bottom edge instead of floating \
                    above the home-indicator strip — more daylight below the keys, in \
                    iPhone landscape too.
                    """),
                tag: "iPhone · iPad",
                platforms: ReleaseNotePlatform.iOS,
                mention: nil
            ),
            ReleaseNoteEntry(
                id: "ninety",
                bank: .terminal,
                title: String(localized: "Smoother streaming output"),
                body: String(localized: """
                    Repaints align to the 90 Hz display instead of a 60 Hz clock, so \
                    fast-scrolling output advances evenly.
                    """),
                tag: "Vision Pro",
                platforms: [.vision],
                mention: String(localized: "90 Hz repaints")
            ),
            ReleaseNoteEntry(
                id: "wheelpin",
                bank: .terminal,
                title: String(localized: "Scrolls stay in their lane"),
                body: String(localized: """
                    A long scroll could drift the reported wheel position onto herdr's tab \
                    bar or the tmux status line — which switch content on scroll. Wheel \
                    events stay pinned to where the pan began.
                    """),
                tag: "Vision Pro",
                platforms: [.vision],
                mention: nil
            ),
            ReleaseNoteEntry(
                id: "metal",
                bank: .terminal,
                title: String(localized: "A Metal renderer, if you want it"),
                body: String(localized: """
                    Settings ▸ Terminal renderer draws terminal text on the GPU instead of \
                    CoreGraphics. Off by default, and applied to newly opened terminal \
                    windows.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: String(localized: "an optional Metal renderer")
            ),

            // MARK: Elsewhere
            ReleaseNoteEntry(
                id: "hostkeys",
                bank: .elsewhere,
                title: String(localized: "Host keys are verified"),
                body: String(localized: """
                    Every connection checks the server against the host's recorded \
                    fingerprints — from Bind Host, a key pasted into Add Host ▸ Host key, \
                    or pinned on first connection. Host Settings ▸ Host key lists them, \
                    with FORGET.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: String(localized: "verified host keys")
            ),
            ReleaseNoteEntry(
                id: "openfile",
                bank: .elsewhere,
                title: String(localized: "Open File from Shortcuts"),
                body: String(localized: """
                    A host, a remote path, and an optional line: Sources/App.swift:10-15 \
                    opens read-only in a ▤ File Viewer tab with the range highlighted. \
                    Pressed paths in the terminal carry line ranges the same way.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: nil
            ),
            ReleaseNoteEntry(
                id: "restore",
                bank: .elsewhere,
                title: String(localized: "Restore Purchases recovers"),
                body: String(localized: """
                    When the App Store's restore sync fails, Restore checks your owned \
                    purchases directly — and errors now name something you can act on.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: String(localized: "a sturdier Restore Purchases")
            ),
        ],
        highlights: [
            ReleaseNoteHighlight(
                id: "mdimages",
                covers: ["mdimages"],
                title: String(localized: "Pictures in your READMEs"),
                body: String(localized: """
                    Press an “image: …” placeholder in a rendered README and the picture \
                    appears right in the document.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all
            ),
            ReleaseNoteHighlight(
                id: "splitpaths",
                covers: ["splitpaths"],
                title: String(localized: "File paths work in split panes"),
                body: String(localized: """
                    A wrapped path is stitched back together, and a relative path resolves \
                    against the pane you pressed.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all
            ),
            ReleaseNoteHighlight(
                id: "openfile",
                covers: ["openfile"],
                title: String(localized: "Open File from Shortcuts"),
                body: String(localized: """
                    A host, a path, and an optional line — straight into a read-only ▤ File \
                    Viewer tab.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all
            ),
            ReleaseNoteHighlight(
                id: "ornaments",
                covers: ["ornaments"],
                title: String(localized: "Bars float below the window"),
                body: String(localized: """
                    ▤ File Viewer and ⌗ viewport bars float outside the window, clear of \
                    the resize corners.
                    """),
                tag: "Vision Pro",
                platforms: [.vision]
            ),
            ReleaseNoteHighlight(
                id: "keyrail",
                covers: ["keyrail"],
                title: String(localized: "The key rail meets the window's edge"),
                body: String(localized: """
                    Flush with the window's bottom instead of floating above the \
                    home-indicator strip.
                    """),
                tag: "iPhone · iPad",
                platforms: ReleaseNotePlatform.iOS
            ),
        ]
    )

    // MARK: - 1.3

    private static let v13 = ReleaseNotesRelease(
        version: "1.3",
        promise: String(localized: """
            Run herdr instead of tmux, select text in any pane, and hear from your \
            agents after you’ve walked away.
            """),
        entries: [
            // MARK: Backends
            ReleaseNoteEntry(
                id: "herdr",
                bank: .backends,
                title: String(localized: "herdr on any host"),
                body: String(localized: """
                    Host Settings ▸ Backend switches a host between tmux and herdr — one \
                    deck tile per session either way, with the shortcut panel, file \
                    attachment, split resizing, and Claude Code history all following.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: nil
            ),
            ReleaseNoteEntry(
                id: "mixed",
                bank: .backends,
                title: String(localized: "Both on one host"),
                body: String(localized: """
                    When the other multiplexer has sessions, the host rail offers to add \
                    them and says what the extra checking costs. Accept and both share one \
                    wall, herdr's tiles in a lighter chassis. Long-press the offer to stop \
                    being asked here.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: String(localized: "tmux and herdr sharing one wall")
            ),

            // MARK: Terminal
            ReleaseNoteEntry(
                id: "selecttext",
                bank: .terminal,
                title: String(localized: "Select text"),
                body: String(localized: """
                    Long-press, double-tap, or right-click a pane for SELECT / SELECT ALL / \
                    PASTE right at the gesture. The selection stays inside the pane you \
                    pressed, with COPY and DONE floating beside it. On herdr tabs the block \
                    adds MENU.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: nil
            ),
            ReleaseNoteEntry(
                id: "guide",
                bank: .terminal,
                title: String(localized: "Guide"),
                body: String(localized: """
                    An illustrated field manual of that tab's gestures, on the title rail.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: String(localized: "an illustrated Guide on every tab")
            ),
            ReleaseNoteEntry(
                id: "titlebar",
                bank: .terminal,
                title: String(localized: "A title bar of its own"),
                body: String(localized: """
                    DECK, the session, LIVE, A− A+, + TAB, FILE, TMUX and DETACH on one \
                    slim rail that matches the key rail at the other end of the pane.
                    """),
                tag: "iPad",
                platforms: [.pad],
                mention: String(localized: "a terminal title bar of its own")
            ),
            ReleaseNoteEntry(
                id: "fileviewer",
                bank: .terminal,
                title: String(localized: "File viewer tabs"),
                body: String(localized: """
                    Open several files at once, browse back and forth with ◂ ▸, and set \
                    reading size with A− / A+ or a pinch — remembered, and applied to every \
                    file viewer tab.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: String(localized: "file viewer tabs and reading size")
            ),
            ReleaseNoteEntry(
                id: "tabreorder",
                bank: .terminal,
                title: String(localized: "Tabs drag to reorder"),
                body: String(localized: "Drag a window's tabs into the order you want."),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: String(localized: "window tabs that drag to reorder")
            ),
            ReleaseNoteEntry(
                id: "taps",
                bank: .terminal,
                title: String(localized: "Every tap reaches the remote"),
                body: String(localized: """
                    Under mouse reporting each tap lands immediately, one click per tap, so \
                    a TUI's own double-click works.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: nil
            ),
            ReleaseNoteEntry(
                id: "stop",
                bank: .terminal,
                title: String(localized: "The STOP chip is gone"),
                body: String(localized: """
                    Press ESC to interrupt a turn — the key rail and the visionOS key \
                    cluster both carry it.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: nil
            ),

            // MARK: While you're away
            ReleaseNoteEntry(
                id: "keepalive",
                bank: .away,
                title: String(localized: "Keep a host alive after you leave"),
                body: String(localized: """
                    Host Settings ▸ Monitoring, off by default. That host keeps running for \
                    the extra time iOS grants a departing app, and iOS can wake Multiplex \
                    later to check again — so a turn that ends after you leave can still \
                    reach you. The timing is iOS's call, and nothing runs for a host you \
                    did not switch on.
                    """),
                tag: "iPhone · iPad",
                platforms: ReleaseNotePlatform.iOS,
                mention: nil
            ),
            ReleaseNoteEntry(
                id: "alerts",
                bank: .away,
                title: String(localized: "Agent alerts find you"),
                body: String(localized: """
                    Including for the session you just walked away from — the one case that \
                    used to stay silent. Permission is asked while Multiplex is on screen, \
                    never from the background.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: String(localized: "agent alerts that find you")
            ),

            // MARK: Appearance
            ReleaseNoteEntry(
                id: "glass",
                bank: .appearance,
                title: String(localized: "Glass"),
                body: String(localized: """
                    A fourth appearance beside SYSTEM, LIGHT and DARK, live across the \
                    deck, terminals, forms and popovers. Typing repaints only the rows that \
                    changed.
                    """),
                tag: "Vision Pro",
                platforms: [.vision],
                mention: String(localized: "the GLASS appearance")
            ),

            // MARK: Elsewhere
            ReleaseNoteEntry(
                id: "licenses",
                bank: .elsewhere,
                title: String(localized: "Open Source Licenses"),
                body: String(localized: """
                    Settings ▸ About lists every open-source component in the binary with \
                    its full license text.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: String(localized: "the open-source licenses in Settings")
            ),
            ReleaseNoteEntry(
                id: "uikit",
                bank: .elsewhere,
                title: String(localized: "Rebuilt on UIKit"),
                body: String(localized: """
                    Every surface was rewritten, for steadier typing, scrolling and window \
                    handling.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all,
                mention: nil
            ),
        ],
        highlights: [
            ReleaseNoteHighlight(
                id: "backends",
                covers: ["herdr", "mixed"],
                title: String(localized: "herdr, or both at once"),
                body: String(localized: """
                    Switch a host's backend in its settings — or let one wall show tmux and \
                    herdr sessions side by side.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all
            ),
            ReleaseNoteHighlight(
                id: "selecttext",
                covers: ["selecttext"],
                title: String(localized: "Select text"),
                body: String(localized: """
                    Long-press, double-tap, or right-click a pane. The selection stays \
                    inside the pane you pressed.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all
            ),
            ReleaseNoteHighlight(
                id: "keepalive",
                covers: ["keepalive"],
                title: String(localized: "Keep a host alive after you leave"),
                body: String(localized: """
                    Opt a host in under Monitoring and an agent that finishes while you are \
                    away can still reach you.
                    """),
                tag: "iPhone · iPad",
                platforms: ReleaseNotePlatform.iOS
            ),
            ReleaseNoteHighlight(
                id: "glass",
                covers: ["glass"],
                title: String(localized: "Glass"),
                body: String(localized: """
                    A fourth appearance beside SYSTEM, LIGHT and DARK — live across every \
                    window.
                    """),
                tag: "Vision Pro",
                platforms: [.vision]
            ),
            ReleaseNoteHighlight(
                id: "titlebar",
                covers: ["titlebar"],
                title: String(localized: "A title bar of its own"),
                body: String(localized: """
                    DECK, the session, LIVE, + TAB, FILE, TMUX, DETACH — one slim rail \
                    instead of the system bar.
                    """),
                tag: "iPad",
                platforms: [.pad]
            ),
            ReleaseNoteHighlight(
                id: "alerts",
                covers: ["alerts"],
                title: String(localized: "Agent alerts find you"),
                body: String(localized: """
                    Including for the session you just walked away from — the one case that \
                    used to stay silent.
                    """),
                tag: nil,
                platforms: ReleaseNotePlatform.all
            ),
        ]
    )
}

/// Whether this launch owes the reader the release notes.
///
/// Pure so the one rule that cannot be re-tested by hand — a person updating
/// from a version that never stamped anything — is pinned by a test rather
/// than by a fresh install.
enum ReleaseNotesGate {
    enum Decision: Equatable {
        /// Present the card, then stamp.
        case show
        /// Stamp without presenting: a first run, which owes nobody a
        /// changelog for a release they never missed.
        case stampSilently
        /// Already seen, or a build older than the stamp.
        case nothing
    }

    /// - Parameters:
    ///   - lastSeen: the stamp this device carries, `nil` before any version
    ///     that wrote one.
    ///   - current: `ReleaseNotes.version`.
    ///   - installHasPriorUse: whether this install was already in use — the
    ///     only thing separating "updated from 1.2" from "installed today",
    ///     since neither carries a stamp. The deck answers it with its own
    ///     locally cached host list.
    static func decide(
        lastSeen: String?,
        current: String,
        installHasPriorUse: Bool
    ) -> Decision {
        guard let currentRelease = release(current) else { return .nothing }
        guard let lastSeen else {
            return installHasPriorUse ? .show : .stampSilently
        }
        guard let seenRelease = release(lastSeen) else { return .show }
        return seenRelease < currentRelease ? .show : .nothing
    }

    /// Every component of the NOTES version counts: 1.3 → 1.3.1 reopens the
    /// card, because `ReleaseNotes.version` only reaches 1.3.1 when 1.3.1
    /// writes notes of its own. A patch BUILD that leaves the constant alone
    /// compares equal here and stays silent — that is the guard, not the
    /// version arithmetic.
    private static func release(_ version: String) -> (major: Int, minor: Int, patch: Int)? {
        let parts = version.split(separator: ".").prefix(3).map { Int($0) }
        guard let first = parts.first, let major = first else { return nil }
        guard let minor = parts.count > 1 ? parts[1] : 0 else { return nil }
        guard let patch = parts.count > 2 ? parts[2] : 0 else { return nil }
        return (major, minor, patch)
    }
}
