import Observation
import UIKit

/// Equatable projection of the controller's content enum. Observation can
/// repaint the rail for a busy flag or git badge without tearing down the
/// live text selection and scroll position in the screen above it.
private enum FileViewerPaneBodyState: Equatable {
    case idle
    case loading(String)
    case document(FileViewerController.Document)
    case diff(GitDiff, FileViewerController.DiffScope)
    case failure(String, String)

    @MainActor
    init(_ content: FileViewerController.Content) {
        switch content {
        case .idle: self = .idle
        case .loading(let label): self = .loading(label)
        case .document(let document): self = .document(document)
        case .diff(let diff, let scope): self = .diff(diff, scope)
        case .failure(let title, let message): self = .failure(title, message)
        }
    }
}

private struct FileViewerPaneObservedState {
    var body: FileViewerPaneBodyState
    var hostName: String
    var rootPath: String
    var railPath: String
    var hasGitRoot: Bool
    var documentDiffBadge: GitFileStatus.Badge?
    var documentBadge: GitFileStatus.Badge?
    var markdownRaw: Bool
    var isBusy: Bool
    var canGoBack: Bool
    var canGoForward: Bool

    @MainActor
    init(controller: FileViewerController) {
        body = FileViewerPaneBodyState(controller.content)
        hostName = controller.hostName
        rootPath = controller.rootPath
        railPath = controller.railPath
        hasGitRoot = controller.gitRoot != nil
        documentDiffBadge = controller.documentDiffBadge
        markdownRaw = controller.markdownRaw
        isBusy = controller.isBusy
        canGoBack = controller.canGoBack
        canGoForward = controller.canGoForward
        if case .document = controller.content {
            // `documentDiffBadge` is the document's own badge already, and
            // every read of `controller.badges` rebuilds the repo-wide map —
            // one render pays for that once.
            documentBadge = documentDiffBadge
        }
    }
}

/// Native WORKBENCH pane. The controller composes the already-native tree and
/// selectable text surfaces, owns compact/regular geometry, and observes the
/// service directly.
@MainActor
final class FileViewerPaneViewController: UIViewController {
    static let treeWidth: CGFloat = 236
    static let compactThreshold: CGFloat = 700
    static let drawerExtraWidth: CGFloat = 24
    static let drawerClearance: CGFloat = 56

    private let controller: FileViewerController
    private var contentSafeArea: UIEdgeInsets
    private var isActive: Bool
    private var openInNewTabAction: (FileTree.Row) -> Void
    private var closeAction: () -> Void
    private let startsController: Bool

    private(set) var treeDocked = true
    private(set) var drawerOpen: Bool
    private(set) var isCompactLayout = false
    private(set) var selectingMarkdownSource = false

    private let rootStack = UIStackView()
    private let contentRegion = UIView()
    private let contentColumn = UIStackView()
    private let bodyContainer = UIView()
    private let headerNameLabel = UILabel()
    private let headerMetaLabel = UIKitChassisLabel("", size: 8, color: UIKitChassis.signal3)
    private let headerBadgeLabel = UILabel()
    private let headerCountsLabel = UILabel()
    private let railView = UIView()
    private let railStack = UIStackView()
    private let railPathLabel = UILabel()
    private let workingLine = UIView()
    private let treeShell = UIView()
    private let treeDivider = UIView()
    private(set) var treeView = FileViewerTreeColumnView()

    private(set) var backChip: UIKitChassisChip?
    private(set) var forwardChip: UIKitChassisChip?
    private(set) var sourceChip: UIKitChassisChip?
    private(set) var diffChip: UIKitChassisChip?
    private(set) var selectChip: UIKitChassisChip?
    private(set) var treeChip: UIKitChassisChip?
    private(set) var refreshChip: UIKitChassisChip?
    private(set) var closeChip: UIKitChassisChip?
    private(set) var currentBodyView: UIView?

    private var railLeading: NSLayoutConstraint!
    private var railTrailing: NSLayoutConstraint!
    private var railBottom: NSLayoutConstraint!
    private var responsiveConstraints: [NSLayoutConstraint] = []
    private var compactTrailing: NSLayoutConstraint?
    private var compactWidth: NSLayoutConstraint?
    private var lastLayoutWidth: CGFloat = -1

    private var observedState: FileViewerPaneObservedState?
    private var renderedBodyState: FileViewerPaneBodyState?
    private var renderedBodyKey: BodyKey?
    private var markdownSelectKey: String?
    private var observationGeneration = 0
    private var startTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?

    #if DEBUG
    private var debugSelectObserver: NSObjectProtocol?
    #endif

    init(
        controller: FileViewerController,
        contentSafeArea: UIEdgeInsets = .zero,
        isActive: Bool = true,
        startsController: Bool = true,
        openInNewTab: @escaping (FileTree.Row) -> Void = { _ in },
        close: @escaping () -> Void
    ) {
        self.controller = controller
        self.contentSafeArea = contentSafeArea
        self.isActive = isActive
        self.startsController = startsController
        openInNewTabAction = openInNewTab
        closeAction = close
        drawerOpen = Self.startsWithDrawerOpen(controller)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        startTask?.cancel()
        watchTask?.cancel()
        #if DEBUG
        if let debugSelectObserver {
            NotificationCenter.default.removeObserver(debugSelectObserver)
        }
        #endif
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIKitChassis.screen
        buildHierarchy()
        // Give Auto Layout a complete initial graph before the first
        // controller layout callback supplies the real canvas width.
        applyResponsiveLayout(for: max(view.bounds.width, Self.compactThreshold))
        treeView.apply(
            controller: controller,
            closeDrawer: { [weak self] in
                self?.setDrawerOpen(false, animated: true)
            },
            openInNewTab: { [weak self] row in
                self?.openInNewTabAction(row)
            }
        )

        observationGeneration &+= 1
        observeAndRender(generation: observationGeneration)
        if startsController {
            startTask = Task { [weak controller] in await controller?.start() }
            restartWatch()
        }

        #if DEBUG
        debugSelectObserver = NotificationCenter.default.addObserver(
            forName: .multiplexDebugFileViewerSelect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.toggleMarkdownSelection() }
        }
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = contentRegion.bounds.width
        guard width > 0 else { return }
        if abs(width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = width
            applyResponsiveLayout(for: width)
        }
        if isCompactLayout, !treeShell.isHidden {
            treeShell.layer.shadowPath = UIBezierPath(rect: treeShell.bounds).cgPath
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshDrawerShadow()
        if let state = observedState {
            updateHeader(state)
            rebuildRail(state)
        }
    }

    func update(
        contentSafeArea: UIEdgeInsets,
        isActive: Bool,
        openInNewTab: @escaping (FileTree.Row) -> Void,
        close: @escaping () -> Void
    ) {
        openInNewTabAction = openInNewTab
        closeAction = close
        if self.contentSafeArea != contentSafeArea {
            self.contentSafeArea = contentSafeArea
            if isViewLoaded { updateRailInsets() }
        }
        guard self.isActive != isActive else { return }
        self.isActive = isActive
        if isViewLoaded, startsController { restartWatch() }
    }

    func prepareForRemoval() {
        observationGeneration &+= 1
        startTask?.cancel()
        startTask = nil
        watchTask?.cancel()
        watchTask = nil
    }

    static func startsWithDrawerOpen(_ controller: FileViewerController) -> Bool {
        guard controller.opensBrowsing else { return false }
        switch controller.content {
        case .document, .diff: return false
        default: return true
        }
    }

    static func isCompact(width: CGFloat) -> Bool {
        width < compactThreshold
    }

    static func drawerWidth(for width: CGFloat) -> CGFloat {
        max(0, min(treeWidth + drawerExtraWidth, width - drawerClearance))
    }

    static func badgeCaption(_ badge: GitFileStatus.Badge) -> String {
        switch badge {
        case .modified: "MODIFIED"
        case .added: "STAGED ADD"
        case .deleted: "DELETED"
        case .renamed: "RENAMED"
        case .untracked: "UNTRACKED"
        case .conflicted: "CONFLICT"
        }
    }

    // MARK: Hierarchy

    private func buildHierarchy() {
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 0
        view.addSubview(rootStack)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        contentRegion.backgroundColor = UIKitChassis.screen
        contentRegion.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        rootStack.addArrangedSubview(contentRegion)
        buildContentColumn()
        buildTreeShell()
        buildRail()
        rootStack.addArrangedSubview(railView)
    }

    private func buildContentColumn() {
        contentColumn.axis = .vertical
        contentColumn.alignment = .fill
        contentColumn.spacing = 0
        contentColumn.backgroundColor = UIKitChassis.screen
        contentRegion.addSubview(contentColumn)
        contentColumn.translatesAutoresizingMaskIntoConstraints = false

        let header = UIView()
        header.backgroundColor = UIKitChassis.screen
        headerNameLabel.font = UIKitChassis.monoFont(11, weight: .semibold)
        headerNameLabel.textColor = UIKitChassis.signal
        headerNameLabel.numberOfLines = 1
        headerNameLabel.lineBreakMode = .byTruncatingMiddle
        headerNameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        headerMetaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerBadgeLabel.numberOfLines = 1
        headerBadgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        headerCountsLabel.numberOfLines = 1
        headerCountsLabel.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = flexibleSpacer(minimum: 6)
        let row = UIStackView(arrangedSubviews: [
            headerNameLabel, headerMetaLabel, spacer,
            headerBadgeLabel, headerCountsLabel,
        ])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        header.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: header.topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -7),
        ])
        contentColumn.addArrangedSubview(header)

        let divider = UIView()
        divider.backgroundColor = UIKitChassis.bezelHi
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        contentColumn.addArrangedSubview(divider)
        bodyContainer.backgroundColor = UIKitChassis.screen
        bodyContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        contentColumn.addArrangedSubview(bodyContainer)
    }

    private func buildTreeShell() {
        treeShell.backgroundColor = UIKitChassis.bezel
        treeShell.clipsToBounds = false
        treeDivider.backgroundColor = UIKitChassis.bezelHi
        treeShell.addSubview(treeDivider)
        treeShell.addSubview(treeView)
        treeDivider.translatesAutoresizingMaskIntoConstraints = false
        treeView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            treeDivider.leadingAnchor.constraint(equalTo: treeShell.leadingAnchor),
            treeDivider.topAnchor.constraint(equalTo: treeShell.topAnchor),
            treeDivider.bottomAnchor.constraint(equalTo: treeShell.bottomAnchor),
            treeDivider.widthAnchor.constraint(equalToConstant: 1),
            treeView.leadingAnchor.constraint(equalTo: treeDivider.trailingAnchor),
            treeView.trailingAnchor.constraint(equalTo: treeShell.trailingAnchor),
            treeView.topAnchor.constraint(equalTo: treeShell.topAnchor),
            treeView.bottomAnchor.constraint(equalTo: treeShell.bottomAnchor),
        ])
        contentRegion.addSubview(treeShell)
        treeShell.translatesAutoresizingMaskIntoConstraints = false
    }

    private func buildRail() {
        railView.backgroundColor = UIKitChassis.bezel
        railStack.axis = .horizontal
        railStack.alignment = .center
        railStack.spacing = 8
        railView.addSubview(railStack)
        railStack.translatesAutoresizingMaskIntoConstraints = false
        railLeading = railStack.leadingAnchor.constraint(equalTo: railView.leadingAnchor)
        railTrailing = railStack.trailingAnchor.constraint(equalTo: railView.trailingAnchor)
        railBottom = railStack.bottomAnchor.constraint(equalTo: railView.bottomAnchor)
        NSLayoutConstraint.activate([
            railLeading,
            railTrailing,
            railStack.topAnchor.constraint(equalTo: railView.topAnchor, constant: 8),
            railBottom,
        ])
        updateRailInsets()

        let topLine = UIView()
        topLine.backgroundColor = UIKitChassis.bezelHi
        railView.addSubview(topLine)
        topLine.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topLine.leadingAnchor.constraint(equalTo: railView.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: railView.trailingAnchor),
            topLine.topAnchor.constraint(equalTo: railView.topAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),
        ])
        workingLine.backgroundColor = TallyPalette.caution
        workingLine.isAccessibilityElement = false
        railView.addSubview(workingLine)
        workingLine.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            workingLine.leadingAnchor.constraint(equalTo: railView.leadingAnchor),
            workingLine.topAnchor.constraint(equalTo: railView.topAnchor),
            workingLine.widthAnchor.constraint(equalToConstant: 90),
            workingLine.heightAnchor.constraint(equalToConstant: 2),
        ])

        railPathLabel.numberOfLines = 1
        railPathLabel.lineBreakMode = .byTruncatingHead
        railPathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        railPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func updateRailInsets() {
        railLeading.constant = 10 + contentSafeArea.left
        railTrailing.constant = -(10 + contentSafeArea.right)
        railBottom.constant = -(8 + contentSafeArea.bottom)
    }

    // MARK: Observation + lifecycle

    private func observeAndRender(generation: Int) {
        guard generation == observationGeneration else { return }
        let state = withObservationTracking {
            FileViewerPaneObservedState(controller: controller)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeAndRender(generation: generation)
            }
        }
        render(state)
    }

    private func restartWatch() {
        watchTask?.cancel()
        watchTask = nil
        guard isActive else { return }
        watchTask = Task { [weak controller] in
            await controller?.watchWhileActive()
        }
    }

    private func render(_ state: FileViewerPaneObservedState) {
        let selectKey = markdownSelectionKey(for: state)
        if selectKey != markdownSelectKey {
            markdownSelectKey = selectKey
            selectingMarkdownSource = false
        }
        observedState = state
        updateHeader(state)
        updateBody(state)
        rebuildRail(state)
        workingLine.isHidden = !isWorking(state)
    }

    // MARK: Responsive tree

    /// Explicit width seam used by `viewDidLayoutSubviews` and focused UIKit
    /// tests; keeping the breakpoint decision here prevents trait heuristics
    /// from disagreeing with the actual pane canvas.
    func applyResponsiveLayout(for width: CGFloat) {
        let compact = Self.isCompact(width: width)
        let modeChanged = compact != isCompactLayout
        isCompactLayout = compact
        NSLayoutConstraint.deactivate(responsiveConstraints)
        responsiveConstraints.removeAll()
        compactTrailing = nil
        compactWidth = nil

        if compact {
            let trailing = treeShell.trailingAnchor.constraint(equalTo: contentRegion.trailingAnchor)
            let widthConstraint = treeShell.widthAnchor.constraint(
                equalToConstant: Self.drawerWidth(for: width)
            )
            compactTrailing = trailing
            compactWidth = widthConstraint
            responsiveConstraints = [
                contentColumn.leadingAnchor.constraint(equalTo: contentRegion.leadingAnchor),
                contentColumn.trailingAnchor.constraint(equalTo: contentRegion.trailingAnchor),
                contentColumn.topAnchor.constraint(equalTo: contentRegion.topAnchor),
                contentColumn.bottomAnchor.constraint(equalTo: contentRegion.bottomAnchor),
                trailing,
                widthConstraint,
                treeShell.topAnchor.constraint(equalTo: contentRegion.topAnchor),
                treeShell.bottomAnchor.constraint(equalTo: contentRegion.bottomAnchor),
            ]
            treeShell.isHidden = !drawerOpen
            contentRegion.bringSubviewToFront(treeShell)
            refreshDrawerShadow()
        } else {
            treeShell.layer.shadowOpacity = 0
            if treeDocked {
                treeShell.isHidden = false
                responsiveConstraints = [
                    contentColumn.leadingAnchor.constraint(equalTo: contentRegion.leadingAnchor),
                    contentColumn.topAnchor.constraint(equalTo: contentRegion.topAnchor),
                    contentColumn.bottomAnchor.constraint(equalTo: contentRegion.bottomAnchor),
                    contentColumn.trailingAnchor.constraint(equalTo: treeShell.leadingAnchor),
                    treeShell.trailingAnchor.constraint(equalTo: contentRegion.trailingAnchor),
                    treeShell.topAnchor.constraint(equalTo: contentRegion.topAnchor),
                    treeShell.bottomAnchor.constraint(equalTo: contentRegion.bottomAnchor),
                    treeShell.widthAnchor.constraint(equalToConstant: Self.treeWidth + 1),
                ]
            } else {
                treeShell.isHidden = true
                responsiveConstraints = [
                    contentColumn.leadingAnchor.constraint(equalTo: contentRegion.leadingAnchor),
                    contentColumn.trailingAnchor.constraint(equalTo: contentRegion.trailingAnchor),
                    contentColumn.topAnchor.constraint(equalTo: contentRegion.topAnchor),
                    contentColumn.bottomAnchor.constraint(equalTo: contentRegion.bottomAnchor),
                ]
            }
        }
        NSLayoutConstraint.activate(responsiveConstraints)
        if modeChanged, let state = observedState { rebuildRail(state) }
    }

    private func refreshDrawerShadow() {
        guard isCompactLayout else { return }
        // CALayer supports one cast; the wider ambient cast is the one that
        // carries separation in both appearances, with a tight one-point
        // border supplying the contact edge.
        treeShell.layer.shadowColor = TallyPalette.shadowAmbient
            .resolvedColor(with: traitCollection).cgColor
        treeShell.layer.shadowOpacity = 1
        treeShell.layer.shadowRadius = 18
        treeShell.layer.shadowOffset = CGSize(width: -8, height: 0)
    }

    private func toggleTree() {
        if isCompactLayout {
            setDrawerOpen(!drawerOpen, animated: view.window != nil)
        } else {
            treeDocked.toggle()
            applyResponsiveLayout(for: max(contentRegion.bounds.width, view.bounds.width))
            if let state = observedState { rebuildRail(state) }
        }
    }

    func setDrawerOpen(_ open: Bool, animated: Bool) {
        guard drawerOpen != open else { return }
        drawerOpen = open
        guard isCompactLayout, let trailing = compactTrailing else {
            if let state = observedState { rebuildRail(state) }
            return
        }
        let width = compactWidth?.constant ?? Self.drawerWidth(for: contentRegion.bounds.width)
        if open {
            treeShell.isHidden = false
            trailing.constant = width
            contentRegion.layoutIfNeeded()
            trailing.constant = 0
        } else {
            trailing.constant = width
        }
        let completion: (Bool) -> Void = { [weak self] _ in
            guard let self else { return }
            if !self.drawerOpen {
                self.treeShell.isHidden = true
                trailing.constant = 0
            }
        }
        if animated {
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState],
                animations: { self.contentRegion.layoutIfNeeded() },
                completion: completion
            )
        } else {
            contentRegion.layoutIfNeeded()
            completion(true)
        }
        if let state = observedState { rebuildRail(state) }
    }

    // MARK: Header

    private func updateHeader(_ state: FileViewerPaneObservedState) {
        headerNameLabel.text = headerName(state)
        headerNameLabel.accessibilityLabel = headerName(state)
        headerMetaLabel.setText(headerMeta(state))

        if case .document = state.body, let badge = state.documentBadge {
            headerBadgeLabel.attributedText = chassisText(
                Self.badgeCaption(badge),
                size: 8,
                color: FileViewerTreeColumn.badgeUIColor(badge)
            )
            headerBadgeLabel.accessibilityLabel = Self.badgeCaption(badge)
            headerBadgeLabel.isHidden = false
        } else {
            headerBadgeLabel.isHidden = true
        }

        if case .diff(let diff, _) = state.body,
           diff.additions > 0 || diff.deletions > 0 {
            headerCountsLabel.attributedText = Self.countsText(
                additions: diff.additions,
                deletions: diff.deletions
            )
            headerCountsLabel.accessibilityLabel = "\(diff.additions) additions, \(diff.deletions) deletions"
            headerCountsLabel.isHidden = false
        } else {
            headerCountsLabel.isHidden = true
        }
    }

    private func headerName(_ state: FileViewerPaneObservedState) -> String {
        switch state.body {
        case .document(let document): document.name
        case .diff(_, .repo): "Working tree vs HEAD"
        case .diff(_, .file(let path)): FileTree.name(of: path)
        case .loading(let label): label
        case .failure: "—"
        case .idle: FileTree.name(of: state.rootPath)
        }
    }

    private func headerMeta(_ state: FileViewerPaneObservedState) -> String {
        switch state.body {
        case .document(let document):
            var parts: [String] = []
            if case .code(let language) = document.kind {
                parts.append(language?.rawValue ?? "TEXT")
            } else if document.kind == .markdown {
                parts.append(
                    state.markdownRaw
                        ? "MARKDOWN · RAW"
                        : (selectingMarkdownSource ? "MARKDOWN · SOURCE" : "MARKDOWN")
                )
            } else if document.kind == .image {
                parts.append("IMAGE")
            } else {
                parts.append("BINARY")
            }
            parts.append(FileViewerController.formatBytes(document.size))
            if document.truncated { parts.append("TRUNCATED") }
            return parts.joined(separator: " · ")
        case .diff(let diff, .repo):
            return "\(diff.files.count) FILE\(diff.files.count == 1 ? "" : "S")"
        case .diff(_, .file):
            return "DIFF VS HEAD"
        case .loading:
            return "LOADING"
        default:
            return state.hostName.uppercased()
        }
    }

    static func countsText(additions: Int, deletions: Int) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: "+\(additions) ",
            attributes: [
                .font: UIKitChassis.monoFont(9, weight: .semibold),
                .foregroundColor: CodePalette.diffAddText,
            ]
        )
        text.append(NSAttributedString(
            string: "−\(deletions)",
            attributes: [
                .font: UIKitChassis.monoFont(9, weight: .semibold),
                .foregroundColor: CodePalette.diffDeleteText,
            ]
        ))
        return text
    }

    // MARK: Rail

    private func rebuildRail(_ state: FileViewerPaneObservedState) {
        for child in railStack.arrangedSubviews {
            railStack.removeArrangedSubview(child)
            if child !== railPathLabel { child.removeFromSuperview() }
        }
        backChip = nil
        forwardChip = nil
        sourceChip = nil
        diffChip = nil
        selectChip = nil

        // Back/forward appear once there is anywhere to go — a fresh tab's
        // rail stays uncluttered. The pair shows together (a dimmed twin
        // keeps the other from jumping around) and dims like REFRESH does.
        if state.canGoBack || state.canGoForward {
            let back = makeChip("◂", accessibility: "Back") { [weak controller] in
                controller?.goBack()
            }
            back.accessibilityIdentifier = "fileViewer.back"
            setChipEnabled(back, state.canGoBack)
            backChip = back
            let forward = makeChip("▸", accessibility: "Forward") { [weak controller] in
                controller?.goForward()
            }
            forward.accessibilityIdentifier = "fileViewer.forward"
            setChipEnabled(forward, state.canGoForward)
            forwardChip = forward
            let pair = UIStackView(arrangedSubviews: [back, forward])
            pair.axis = .horizontal
            pair.alignment = .center
            pair.spacing = 4
            pair.isAccessibilityElement = false
            railStack.addArrangedSubview(pair)
        }

        if state.documentDiffBadge != nil {
            let sourceMode: Bool
            if case .document = state.body { sourceMode = true } else { sourceMode = false }
            let source = makeChip(
                "SOURCE",
                prominent: sourceMode,
                accessibility: "Show source"
            ) { [weak controller] in controller?.showSource() }
            source.accessibilityIdentifier = "fileViewer.source"
            let diff = makeChip(
                "DIFF",
                prominent: !sourceMode,
                accessibility: "Show diff"
            ) { [weak self] in
                guard let self,
                      case .document(let document) = self.observedState?.body
                else { return }
                Task { @MainActor [weak controller = self.controller] in
                    await controller?.showFileDiff(path: document.path)
                }
            }
            diff.accessibilityIdentifier = "fileViewer.diff"
            sourceChip = source
            diffChip = diff
            let mode = UIStackView(arrangedSubviews: [source, diff])
            mode.axis = .horizontal
            mode.alignment = .center
            mode.spacing = 4
            mode.isAccessibilityElement = false
            mode.accessibilityLabel = "Source or diff"
            railStack.addArrangedSubview(mode)
        }

        if markdownSelectionAvailable(state) {
            let select = makeChip(
                selectingMarkdownSource ? "DONE" : "SELECT",
                prominent: selectingMarkdownSource,
                accessibility: selectingMarkdownSource
                    ? "Back to rendered markdown"
                    : "Select source text to copy"
            ) { [weak self] in self?.toggleMarkdownSelection() }
            select.accessibilityIdentifier = "fileViewer.markdownSelect"
            selectChip = select
            railStack.addArrangedSubview(select)
        }

        railPathLabel.attributedText = pathText(state.railPath)
        railPathLabel.accessibilityLabel = state.railPath
        railStack.addArrangedSubview(railPathLabel)

        let host = FileViewerBadgeView(state.hostName.uppercased())
        host.accessibilityLabel = "Files on \(state.hostName)"
        host.setContentHuggingPriority(.required, for: .horizontal)
        railStack.addArrangedSubview(host)

        let treeVisible = isCompactLayout ? drawerOpen : treeDocked
        let tree = makeChip(
            treeVisible ? "HIDE" : "TREE",
            accessibility: treeVisible ? "Hide the file tree" : "Show the file tree"
        ) { [weak self] in self?.toggleTree() }
        tree.accessibilityIdentifier = "fileViewer.tree"
        treeChip = tree
        railStack.addArrangedSubview(tree)

        let refresh = makeChip("REFRESH", accessibility: "Refresh file viewer") { [weak controller] in
            controller?.refresh()
        }
        refresh.accessibilityIdentifier = "fileViewer.refresh"
        setChipEnabled(refresh, !state.isBusy)
        refreshChip = refresh
        railStack.addArrangedSubview(refresh)

        let close = makeChip(
            "CLOSE",
            prominent: true,
            accessibility: "Close file viewer"
        ) { [weak self] in self?.closeAction() }
        close.accessibilityIdentifier = "fileViewer.close"
        closeChip = close
        railStack.addArrangedSubview(close)
    }

    private func makeChip(
        _ caption: String,
        prominent: Bool = false,
        accessibility: String,
        action: @escaping () -> Void
    ) -> UIKitChassisChip {
        let chip = UIKitChassisChip(
            caption,
            prominent: prominent,
            accessibilityLabel: accessibility,
            action: action
        )
        chip.setContentHuggingPriority(.required, for: .horizontal)
        chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        return chip
    }

    private func setChipEnabled(_ chip: UIKitChassisChip, _ enabled: Bool) {
        chip.isUserInteractionEnabled = enabled
        chip.alpha = enabled ? 1 : 0.5
        chip.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
    }

    private func toggleMarkdownSelection() {
        guard isActive, let state = observedState, markdownSelectionAvailable(state)
        else { return }
        selectingMarkdownSource.toggle()
        updateHeader(state)
        updateBody(state)
        rebuildRail(state)
    }

    private func markdownSelectionAvailable(_ state: FileViewerPaneObservedState) -> Bool {
        if case .document(let document) = state.body,
           document.kind == .markdown,
           !document.markdown.isEmpty,
           document.sourceText != nil {
            return true
        }
        return false
    }

    private func markdownSelectionKey(for state: FileViewerPaneObservedState) -> String? {
        guard case .document(let document) = state.body,
              document.kind == .markdown
        else { return nil }
        return "\(document.path):\(state.markdownRaw)"
    }

    private func pathText(_ path: String) -> NSAttributedString {
        let name = FileTree.name(of: path)
        let directory = String(path.dropLast(name.count))
        let text = NSMutableAttributedString(
            string: directory,
            attributes: [
                .font: UIKitChassis.monoFont(10),
                .foregroundColor: UIKitChassis.signal3,
            ]
        )
        text.append(NSAttributedString(
            string: name,
            attributes: [
                .font: UIKitChassis.monoFont(10, weight: .semibold),
                .foregroundColor: UIKitChassis.signal,
            ]
        ))
        return text
    }

    private func isWorking(_ state: FileViewerPaneObservedState) -> Bool {
        if state.isBusy { return true }
        if case .loading = state.body { return true }
        return false
    }

    // MARK: Body

    private enum BodyKey: Equatable {
        case idle
        case loading(String)
        case binary(String)
        case image(String)
        case code(String)
        case markdown(String)
        case markdownSource(String)
        case diff(FileViewerController.DiffScope)
        case failure(String, String)
    }

    private func bodyKey(for state: FileViewerPaneObservedState) -> BodyKey {
        switch state.body {
        case .idle: return .idle
        case .loading(let label): return .loading(label)
        case .failure(let title, let message): return .failure(title, message)
        case .diff(_, let scope): return .diff(scope)
        case .document(let document):
            switch document.kind {
            case .binary: return .binary(document.path)
            case .image: return document.image == nil
                ? .binary(document.path) : .image(document.path)
            case .markdown where !document.markdown.isEmpty:
                return selectingMarkdownSource && document.sourceText != nil
                    ? .markdownSource(document.path) : .markdown(document.path)
            case .markdown, .code:
                return .code(document.path)
            }
        }
    }

    private func updateBody(_ state: FileViewerPaneObservedState) {
        let key = bodyKey(for: state)
        guard renderedBodyState != state.body || renderedBodyKey != key else { return }
        renderedBodyState = state.body

        if renderedBodyKey == key, let currentBodyView {
            apply(state.body, to: currentBodyView)
            return
        }

        renderedBodyKey = key
        let replacement = makeBody(for: state)
        currentBodyView?.removeFromSuperview()
        currentBodyView = replacement
        bodyContainer.addSubview(replacement)
        replacement.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            replacement.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            replacement.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            replacement.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            replacement.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
        ])
    }

    private func makeBody(for state: FileViewerPaneObservedState) -> UIView {
        switch state.body {
        case .idle:
            return FileViewerMessageView(
                caption: "NO FILE ON SCREEN",
                detail: "Pick a file from the tree\(state.hasGitRoot ? ", or open the branch's diff from its ± counts" : "").",
                captionColor: UIKitChassis.signal3,
                detailFont: UIFont.preferredFont(forTextStyle: .footnote),
                maximumWidth: 300
            )
        case .loading(let label):
            return FileViewerMessageView(
                caption: "LOADING",
                detail: label,
                captionColor: TallyPalette.caution,
                detailFont: UIKitChassis.monoFont(11),
                maximumWidth: 360
            )
        case .failure(let title, let message):
            return FileViewerPanelHostView(
                panel: FileViewerPanelView(
                    caption: title,
                    details: [(message, UIFont.preferredFont(forTextStyle: .subheadline), UIKitChassis.signal2)],
                    action: ("REFRESH", { [weak controller] in controller?.refresh() })
                ),
                outerInset: 20
            )
        case .diff(let diff, let scope):
            let view = FileViewerDiffContentView()
            view.apply(diff: diff, scope: scope)
            return view
        case .document(let document):
            return makeDocumentBody(document)
        }
    }

    private func makeDocumentBody(_ document: FileViewerController.Document) -> UIView {
        switch document.kind {
        case .binary:
            return binaryBody(document)
        case .image:
            guard let image = document.image else { return binaryBody(document) }
            let view = FileViewerImageContentView()
            view.apply(image: image)
            return view
        case .markdown where !document.markdown.isEmpty:
            if selectingMarkdownSource, let text = document.sourceText {
                let view = FileViewerMarkdownSourceContentView()
                view.apply(text: text)
                return view
            }
            let view = FileViewerMarkdownContentView()
            view.openLink = { [weak self] in self?.openMarkdownLink($0) }
            view.apply(blocks: document.markdown)
            return view
        case .markdown, .code:
            let view = FileViewerCodeContentView()
            view.apply(
                lines: document.codeLines,
                truncated: document.truncated,
                targetLine: document.targetLine
            )
            return view
        }
    }

    private func binaryBody(_ document: FileViewerController.Document) -> UIView {
        FileViewerPanelHostView(panel: FileViewerPanelView(
            caption: "BINARY",
            details: [
                (
                    "\(document.name) · \(FileViewerController.formatBytes(document.size))",
                    UIKitChassis.monoFont(12),
                    UIKitChassis.signal2
                ),
                (
                    "Not text — Multiplex won't render it as code.",
                    UIFont.preferredFont(forTextStyle: .footnote),
                    UIKitChassis.signal3
                ),
            ]
        ))
    }

    private func apply(_ body: FileViewerPaneBodyState, to view: UIView) {
        switch (body, view) {
        case (.document(let document), let code as FileViewerCodeContentView):
            code.apply(
                lines: document.codeLines,
                truncated: document.truncated,
                targetLine: document.targetLine
            )
        case (.document(let document), let markdown as FileViewerMarkdownContentView):
            markdown.openLink = { [weak self] in self?.openMarkdownLink($0) }
            markdown.apply(blocks: document.markdown)
        case (.document(let document), let source as FileViewerMarkdownSourceContentView):
            source.apply(text: document.sourceText ?? "")
        case (.document(let document), let image as FileViewerImageContentView):
            if let uiImage = document.image { image.apply(image: uiImage) }
        case (.diff(let diff, let scope), let diffView as FileViewerDiffContentView):
            diffView.apply(diff: diff, scope: scope)
        default:
            // Static state panels are keyed by all visible copy, so a key
            // match needs no mutation.
            break
        }
    }

    private func openMarkdownLink(_ destination: String) {
        // External targets are untrusted document text — the link sheet
        // decides, exactly like a pane press. A scheme-less target is
        // in-document navigation by markdown's own definition (a relative
        // reference), so the pane-press schemeless-host reading is opted
        // out — `api.v2/index.md` navigates, it does not become a URL.
        if let link = TerminalLink.resolve(destination, schemelessHosts: false) {
            presentLinkConfirmation(link)
        } else if !destination.contains(":"), let current = controller.lastDocument {
            let base = FileTree.parent(of: current.path) ?? "/"
            Task { [weak controller] in
                await controller?.open(
                    path: FileTree.join(base, destination),
                    line: nil
                )
            }
        }
    }

    private func presentLinkConfirmation(_ link: TerminalLink) {
        guard presentedViewController == nil else { return }
        let sheet = TerminalLinkSheetViewController(
            link: link,
            onOpen: { confirmed in
                if let url = confirmed.openableURL { UIApplication.shared.open(url) }
            },
            onCopy: { UIPasteboard.general.string = $0 }
        )
        let navigation = UINavigationController(rootViewController: sheet)
        sheet.onDismiss = { [weak navigation] in navigation?.dismiss(animated: true) }
        present(navigation, animated: true)
    }

    // MARK: Helpers

    private func chassisText(_ text: String, size: CGFloat, color: UIColor) -> NSAttributedString {
        let scaled = size * Theme.typeScale
        return NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: UIKitChassis.compressedLabelFont(size),
                .kern: scaled * 0.09,
                .foregroundColor: color,
            ]
        )
    }

    private func flexibleSpacer(minimum: CGFloat) -> UIView {
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: minimum).isActive = true
        return spacer
    }
}

/// Non-interactive native counterpart of `ChassisBadge` for the host tag in
/// the rail. The action chip is deliberately not reused: VoiceOver should
/// announce state, not fabricate a button.
@MainActor
final class FileViewerBadgeView: UIKitTallyBorderedView {
    private let label = UILabel()

    init(_ text: String) {
        super.init(frame: .zero)
        backgroundColor = GlassPrototype.strataChassis
        isAccessibilityElement = true
        label.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: UIKitChassis.monoFont(9, weight: .semibold),
                .kern: 1.1,
                .foregroundColor: UIKitChassis.signal2,
            ]
        )
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

// MARK: - Syntax + diff palette (screen content, not chrome)

/// The content screens' color vocabulary. Deliberately not `Theme` tokens:
/// these color *what the file says*, the way a terminal theme colors a
/// pane — appearance-dynamic so Frost gets legible ink, but never spent on
/// chrome.
enum CodePalette {
    static let keyword = UIColor(light: 0x2E6E8E, dark: 0x7FB4C9)
    static let type = UIColor(light: 0x966618, dark: 0xE0A33E)
    static let string = UIColor(light: 0x3E7C58, dark: 0x7FBF9A)
    static let comment = UIColor(light: 0x87919E, dark: 0x5C6166)
    static let number = UIColor(light: 0x8A6D3B, dark: 0xC9A26D)
    static let function = UIColor(light: 0x191E25, dark: 0xF2F3F4)
    static let property = UIColor(light: 0x44618F, dark: 0x8FA8D0)
    static let meta = UIColor(light: 0x7A4E75, dark: 0xC08CB8)
    static let plain = UIColor(light: 0x3A434E, dark: 0xC8D2D6)
    static let gutter = UIColor(light: 0x87919E, dark: 0x5C6166)

    static let diffAddText = UIColor(light: 0x3E7C58, dark: 0x7FBF9A)
    static let diffDeleteText = UIColor(light: 0xC13439, dark: 0xE5484D)
    static let diffAddGround = diffAddText.withAlphaComponent(0.10)
    static let diffDeleteGround = diffDeleteText.withAlphaComponent(0.09)
    static let hunkHeader = keyword.withAlphaComponent(0.8)
    static let link = keyword

    static func color(for kind: CodeTokenKind) -> UIColor {
        switch kind {
        case .plain: plain
        case .keyword: keyword
        case .type: type
        case .string: string
        case .comment: comment
        case .number: number
        case .function: function
        case .property: property
        case .meta: meta
        }
    }

}

// MARK: - Native content states

private extension UIFont {
    /// Only a semantic text style scales with Dynamic Type; the chassis's
    /// fixed sizes already carry `Theme.typeScale` and must never compound
    /// with it. The panels below take their body font from the caller, so
    /// they opt in by what they were handed.
    var followsDynamicType: Bool {
        fontDescriptor.object(forKey: .textStyle) != nil
    }
}

@MainActor
final class FileViewerMessageView: UIView {
    private(set) var captionLabel: UIKitChassisLabel
    private(set) var detailLabel = UILabel()

    init(
        caption: String,
        detail: String,
        captionColor: UIColor,
        detailFont: UIFont,
        maximumWidth: CGFloat = 380,
        topInset: CGFloat? = nil
    ) {
        captionLabel = UIKitChassisLabel(
            caption,
            size: caption == "LOADING" ? 9 : 10,
            color: captionColor
        )
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.screen
        detailLabel.text = detail
        detailLabel.font = detailFont
        detailLabel.adjustsFontForContentSizeCategory = detailFont.followsDynamicType
        detailLabel.textColor = caption == "LOADING"
            ? UIKitChassis.signal2 : UIKitChassis.signal3
        detailLabel.numberOfLines = caption == "LOADING" ? 2 : 0
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [captionLabel, detailLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = caption == "NO FILE ON SCREEN" ? 12 : 10
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let vertical: NSLayoutConstraint = if let topInset {
            stack.topAnchor.constraint(equalTo: topAnchor, constant: topInset)
        } else {
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        }
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: maximumWidth),
            vertical,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

@MainActor
final class FileViewerPanelView: UIKitTallyBorderedView {
    typealias Detail = (text: String, font: UIFont, color: UIColor)

    init(
        caption: String,
        details: [Detail],
        action: (caption: String, handler: () -> Void)? = nil
    ) {
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.bezel
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.addArrangedSubview(UIKitTallyLamp(caption: caption, color: TallyPalette.caution))
        for detail in details {
            let label = UILabel()
            label.text = detail.text
            label.font = detail.font
            label.adjustsFontForContentSizeCategory = detail.font.followsDynamicType
            label.textColor = detail.color
            label.numberOfLines = 0
            label.textAlignment = .center
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
            stack.addArrangedSubview(label)
        }
        if let action {
            let chip = UIKitChassisChip(
                action.caption,
                prominent: true,
                accessibilityLabel: action.caption.capitalized,
                action: action.handler
            )
            stack.addArrangedSubview(chip)
        }
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 30),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -30),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

@MainActor
final class FileViewerPanelHostView: UIView {
    init(panel: UIView, outerInset: CGFloat = 0) {
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.screen
        addSubview(panel)
        panel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: outerInset),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -outerInset),
            panel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: outerInset),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -outerInset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

// MARK: - Native selectable code and diff screens

@MainActor
private func makeFileViewerTextView() -> FileViewerTextView {
    let view = FileViewerTextView()
    view.isEditable = false
    view.isSelectable = true
    view.backgroundColor = .clear
    view.alwaysBounceVertical = true
    view.dataDetectorTypes = []
    view.textContainer.lineFragmentPadding = 0
    view.installDecor()
    return view
}

@MainActor
final class FileViewerCodeContentView: UIView {
    private let stack = UIStackView()
    private(set) var truncatedBanner: UIView
    private(set) var textView = makeFileViewerTextView()
    private var buildTask: Task<Void, Never>?
    private var generation = 0

    override init(frame: CGRect) {
        let caption = UIKitChassisLabel("TRUNCATED", size: 8, color: TallyPalette.caution)
        let detail = UILabel()
        detail.text = "Showing the first \(FileViewerController.formatBytes(UInt64(FileViewerController.textByteLimit)))."
        detail.font = UIFont.preferredFont(forTextStyle: .footnote)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = UIKitChassis.signal3
        let row = UIStackView(arrangedSubviews: [caption, detail, UIView()])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        let banner = UIView()
        banner.backgroundColor = TallyPalette.caution.withAlphaComponent(0.08)
        banner.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: banner.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -6),
        ])
        truncatedBanner = banner
        super.init(frame: frame)
        backgroundColor = UIKitChassis.screen
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        stack.addArrangedSubview(truncatedBanner)
        stack.addArrangedSubview(textView)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    deinit { buildTask?.cancel() }

    func apply(
        lines: [HighlightedLine],
        truncated: Bool = false,
        targetLine: Int? = nil
    ) {
        truncatedBanner.isHidden = !truncated
        generation &+= 1
        let expected = generation
        let preservingOffset = textView.content != nil
        buildTask?.cancel()
        buildTask = Task { [weak self] in
            let built = await Task.detached {
                FileViewerTextContent.code(lines, targetLine: targetLine)
            }.value
            guard !Task.isCancelled, let self, self.generation == expected else { return }
            self.textView.setContent(
                built,
                targetLine: preservingOffset ? nil : targetLine,
                preservingOffset: preservingOffset
            )
        }
    }
}

/// SELECT mode for rendered markdown: one raw-source text surface, so a copy
/// can cross the block boundaries that make the rich render readable.
@MainActor
final class FileViewerMarkdownSourceContentView: UIView {
    private(set) var textView = makeFileViewerTextView()
    private var buildTask: Task<Void, Never>?
    private var generation = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIKitChassis.screen
        addSubview(textView)
        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    deinit { buildTask?.cancel() }

    func apply(text: String) {
        generation &+= 1
        let expected = generation
        let preservingOffset = textView.content != nil
        buildTask?.cancel()
        buildTask = Task { [weak self] in
            let built = await Task.detached {
                let lines = CodeHighlighter.highlight(text, language: nil)
                return FileViewerTextContent.code(lines, targetLine: nil)
            }.value
            guard !Task.isCancelled, let self, self.generation == expected else { return }
            self.textView.setContent(
                built,
                targetLine: nil,
                preservingOffset: preservingOffset
            )
        }
    }
}

@MainActor
final class FileViewerDiffContentView: UIView {
    private(set) var textView = makeFileViewerTextView()
    private(set) var cleanView = FileViewerMessageView(
        caption: "NOTHING TO DIFF",
        detail: "The working tree matches HEAD here.",
        captionColor: UIKitChassis.signal3,
        detailFont: UIFont.preferredFont(forTextStyle: .footnote),
        topInset: 60
    )
    private var visibleView: UIView?
    private var buildTask: Task<Void, Never>?
    private var generation = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIKitChassis.screen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    deinit { buildTask?.cancel() }

    func apply(diff: GitDiff, scope: FileViewerController.DiffScope) {
        generation &+= 1
        let expected = generation
        buildTask?.cancel()
        guard !diff.files.isEmpty else {
            show(cleanView)
            return
        }
        show(textView)
        let preservingOffset = textView.content != nil
        let repoScope: Bool
        if case .repo = scope { repoScope = true } else { repoScope = false }
        buildTask = Task { [weak self] in
            let built = await Task.detached {
                FileViewerTextContent.diff(diff, repoScope: repoScope)
            }.value
            guard !Task.isCancelled, let self, self.generation == expected else { return }
            self.textView.setContent(
                built,
                targetLine: nil,
                preservingOffset: preservingOffset
            )
        }
    }

    private func show(_ child: UIView) {
        guard visibleView !== child else { return }
        visibleView?.removeFromSuperview()
        visibleView = child
        addSubview(child)
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor),
            child.trailingAnchor.constraint(equalTo: trailingAnchor),
            child.topAnchor.constraint(equalTo: topAnchor),
            child.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

// MARK: - Native image screen

@MainActor
final class FileViewerImageContentView: UIView, UIScrollViewDelegate {
    static let zoomRange: ClosedRange<CGFloat> = 0.25...8

    private(set) var scrollView = UIScrollView()
    private(set) var imageView = UIImageView()
    private(set) var zoomChip: UIKitChassisChip!
    private var image: UIImage?
    private var lastViewportSize = CGSize.zero
    private var needsRefit = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIKitChassis.screen
        scrollView.backgroundColor = UIKitChassis.screen
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.minimumZoomScale = Self.zoomRange.lowerBound
        scrollView.maximumZoomScale = Self.zoomRange.upperBound
        scrollView.delegate = self
        scrollView.bouncesZoom = true
        addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Image, pinch to zoom"
        scrollView.addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        zoomChip = UIKitChassisChip(
            "100% · FIT",
            accessibilityLabel: "Zoom 100 percent; resets to fit",
            action: { [weak self] in self?.resetZoom(animated: true) }
        )
        zoomChip.isHidden = true
        addSubview(zoomChip)
        zoomChip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            zoomChip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            zoomChip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func apply(image: UIImage) {
        let replacing = self.image !== image
        self.image = image
        imageView.image = image
        if replacing { needsRefit = true }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let viewport = scrollView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        if needsRefit || viewport != lastViewportSize {
            let oldZoom = scrollView.zoomScale
            scrollView.setZoomScale(1, animated: false)
            imageView.transform = .identity
            imageView.frame = CGRect(origin: .zero, size: fittedSize(in: viewport))
            scrollView.contentSize = imageView.bounds.size
            lastViewportSize = viewport
            needsRefit = false
            scrollView.setZoomScale(oldZoom.clamped(to: Self.zoomRange), animated: false)
            centerImage()
            updateZoomChip()
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        updateZoomChip()
    }

    @objc private func doubleTapped() {
        scrollView.setZoomScale(abs(scrollView.zoomScale - 1) < 0.01 ? 2 : 1, animated: true)
    }

    private func resetZoom(animated: Bool) {
        scrollView.setZoomScale(1, animated: animated)
    }

    private func centerImage() {
        let horizontal = max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2)
        let vertical = max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        scrollView.contentInset = UIEdgeInsets(
            top: vertical, left: horizontal, bottom: vertical, right: horizontal
        )
    }

    private func updateZoomChip() {
        let percent = Int((scrollView.zoomScale * 100).rounded())
        zoomChip.setContent(caption: "\(percent)% · FIT", systemImage: nil)
        zoomChip.accessibilityLabel = "Zoom \(percent) percent; resets to fit"
        zoomChip.isHidden = abs(scrollView.zoomScale - 1) < 0.01
    }

    private func fittedSize(in container: CGSize) -> CGSize {
        let available = CGSize(
            width: max(40, container.width - 24),
            height: max(40, container.height - 24)
        )
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return available
        }
        let ratio = min(
            available.width / image.size.width,
            available.height / image.size.height,
            1
        )
        return CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Native rendered markdown

struct FileViewerMarkdownAttributedText {
    var text: NSAttributedString
    var destinations: [URL: String]
}

@MainActor
private enum FileViewerMarkdownInlineRenderer {
    static func render(
        _ inlines: [MarkdownInline],
        baseFont: UIFont,
        lineSpacing: CGFloat = 0
    ) -> FileViewerMarkdownAttributedText {
        let result = NSMutableAttributedString(string: "")
        var destinations: [URL: String] = [:]
        var linkOrdinal = 0
        for inline in inlines {
            switch inline {
            case .text(let value, let emphasis):
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: emphasizedFont(baseFont, emphasis),
                    .foregroundColor: CodePalette.plain,
                ]
                if emphasis.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                result.append(NSAttributedString(string: value, attributes: attributes))
            case .code(let value):
                result.append(NSAttributedString(
                    string: value,
                    attributes: [
                        .font: UIKitChassis.monoFont(11),
                        .foregroundColor: CodePalette.string,
                        .backgroundColor: UIKitChassis.bezel,
                    ]
                ))
            case .link(let text, let destination):
                let url = URL(string: "multiplex-markdown://link/\(linkOrdinal)")!
                linkOrdinal += 1
                destinations[url] = destination
                result.append(NSAttributedString(
                    string: text,
                    attributes: [
                        .font: baseFont,
                        .foregroundColor: CodePalette.link,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .link: url,
                    ]
                ))
            case .image(let alt):
                result.append(NSAttributedString(
                    string: "⟨image\(alt.isEmpty ? "" : ": \(alt)")⟩",
                    attributes: [
                        .font: UIKitChassis.monoFont(10),
                        .foregroundColor: UIKitChassis.signal3,
                    ]
                ))
            }
        }
        if result.length == 0 {
            result.append(NSAttributedString(
                string: " ",
                attributes: [.font: baseFont, .foregroundColor: CodePalette.plain]
            ))
        }
        if lineSpacing > 0 {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = lineSpacing
            result.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: NSRange(location: 0, length: result.length)
            )
        }
        return FileViewerMarkdownAttributedText(text: result, destinations: destinations)
    }

    private static func emphasizedFont(
        _ base: UIFont,
        _ emphasis: MarkdownEmphasis
    ) -> UIFont {
        var traits = base.fontDescriptor.symbolicTraits
        if emphasis.contains(.bold) { traits.insert(.traitBold) }
        if emphasis.contains(.italic) { traits.insert(.traitItalic) }
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: 0)
    }
}

@MainActor
final class FileViewerMarkdownTextView: UITextView, UITextViewDelegate {
    private var destinations: [URL: String] = [:]
    var openLink: (String) -> Void = { _ in }
    private var lastMeasuredWidth: CGFloat = -1
    private let attributed: FileViewerMarkdownAttributedText

    init(
        attributed: FileViewerMarkdownAttributedText,
        openLink: @escaping (String) -> Void
    ) {
        self.attributed = attributed
        super.init(frame: .zero, textContainer: nil)
        backgroundColor = .clear
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        dataDetectorTypes = []
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        linkTextAttributes = [:]
        self.openLink = openLink
        destinations = attributed.destinations
        attributedText = attributed.text
        delegate = self
        accessibilityLabel = attributed.text.string
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        registerForTraitChanges(
            [UITraitUserInterfaceStyle.self]
        ) { (view: FileViewerMarkdownTextView, _: UITraitCollection) in
            // TextKit resolves an attributed string's dynamic inks when the
            // text is set, so an appearance flip only reaches a rendered
            // block by re-feeding it. Blocks the reader has not scrolled to
            // are not built yet and resolve against the new appearance when
            // they mount.
            view.attributedText = view.attributed.text
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : 320
        let height = ceil(sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height)
        return CGSize(width: UIView.noIntrinsicMetric, height: max(1, height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastMeasuredWidth) > 0.5 {
            lastMeasuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    func textView(
        _ textView: UITextView,
        shouldInteractWith URL: URL,
        in characterRange: NSRange,
        interaction: UITextItemInteraction
    ) -> Bool {
        // Only an actual activation opens the link. UIKit also asks with
        // `.presentActions` and `.preview` while a long press is building its
        // menu, and answering those would raise the confirmation sheet from a
        // gesture that used to offer text selection instead. `false` keeps the
        // system's own link menu (which would bypass the sheet) out of the way.
        guard interaction == .invokeDefaultAction else { return false }
        openLink(destinations[URL] ?? URL.absoluteString)
        return false
    }
}

@MainActor
final class FileViewerMarkdownContentView: UIView, UIScrollViewDelegate {
    /// Blocks mount progressively — enough to fill the viewport plus
    /// `mountAhead`, then more as the reader scrolls — because each one is a
    /// full TextKit surface and a document may hold thousands of them
    /// (`FileViewerController.textByteLimit` is 1.5 MB). This is the UIKit
    /// spelling of the `LazyVStack` this screen replaced, and the smallest
    /// design that bounds the work: appending in order keeps the geometry
    /// above the reader exact, so no block ever needs an estimated height,
    /// and mounted blocks are kept (never recycled) so scrolling back is
    /// instant and a live text selection survives.
    private static let mountAhead: CGFloat = 600
    private static let mountBatch = 8
    private static let maximumMountPasses = 24

    var openLink: (String) -> Void = { _ in }
    private(set) var scrollView = UIScrollView()
    private(set) var blockStack = UIStackView()
    private var blocks: [MarkdownBlock] = []
    private var mountedCount = 0
    private var mounting = false
    private var pendingRestoreOffset: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIKitChassis.screen
        scrollView.backgroundColor = UIKitChassis.screen
        scrollView.alwaysBounceVertical = true
        scrollView.delegate = self
        addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        blockStack.axis = .vertical
        blockStack.alignment = .fill
        blockStack.spacing = 12
        scrollView.addSubview(blockStack)
        blockStack.translatesAutoresizingMaskIntoConstraints = false
        let pageWidth = blockStack.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -44
        )
        pageWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            blockStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 18),
            blockStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -18),
            blockStack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            blockStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: 22
            ),
            blockStack.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -22
            ),
            blockStack.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            pageWidth,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func apply(blocks: [MarkdownBlock]) {
        guard self.blocks != blocks else { return }
        self.blocks = blocks
        let oldOffset = scrollView.contentOffset
        for child in blockStack.arrangedSubviews {
            blockStack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        mountedCount = 0
        // The QUIET watch swap keeps the reader where they were, so the fill
        // has to reach the restored offset before it can be applied.
        pendingRestoreOffset = oldOffset.y
        mountBlocksIfNeeded()
        pendingRestoreOffset = nil
        let maximum = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        scrollView.contentOffset = CGPoint(x: 0, y: min(oldOffset.y, maximum))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A width or height change moves the fill line — the pane sizes this
        // view only after `apply(blocks:)` has already run.
        mountBlocksIfNeeded()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        mountBlocksIfNeeded()
    }

    private func mountBlocksIfNeeded() {
        guard !mounting, mountedCount < blocks.count else { return }
        mounting = true
        defer { mounting = false }
        // contentSize can be stale here: a width change reflows the mounted
        // text to a shorter height only during the scroll view's NEXT layout
        // pass, and reading the old (taller) height makes the reach check
        // decide the viewport is already filled — leaving a half-rendered
        // page until a scroll re-enters this method.
        scrollView.layoutIfNeeded()
        var passes = 0
        while mountedCount < blocks.count, passes < Self.maximumMountPasses {
            passes += 1
            let reach = max(scrollView.contentOffset.y, pendingRestoreOffset ?? 0)
                + max(scrollView.bounds.height, 1)
                + Self.mountAhead
            guard scrollView.contentSize.height < reach else { break }
            let end = min(mountedCount + Self.mountBatch, blocks.count)
            while mountedCount < end {
                blockStack.addArrangedSubview(makeBlock(blocks[mountedCount]))
                mountedCount += 1
            }
            // Resolve the new content height before deciding on another batch.
            scrollView.setNeedsLayout()
            scrollView.layoutIfNeeded()
        }
    }

    private func makeBlock(_ block: MarkdownBlock) -> UIView {
        switch block {
        case .heading(let level, let inlines):
            let rendered = FileViewerMarkdownInlineRenderer.render(
                inlines,
                baseFont: Self.headingFont(level)
            )
            return inset(
                FileViewerMarkdownTextView(attributed: rendered, openLink: openLink),
                top: level <= 2 ? 8 : 4
            )
        case .paragraph(let inlines):
            return FileViewerMarkdownTextView(
                attributed: FileViewerMarkdownInlineRenderer.render(
                    inlines,
                    baseFont: UIKitChassis.uiFont(13),
                    lineSpacing: 3
                ),
                openLink: openLink
            )
        case .code(let language, _, let lines):
            return FileViewerMarkdownCodeFenceView(language: language, lines: lines)
        case .quote(let inner):
            let bar = UIView()
            bar.backgroundColor = UIKitChassis.bezelHi
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
            let innerStack = UIStackView()
            innerStack.axis = .vertical
            innerStack.alignment = .fill
            innerStack.spacing = 10
            inner.forEach { innerStack.addArrangedSubview(makeBlock($0)) }
            let row = UIStackView(arrangedSubviews: [bar, innerStack])
            row.axis = .horizontal
            row.alignment = .fill
            row.spacing = 12
            return inset(row, left: 2)
        case .listItem(let marker, let level, let inlines):
            let markerLabel = UILabel()
            markerLabel.text = marker
            markerLabel.font = UIKitChassis.monoFont(11)
            markerLabel.textColor = UIKitChassis.signal3
            markerLabel.setContentHuggingPriority(.required, for: .horizontal)
            let text = FileViewerMarkdownTextView(
                attributed: FileViewerMarkdownInlineRenderer.render(
                    inlines,
                    baseFont: UIKitChassis.uiFont(13),
                    lineSpacing: 3
                ),
                openLink: openLink
            )
            let row = UIStackView(arrangedSubviews: [markerLabel, text])
            row.axis = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 9
            return inset(row, left: CGFloat(level) * 18)
        case .table(let header, let rows):
            return FileViewerMarkdownTableView(
                header: header,
                rows: rows,
                openLink: openLink
            )
        case .rule:
            let container = UIView()
            let line = UIView()
            line.backgroundColor = UIKitChassis.bezelHi
            container.addSubview(line)
            line.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                container.heightAnchor.constraint(equalToConstant: 9),
                line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                line.heightAnchor.constraint(equalToConstant: 1),
            ])
            return container
        }
    }

    private static func headingFont(_ level: Int) -> UIFont {
        switch level {
        case 1: UIKitChassis.uiFont(22, weight: .bold)
        case 2: UIKitChassis.uiFont(17, weight: .bold)
        case 3: UIKitChassis.uiFont(14, weight: .semibold)
        default: UIKitChassis.uiFont(13, weight: .semibold)
        }
    }

    private func inset(
        _ content: UIView,
        top: CGFloat = 0,
        left: CGFloat = 0
    ) -> UIView {
        guard top != 0 || left != 0 else { return content }
        let container = UIView()
        container.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: left),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: top),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }
}

@MainActor
final class FileViewerMarkdownCodeFenceView: UIKitTallyBorderedView {
    private let fixedHeight: CGFloat
    private let fenceText: NSAttributedString
    private let textView = UITextView()

    init(language: CodeLanguage?, lines: [String]) {
        let highlighted = CodeHighlighter.highlight(
            lines.joined(separator: "\n"),
            language: language
        )
        let font = UIKitChassis.monoFont(10.5)
        let italic: UIFont = {
            guard let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic)
            else { return font }
            return UIFont(descriptor: descriptor, size: 0)
        }()
        let text = NSMutableAttributedString(string: "")
        var widest: CGFloat = 0
        let visualLines = highlighted.isEmpty
            ? [HighlightedLine(segments: [.init(text: " ", kind: .plain)])]
            : highlighted
        for (index, line) in visualLines.enumerated() {
            let row = NSMutableAttributedString(string: "")
            for segment in line.segments {
                row.append(NSAttributedString(
                    string: segment.text.isEmpty ? " " : segment.text,
                    attributes: [
                        .font: segment.kind == .comment ? italic : font,
                        .foregroundColor: CodePalette.color(for: segment.kind),
                    ]
                ))
            }
            widest = max(widest, ceil(row.size().width))
            text.append(row)
            if index < visualLines.count - 1 { text.append(NSAttributedString(string: "\n")) }
        }
        fixedHeight = ceil(font.lineHeight * CGFloat(visualLines.count)) + 20
        fenceText = text
        super.init(frame: .zero)
        backgroundColor = GlassPrototype.strataChassis
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        clipsToBounds = true
        registerForTraitChanges(
            [UITraitUserInterfaceStyle.self]
        ) { (view: FileViewerMarkdownCodeFenceView, _: UITraitCollection) in
            // Same rule as the prose blocks: TextKit caches the resolved
            // token colors, so the fence has to be re-fed on a flip.
            view.textView.attributedText = view.fenceText
        }

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.attributedText = text
        scroll.addSubview(textView)
        addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        let contentWidth = max(80, widest + 20)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 10),
            textView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -10),
            textView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 10),
            textView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -10),
            textView.widthAnchor.constraint(equalToConstant: max(60, contentWidth - 20)),
            textView.heightAnchor.constraint(equalToConstant: fixedHeight - 20),
            scroll.contentLayoutGuide.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        heightAnchor.constraint(equalToConstant: fixedHeight).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}

@MainActor
final class FileViewerMarkdownTableView: UIKitTallyBorderedView {
    init(
        header: [[MarkdownInline]],
        rows: [[[MarkdownInline]]],
        openLink: @escaping (String) -> Void
    ) {
        super.init(frame: .zero)
        backgroundColor = .clear
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else {
            heightAnchor.constraint(equalToConstant: 1).isActive = true
            return
        }

        let headerFont = UIKitChassis.uiFont(12, weight: .semibold)
        let bodyFont = UIKitChassis.uiFont(12)
        let allRows = [header] + rows
        let rendered: [[FileViewerMarkdownAttributedText]] = allRows.enumerated().map { rowIndex, cells in
            (0..<columns).map { column in
                FileViewerMarkdownInlineRenderer.render(
                    column < cells.count ? cells[column] : [],
                    baseFont: rowIndex == 0 ? headerFont : bodyFont
                )
            }
        }
        let widths: [CGFloat] = (0..<columns).map { column in
            let widest = rendered.map { row in
                ceil(row[column].text.boundingRect(
                    with: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                ).width) + 20
            }.max() ?? 60
            return widest.clamped(to: 60...320)
        }
        var rowHeights: [CGFloat] = []
        for row in rendered {
            let height = row.enumerated().map { column, cell in
                ceil(cell.text.boundingRect(
                    with: CGSize(
                        width: widths[column] - 20,
                        height: CGFloat.greatestFiniteMagnitude
                    ),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                ).height) + 12
            }.max() ?? 32
            rowHeights.append(max(32, height))
        }

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let rowStack = UIStackView()
        rowStack.axis = .vertical
        rowStack.alignment = .fill
        rowStack.spacing = 0
        for rowIndex in rendered.indices {
            let rowView = UIStackView()
            rowView.axis = .horizontal
            rowView.alignment = .fill
            rowView.spacing = 0
            rowView.backgroundColor = rowIndex == 0
                ? UIKitChassis.bezel
                : (rowIndex.isMultiple(of: 2)
                    ? .clear : UIKitChassis.bezel.withAlphaComponent(0.4))
            for column in 0..<columns {
                let text = FileViewerMarkdownTextView(
                    attributed: rendered[rowIndex][column],
                    openLink: openLink
                )
                let cell = UIView()
                cell.addSubview(text)
                text.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    cell.widthAnchor.constraint(equalToConstant: widths[column]),
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                    text.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
                    text.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -6),
                ])
                rowView.addArrangedSubview(cell)
            }
            rowView.heightAnchor.constraint(equalToConstant: rowHeights[rowIndex]).isActive = true
            rowStack.addArrangedSubview(rowView)
        }
        scroll.addSubview(rowStack)
        addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        let totalHeight = rowHeights.reduce(0, +)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowStack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            rowStack.widthAnchor.constraint(equalToConstant: widths.reduce(0, +)),
            rowStack.heightAnchor.constraint(equalToConstant: totalHeight),
            scroll.contentLayoutGuide.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            heightAnchor.constraint(equalToConstant: totalHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}
