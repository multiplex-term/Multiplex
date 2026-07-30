import Citadel
import Foundation
import Observation

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
final class FileViewerController {
    /// Text render cap: the capped head still renders, under a TRUNCATED
    /// banner. Big enough for every source file that matters; small enough
    /// that highlighting stays interactive.
    static let textByteLimit = 1_500_000
    static let imageByteLimit = 12_000_000

    let tabID: UUID
    private let host: Host
    var hostName: String { host.name }

    /// The pane cwd at summon time (absolute), when a pane could answer.
    private let startDirectory: String?
    /// The pressed path this tab was summoned to show, when it was.
    private let target: TerminalPathTarget?

    init(
        tabID: UUID,
        host: Host,
        startDirectory: String?,
        target: TerminalPathTarget?
    ) {
        self.tabID = tabID
        self.host = host
        self.startDirectory = startDirectory
        self.target = target
    }

    // MARK: Content

    struct Document: Equatable {
        var path: String
        var size: UInt64
        var kind: FileRenderKind
        var language: CodeLanguage?
        var isBinary = false
        var truncated = false
        /// Code (and markdown RAW) render.
        var codeLines: [HighlightedLine] = []
        /// Markdown rendered blocks.
        var markdown: [MarkdownBlock] = []
        var imageData: Data?
        /// From a `path:12` press — the code view scrolls here once.
        var targetLine: Int?

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
    /// The document behind a per-file DIFF, so SOURCE flips back without a
    /// round trip.
    private(set) var lastDocument: Document?
    /// Markdown RAW toggle — kept across files (a preference, not a mode).
    var markdownRaw = false {
        didSet {
            guard markdownRaw != oldValue,
                  let document = lastDocument, document.kind == .markdown,
                  case .document = content
            else { return }
            Task { await open(path: document.path, line: nil) }
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
            let base = startDirectory ?? home

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
            await list(rootPath)
            expandChain(to: anchor)
            await refreshGitVerdicts()

            if let resolvedTarget {
                await open(path: resolvedTarget, line: target?.line)
            } else {
                content = .idle
            }
        } catch {
            content = .failure(
                title: "NO CONNECTION",
                message: failureMessage(error)
            )
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

    private func refreshGitVerdicts() async {
        guard let gitRoot else {
            statuses = []
            shortStat = GitShortStat()
            return
        }
        if let output = try? await withConnection({
            try await $0.exec(GitCommands.status(root: gitRoot))
        }) {
            let (body, exit) = GitCommands.splitExit(output)
            statuses = exit == 0 ? GitFileStatus.parse(porcelainZ: body) : []
        }
        if let output = try? await withConnection({
            try await $0.exec(GitCommands.shortstat(root: gitRoot))
        }) {
            let (body, exit) = GitCommands.splitExit(output)
            shortStat = exit == 0 ? GitShortStat.parse(body) : GitShortStat()
        }
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
            childrenByPath[directory] = listed.map { entry in
                let typeBits = (entry.permissions ?? 0) & 0o170000
                return FileTreeEntry(
                    name: entry.name,
                    path: FileTree.join(directory, entry.name),
                    isDirectory: typeBits == 0o040000,
                    isSymlink: typeBits == 0o120000,
                    size: entry.size
                )
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
        // A deleted file has no working-tree bytes — its diff IS the file.
        if badges[row.entry.path] == .deleted {
            Task { await showFileDiff(path: row.entry.path) }
            return
        }
        Task { await open(path: row.entry.path, line: nil) }
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
            for directory in [rootPath] + expanded.sorted() {
                await list(directory)
            }
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

    func open(path: String, line: Int?) async {
        let name = FileTree.name(of: path)
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
                content = .idle
                return
            }
            let size = stat.size ?? 0
            var document = Document(path: path, size: size, kind: FileKind.classify(fileName: name))
            document.targetLine = line

            switch document.kind {
            case .binary:
                document.isBinary = true
            case .image:
                guard size <= UInt64(Self.imageByteLimit) else {
                    content = .failure(
                        title: "TOO LARGE",
                        message: "\(name) is \(Self.formatBytes(size)) — the viewer renders images up to \(Self.formatBytes(UInt64(Self.imageByteLimit)))."
                    )
                    return
                }
                let (data, _) = try await withConnection {
                    try await $0.readFile(atPath: path, limit: Self.imageByteLimit)
                }
                document.imageData = data
            case .markdown, .code:
                let (data, truncated) = try await withConnection {
                    try await $0.readFile(atPath: path, limit: Self.textByteLimit)
                }
                document.truncated = truncated
                if FileKind.looksBinary(data) {
                    document.isBinary = true
                    break
                }
                let text = String(decoding: data, as: UTF8.self)
                if document.kind == .markdown, !markdownRaw {
                    document.markdown = await Task.detached {
                        MarkdownDocument.parse(text)
                    }.value
                } else {
                    let language: CodeLanguage? = {
                        if case .code(let detected) = document.kind { return detected }
                        return nil // markdown RAW renders plain
                    }()
                    document.language = language
                    document.codeLines = await Task.detached {
                        CodeHighlighter.highlight(text, language: language)
                    }.value
                }
            }
            lastDocument = document
            content = .document(document)
        } catch {
            content = .failure(
                title: "CAN'T READ \(name.uppercased())",
                message: failureMessage(error)
            )
        }
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

    func showFileDiff(path: String) async {
        guard let gitRoot else { return }
        let name = FileTree.name(of: path)
        let relative = relativeToRepo(path) ?? path
        content = .loading(label: "DIFF · \(name)")
        let command = badges[path] == .untracked
            ? GitCommands.untrackedDiff(root: gitRoot, path: relative)
            : GitCommands.diffFile(root: gitRoot, path: relative)
        await runDiff(command: command, scope: .file(path: path), emptyLabel: name)
    }

    func showRepoDiff() async {
        guard let gitRoot else { return }
        content = .loading(label: "DIFF")
        await runDiff(
            command: GitCommands.fullDiff(root: gitRoot),
            scope: .repo,
            emptyLabel: FileTree.name(of: gitRoot)
        )
    }

    private func runDiff(command: String, scope: DiffScope, emptyLabel: String) async {
        do {
            let output = try await withConnection { try await $0.exec(command) }
            let (body, _) = GitCommands.splitExit(output)
            // --no-index exits 1 whenever sides differ; the body is the
            // verdict that matters.
            let diff = await Task.detached { GitDiff.parse(body) }.value
            content = .diff(diff, scope: scope)
        } catch {
            content = .failure(
                title: "CAN'T DIFF \(emptyLabel.uppercased())",
                message: failureMessage(error)
            )
        }
    }

    /// The SOURCE chip: back to the document behind a per-file diff.
    func showSource() {
        if let lastDocument, case .diff(_, .file(let path)) = content,
           lastDocument.path == path {
            content = .document(lastDocument)
            return
        }
        if case .diff(_, .file(let path)) = content {
            Task { await open(path: path, line: nil) }
        }
    }

    // MARK: Failure copy

    private func failureMessage(_ error: Error) -> String {
        if let connectionError = error as? SSHConnectionError {
            switch connectionError {
            case .keyPassphraseRequired, .incorrectKeyPassphrase:
                return "The host's key is sealed. Set its passphrase in "
                    + "Host Settings, or open a terminal to this host first."
            case .missingCredentials:
                return "No credentials for \(host.name) — check Host Settings."
            case .connectFailed(let reason):
                return reason
            case .notConnected:
                return "The connection dropped. REFRESH dials again."
            case .unsupportedKey:
                return "The host's key format isn't supported."
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
