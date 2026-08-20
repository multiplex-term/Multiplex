import Foundation

enum TerminalGuideBank: CaseIterable, Equatable {
    case touchPointer
    case linksPaths
    case keyboard
    case herdrPanes
    case clipboard

    var title: String {
        switch self {
        case .touchPointer: String(localized: "TOUCH & POINTER")
        case .linksPaths: String(localized: "LINKS & PATHS")
        case .keyboard: String(localized: "KEYBOARD")
        case .herdrPanes: String(localized: "HERDR PANES")
        case .clipboard: String(localized: "CLIPBOARD")
        }
    }
}

struct TerminalGuideEntry {
    enum Run {
        case text(String)
        case control(String)
        case key(String)

        var text: String {
            switch self {
            case .text(let text), .control(let text), .key(let text): text
            }
        }
    }

    let id: String
    let figure: Int?
    let bank: TerminalGuideBank
    let title: String
    let tag: String?
    let body: [Run]

    var bodyText: String {
        body.map(\.text).joined()
    }
}

struct TerminalGuideContext {
    enum Platform: Equatable {
        case phone
        case pad
        case vision
    }

    let platform: Platform
    let backendIsHerdr: Bool
}

enum TerminalGuide {
    static let allEntries: [TerminalGuideEntry] = [
        TerminalGuideEntry(
            id: "doubletap",
            figure: 1,
            bank: .touchPointer,
            title: String(localized: "DOUBLE TAP"),
            tag: nil,
            body: [
                .text(String(localized: """
                    Tap or click twice. The remote gets two real clicks first — then the \
                    selection block rises at that spot:\u{20}
                    """)),
                .control("SELECT"),
                .text(" · "),
                .control("SELECT ALL"),
                .text(" · "),
                .control("PASTE"),
                .text("."),
            ]
        ),
        TerminalGuideEntry(
            id: "longpress",
            figure: 2,
            bank: .touchPointer,
            title: String(localized: "LONG PRESS"),
            tag: nil,
            body: [
                .text(String(localized: """
                    The same block, right where you pressed — and it reaches links and \
                    paths at any mouse mode, when a tap belongs to the remote.
                    """)),
            ]
        ),
        TerminalGuideEntry(
            id: "rightclick",
            figure: 3,
            bank: .touchPointer,
            title: String(localized: "RIGHT CLICK"),
            tag: String(localized: "Pointer"),
            body: [
                .text(String(localized: """
                    A mouse's secondary click runs the same chain as a long press. On herdr \
                    it adds\u{20}
                    """)),
                .control("MENU"),
                .text(String(localized: " — the remote's own pane menu.")),
            ]
        ),
        TerminalGuideEntry(
            id: "pan",
            figure: 4,
            bank: .touchPointer,
            title: String(localized: "PAN TO SCROLL"),
            tag: nil,
            body: [
                .text(String(localized: """
                    A drag scrolls the remote screen itself — the app speaks wheel, or \
                    arrow keys in full-screen apps. There is no separate local scrollback \
                    to fall out of.
                    """)),
            ]
        ),
        TerminalGuideEntry(
            id: "edgeswipe",
            figure: 5,
            bank: .touchPointer,
            title: String(localized: "EDGE SWIPE"),
            tag: "iPhone",
            body: [
                .text(String(localized: """
                    From the screen's left edge, swipe right to step back to the deck.
                    """)),
            ]
        ),
        TerminalGuideEntry(
            id: "link",
            figure: 6,
            bank: .linksPaths,
            title: String(localized: "PRESS A LINK"),
            tag: nil,
            body: [
                .text(String(localized: """
                    Nothing opens by itself. A press raises a sheet showing where it \
                    really points —\u{20}
                    """)),
                .control("OPEN"),
                .text(String(localized: ", or dock the page beside this tab as a ")),
                .control("⌗ VIEWPORT"),
                .text(String(localized: """
                    . On Vision Pro, links glow under your eye; pinch for the same sheet.
                    """)),
            ]
        ),
        TerminalGuideEntry(
            id: "path",
            figure: 7,
            bank: .linksPaths,
            title: String(localized: "PRESS A PATH"),
            tag: nil,
            body: [
                .text(String(localized: "Same press, its own sheet: ")),
                .control("▤ VIEW"),
                .text(String(localized: " opens it in the File Viewer. A ")),
                .key(":120"),
                .text(String(localized: " after the name scrolls to that line.")),
            ]
        ),
        TerminalGuideEntry(
            id: "kbdlock",
            figure: 8,
            bank: .keyboard,
            title: String(localized: "LOCK THE KEYBOARD"),
            tag: "iPhone · iPad",
            body: [
                .text(String(localized: "Hold the ")),
                .key("⌨"),
                .text(String(localized: """
                     key about half a second: taps stop summoning the keyboard. Hold \
                    again — or ⋯ → Unlock Keyboard — to release.
                    """)),
            ]
        ),
        TerminalGuideEntry(
            id: "dictate",
            figure: 9,
            bank: .keyboard,
            title: String(localized: "DICTATE"),
            tag: "iPhone · iPad",
            body: [
                .text(String(localized: """
                    With a hardware keyboard — or while locked — the mic key listens. Words \
                    type once they settle, and nothing is ever submitted for you.
                    """)),
            ]
        ),
        TerminalGuideEntry(
            id: "shiftreturn",
            figure: 10,
            bank: .keyboard,
            title: "SHIFT + RETURN",
            tag: String(localized: "HW keyboard"),
            body: [
                .text(String(localized: "A newline that doesn't send the line.")),
            ]
        ),
        TerminalGuideEntry(
            id: "shortcutkey",
            figure: 11,
            bank: .keyboard,
            title: String(localized: "THE TMUX / HRDR KEY"),
            tag: nil,
            body: [
                .text(String(localized: """
                    One key on the rail opens the whole shortcut panel: copy mode, splits, \
                    windows, workspaces, and the confirmed closes.
                    """)),
            ]
        ),
        TerminalGuideEntry(
            id: "keycommands",
            figure: 12,
            bank: .keyboard,
            title: String(localized: "HOLD CTRL"),
            tag: nil,
            body: [
                .text(String(localized: "A tap latches ")),
                .key("CTRL"),
                .text(String(localized: "; a hold opens KEY COMMANDS — ")),
                .key("⇧⏎"),
                .text(String(localized: " newline, a double ")),
                .key("⌃C"),
                .text(", "),
                .key("⌥⌫"),
                .text(String(localized: """
                     delete-word, and your own chords or one-line text macros from CUSTOM \
                    SETUP, on every device.
                    """)),
            ]
        ),
        TerminalGuideEntry(
            id: "talkback",
            figure: 13,
            bank: .keyboard,
            title: String(localized: "MESSAGE BOX"),
            tag: nil,
            body: [
                .text(String(localized: "The speech-bubble key beside ")),
                .key("RET"),
                .text(String(localized: """
                     opens a message box: write with autocorrect and your keyboard's own \
                    dictation, attach photos or files, then\u{20}
                    """)),
                .control("↑"),
                .text(String(localized: """
                     sends it all as one message. The rail keeps driving the pane while you \
                    write; hold\u{20}
                    """)),
                .control("↑"),
                .text(String(localized: """
                     to type without submitting. Locking the keyboard closes it.
                    """)),
            ]
        ),
        TerminalGuideEntry(
            id: "resize",
            figure: 14,
            bank: .herdrPanes,
            title: String(localized: "RESIZE PANES"),
            tag: "herdr",
            body: [
                .text(String(localized: """
                    Hold a pane border until it wakes, then drag it where you want.
                    """)),
            ]
        ),
        TerminalGuideEntry(
            id: "panemenu",
            figure: 15,
            bank: .herdrPanes,
            title: String(localized: "PANE MENU"),
            tag: "herdr",
            body: [
                .control("MENU"),
                .text(String(localized: """
                     in the press block right-clicks the remote for you — herdr's pane menu \
                    opens under your finger.
                    """)),
            ]
        ),
        TerminalGuideEntry(
            id: "paste",
            figure: nil,
            bank: .clipboard,
            title: String(localized: "\"ALLOW PASTE\" EVERY TIME?"),
            tag: "iPhone · iPad",
            body: [
                .text(String(localized: """
                    iOS asks before Multiplex may read another app's copy. To stop the \
                    prompt: Settings → Multiplex → Paste from Other Apps → Allow.
                    """)),
            ]
        ),
    ]

    static func entries(for context: TerminalGuideContext) -> [TerminalGuideEntry] {
        allEntries.filter { entry in
            switch entry.id {
            case "edgeswipe":
                context.platform == .phone
            case "kbdlock", "dictate", "paste":
                context.platform != .vision
            case "resize", "panemenu":
                context.backendIsHerdr
            default:
                true
            }
        }
    }
}
