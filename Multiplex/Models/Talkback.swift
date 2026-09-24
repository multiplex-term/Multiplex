import Foundation

/// Talkback — the chat-style message box under a terminal pane. Pure state
/// and byte composition; the composer view renders it and
/// `TerminalSessionController` moves attachments through their upload
/// states. Design record: `local-plan/talkback-bakeoff/` (Candidate B).

/// One file the composer holds until SEND. Uploaded on pick over the tab's
/// own SFTP into the pane's cwd (the FILE drop path), so a chip is either on
/// its way, landed with the path SEND will type, or failed with a reason.
struct TalkbackAttachment: Identifiable, Equatable {
    enum Kind: Equatable {
        case image
        case file
    }

    enum State: Equatable {
        case uploading(fraction: Double)
        /// `path` is the path as typed into the pane — relative to the cwd
        /// where the drop path could verify it, absolute otherwise —
        /// UNQUOTED; SEND quotes through `DropText.typedPaths`.
        case ready(path: String)
        case failed(String)
    }

    let id: UUID
    var name: String
    var byteCount: Int
    var kind: Kind
    /// A small JPEG for the composer's thumbnail; nil for non-images.
    var preview: Data?
    var state: State

    init(
        id: UUID = UUID(),
        name: String,
        byteCount: Int,
        kind: Kind,
        preview: Data? = nil,
        state: State = .uploading(fraction: 0)
    ) {
        self.id = id
        self.name = name
        self.byteCount = byteCount
        self.kind = kind
        self.preview = preview
        self.state = state
    }

    var isUploading: Bool {
        if case .uploading = state { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    var readyPath: String? {
        if case .ready(let path) = state { return path }
        return nil
    }

    /// The image test the drop path can afford: an extension, not the bytes
    /// — the file viewer's own classification.
    static func kind(forName name: String) -> Kind {
        FileKind.classify(fileName: name) == .image ? .image : .file
    }
}

/// The per-tab draft: what's typed and what's attached. Lives on the tab's
/// session controller (beside its open state) so it follows the tab across
/// window and tab switches and dies with the tab — never persisted.
struct TalkbackDraft: Equatable {
    /// The SEND face. `.waiting` while an upload is still in flight (the
    /// message is never sent half); `.disabled` with nothing to send, with a
    /// failed chip still attached, or while the pane can't take input.
    enum SendState: Equatable {
        case disabled
        case waiting
        case ready
    }

    var text = ""
    var attachments: [TalkbackAttachment] = []
    /// Bumped by the key that opens the box: the composer focuses its field
    /// exactly once per request, so a tab switch back to an open box never
    /// steals the keyboard.
    var focusRequest = 0

    var isEmpty: Bool {
        TalkbackMessage.sanitizedBody(text).isEmpty && attachments.isEmpty
    }

    var hasUploadInFlight: Bool { attachments.contains(where: \.isUploading) }
    var hasFailedAttachment: Bool { attachments.contains(where: \.isFailed) }

    /// Paths of the landed attachments, in attach order.
    var readyPaths: [String] { attachments.compactMap(\.readyPath) }

    /// The SEND face for a pane that can take input; the controller folds
    /// its own liveness in on top.
    var sendState: SendState {
        if isEmpty || hasFailedAttachment { return .disabled }
        if hasUploadInFlight { return .waiting }
        return .ready
    }

    /// What SEND leaves behind: an empty box (the open state lives outside).
    mutating func clearAfterSend() {
        text = ""
        attachments.removeAll()
    }

    mutating func update(_ id: UUID, _ change: (inout TalkbackAttachment) -> Void) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        change(&attachments[index])
    }
}

/// The bytes SEND writes, and the rules that keep them honest.
enum TalkbackMessage {
    /// A CR sent as a SEPARATE write this long after the text — the slash
    /// chips' proven shape (Codex reads a same-burst Enter as a pasted
    /// newline; verified rust-v0.144, Claude / Pi / Grok accept it too).
    static let submitDelay = AgentCommand.submitDelay
    /// The most lines the field grows to before scrolling inside itself.
    static let maximumVisibleLines = 5

    static let bracketedPasteStart = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])
    static let bracketedPasteEnd = Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])
    static let submit = Data([0x0D])

    /// The body as it goes on the wire: the composed-text rule (CR / CRLF
    /// become LF, tabs stay, every other control is dropped — no Escape, no
    /// Ctrl-B, no CSI can ride a message) with trailing blank space trimmed
    /// so a submitting CR never lands on an empty line. Leading space stays:
    /// the user typed it.
    static func sanitizedBody(_ text: String) -> String {
        var body = ComposedText.lineNormalized(text)
        while let last = body.unicodeScalars.last,
              last == " " || last == "\n" || last == "\t" {
            body.unicodeScalars.removeLast()
        }
        return body
    }

    /// One paste: the landed attachment paths first (quoted only where a
    /// shell would need it, space-joined, one trailing space — exactly what
    /// the FILE button types), then the sanitized body verbatim, newlines
    /// included. Wrapped in the bracketed-paste markers when the pane has
    /// mode 2004 on (Claude Code and Codex do — a multi-line body then lands
    /// as one message); at a bare shell the lines go as-is, PASTE's own
    /// behaviour. Empty when there is nothing to say.
    static func payload(body: String, paths: [String], bracketed: Bool) -> Data {
        let text = DropText.typedPaths(paths) + sanitizedBody(body)
        guard !text.isEmpty else { return Data() }
        var data = Data()
        if bracketed { data.append(bracketedPasteStart) }
        data.append(Data(text.utf8))
        if bracketed { data.append(bracketedPasteEnd) }
        return data
    }

    /// The field's empty-state copy, in the target's own name.
    static func placeholder(agentName: String?) -> String {
        agentName.map { String(localized: "Message \($0)…") }
            ?? String(localized: "Message this pane…")
    }
}
