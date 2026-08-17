enum TerminalGuideBank: CaseIterable, Equatable {
    case touchPointer
    case linksPaths
    case keyboard
    case herdrPanes
    case clipboard

    var title: String {
        switch self {
        case .touchPointer: "TOUCH & POINTER"
        case .linksPaths: "LINKS & PATHS"
        case .keyboard: "KEYBOARD"
        case .herdrPanes: "HERDR PANES"
        case .clipboard: "CLIPBOARD"
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
            title: "DOUBLE TAP",
            tag: nil,
            body: [
                .text(
                    "Tap or click twice. The remote gets two real clicks first — "
                        + "then the selection block rises at that spot: "
                ),
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
            title: "LONG PRESS",
            tag: nil,
            body: [
                .text("The same block, right where you pressed. On a link or file path, "
                    + "its confirm sheet comes first."),
            ]
        ),
        TerminalGuideEntry(
            id: "rightclick",
            figure: 3,
            bank: .touchPointer,
            title: "RIGHT CLICK",
            tag: "Pointer",
            body: [
                .text("A mouse's secondary click runs the same chain as a long press. On herdr it adds "),
                .control("MENU"),
                .text(" — the remote's own pane menu."),
            ]
        ),
        TerminalGuideEntry(
            id: "pan",
            figure: 4,
            bank: .touchPointer,
            title: "PAN TO SCROLL",
            tag: nil,
            body: [
                .text("A drag scrolls the remote screen itself — the app speaks wheel, "
                    + "or arrow keys in full-screen apps. There is no separate local "
                    + "scrollback to fall out of."),
            ]
        ),
        TerminalGuideEntry(
            id: "edgeswipe",
            figure: 5,
            bank: .touchPointer,
            title: "EDGE SWIPE",
            tag: "iPhone",
            body: [
                .text("From the screen's left edge, swipe right to step back to the deck."),
            ]
        ),
        TerminalGuideEntry(
            id: "link",
            figure: 6,
            bank: .linksPaths,
            title: "HOLD A LINK",
            tag: nil,
            body: [
                .text("Nothing opens by itself. The sheet shows where it really points — "),
                .control("OPEN"),
                .text(", or dock the page beside this tab as a "),
                .control("⌗ VIEWPORT"),
                .text(". On Vision Pro, links glow under your eye; pinch for the same sheet."),
            ]
        ),
        TerminalGuideEntry(
            id: "path",
            figure: 7,
            bank: .linksPaths,
            title: "HOLD A PATH",
            tag: nil,
            body: [
                .control("▤ VIEW"),
                .text(" opens it in the File Viewer. A "),
                .key(":120"),
                .text(" after the name scrolls to that line."),
            ]
        ),
        TerminalGuideEntry(
            id: "kbdlock",
            figure: 8,
            bank: .keyboard,
            title: "LOCK THE KEYBOARD",
            tag: "iPhone · iPad",
            body: [
                .text("Hold the "),
                .key("⌨"),
                .text(" key about half a second: taps stop summoning the keyboard. "
                    + "Hold again — or ⋯ → Unlock Keyboard — to release."),
            ]
        ),
        TerminalGuideEntry(
            id: "dictate",
            figure: 9,
            bank: .keyboard,
            title: "DICTATE",
            tag: "iPhone · iPad",
            body: [
                .text("With a hardware keyboard — or while locked — the mic key listens. "
                    + "Words type once they settle, and nothing is ever submitted for you."),
            ]
        ),
        TerminalGuideEntry(
            id: "shiftreturn",
            figure: 10,
            bank: .keyboard,
            title: "SHIFT + RETURN",
            tag: "HW keyboard",
            body: [
                .text("A newline that doesn't send the line."),
            ]
        ),
        TerminalGuideEntry(
            id: "shortcutkey",
            figure: 11,
            bank: .keyboard,
            title: "THE TMUX / HRDR KEY",
            tag: nil,
            body: [
                .text("One key on the rail opens the whole shortcut panel: copy mode, "
                    + "splits, windows, workspaces, and the confirmed closes."),
            ]
        ),
        TerminalGuideEntry(
            id: "keycommands",
            figure: 12,
            bank: .keyboard,
            title: "HOLD CTRL",
            tag: nil,
            body: [
                .text("A tap latches "),
                .key("CTRL"),
                .text("; a hold opens KEY COMMANDS — "),
                .key("⇧⏎"),
                .text(" newline, a double "),
                .key("⌃C"),
                .text(", "),
                .key("⌥⌫"),
                .text(" delete-word, and your own chords or one-line text macros "
                    + "from CUSTOM SETUP, on every device."),
            ]
        ),
        TerminalGuideEntry(
            id: "talkback",
            figure: 13,
            bank: .keyboard,
            title: "MESSAGE BOX",
            tag: nil,
            body: [
                .text("The speech-bubble key beside "),
                .key("RET"),
                .text(" opens a message box: write with autocorrect and your keyboard's "
                    + "own dictation, attach photos or files, then "),
                .control("↑"),
                .text(" sends it all as one message. The rail keeps driving the pane "
                    + "while you write; hold "),
                .control("↑"),
                .text(" to type without submitting. Locking the keyboard closes it."),
            ]
        ),
        TerminalGuideEntry(
            id: "resize",
            figure: 14,
            bank: .herdrPanes,
            title: "RESIZE PANES",
            tag: "herdr",
            body: [
                .text("Hold a pane border until it wakes, then drag it where you want."),
            ]
        ),
        TerminalGuideEntry(
            id: "panemenu",
            figure: 15,
            bank: .herdrPanes,
            title: "PANE MENU",
            tag: "herdr",
            body: [
                .control("MENU"),
                .text(" in the press block right-clicks the remote for you — herdr's "
                    + "pane menu opens under your finger."),
            ]
        ),
        TerminalGuideEntry(
            id: "paste",
            figure: nil,
            bank: .clipboard,
            title: "\"ALLOW PASTE\" EVERY TIME?",
            tag: "iPhone · iPad",
            body: [
                .text("iOS asks before Multiplex may read another app's copy. To stop "
                    + "the prompt: Settings → Multiplex → Paste from Other Apps → Allow."),
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
