import Citadel
import Foundation
import ImageIO
import Observation
import UIKit

/// One file-viewer tab's state: its own SSH connection (dialed lazily,
/// redialed per operation after suspension — request/response needs no
/// resume policy), the tree, the git verdicts, and whatever the content
/// screen is showing. A value sibling of `ViewportController`: lives only
/// in `TerminalWorkspace` memory (summoned, not restored), never claims
/// terminal focus, and has no send path into any terminal.
///
/// Why its own connection: the probe connection belongs to the deck's
/// lifecycle (a disabled host must not be revived by a viewer tab), and the
/// summoning tab's transport moves away from this tab on merge/split — a
/// tab owning its transport is the app's architecture. SSH remains every
/// host's control plane, so mosh hosts open viewers the same way.
@MainActor
@Observable
final class FileViewerController: AuxiliaryPaneController {
    /// Text render cap: the capped head still renders, under a TRUNCATED
    /// banner. Big enough for every source file that matters; small enough
    /// that highlighting stays interactive.
    static let textByteLimit = 1_500_000
    static let imageByteLimit = 12_000_000
    /// The longest edge the viewer decodes to. Encoded bytes bound nothing
    /// about a bitmap's size, and the screen this renders on is smaller than
    /// this in every dimension.
    static let imageMaxPixelEdge = 4096

    /// The ceiling for an image shown INSIDE a document. A rendered column is
    /// at most 760 pt wide, so this is retina-generous — and a README can
    /// hold many of these at once, where the full screen shows exactly one.
    static let inlineImageMaxPixelEdge = 1600

    /// Decode through ImageIO with a pixel ceiling, so a decompression bomb
    /// from the host costs a downsample instead of the app's memory.
    /// Falls back to nothing (i.e. "binary") when the bytes aren't an image.
    static func decodeImage(_ data: Data, maxPixelEdge: Int = imageMaxPixelEdge) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelEdge,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    let tabID: UUID
    private let host: Host
    var hostName: String { host.name }

    /// Web links inside a remote document use the same admitted viewport road
    /// as links printed in a terminal. The controller's host snapshot is the
    /// authority for localhost rewriting, so a moved viewer tab never depends
    /// on whichever terminal happens to be active in its new window.
    func viewportOffer(for link: TerminalLink) -> ViewportOffer? {
        ViewportOffer.make(for: link, host: host)
    }

    /// The pane cwd at summon time (absolute), when the summoning tab could
    /// answer over its own transport.
    private let startDirectory: String?
    /// The backend + session the summoning tab was attached to. A mosh tab
    /// has no exec surface, so it cannot resolve its own pane cwd — but SSH
    /// remains every host's control plane and this viewer dials its own
    /// connection, so the backend-specific query simply moves here rather
    /// than silently rooting tmux or herdr at $HOME.
    let anchorSession: SessionKey?
    /// The pressed screen cell that summoned this viewer, when a path press
    /// did — the mosh re-ask (`anchorPaneDirectory`) aims at the pane under
    /// the finger with it; nil keeps the active/focused-pane answer.
    let anchorCell: (col: Int, row: Int)?
    /// The pressed path this tab was summoned to show, when it was.
    private let target: TerminalPathTarget?
    /// A file viewer keeps SOURCE | DIFF as a browsing mode: once DIFF is
    /// selected, choosing another changed file opens its diff too. The mode
    /// also rides an "Open in New Tab" summons so the new viewer opens the
    /// same representation instead of flashing source first.
    enum FilePresentation: Equatable {
        case source
        case diff
    }
    private let targetPresentation: FilePresentation
    private(set) var filePresentation: FilePresentation
    /// True when the tab was summoned to BROWSE (+ TAB ▸ File Viewer)
    /// rather than to show a specific pressed file — the tree is the
    /// subject until a file is chosen, so the compact drawer opens itself
    /// and picking the first file costs one tap, not two.
    let opensBrowsing: Bool

    init(
        tabID: UUID,
        host: Host,
        startDirectory: String?,
        anchorSession: SessionKey? = nil,
        anchorCell: (col: Int, row: Int)? = nil,
        target: TerminalPathTarget?,
        targetPresentation: FilePresentation = .source
    ) {
        self.tabID = tabID
        self.host = host
        self.startDirectory = startDirectory
        self.anchorSession = anchorSession
        self.anchorCell = anchorCell
        self.target = target
        self.targetPresentation = targetPresentation
        self.filePresentation = targetPresentation
        self.opensBrowsing = target == nil
    }

    // MARK: Content

    struct Document: Equatable {
        var path: String
        var size: UInt64
        /// The render verdict — including binary: a NUL-sniffed text file
        /// re-classifies to `.binary` here, so header and body always
        /// agree on what the screen is.
        var kind: FileRenderKind
        var truncated = false
        /// Code (and markdown RAW) render.
        var codeLines: [HighlightedLine] = []
        /// Markdown rendered blocks.
        var markdown: [MarkdownBlock] = []
        /// Decoded once at load — re-decoding megabytes per body
        /// evaluation is what image views must never do.
        var image: UIImage?
        /// The text behind a markdown render, kept so the RAW toggle
        /// re-renders locally instead of re-downloading the file.
        var sourceText: String?
        /// From a `path:12` / `path:12-18` press — the code view scrolls to
        /// the first line once and highlights the requested line range.
        var targetLine: Int?
        var targetEndLine: Int?

        var name: String { FileTree.name(of: path) }
    }

    enum DiffScope: Equatable {
        case file(path: String)
        case repo
    }

    enum Content {
        /// Nothing selected yet — the tree is the subject.
        case idle
        case loading(label: String)
        case document(Document)
        case diff(GitDiff, scope: DiffScope)
        case failure(title: String, message: String)
    }

    private(set) var content: Content = .idle
    /// Back/forward trail of the content screens this tab visited. Written
    /// only where content lands (a failed load is never a destination);
    /// `visit`'s equality gate keeps refresh and quiet watch swaps out.
    private(set) var history = FileViewerHistory()
    /// The document behind a per-file DIFF, so SOURCE flips back without a
    /// round trip.
    private(set) var lastDocument: Document?
    /// Bumped by every user-driven content change (open, diff, source,
    /// refresh) — a quiet watch update finishing late must never clobber
    /// what the person navigated to since.
    private var contentGeneration = 0
    /// (size, mtime) of the path the watch is minding — the open document,
    /// or the worktree side of a per-file diff.
    private var watchedStamp: SSHConnection.FileStat?
    private var watchTickCount = 0
    /// Markdown RAW toggle — kept across files (a preference, not a mode).
    /// Re-renders from the text already in hand; flipping a preference
    /// must not cost a network round trip.
    var markdownRaw = false {
        didSet {
            guard markdownRaw != oldValue,
                  case .document(let document) = content,
                  document.kind == .markdown
            else { return }
            contentGeneration += 1
            let generation = contentGeneration
            Task {
                let updated = await Self.renderedMarkdown(document, raw: markdownRaw)
                guard generation == contentGeneration,
                      case .document(let still) = content, still.path == updated.path
                else { return }
                lastDocument = updated
                content = .document(updated)
            }
        }
    }

    // MARK: Markdown images

    /// A picture the reader asked to SEE, shown where the document places it.
    /// Rendering a document still fetches nothing — the placeholder is a
    /// press, and this is what that press produced.
    enum InlineImage: Equatable {
        case loading
        case ready(UIImage)
        /// Why it can't be shown here, in the pane's caps voice.
        case failed(String)

        /// Two decodes of the same bytes are different pictures to the screen
        /// (it must re-measure and redraw), and `UIImage`'s own `==` compares
        /// pixel data — identity is both the cheaper and the truer answer.
        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading): true
            case (.ready(let left), .ready(let right)): left === right
            case (.failed(let left), .failed(let right)): left == right
            default: false
            }
        }
    }

    /// Keyed by the destination exactly as the document spells it — so the
    /// same picture referenced twice shows in both places from one fetch, and
    /// the map is meaningless outside the document that named those
    /// references (`open` clears it when the screen moves to another file).
    /// Bounded by what a person can press, and by the inline pixel ceiling.
    private(set) var inlineImages: [String: InlineImage] = [:]

    /// Show or hide one markdown image. `destination` is the document's own
    /// spelling (the key the screen knows), `path` the absolute remote path
    /// it resolved to (`FileTree.resolve`).
    func toggleInlineImage(destination: String, path: String) {
        guard inlineImages[destination] == nil else {
            inlineImages[destination] = nil
            return
        }
        inlineImages[destination] = .loading
        let generation = contentGeneration
        Task { [weak self] in
            guard let self else { return }
            let verdict = await loadInlineImage(path: path)
            // The reader may have collapsed it, or left the document, while
            // the bytes were in flight.
            guard generation == contentGeneration,
                  case .loading = inlineImages[destination]
            else { return }
            inlineImages[destination] = verdict
        }
    }

    private func loadInlineImage(path: String) async -> InlineImage {
        let name = FileTree.name(of: path)
        do {
            let stat = try await withConnection { try await $0.statFile(atPath: path) }
            if stat.isDirectory { return .failed("\(name.uppercased()) IS A FOLDER") }
            let size = stat.size ?? 0
            guard size <= UInt64(Self.imageByteLimit) else {
                return .failed("TOO LARGE — \(Self.formatBytes(size))")
            }
            let (data, _) = try await withConnection {
                try await $0.readFile(atPath: path, limit: Self.imageByteLimit)
            }
            // Decoded on the main actor, as the full screen's read already is:
            // the downsample below is bounded and the alternative is making
            // this type's statics nonisolated for one hop.
            guard let image = Self.decodeImage(
                data, maxPixelEdge: Self.inlineImageMaxPixelEdge
            ) else {
                return .failed("NOT AN IMAGE THIS VIEWER CAN DRAW")
            }
            return .ready(image)
        } catch {
            return .failed(failureMessage(error).uppercased())
        }
    }

    // MARK: Tree

    private(set) var rootPath = ""
    private(set) var homePath: String?
    private(set) var gitRoot: String?
    private(set) var branch: String?
    private(set) var shortStat = GitShortStat()
    private(set) var statuses: [GitFileStatus] = []
    private(set) var childrenByPath: [String: [FileTreeEntry]] = [:]
    private(set) var expanded: Set<String> = []
    private(set) var pendingListings: Set<String> = []
    var changedFilter = false
    private(set) var treeFailure: String?
    private(set) var isBusy = false

    var badges: [String: GitFileStatus.Badge] {
        guard let gitRoot else { return [:] }
        return FileTree.badges(statuses: statuses, repoRoot: gitRoot)
    }

    var treeRows: [FileTree.Row] {
        if changedFilter, let gitRoot {
            return FileTree.changedRows(statuses: statuses, repoRoot: gitRoot)
        }
        let changedDirectories = gitRoot.map {
            FileTree.changedDirectories(statuses: statuses, repoRoot: $0)
        } ?? []
        return FileTree.rows(
            root: rootPath,
            children: childrenByPath,
            expanded: expanded,
            badges: badges,
            changedDirectories: changedDirectories
        )
    }

    /// The tab cell / UMD label: the file on screen, else the room.
    var displayName: String {
        switch content {
        case .document(let document): document.name
        case .diff(_, .repo): "DIFF"
        case .diff(_, .file(let path)): FileTree.name(of: path)
        default: rootPath.isEmpty ? "FILES" : FileTree.name(of: rootPath)
        }
    }

    var tabLabel: String { TerminalRoute.fileViewerLabel(name: displayName) }

    /// The rail readout: where the screen actually is.
    var railPath: String {
        switch content {
        case .document(let document): document.path
        case .diff(_, .file(let path)): path
        case .diff(_, .repo): gitRoot ?? rootPath
        default: rootPath
        }
    }

    // MARK: Connection

    @ObservationIgnored private var connection: SSHConnection?

    private func liveConnection() async throws -> (SSHConnection, fresh: Bool) {
        if let connection { return (connection, false) }
        let secrets = await HostSecrets.loadOffMain(for: host)
        let dialed = SSHConnection(host: host, secrets: secrets)
        try await dialed.connect()
        connection = dialed
        return (dialed, true)
    }

    /// Run one operation, redialing once when a *reused* connection turns
    /// out to be a suspension corpse. An SFTP status error means the server
    /// answered — never a reason to redial.
    private func withConnection<T: Sendable>(
        _ body: @Sendable (SSHConnection) async throws -> T
    ) async throws -> T {
        let (link, fresh) = try await liveConnection()
        do {
            return try await body(link)
        } catch {
            guard !fresh, !(error is SFTPError), !(error is CancellationError)
            else { throw error }
            connection = nil
            Task { await link.close() }
            let (redialed, _) = try await liveConnection()
            return try await body(redialed)
        }
    }

    func shutdown() {
        let dying = connection
        connection = nil
        Task { await dying?.close() }
    }

    // MARK: Boot

    /// One-shot boot from the pane's `.task`: resolve the anchor, probe
    /// git, list the tree, open the pressed file if there is one.
    func start() async {
        guard rootPath.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        content = .loading(label: target?.path ?? startDirectory ?? "~")
        do {
            let home = try await withConnection { try await $0.remoteHomeDirectory() }
            homePath = home
            // The summoning tab answers when it can; a mosh tab cannot, so
            // the same query runs over this viewer's own SSH connection
            // before $HOME is ever settled for.
            var resolvedBase = startDirectory
            if resolvedBase == nil { resolvedBase = await anchorPaneDirectory() }
            let base = resolvedBase ?? home

            var resolvedTarget: String?
            if let target {
                let joined: String
                switch target.base {
                case .absolute: joined = target.path
                case .home: joined = FileTree.join(home, target.relativePart)
                case .workingDirectory: joined = FileTree.join(base, target.relativePart)
                }
                // Canonicalize ../ and symlinked segments where the server
                // cooperates; the joined spelling is the honest fallback.
                resolvedTarget = (try? await withConnection {
                    try await $0.canonicalPath(atPath: joined)
                }) ?? joined
            }

            let anchor = resolvedTarget.map { FileTree.parent(of: $0) ?? "/" } ?? base
            await probeGit(at: anchor)
            rootPath = gitRoot ?? anchor
            // A source summons renders before the listing and the (possibly
            // seconds-cold) git status. A DIFF summons needs the status first:
            // it distinguishes an untracked all-additions diff from HEAD and
            // confirms the file is still changed before preserving the mode.
            var loadedGitVerdicts = false
            if let resolvedTarget {
                if targetPresentation == .diff, gitRoot != nil {
                    await refreshGitVerdicts()
                    loadedGitVerdicts = true
                    if badges[resolvedTarget] != nil {
                        await showFileDiff(path: resolvedTarget)
                    } else {
                        await open(
                            path: resolvedTarget,
                            line: target?.line,
                            endLine: target?.endLine
                        )
                    }
                } else {
                    await open(
                        path: resolvedTarget,
                        line: target?.line,
                        endLine: target?.endLine
                    )
                }
            }
            await list(rootPath)
            expandChain(to: anchor)
            if !loadedGitVerdicts { await refreshGitVerdicts() }
            if resolvedTarget == nil { content = .idle }
        } catch {
            content = .failure(
                title: "NO CONNECTION",
                message: failureMessage(error)
            )
        }
    }

    /// The summoning tab's pane cwd, asked over this viewer's own SSH
    /// connection. Only reached when the tab itself could not answer — a mosh
    /// tab has no exec channel. Dispatch by the tab's backend rather than
    /// assuming tmux: herdr's focused pane comes from its snapshot envelope.
    /// A path press carries its screen cell (`anchorCell`) so a split
    /// resolves against the pane that printed the path; a browse summon
    /// keeps the active/focused pane.
    private func anchorPaneDirectory() async -> String? {
        guard let anchorSession,
              let output = try? await withConnection({
                  try await $0.exec(Self.anchorDirectoryCommand(for: anchorSession))
              })
        else { return nil }
        return Self.parseAnchorDirectory(
            output, backend: anchorSession.backend, atScreenCell: anchorCell
        )
    }

    static func anchorDirectoryCommand(for session: SessionKey) -> String {
        switch session.backend {
        case .tmux:
            TmuxProbe.pathAnchorCommand(sessionName: session.name)
        case .herdr:
            HerdrProbe.snapshotCommand(sessionName: session.name)
        }
    }

    static func parseAnchorDirectory(
        _ output: String,
        backend: Host.SessionBackend,
        atScreenCell cell: (col: Int, row: Int)? = nil
    ) -> String? {
        switch backend {
        case .tmux:
            TmuxProbe.parsePathAnchorDirectory(output, atScreenCell: cell)
        case .herdr:
            HerdrProbe.parsePaneWorkingDirectory(output, atScreenCell: cell)
        }
    }

    // MARK: Git

    private func probeGit(at path: String) async {
        gitRoot = nil
        branch = nil
        guard let output = try? await withConnection({
            try await $0.exec(GitCommands.repoProbe(path: path))
        }) else { return }
        let (body, exit) = GitCommands.splitExit(output)
        guard exit == 0 else { return }
        let parsed = GitCommands.parseRepoProbe(body: body)
        gitRoot = parsed.toplevel
        branch = parsed.branch
    }

    /// One `watchProbe` round trip refreshes branch, statuses, and the ±
    /// counts together — the refresh path and the watch tick share it.
    /// Returns whether anything actually moved.
    @discardableResult
    private func refreshGitVerdicts() async -> Bool {
        // Every write below is equality-gated: @Observable has no gate of
        // its own, an identical assignment still churns every observer,
        // and this runs on the watch's 5 s tick — an idle repo must cost
        // the wall nothing.
        guard let gitRoot else {
            if !statuses.isEmpty { statuses = [] }
            if shortStat != GitShortStat() { shortStat = GitShortStat() }
            return false
        }
        guard let output = try? await withConnection({
            try await $0.exec(GitCommands.watchProbe(root: gitRoot))
        }), let probe = GitCommands.parseWatchProbe(output) else { return false }
        var changed = false
        if branch != probe.branch { branch = probe.branch; changed = true }
        if statuses != probe.statuses { statuses = probe.statuses; changed = true }
        if shortStat != probe.shortStat { shortStat = probe.shortStat; changed = true }
        return changed
    }

    // MARK: Tree operations

    private func list(_ directory: String) async {
        guard !pendingListings.contains(directory) else { return }
        pendingListings.insert(directory)
        defer { pendingListings.remove(directory) }
        do {
            let listed = try await withConnection {
                try await $0.listDirectory(atPath: directory)
            }
            treeFailure = nil
            // Sorted at write time: rows() renders straight from storage
            // (re-sorting per render is ICU work the tree pays on every
            // body evaluation), and a stable order also keeps the
            // compare-before-write below honest against server ordering.
            let entries = FileTree.sorted(listed.map { entry in
                FileTreeEntry(
                    name: entry.name,
                    path: FileTree.join(directory, entry.name),
                    isDirectory: entry.isDirectory
                )
            })
            // Compare before writing: the watch relists on a cadence, and
            // an identical assignment would still churn observers.
            if childrenByPath[directory] != entries {
                childrenByPath[directory] = entries
            }
        } catch {
            treeFailure = failureMessage(error)
        }
    }

    /// True when `path` lives under `directory` (or is it) — a component-
    /// boundary check, because "/repo2".hasPrefix("/repo") lies.
    private static func path(_ path: String, isUnder directory: String) -> Bool {
        path == directory || directory == "/" || path.hasPrefix(directory + "/")
    }

    /// Expand every directory between the root and `path`, listing as
    /// needed — how a pressed file's row becomes visible.
    private func expandChain(to path: String) {
        var chain: [String] = []
        var cursor: String? = path
        while let current = cursor, current != rootPath,
              Self.path(current, isUnder: rootPath) {
            chain.append(current)
            cursor = FileTree.parent(of: current)
        }
        guard cursor == rootPath else { return }
        for directory in chain.reversed() {
            expanded.insert(directory)
            Task { await list(directory) }
        }
    }

    func toggleExpand(_ entry: FileTreeEntry) {
        guard entry.isDirectory else { return }
        if expanded.contains(entry.path) {
            expanded.remove(entry.path)
        } else {
            expanded.insert(entry.path)
            if childrenByPath[entry.path] == nil {
                Task { await list(entry.path) }
            }
        }
    }

    func select(_ row: FileTree.Row) {
        if row.entry.isDirectory {
            toggleExpand(row.entry)
            return
        }
        switch selectionPresentation(for: row) {
        case .source:
            Task { await open(path: row.entry.path, line: nil) }
        case .diff:
            Task { await showFileDiff(path: row.entry.path) }
        }
    }

    /// The representation a tree-file choice should open. Deleted files have
    /// no worktree bytes, so their diff remains the only honest source in
    /// either mode. A clean file leaves DIFF mode because it has no diff to
    /// show; changed files inherit the current mode.
    func selectionPresentation(for row: FileTree.Row) -> FilePresentation {
        let badge = row.badge ?? badges[row.entry.path]
        if badge == .deleted { return .diff }
        if filePresentation == .diff, badge != nil { return .diff }
        return .source
    }

    /// The tree header's UP chip: hoist the root one directory.
    func hoistRoot() {
        guard let parent = FileTree.parent(of: rootPath) else { return }
        let previousRoot = rootPath
        rootPath = parent
        expanded.insert(previousRoot)
        Task {
            if childrenByPath[parent] == nil { await list(parent) }
            // Leaving the repo's roof means the git verdicts no longer
            // describe the root on screen; a new probe answers honestly.
            if let gitRoot, !Self.path(parent, isUnder: gitRoot) {
                await probeGit(at: parent)
                await refreshGitVerdicts()
            }
        }
    }

    func refresh() {
        guard !isBusy else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            await probeGit(at: rootPath)
            await refreshGitVerdicts()
            await relistVisibleDirectories()
            switch content {
            case .document(let document):
                await open(path: document.path, line: nil)
            case .diff(_, .file(let path)):
                await showFileDiff(path: path)
            case .diff(_, .repo):
                await showRepoDiff()
            default:
                break
            }
        }
    }

    // MARK: Opening files

    func open(path: String, line: Int?, endLine: Int? = nil) async {
        filePresentation = .source
        // Shown images belong to the document that named them.
        if lastDocument?.path != path { inlineImages.removeAll() }
        let name = FileTree.name(of: path)
        contentGeneration += 1
        let generation = contentGeneration
        content = .loading(label: name)
        do {
            let stat = try await withConnection { try await $0.statFile(atPath: path) }
            if stat.isDirectory {
                // A directory "opens" in the tree, not the screen. The
                // phantom child makes expandChain include `path` itself.
                if Self.path(path, isUnder: rootPath) {
                    expandChain(to: FileTree.join(path, "."))
                } else {
                    rootPath = path
                    await list(path)
                }
                if generation == contentGeneration { content = .idle }
                return
            }
            let document = try await makeDocument(
                path: path, line: line, endLine: endLine, stat: stat
            )
            guard generation == contentGeneration else { return }
            lastDocument = document
            watchedStamp = stat
            content = .document(document)
            history.visit(.document(path: path))
        } catch {
            guard generation == contentGeneration else { return }
            if let refusal = error as? LoadRefusal {
                content = .failure(title: refusal.title, message: refusal.message)
            } else {
                content = .failure(
                    title: "CAN'T READ \(name.uppercased())",
                    message: failureMessage(error)
                )
            }
        }
    }

    /// A refusal the pipeline can title itself (the size cap) — one error
    /// channel: `makeDocument` throws, callers catch into the panel.
    private struct LoadRefusal: Error {
        var title: String
        var message: String
    }

    /// The read → classify → parse/highlight pipeline, shared by the loud
    /// open above and the watch's quiet rebuild.
    private func makeDocument(
        path: String,
        line: Int?,
        endLine: Int?,
        stat: SSHConnection.FileStat
    ) async throws -> Document {
        let name = FileTree.name(of: path)
        let size = stat.size ?? 0
        var document = Document(path: path, size: size, kind: FileKind.classify(fileName: name))
        document.targetLine = line
        document.targetEndLine = endLine

        switch document.kind {
        case .binary:
            break
        case .image:
            guard size <= UInt64(Self.imageByteLimit) else {
                throw LoadRefusal(
                    title: "TOO LARGE",
                    message: "\(name) is \(Self.formatBytes(size)) — the viewer renders images up to \(Self.formatBytes(UInt64(Self.imageByteLimit)))."
                )
            }
            let (data, _) = try await withConnection {
                try await $0.readFile(atPath: path, limit: Self.imageByteLimit)
            }
            // Undecodable "image" bytes are binary content by any honest
            // reading — same verdict as the NUL sniff below. Decoding goes
            // through a bounded downsample: the byte limit above says nothing
            // about pixels, and a few hundred kilobytes of valid PNG can
            // decode into gigabytes of bitmap (the viewer only ever shows it
            // at screen size anyway).
            if let image = Self.decodeImage(data) {
                document.image = image
            } else {
                document.kind = .binary
            }
        case .markdown, .code:
            let (data, truncated) = try await withConnection {
                try await $0.readFile(atPath: path, limit: Self.textByteLimit)
            }
            document.truncated = truncated
            if FileKind.looksBinary(data) {
                document.kind = .binary
                break
            }
            let text = await Task.detached { String(decoding: data, as: UTF8.self) }.value
            if document.kind == .markdown {
                document.sourceText = text
                document = await Self.renderedMarkdown(document, raw: markdownRaw)
            } else {
                let language: CodeLanguage? = {
                    if case .code(let detected) = document.kind { return detected }
                    return nil
                }()
                document.codeLines = await Task.detached {
                    CodeHighlighter.highlight(text, language: language)
                }.value
            }
        }
        return document
    }

    /// Markdown renders both ways from the same held text: blocks when
    /// rendered, plain lines when RAW.
    private static func renderedMarkdown(_ document: Document, raw: Bool) async -> Document {
        var document = document
        guard let text = document.sourceText else { return document }
        if raw {
            document.markdown = []
            document.codeLines = await Task.detached {
                CodeHighlighter.highlight(text, language: nil)
            }.value
        } else {
            document.codeLines = []
            document.markdown = await Task.detached {
                MarkdownDocument.parse(text)
            }.value
        }
        return document
    }

    // MARK: Diff

    /// SOURCE | DIFF applies when git has a verdict for the file on screen.
    /// Badges key by absolute path, and both content cases carry one.
    var documentDiffBadge: GitFileStatus.Badge? {
        guard gitRoot != nil else { return nil }
        switch content {
        case .document(let document): return badges[document.path]
        case .diff(_, .file(let path)): return badges[path]
        default: return nil
        }
    }

    private func relativeToRepo(_ path: String) -> String? {
        guard let gitRoot, path.hasPrefix(gitRoot + "/") else { return nil }
        return String(path.dropFirst(gitRoot.count + 1))
    }

    /// Untracked files diff `--no-index /dev/null` (an all-additions
    /// render); tracked files diff against HEAD. Both spellings live here
    /// only — the loud diff and the watch's quiet one share it.
    private func fileDiffCommand(gitRoot: String, path: String) -> String {
        let relative = relativeToRepo(path) ?? path
        return badges[path] == .untracked
            ? GitCommands.untrackedDiff(root: gitRoot, path: relative)
            : GitCommands.diffFile(root: gitRoot, path: relative)
    }

    func showFileDiff(path: String) async {
        guard let gitRoot else { return }
        filePresentation = .diff
        contentGeneration += 1
        let generation = contentGeneration
        let name = FileTree.name(of: path)
        content = .loading(label: "DIFF · \(name)")
        // Baseline the stamp now, so the watch compares against the
        // worktree the diff was cut from — not against nothing.
        watchedStamp = try? await withConnection { try await $0.statFile(atPath: path) }
        await runDiff(
            command: fileDiffCommand(gitRoot: gitRoot, path: path),
            scope: .file(path: path),
            emptyLabel: name,
            generation: generation
        )
    }

    func showRepoDiff() async {
        guard let gitRoot else { return }
        // The repo-wide review is not SOURCE | DIFF for one file. Preserve
        // the prior behavior when a tree row is picked from this screen.
        filePresentation = .source
        contentGeneration += 1
        let generation = contentGeneration
        watchedStamp = nil
        content = .loading(label: "DIFF")
        await runDiff(
            command: GitCommands.fullDiff(root: gitRoot),
            scope: .repo,
            emptyLabel: FileTree.name(of: gitRoot),
            generation: generation
        )
    }

    private func runDiff(
        command: String,
        scope: DiffScope,
        emptyLabel: String,
        generation: Int
    ) async {
        do {
            let output = try await withConnection { try await $0.exec(command) }
            let (body, _) = GitCommands.splitExit(output)
            // --no-index exits 1 whenever sides differ; the body is the
            // verdict that matters.
            let diff = await Task.detached { GitDiff.parse(body) }.value
            guard generation == contentGeneration else { return }
            content = .diff(diff, scope: scope)
            switch scope {
            case .file(let path): history.visit(.fileDiff(path: path))
            case .repo: history.visit(.repoDiff)
            }
        } catch {
            guard generation == contentGeneration else { return }
            content = .failure(
                title: "CAN'T DIFF \(emptyLabel.uppercased())",
                message: failureMessage(error)
            )
        }
    }

    /// The watch's diff refresh: recompute whatever diff is on screen and
    /// swap it in place — no .loading, no scroll reset, and a stale result
    /// (the person navigated meanwhile) is dropped on the floor.
    private func refreshDiffQuietly(generation: Int) async {
        guard let gitRoot, case .diff(_, let scope) = content else { return }
        let command: String
        switch scope {
        case .repo:
            command = GitCommands.fullDiff(root: gitRoot)
        case .file(let path):
            command = fileDiffCommand(gitRoot: gitRoot, path: path)
        }
        guard let output = try? await withConnection({ try await $0.exec(command) })
        else { return }
        let (body, _) = GitCommands.splitExit(output)
        let diff = await Task.detached { GitDiff.parse(body) }.value
        guard generation == contentGeneration,
              case .diff(_, let still) = content, still == scope
        else { return }
        content = .diff(diff, scope: scope)
    }

    /// The SOURCE chip: back to the document behind a per-file diff.
    func showSource() {
        guard case .diff(_, .file(let path)) = content else { return }
        filePresentation = .source
        if let lastDocument, lastDocument.path == path {
            contentGeneration += 1
            content = .document(lastDocument)
            history.visit(.document(path: path))
        } else {
            Task { await open(path: path, line: nil) }
        }
    }

    // MARK: History

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    /// Back/forward re-run the recorded navigation; `history.current`
    /// already names the destination, so the landing's own `visit` no-ops
    /// and a failed load leaves the failure panel with the trail moved —
    /// the browser contract.
    func goBack() {
        guard let entry = history.goBack() else { return }
        Task { await navigate(to: entry) }
    }

    func goForward() {
        guard let entry = history.goForward() else { return }
        Task { await navigate(to: entry) }
    }

    private func navigate(to entry: FileViewerHistory.Entry) async {
        switch entry {
        case .document(let path):
            await open(path: path, line: nil)
        case .fileDiff(let path):
            await showFileDiff(path: path)
        case .repoDiff:
            await showRepoDiff()
        }
    }

    // MARK: Watch

    /// Run by the pane while this tab is the window's ACTIVE tab — the
    /// deck's own cadence and gates: a 5 s tick, network work only while
    /// the app is frontmost-active, and an obscured tab ticks not at all
    /// (the pane's task cancels). Each tick costs one git round trip
    /// (`watchProbe`) plus one stat on the watched path; everything it
    /// learns lands as a quiet swap — no .loading, no scroll reset.
    func watchWhileActive() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await watchTick()
        }
    }

    /// The path whose bytes the current screen shows: the open document,
    /// or the worktree side of a per-file diff. Repo diffs and idle
    /// screens watch git state alone.
    private var watchedContentPath: String? {
        switch content {
        case .document(let document): return document.path
        case .diff(_, .file(let path)): return path
        default: return nil
        }
    }

    private func watchTick() async {
        guard UIApplication.shared.applicationState == .active,
              !isBusy, !rootPath.isEmpty else { return }
        if case .loading = content { return }
        watchTickCount += 1
        let generation = contentGeneration

        var gitChanged = false
        if gitRoot != nil {
            gitChanged = await refreshGitVerdicts()
        }
        if gitChanged {
            await relistVisibleDirectories()
            await refreshDiffQuietly(generation: generation)
        } else if watchTickCount.isMultiple(of: 3) {
            // Ignored files and non-repo directories change without a
            // porcelain verdict; a slower sweep keeps the tree honest.
            await relistVisibleDirectories()
        }

        guard generation == contentGeneration,
              let path = watchedContentPath else { return }
        do {
            let stat = try await withConnection { try await $0.statFile(atPath: path) }
            guard stat != watchedStamp else { return }
            watchedStamp = stat
            await reloadWatchedContent(generation: generation, stat: stat)
        } catch {
            // A transport blip must not tear the screen down; only the
            // server's own verdict that the file is gone is worth acting
            // on, and only for a document (a deleted file's diff IS the
            // record of the deletion).
            if error is SFTPError,
               generation == contentGeneration,
               case .document(let document) = content {
                content = .failure(
                    title: "FILE GONE",
                    message: "The host says \(document.name) no longer exists."
                )
            }
        }
    }

    private func relistVisibleDirectories() async {
        for directory in Set([rootPath]).union(expanded).sorted() {
            await list(directory)
        }
    }

    private func reloadWatchedContent(
        generation: Int,
        stat: SSHConnection.FileStat
    ) async {
        switch content {
        case .document(let current):
            guard !stat.isDirectory,
                  let document = try? await makeDocument(
                      path: current.path, line: nil, endLine: nil, stat: stat
                  ),
                  generation == contentGeneration,
                  case .document(let still) = content, still.path == current.path
            else { return }
            lastDocument = document
            content = .document(document)
        case .diff:
            await refreshDiffQuietly(generation: generation)
        default:
            break
        }
    }

    // MARK: Failure copy

    private func failureMessage(_ error: Error) -> String {
        if let connectionError = error as? SSHConnectionError {
            switch connectionError {
            case .keyPassphraseRequired, .incorrectKeyPassphrase:
                // The stock copy asks for the passphrase; the viewer has no
                // prompt to offer, so point at the two places that can
                // unlock the key instead.
                return "The host's key is sealed. Set its passphrase in "
                    + "Host Settings, or open a terminal to this host first."
            case .notConnected:
                return connectionError.userMessage(host: host) + " REFRESH dials again."
            case .missingCredentials, .unsupportedKey, .connectFailed:
                // One copy source for connection failures, app-wide.
                return connectionError.userMessage(host: host)
            }
        }
        let message = "\(error)"
        if message.localizedCaseInsensitiveContains("no such file") {
            return "The host says there is no such file."
        }
        if message.localizedCaseInsensitiveContains("permission denied") {
            return "The host refused: permission denied."
        }
        return message
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let digits = value >= 100 || unit == 0 ? 0 : 1
        return String(format: "%.\(digits)f %@", value, units[unit])
    }
}
