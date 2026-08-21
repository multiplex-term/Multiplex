import Observation
import PDFKit
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
    /// The reader's text size. Read inside the pane's observation, so a pinch
    /// in one ▤ tab resizes every open one.
    var textScale: CGFloat
    /// The pictures the reader pressed open inside the rendered document.
    var inlineImages: [String: FileViewerController.InlineImage]

    @MainActor
    init(controller: FileViewerController, textScales: FileViewerTextScaleStore) {
        textScale = textScales.scale
        body = FileViewerPaneBodyState(controller.content)
        inlineImages = controller.inlineImages
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

/// Value snapshot consumed by the visionOS Stacked Deck. Actions remain
/// pane-owned because tree presentation and markdown selection are local UI
/// state, while file loading/navigation stays in `FileViewerController`.
struct FileViewerOrnamentConfiguration {
    struct RenderKey: Equatable {
        var canGoBack: Bool
        var canGoForward: Bool
        var showsSourceDiff: Bool
        var sourceSelected: Bool
        var markdownSelectionCaption: String?
        var path: String
        var hostName: String
        var treeCaption: String
        var isBusy: Bool
        var isWorking: Bool
    }

    var key: RenderKey
    var goBack: () -> Void
    var goForward: () -> Void
    var showSource: () -> Void
    var showDiff: () -> Void
    var toggleMarkdownSelection: () -> Void
    var toggleTree: () -> Void
    var refresh: () -> Void
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
    let textScaleStore: FileViewerTextScaleStore
    private var contentSafeArea: UIEdgeInsets
    private var isActive: Bool
    private var openInNewTabAction: (FileTree.Row) -> Void
    private var openViewportAction: (ViewportOffer) -> Void
    private var closeAction: () -> Void
    private let startsController: Bool
    private let showsInWindowRail: Bool
    private var ornamentRailDidChange: () -> Void

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
    private var renderedTextScale = FileViewerTextScale.default
    private var renderedInlineImages: [String: FileViewerController.InlineImage] = [:]
    private var markdownSelectKey: String?
    private var observationGeneration = 0
    private var startTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?

    #if DEBUG
    private var debugObservers: [NSObjectProtocol] = []
    #endif

    init(
        controller: FileViewerController,
        contentSafeArea: UIEdgeInsets = .zero,
        isActive: Bool = true,
        startsController: Bool = true,
        showsInWindowRail: Bool = true,
        textScaleStore: FileViewerTextScaleStore = .shared,
        ornamentRailDidChange: @escaping () -> Void = {},
        openInNewTab: @escaping (FileTree.Row) -> Void = { _ in },
        openViewport: @escaping (ViewportOffer) -> Void = { _ in },
        close: @escaping () -> Void
    ) {
        self.controller = controller
        self.textScaleStore = textScaleStore
        self.contentSafeArea = contentSafeArea
        self.isActive = isActive
        self.startsController = startsController
        self.showsInWindowRail = showsInWindowRail
        self.ornamentRailDidChange = ornamentRailDidChange
        openInNewTabAction = openInNewTab
        openViewportAction = openViewport
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
        for observer in debugObservers { NotificationCenter.default.removeObserver(observer) }
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
        let center = NotificationCenter.default
        debugObservers = [
            center.addObserver(
                forName: .multiplexDebugFileViewerSelect, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.toggleMarkdownSelection() }
            },
            center.addObserver(
                forName: .multiplexDebugFileViewerImage, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.pressFirstMarkdownImage() }
            },
            center.addObserver(
                forName: .multiplexDebugFileViewerPlay, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, isActive,
                          let audio = currentBodyView as? FileViewerAudioContentView
                    else { return }
                    _ = audio.playChip.accessibilityActivate()
                }
            },
        ]
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
        openViewport: @escaping (ViewportOffer) -> Void,
        close: @escaping () -> Void,
        ornamentRailDidChange: @escaping () -> Void = {}
    ) {
        openInNewTabAction = openInNewTab
        openViewportAction = openViewport
        closeAction = close
        self.ornamentRailDidChange = ornamentRailDidChange
        if self.contentSafeArea != contentSafeArea {
            self.contentSafeArea = contentSafeArea
            if isViewLoaded { updateRailInsets() }
        }
        setActive(isActive)
    }

    /// Side-panel tab switches hide the mount without destroying it. Keep the
    /// first load alive, but stop the five-second active-reader watch until
    /// its host tab is visible again.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
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
        if showsInWindowRail {
            rootStack.addArrangedSubview(railView)
        }
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
            FileViewerPaneObservedState(controller: controller, textScales: textScaleStore)
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
        // A pure size change leaves the body state untouched, so `updateBody`
        // keeps the live view (scroll position and selection with it) and the
        // screen rebuilds itself at the new size in place.
        if renderedTextScale != state.textScale {
            renderedTextScale = state.textScale
            applyTextScale(state.textScale, to: currentBodyView)
        }
        // A picture arriving (or being put away) changes one block's height —
        // never the body's identity, so the screen keeps its scroll position
        // and any live selection.
        if renderedInlineImages != state.inlineImages {
            renderedInlineImages = state.inlineImages
            (currentBodyView as? FileViewerMarkdownContentView)?
                .setImageStates(state.inlineImages)
        }
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
            headerCountsLabel.accessibilityLabel = String(
                localized: "\(diff.additions) additions, \(diff.deletions) deletions"
            )
            headerCountsLabel.isHidden = false
        } else {
            headerCountsLabel.isHidden = true
        }
    }

    private func headerName(_ state: FileViewerPaneObservedState) -> String {
        switch state.body {
        case .document(let document): document.name
        case .diff(_, .repo): String(localized: "Working tree vs HEAD")
        case .diff(_, .file(let path)): FileTree.name(of: path)
        case .loading(let label): label
        case .failure: "—"
        case .idle: FileTree.name(of: state.rootPath)
        }
    }

    private func headerMeta(_ state: FileViewerPaneObservedState) -> String {
        switch state.body {
        case .document(let document):
            let kind: String = switch document.kind {
            case .code(let language): language?.rawValue ?? "TEXT"
            case .markdown where state.markdownRaw: "MARKDOWN · RAW"
            case .markdown: selectingMarkdownSource ? "MARKDOWN · SOURCE" : "MARKDOWN"
            case .image: "IMAGE"
            case .pdf:
                switch document.pdf {
                case nil: "PDF"
                case let pdf? where pdf.isLocked: "PDF · LOCKED"
                case let pdf?: "PDF · \(pdf.pageCount) PAGE\(pdf.pageCount == 1 ? "" : "S")"
                }
            case .audio:
                document.audio.map { "AUDIO · \(FileViewerAudioClock.label($0.duration))" } ?? "AUDIO"
            case .binary: "BINARY"
            }
            var parts = [kind, FileViewerController.formatBytes(document.size)]
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
            let back = makeChip("◂", accessibility: String(localized: "Back")) { [weak controller] in
                controller?.goBack()
            }
            back.accessibilityIdentifier = "fileViewer.back"
            setChipEnabled(back, state.canGoBack)
            backChip = back
            let forward = makeChip(
                "▸",
                accessibility: String(localized: "Forward")
            ) { [weak controller] in
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
                accessibility: String(localized: "Show source")
            ) { [weak controller] in controller?.showSource() }
            source.accessibilityIdentifier = "fileViewer.source"
            let diff = makeChip(
                "DIFF",
                prominent: !sourceMode,
                accessibility: String(localized: "Show diff")
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
            mode.accessibilityLabel = String(localized: "Source or diff")
            railStack.addArrangedSubview(mode)
        }

        if markdownSelectionAvailable(state) {
            let select = makeChip(
                selectingMarkdownSource ? "DONE" : "SELECT",
                prominent: selectingMarkdownSource,
                accessibility: selectingMarkdownSource
                    ? String(localized: "Back to rendered markdown")
                    : String(localized: "Select source text to copy")
            ) { [weak self] in self?.toggleMarkdownSelection() }
            select.accessibilityIdentifier = "fileViewer.markdownSelect"
            selectChip = select
            railStack.addArrangedSubview(select)
        }

        railPathLabel.attributedText = pathText(state.railPath)
        railPathLabel.accessibilityLabel = state.railPath
        railStack.addArrangedSubview(railPathLabel)

        let host = FileViewerBadgeView(state.hostName.uppercased())
        host.accessibilityLabel = String(localized: "Files on \(state.hostName)")
        host.setContentHuggingPriority(.required, for: .horizontal)
        railStack.addArrangedSubview(host)

        let treeVisible = isCompactLayout ? drawerOpen : treeDocked
        let tree = makeChip(
            treeVisible ? "HIDE" : "TREE",
            accessibility: treeVisible
                ? String(localized: "Hide the file tree")
                : String(localized: "Show the file tree")
        ) { [weak self] in self?.toggleTree() }
        tree.accessibilityIdentifier = "fileViewer.tree"
        treeChip = tree
        railStack.addArrangedSubview(tree)

        let refresh = makeChip(
            "REFRESH",
            accessibility: String(localized: "Refresh file viewer")
        ) { [weak controller] in
            controller?.refresh()
        }
        refresh.accessibilityIdentifier = "fileViewer.refresh"
        setChipEnabled(refresh, !state.isBusy)
        refreshChip = refresh
        railStack.addArrangedSubview(refresh)

        let close = makeChip(
            "CLOSE",
            prominent: true,
            accessibility: String(localized: "Close file viewer")
        ) { [weak self] in self?.closeAction() }
        close.accessibilityIdentifier = "fileViewer.close"
        closeChip = close
        railStack.addArrangedSubview(close)

        if !showsInWindowRail { ornamentRailDidChange() }
    }

    var ornamentConfiguration: FileViewerOrnamentConfiguration? {
        guard !showsInWindowRail, let state = observedState else { return nil }
        let sourceSelected: Bool
        if case .document = state.body { sourceSelected = true } else { sourceSelected = false }
        let markdownCaption = markdownSelectionAvailable(state)
            ? (selectingMarkdownSource ? "DONE" : "SELECT") : nil
        let treeVisible = isCompactLayout ? drawerOpen : treeDocked
        return FileViewerOrnamentConfiguration(
            key: .init(
                canGoBack: state.canGoBack,
                canGoForward: state.canGoForward,
                showsSourceDiff: state.documentDiffBadge != nil,
                sourceSelected: sourceSelected,
                markdownSelectionCaption: markdownCaption,
                path: state.railPath,
                hostName: state.hostName,
                treeCaption: treeVisible ? "HIDE" : "TREE",
                isBusy: state.isBusy,
                isWorking: isWorking(state)
            ),
            goBack: { [weak controller] in controller?.goBack() },
            goForward: { [weak controller] in controller?.goForward() },
            showSource: { [weak controller] in controller?.showSource() },
            showDiff: { [weak self] in
                guard let self,
                      case .document(let document) = self.observedState?.body
                else { return }
                Task { @MainActor [weak controller = self.controller] in
                    await controller?.showFileDiff(path: document.path)
                }
            },
            toggleMarkdownSelection: { [weak self] in self?.toggleMarkdownSelection() },
            toggleTree: { [weak self] in self?.toggleTree() },
            refresh: { [weak controller] in controller?.refresh() }
        )
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

    #if DEBUG
    /// The headless spelling of pressing the first image placeholder on the
    /// rendered screen: it takes the destination the renderer recorded and
    /// runs the real press path, so what it proves is what a finger proves.
    /// Firing it twice shows the picture and puts it away again.
    private func pressFirstMarkdownImage() {
        guard isActive,
              let markdown = currentBodyView as? FileViewerMarkdownContentView,
              let destination = markdown.firstMountedImageDestination()
        else { return }
        showMarkdownImage(destination)
    }
    #endif

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
        case pdf(String)
        case pdfLocked(String)
        case audio(String)
        case audioUnplayable(String)
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
            case .pdf:
                guard let pdf = document.pdf else { return .binary(document.path) }
                return pdf.isLocked ? .pdfLocked(document.path) : .pdf(document.path)
            case .audio: return document.audio == nil
                ? .audioUnplayable(document.path) : .audio(document.path)
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
            let gitHint = state.hasGitRoot
                ? String(localized: ", or open the branch's diff from its ± counts")
                : ""
            return FileViewerMessageView(
                caption: "NO FILE ON SCREEN",
                detail: String(localized: "Pick a file from the tree\(gitHint)."),
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
            view.setTextScale(state.textScale)
            view.apply(diff: diff, scope: scope)
            return view
        case .document(let document):
            return makeDocumentBody(document, scale: state.textScale)
        }
    }

    /// Fresh screens are told their size before their content, so a resized
    /// reader never sees one build at the authored size and rebuild.
    private func makeDocumentBody(
        _ document: FileViewerController.Document,
        scale: CGFloat
    ) -> UIView {
        switch document.kind {
        case .binary:
            return binaryBody(document)
        case .image:
            guard let image = document.image else { return binaryBody(document) }
            let view = FileViewerImageContentView()
            view.apply(image: image)
            return view
        case .pdf:
            guard let pdf = document.pdf else { return binaryBody(document) }
            if pdf.isLocked {
                // Still the file that was asked for: the panel says so and
                // offers the one action that changes it.
                return verdictPanel(
                    document,
                    caption: "LOCKED",
                    message: String(localized: """
                        Password-protected. Unlocking opens it on this screen only — the \
                        password is not kept.
                        """),
                    action: ("UNLOCK…", { [weak self] in self?.presentPDFUnlock(retrying: false) })
                )
            }
            let view = FileViewerPDFContentView()
            view.openLink = { [weak self] in self?.openMarkdownLink($0) }
            view.apply(document: pdf)
            return view
        case .audio:
            guard let clip = document.audio else {
                // The bytes came down and Core Audio declined them; the
                // verdict stays AUDIO — a sound file this device can't play,
                // not "binary".
                return verdictPanel(
                    document,
                    caption: "CAN'T PLAY",
                    message: String(localized: """
                        This device can't decode it — a format Core Audio doesn't read (Ogg \
                        Vorbis, for one), or not audio at all.
                        """)
                )
            }
            let view = FileViewerAudioContentView(volumeStore: .shared)
            view.apply(clip: clip, name: document.name)
            return view
        case .markdown where !document.markdown.isEmpty:
            if selectingMarkdownSource, let text = document.sourceText {
                let view = FileViewerMarkdownSourceContentView()
                view.setTextScale(scale)
                view.apply(text: text)
                return view
            }
            let view = FileViewerMarkdownContentView()
            view.setTextScale(scale)
            view.openLink = { [weak self] in self?.openMarkdownLink($0) }
            view.showImage = { [weak self] in self?.showMarkdownImage($0) }
            view.setImageStates(controller.inlineImages)
            view.apply(blocks: document.markdown)
            return view
        case .markdown, .code:
            let view = FileViewerCodeContentView()
            view.setTextScale(scale)
            view.apply(
                lines: document.codeLines,
                truncated: document.truncated,
                targetLine: document.targetLine,
                targetEndLine: document.targetEndLine
            )
            return view
        }
    }

    private func binaryBody(_ document: FileViewerController.Document) -> UIView {
        verdictPanel(
            document,
            caption: "BINARY",
            message: String(localized: "Not text — Multiplex won't render it as code.")
        )
    }

    /// The chassis verdict panels — BINARY, LOCKED, CAN'T PLAY: the file
    /// named with its size, one sentence, at most one action.
    private func verdictPanel(
        _ document: FileViewerController.Document,
        caption: String,
        message: String,
        action: (caption: String, handler: () -> Void)? = nil
    ) -> UIView {
        FileViewerPanelHostView(panel: FileViewerPanelView(
            caption: caption,
            details: [
                (
                    "\(document.name) · \(FileViewerController.formatBytes(document.size))",
                    UIKitChassis.monoFont(12),
                    UIKitChassis.signal2
                ),
                (message, UIFont.preferredFont(forTextStyle: .footnote), UIKitChassis.signal3),
            ],
            action: action
        ))
    }

    /// UNLOCK asks in an alert (the only host a system secure field gets
    /// here) whose text is cleared in every button action — the key-unlock
    /// alert's rule.
    private func presentPDFUnlock(retrying: Bool) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: String(localized: "Unlock PDF"),
            message: retrying
                ? String(localized: "That password didn't unlock it. Try again.")
                : String(localized: "Enter the document's password."),
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.placeholder = String(localized: "Password")
            field.returnKeyType = .go
        }
        alert.addAction(UIAlertAction(
            title: String(localized: "Cancel"),
            style: .cancel
        ) { [weak alert] _ in
            alert?.textFields?.first?.text = ""
        })
        alert.addAction(UIAlertAction(
            title: String(localized: "Unlock"),
            style: .default
        ) { [weak self, weak alert] _ in
            let password = alert?.textFields?.first?.text ?? ""
            alert?.textFields?.first?.text = ""
            guard let self else { return }
            if !controller.unlockPDF(password: password) {
                // The alert is dismissing itself; re-ask on the next turn.
                Task { @MainActor [weak self] in self?.presentPDFUnlock(retrying: true) }
            }
        })
        present(alert, animated: true)
    }

    private func applyTextScale(_ scale: CGFloat, to view: UIView?) {
        switch view {
        case let code as FileViewerCodeContentView: code.setTextScale(scale)
        case let markdown as FileViewerMarkdownContentView: markdown.setTextScale(scale)
        case let source as FileViewerMarkdownSourceContentView: source.setTextScale(scale)
        case let diff as FileViewerDiffContentView: diff.setTextScale(scale)
        default:
            // Image and PDF screens carry their own zoom, the sound panel and
            // the state panels are chassis chrome — none answers to the
            // reading size.
            break
        }
    }

    private func apply(_ body: FileViewerPaneBodyState, to view: UIView) {
        switch (body, view) {
        case (.document(let document), let code as FileViewerCodeContentView):
            code.apply(
                lines: document.codeLines,
                truncated: document.truncated,
                targetLine: document.targetLine,
                targetEndLine: document.targetEndLine
            )
        case (.document(let document), let markdown as FileViewerMarkdownContentView):
            markdown.openLink = { [weak self] in self?.openMarkdownLink($0) }
            markdown.showImage = { [weak self] in self?.showMarkdownImage($0) }
            markdown.setImageStates(controller.inlineImages)
            markdown.apply(blocks: document.markdown)
        case (.document(let document), let source as FileViewerMarkdownSourceContentView):
            source.apply(text: document.sourceText ?? "")
        case (.document(let document), let image as FileViewerImageContentView):
            if let uiImage = document.image { image.apply(image: uiImage) }
        case (.document(let document), let pdf as FileViewerPDFContentView):
            if let pdfDocument = document.pdf { pdf.apply(document: pdfDocument) }
        case (.document(let document), let audio as FileViewerAudioContentView):
            if let clip = document.audio { audio.apply(clip: clip, name: document.name) }
        case (.diff(let diff, let scope), let diffView as FileViewerDiffContentView):
            diffView.apply(diff: diff, scope: scope)
        default:
            // Static state panels are keyed by all visible copy, so a key
            // match needs no mutation.
            break
        }
    }

    /// A pressed image placeholder: show the picture where the document puts
    /// it, or put it away again. A web address is not a file this viewer can
    /// fetch, so it stays the link sheet's business exactly as it is in prose
    /// — and the sheet is also what a `file:`-shaped or malformed target
    /// meets. Rendering a document still fetches nothing; this press is the
    /// only thing that does.
    private func showMarkdownImage(_ destination: String) {
        if let link = TerminalLink.resolve(destination, schemelessHosts: false) {
            presentLinkConfirmation(link)
            return
        }
        guard !destination.contains(":"),
              let current = controller.lastDocument,
              let path = FileTree.resolve(
                  reference: destination,
                  from: FileTree.parent(of: current.path) ?? "/"
              )
        else { return }
        controller.toggleInlineImage(destination: destination, path: path)
    }

    /// A pressed markdown link — and the way out of a picture this screen
    /// can't draw (the inline OPEN FILE chip, and a tap on a shown picture,
    /// which is where zoom lives).
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
            guard let path = FileTree.resolve(reference: destination, from: base)
            else { return }
            Task { [weak controller] in
                await controller?.open(path: path, line: nil)
            }
        }
    }

    private func presentLinkConfirmation(_ link: TerminalLink) {
        guard presentedViewController == nil else { return }
        let sheet = linkConfirmation(for: link)
        let navigation = UINavigationController(rootViewController: sheet)
        sheet.onDismiss = { [weak navigation] in navigation?.dismiss(animated: true) }
        present(navigation, animated: true)
    }

    /// Kept as a small test seam so the File Viewer cannot silently regress
    /// to an external-only link sheet while the shared sheet still tests green.
    func linkConfirmation(for link: TerminalLink) -> TerminalLinkSheetViewController {
        TerminalLinkSheetViewController(
            link: link,
            viewportOffer: { [weak controller] in controller?.viewportOffer(for: $0) },
            onOpen: { confirmed in
                if let url = confirmed.openableURL { UIApplication.shared.open(url) }
            },
            onCopy: { UIPasteboard.general.string = $0 },
            onOpenViewport: { [weak self] in self?.openViewportAction($0) }
        )
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
        setText(text)
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

    /// Readouts that move (a PDF's page) restyle the same badge in place; an
    /// unchanged text is a no-op, so callers can set it from layout.
    func setText(_ text: String) {
        guard text != accessibilityLabel else { return }
        accessibilityLabel = text
        label.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: UIKitChassis.monoFont(9, weight: .semibold),
                .kern: 1.1,
                .foregroundColor: UIKitChassis.signal2,
            ]
        )
    }
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
class FileViewerPanelHostView: UIView {
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

// MARK: - Shared screen furniture

/// The image and PDF screens' zoom-reset chip: `133% · FIT`, hidden at fit,
/// one caption and one accessibility phrasing for both.
@MainActor
enum FileViewerZoomReadout {
    static func makeChip(action: @escaping () -> Void) -> UIKitChassisChip {
        let chip = UIKitChassisChip(
            "100% · FIT",
            accessibilityLabel: String(localized: "Zoom 100 percent; resets to fit"),
            action: action
        )
        chip.isHidden = true
        return chip
    }

    /// `ratio` is the current scale over the fit scale.
    static func show(ratio: CGFloat, on chip: UIKitChassisChip) {
        let percent = Int((ratio * 100).rounded())
        chip.setContent(caption: "\(percent)% · FIT", systemImage: nil)
        chip.accessibilityLabel = String(localized: "Zoom \(percent) percent; resets to fit")
        chip.isHidden = abs(ratio - 1) < 0.01
    }
}

/// The sound panel's sliders — scrubber and volume — in one chassis dress.
@MainActor
private func makeChassisSlider(accessibilityLabel: String) -> UISlider {
    let slider = UISlider()
    slider.minimumValue = 0
    slider.maximumValue = 1
    slider.isContinuous = true
    slider.minimumTrackTintColor = UIKitChassis.signal2
    slider.maximumTrackTintColor = UIKitChassis.bezelHi
    slider.thumbTintColor = UIKitChassis.signal
    slider.accessibilityLabel = accessibilityLabel
    return slider
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
    private var textScale = FileViewerTextScale.default
    private var lastInput: (
        lines: [HighlightedLine],
        truncated: Bool,
        targetLine: Int?,
        targetEndLine: Int?
    )?

    override init(frame: CGRect) {
        let caption = UIKitChassisLabel("TRUNCATED", size: 8, color: TallyPalette.caution)
        let detail = UILabel()
        detail.text = String(localized: """
            Showing the first \
            \(FileViewerController.formatBytes(UInt64(FileViewerController.textByteLimit))).
            """)
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

    func setTextScale(_ scale: CGFloat) {
        guard scale != textScale else { return }
        textScale = scale
        guard let lastInput else { return }
        apply(
            lines: lastInput.lines,
            truncated: lastInput.truncated,
            targetLine: lastInput.targetLine,
            targetEndLine: lastInput.targetEndLine
        )
    }

    func apply(
        lines: [HighlightedLine],
        truncated: Bool = false,
        targetLine: Int? = nil,
        targetEndLine: Int? = nil
    ) {
        lastInput = (lines, truncated, targetLine, targetEndLine)
        truncatedBanner.isHidden = !truncated
        generation &+= 1
        let expected = generation
        let preservingOffset = textView.content != nil
        let scale = textScale
        buildTask?.cancel()
        buildTask = Task { [weak self] in
            let built = await Task.detached {
                FileViewerTextContent.code(
                    lines,
                    targetLine: targetLine,
                    targetEndLine: targetEndLine,
                    scale: scale
                )
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
    private var textScale = FileViewerTextScale.default
    private var lastText: String?

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

    func setTextScale(_ scale: CGFloat) {
        guard scale != textScale else { return }
        textScale = scale
        if let lastText { apply(text: lastText) }
    }

    func apply(text: String) {
        lastText = text
        generation &+= 1
        let expected = generation
        let preservingOffset = textView.content != nil
        let scale = textScale
        buildTask?.cancel()
        buildTask = Task { [weak self] in
            let built = await Task.detached {
                let lines = CodeHighlighter.highlight(text, language: nil)
                return FileViewerTextContent.code(lines, targetLine: nil, scale: scale)
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
        detail: String(localized: "The working tree matches HEAD here."),
        captionColor: UIKitChassis.signal3,
        detailFont: UIFont.preferredFont(forTextStyle: .footnote),
        topInset: 60
    )
    private var visibleView: UIView?
    private var buildTask: Task<Void, Never>?
    private var generation = 0
    private var textScale = FileViewerTextScale.default
    private var lastInput: (diff: GitDiff, scope: FileViewerController.DiffScope)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIKitChassis.screen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    deinit { buildTask?.cancel() }

    func setTextScale(_ scale: CGFloat) {
        guard scale != textScale else { return }
        textScale = scale
        if let lastInput { apply(diff: lastInput.diff, scope: lastInput.scope) }
    }

    func apply(diff: GitDiff, scope: FileViewerController.DiffScope) {
        lastInput = (diff, scope)
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
        let scale = textScale
        buildTask = Task { [weak self] in
            let built = await Task.detached {
                FileViewerTextContent.diff(diff, repoScope: repoScope, scale: scale)
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
        imageView.accessibilityLabel = String(localized: "Image, pinch to zoom")
        scrollView.addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        zoomChip = FileViewerZoomReadout.makeChip { [weak self] in self?.resetZoom(animated: true) }
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
        FileViewerZoomReadout.show(ratio: scrollView.zoomScale, on: zoomChip)
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

// MARK: - Native PDF screen

/// PDFKit's view on the chassis screen: continuous vertical pages, pinch
/// zoom, native text selection, with a page readout and the image screen's
/// zoom-reset chip in the corner. A URL link inside the document is untrusted
/// document text exactly like a markdown link — it goes to the app's link
/// sheet through `openLink`, never straight to the system (PDFKit's default
/// when no delegate answers). A quiet watch swap keeps the reader's page.
///
/// Zoom is left to `autoScales`: while it is on, PDFKit fits the page width
/// and refits on every resize, and it sets its own absolute bounds (0.25–5×,
/// measured 2026-08-15). A pinch — or ANY write to `minScaleFactor` /
/// `maxScaleFactor` / `scaleFactor` — switches it off, after which a resize
/// leaves the page where it was; the FIT chip re-arms it rather than
/// assigning the fit scale, which is what keeps resizes fitting again.
@MainActor
final class FileViewerPDFContentView: UIView {
    private(set) var pdfView = PDFView()
    private(set) var pageBadge = FileViewerBadgeView("")
    private(set) var zoomChip: UIKitChassisChip!
    private var observers: [NSObjectProtocol] = []
    /// `PDFDocument.index(for:)` walks the pages; the page changes only when
    /// PDFKit says so, so the index is looked up once per page, not per layout.
    private var readPage: PDFPage?
    private var readIndex = 0
    private var readoutSize = CGSize.zero
    var openLink: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIKitChassis.screen
        pdfView.backgroundColor = UIKitChassis.screen
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.delegate = self
        pdfView.isAccessibilityElement = false
        addSubview(pdfView)
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        zoomChip = FileViewerZoomReadout.makeChip { [weak self] in self?.resetZoom() }
        pageBadge.isHidden = true
        let corner = UIStackView(arrangedSubviews: [pageBadge, zoomChip])
        corner.axis = .horizontal
        corner.alignment = .center
        corner.spacing = 6
        addSubview(corner)
        corner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            corner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            corner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewPageChanged, .PDFViewScaleChanged] {
            observers.append(center.addObserver(
                forName: name, object: pdfView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateReadouts() }
            })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// The document on screen. A replacement (the watch saw new bytes — a
    /// LaTeX rebuild, say) lands on the page the reader was on when that page
    /// still exists, so a document being rebuilt can be read as it grows; a
    /// zoom the reader chose survives too (autoScales is already off then).
    func apply(document: PDFDocument) {
        guard pdfView.document !== document else { return }
        let keptPage = pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) }
        pdfView.document = document
        if let keptPage, keptPage < document.pageCount, let page = document.page(at: keptPage) {
            pdfView.go(to: page)
        }
        updateReadouts()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A new width is a new fit — the zoom readout must say so even when
        // PDFKit posts no scale change for it; an unchanged size costs nothing.
        guard pdfView.bounds.size != readoutSize else { return }
        readoutSize = pdfView.bounds.size
        updateReadouts()
    }

    /// PDFKit calls this INSTEAD of opening the URL itself, which is the
    /// point: the app confirms links, it never follows them.
    func linkPressed(_ url: URL) {
        openLink?(url.absoluteString)
    }

    private func resetZoom() {
        // Re-arm rather than assign: an assigned fit is stale after the next
        // resize, an armed one follows it.
        pdfView.autoScales = true
        updateReadouts()
    }

    /// Runs from layout as well as from PDFKit's notifications; the widgets
    /// gate their own restyles, so an unchanged readout costs a comparison.
    private func updateReadouts() {
        guard let document = pdfView.document else {
            pageBadge.isHidden = true
            zoomChip.isHidden = true
            return
        }
        if let page = pdfView.currentPage, page !== readPage {
            readPage = page
            readIndex = document.index(for: page)
        }
        let count = document.pageCount
        pageBadge.setText("PAGE \(readIndex + 1) / \(count)")
        pageBadge.isHidden = count <= 1
        let fit = pdfView.scaleFactorForSizeToFit
        FileViewerZoomReadout.show(ratio: fit > 0 ? pdfView.scaleFactor / fit : 1, on: zoomChip)
    }
}

extension FileViewerPDFContentView: PDFViewDelegate {
    /// PDFKit reports the press from the main thread; the hop keeps the
    /// compiler's word for it without isolating the whole conformance.
    nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        Task { @MainActor in self.linkPressed(url) }
    }
}

// MARK: - Native audio screen

/// The transport for a sound file: a centered chassis panel with the state
/// lamp (PLAYING wears tally red — it is live state, and captioned), the
/// file's name, PLAY/PAUSE with ±15 s either side, a scrubber, the clock,
/// and a volume row. The clip belongs to the document; this view is its
/// remote and polls it a few times a second only while it plays — nothing
/// about the position is observable state, and a paused panel costs no
/// wakeups. The controller pauses a clip whose document leaves the screen;
/// a tab merely hidden behind another keeps playing — listening while typing
/// is the point of a sound file beside a session. Volume is the listener's
/// app-wide level (`FileViewerAudioVolumeStore`): the slider writes it, the
/// clip follows it on its own, and this panel mirrors it by observation.
@MainActor
final class FileViewerAudioContentView: FileViewerPanelHostView {
    private(set) var clip: FileViewerAudioClip?
    private let volumeStore: FileViewerAudioVolumeStore
    private let panel = UIKitTallyBorderedView()
    private let lampSlot = UIStackView()
    private var lampState: LampState?
    private let nameLabel = UILabel()
    private(set) var playChip: UIKitChassisChip!
    private(set) var backChip: UIKitChassisChip!
    private(set) var forwardChip: UIKitChassisChip!
    private(set) var slider: UISlider
    private(set) var elapsedLabel = UILabel()
    private(set) var remainingLabel = UILabel()
    private(set) var volumeSlider: UISlider
    private(set) var volumeLabel = UILabel()
    private var timer: Timer?

    enum LampState: Equatable {
        case ready, playing, paused
    }

    init(volumeStore: FileViewerAudioVolumeStore) {
        self.volumeStore = volumeStore
        slider = makeChassisSlider(accessibilityLabel: String(localized: "Playback position"))
        volumeSlider = makeChassisSlider(accessibilityLabel: String(localized: "Volume"))
        super.init(panel: panel, outerInset: 20)

        panel.backgroundColor = UIKitChassis.bezel
        panel.layer.cornerRadius = 12
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true

        nameLabel.font = UIKitChassis.monoFont(12)
        nameLabel.textColor = UIKitChassis.signal2
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.textAlignment = .center

        backChip = UIKitChassisChip(
            "15",
            systemImage: "gobackward",
            accessibilityLabel: String(localized: "Back 15 seconds"),
            action: { [weak self] in
                self?.clip?.skip(by: -FileViewerAudioClip.skipInterval)
                self?.refresh()
            }
        )
        playChip = UIKitChassisChip(
            "PLAY",
            systemImage: "play.fill",
            prominent: true,
            accessibilityLabel: String(localized: "Play"),
            action: { [weak self] in
                self?.clip?.togglePlayback()
                self?.refresh()
            }
        )
        forwardChip = UIKitChassisChip(
            "15",
            systemImage: "goforward",
            accessibilityLabel: String(localized: "Forward 15 seconds"),
            action: { [weak self] in
                self?.clip?.skip(by: FileViewerAudioClip.skipInterval)
                self?.refresh()
            }
        )
        let transport = UIStackView(arrangedSubviews: [backChip, playChip, forwardChip])
        transport.axis = .horizontal
        transport.alignment = .center
        transport.spacing = 8

        slider.addTarget(self, action: #selector(scrubbed), for: .valueChanged)
        for label in [elapsedLabel, remainingLabel, volumeLabel] {
            label.font = UIKitChassis.monoFont(10)
            label.textColor = UIKitChassis.signal2
        }
        remainingLabel.textAlignment = .right
        let clock = UIStackView(arrangedSubviews: [elapsedLabel, remainingLabel])
        clock.axis = .horizontal
        clock.distribution = .fillEqually

        // Volume: a glyph, the level, and its readout.
        let volumeGlyph = UIImageView(image: UIImage(
            systemName: "speaker.wave.2.fill",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 10 * Theme.typeScale, weight: .semibold
            )
        ))
        volumeGlyph.tintColor = UIKitChassis.signal3
        volumeGlyph.contentMode = .scaleAspectFit
        volumeGlyph.setContentHuggingPriority(.required, for: .horizontal)
        volumeGlyph.isAccessibilityElement = false
        volumeSlider.addTarget(self, action: #selector(volumeChanged), for: .valueChanged)
        volumeLabel.textAlignment = .right
        volumeLabel.setContentHuggingPriority(.required, for: .horizontal)
        volumeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        volumeLabel.isAccessibilityElement = false
        let volumeRow = UIStackView(arrangedSubviews: [volumeGlyph, volumeSlider, volumeLabel])
        volumeRow.axis = .horizontal
        volumeRow.alignment = .center
        volumeRow.spacing = 10

        let stack = UIStackView(
            arrangedSubviews: [lampSlot, nameLabel, transport, slider, clock, volumeRow]
        )
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.setCustomSpacing(8, after: slider)
        panel.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let preferredWidth = panel.widthAnchor.constraint(equalToConstant: 440)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            preferredWidth,
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -24),
            slider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            clock.widthAnchor.constraint(equalTo: stack.widthAnchor),
            volumeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // A fixed readout width keeps the slider from breathing as the
            // digits change count.
            volumeLabel.widthAnchor.constraint(equalToConstant: 38 * Theme.typeScale),
            nameLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        setLamp(.ready)
        mirrorVolume()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        timer?.invalidate()
    }

    /// Bind the screen to a clip. Rebinding (a quiet watch swap handed the
    /// position to a replacement clip) restyles in place; the panel keeps
    /// its identity.
    func apply(clip: FileViewerAudioClip, name: String) {
        self.clip = clip
        nameLabel.text = name
        nameLabel.accessibilityLabel = name
        remainingLabel.text = FileViewerAudioClock.label(clip.duration)
        refresh()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopTimer()
        } else {
            refresh()
        }
    }

    /// The remote's one repaint: transport caption, lamp, scrubber, clock.
    /// Every write is change-gated — this runs four times a second while the
    /// clip plays, and a restyle costs the panel a layout pass.
    func refresh() {
        guard let clip else { return }
        let playing = clip.isPlaying
        playChip.setContent(
            caption: playing ? "PAUSE" : "PLAY",
            systemImage: playing ? "pause.fill" : "play.fill"
        )
        playChip.accessibilityLabel = playing
            ? String(localized: "Pause")
            : String(localized: "Play")
        setLamp(playing ? .playing : (clip.currentTime > 0 ? .paused : .ready))
        let duration = clip.duration
        let position = duration > 0 ? Float(clip.currentTime / duration) : 0
        if !slider.isTracking, slider.value != position {
            slider.setValue(position, animated: false)
        }
        let elapsed = FileViewerAudioClock.label(clip.currentTime)
        if elapsedLabel.text != elapsed {
            elapsedLabel.text = elapsed
            slider.accessibilityValue = String(
                localized: "\(elapsed) of \(FileViewerAudioClock.label(duration))"
            )
        }
        // The clock only moves while the clip plays; a paused panel needs no
        // wakeups, and the tick that sees playback end stops itself.
        if playing, window != nil {
            startTimerIfNeeded()
        } else {
            stopTimer()
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func setLamp(_ state: LampState) {
        guard state != lampState else { return }
        lampState = state
        for old in lampSlot.arrangedSubviews { old.removeFromSuperview() }
        let lamp: UIKitTallyLamp = switch state {
        case .ready: UIKitTallyLamp(caption: "READY", color: UIKitChassis.signal3)
        case .playing: UIKitTallyLamp(caption: "PLAYING", color: TallyPalette.tally)
        case .paused: UIKitTallyLamp(caption: "PAUSED", color: UIKitChassis.signal3)
        }
        lampSlot.addArrangedSubview(lamp)
    }

    /// The store is the level's owner; this panel mirrors it — the hop past
    /// Observation's before-the-write hook is what makes the re-read current.
    private func mirrorVolume() {
        withObservationTracking {
            showVolume(volumeStore.volume)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.mirrorVolume() }
        }
    }

    private func showVolume(_ level: Float) {
        if !volumeSlider.isTracking, volumeSlider.value != level {
            volumeSlider.setValue(level, animated: false)
        }
        let readout = FileViewerAudioVolume.percentLabel(level)
        if volumeLabel.text != readout {
            volumeLabel.text = readout
            volumeSlider.accessibilityValue = readout
        }
    }

    @objc private func scrubbed() {
        guard let clip else { return }
        clip.seek(to: Double(slider.value) * clip.duration)
        refresh()
    }

    /// Whole percents: the readout shows nothing finer, and it makes the
    /// store's equality guard coalesce a drag's frames into a few writes.
    @objc private func volumeChanged() {
        volumeStore.set((volumeSlider.value * 100).rounded() / 100)
        showVolume(volumeStore.volume)
    }
}

// MARK: - Native rendered markdown

struct FileViewerMarkdownAttributedText {
    var text: NSAttributedString
    var destinations: [URL: String]
    /// The image targets this run carries, in document order — what the block
    /// mounts pictures for, and what the headless press hook aims at (no sim
    /// tap route reaches a link).
    var imageDestinations: [String] = []
    /// Which of `destinations` are images, so a press can be routed to the
    /// picture rather than to a file screen.
    var imageURLs: Set<URL> = []
}

@MainActor
private enum FileViewerMarkdownInlineRenderer {
    static func render(
        _ inlines: [MarkdownInline],
        baseFont: UIFont,
        lineSpacing: CGFloat = 0,
        scale: CGFloat = FileViewerTextScale.default,
        shownImages: Set<String> = []
    ) -> FileViewerMarkdownAttributedText {
        let result = NSMutableAttributedString(string: "")
        var destinations: [URL: String] = [:]
        var imageDestinations: [String] = []
        var imageURLs: Set<URL> = []
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
                        .font: UIKitChassis.monoFont(11 * scale),
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
            case .image(let alt, let destination):
                // The caption is the picture's switch: pressable in the
                // screen's own link language while the picture is hidden,
                // and — with the picture right below it — a plain label
                // wearing the mark that says pressing hides it again. A
                // nameless image stays the inert caption it always was.
                let shown = shownImages.contains(destination)
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: UIKitChassis.monoFont(10 * scale),
                    .foregroundColor: UIKitChassis.signal3,
                ]
                if !destination.isEmpty {
                    let url = URL(string: "multiplex-markdown://image/\(linkOrdinal)")!
                    linkOrdinal += 1
                    destinations[url] = destination
                    imageDestinations.append(destination)
                    imageURLs.insert(url)
                    attributes[.link] = url
                    if !shown {
                        attributes[.foregroundColor] = CodePalette.link
                        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    }
                }
                let described = "image\(alt.isEmpty ? "" : ": \(alt)")"
                result.append(NSAttributedString(
                    string: shown ? "⌄ \(described)" : "⟨\(described)⟩",
                    attributes: attributes
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
        return FileViewerMarkdownAttributedText(
            text: result,
            destinations: destinations,
            imageDestinations: imageDestinations,
            imageURLs: imageURLs
        )
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
    private var imageURLs: Set<URL> = []
    var openLink: (String) -> Void = { _ in }
    /// Set where a picture can be shown in place. Unset — a table cell, whose
    /// column widths a picture would wreck — an image press falls back to
    /// `openLink`, which opens the file on its own screen.
    var showImage: ((String) -> Void)?
    private var lastMeasuredWidth: CGFloat = -1
    private var attributed: FileViewerMarkdownAttributedText

    /// This block's image targets, in document order.
    var imageDestinations: [String] { attributed.imageDestinations }

    init(
        attributed: FileViewerMarkdownAttributedText,
        openLink: @escaping (String) -> Void
    ) {
        self.attributed = attributed
        imageURLs = attributed.imageURLs
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

    /// Re-renders this block at a new size WITHOUT building another TextKit
    /// surface — the whole point of restyling a mounted stack in place
    /// (measured: ~0.9 ms here against ~2.3 ms to create, add and lay out a
    /// replacement). Clearing first is the same rule `FileViewerTextView`
    /// documents: assigning over a populated document makes TextKit
    /// reconcile the two.
    func update(attributed: FileViewerMarkdownAttributedText) {
        self.attributed = attributed
        destinations = attributed.destinations
        imageURLs = attributed.imageURLs
        if attributedText.length > 0 {
            attributedText = NSAttributedString()
        }
        attributedText = attributed.text
        accessibilityLabel = attributed.text.string
        lastMeasuredWidth = -1
        measuredHeight = nil
        invalidateIntrinsicContentSize()
    }

    /// Measured height per width, because a stack view asks EVERY arranged
    /// subview for its intrinsic size on any layout pass — without the cache
    /// one restyled block re-ran CoreText over every other mounted block on
    /// the screen (the second half of the slow resize, measured 2026-08-06).
    private var measuredWidth: CGFloat = -1
    private var measuredHeight: CGFloat?

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : 320
        if let measuredHeight, abs(width - measuredWidth) <= 0.5 {
            return CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight)
        }
        let height = max(1, ceil(sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height))
        measuredWidth = width
        measuredHeight = height
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastMeasuredWidth) > 0.5 {
            lastMeasuredWidth = bounds.width
            measuredHeight = nil
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
        let destination = destinations[URL] ?? URL.absoluteString
        if imageURLs.contains(URL), let showImage {
            showImage(destination)
        } else {
            openLink(destination)
        }
        return false
    }
}

/// A prose block that can carry pictures: the text, and under it whatever
/// images the reader pressed open, in the order the block names them. The
/// pictures ride INSIDE the block's own view rather than as extra rows of the
/// document stack, because that stack is index-paired with `blocks` —
/// mounting, restyling, and the reader's scroll anchor all count on it.
@MainActor
final class FileViewerMarkdownProseBlockView: UIView {
    let text: FileViewerMarkdownTextView
    private let stack = UIStackView()
    /// Re-renders the text at (size, shown targets) — the caption's own
    /// pressed/unpressed state lives in the attributed run.
    private let updateText: (CGFloat, Set<String>) -> Void
    private let openFull: (String) -> Void
    private var scale: CGFloat
    private var shown: Set<String> = []
    private var mountedImages: [(destination: String, view: FileViewerMarkdownImageView)] = []

    init(
        content: UIView,
        text: FileViewerMarkdownTextView,
        scale: CGFloat,
        updateText: @escaping (CGFloat, Set<String>) -> Void,
        openFull: @escaping (String) -> Void
    ) {
        self.text = text
        self.scale = scale
        self.updateText = updateText
        self.openFull = openFull
        super.init(frame: .zero)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 10
        stack.addArrangedSubview(content)
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

    func setScale(_ scale: CGFloat) {
        self.scale = scale
        updateText(scale, shown)
    }

    func setImages(_ states: [String: FileViewerController.InlineImage]) {
        let wanted = text.imageDestinations.filter { states[$0] != nil }
        if Set(wanted) != shown {
            shown = Set(wanted)
            updateText(scale, shown)
        }
        guard wanted != mountedImages.map(\.destination) else {
            for mounted in mountedImages {
                guard let state = states[mounted.destination],
                      state != mounted.view.state
                else { continue }
                mounted.view.apply(state)
            }
            return
        }
        for mounted in mountedImages {
            stack.removeArrangedSubview(mounted.view)
            mounted.view.removeFromSuperview()
        }
        mountedImages = wanted.compactMap { destination in
            guard let state = states[destination] else { return nil }
            let view = FileViewerMarkdownImageView(state: state) { [weak self] in
                self?.openFull(destination)
            }
            stack.addArrangedSubview(view)
            return (destination, view)
        }
    }

    /// The pictures this block currently shows — the UIKit tests' seam.
    var shownImageViews: [FileViewerMarkdownImageView] { mountedImages.map(\.view) }
}

/// One picture, shown where the document places it. Its size is the reading
/// column's, never larger than the picture itself — an upscaled screenshot is
/// worse than a small one — and never taller than `maximumHeight`, so one
/// figure can't take a whole screen from the prose it belongs to.
@MainActor
final class FileViewerMarkdownImageView: UIKitTallyBorderedView {
    static let maximumHeight: CGFloat = 460
    private static let panelHeight: CGFloat = 84

    private let imageView = UIImageView()
    private let captionLabel = UIKitChassisLabel("", size: 8, color: UIKitChassis.signal3)
    private let openChip: UIKitChassisChip
    private var heightConstraint: NSLayoutConstraint!
    private(set) var state: FileViewerController.InlineImage
    /// Opening the file on its own screen — where zoom lives, and the way out
    /// of a picture this screen can't draw.
    private let openFull: () -> Void

    init(state: FileViewerController.InlineImage, openFull: @escaping () -> Void) {
        self.state = state
        self.openFull = openFull
        openChip = UIKitChassisChip(
            "OPEN FILE",
            accessibilityLabel: String(localized: "Open this file on its own screen"),
            action: openFull
        )
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.bezel
        clipsToBounds = true
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.panelHeight)
        heightConstraint.isActive = true

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(openFullScreen))
        )
        #if os(visionOS)
        imageView.hoverStyle = .init(effect: .highlight, shape: .rect(cornerRadius: 2))
        #endif
        addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let panel = UIStackView(arrangedSubviews: [captionLabel, openChip])
        panel.axis = .vertical
        panel.alignment = .center
        panel.spacing = 8
        addSubview(panel)
        panel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
        apply(state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func openFullScreen() { openFull() }

    func apply(_ state: FileViewerController.InlineImage) {
        self.state = state
        switch state {
        case .loading:
            imageView.image = nil
            imageView.isHidden = true
            captionLabel.setText("LOADING")
            captionLabel.isHidden = false
            openChip.isHidden = true
            isAccessibilityElement = true
            accessibilityLabel = String(localized: "Loading image")
        case .ready(let image):
            imageView.image = image
            imageView.isHidden = false
            captionLabel.isHidden = true
            openChip.isHidden = true
            isAccessibilityElement = false
            imageView.isAccessibilityElement = true
            imageView.accessibilityLabel = String(localized: "Image, opens on its own screen")
            imageView.accessibilityTraits = .button
        case .failed(let reason):
            imageView.image = nil
            imageView.isHidden = true
            captionLabel.setText(String(localized: "CAN'T SHOW — \(reason)"))
            captionLabel.isHidden = false
            openChip.isHidden = false
            isAccessibilityElement = true
            accessibilityLabel = String(localized: "Can't show this image. \(reason)")
        }
        applyHeight()
    }

    /// The height is a CONSTRAINT re-derived from the width Auto Layout
    /// actually gave this view, never a cached intrinsic size: the column's
    /// width arrives after the picture does (and changes again when the tree
    /// drawer moves), and a stale measurement is a picture floating in a
    /// band of empty chassis — which is exactly what caching it produced.
    override func layoutSubviews() {
        super.layoutSubviews()
        applyHeight()
    }

    private func applyHeight() {
        let width = bounds.width > 0 ? bounds.width : 320
        let target = Self.height(for: state, inWidth: width)
        guard abs(heightConstraint.constant - target) > 0.5 else { return }
        heightConstraint.constant = target
    }

    /// Pure: the column width, the picture's own size, and the ceiling.
    static func height(
        for state: FileViewerController.InlineImage,
        inWidth width: CGFloat
    ) -> CGFloat {
        guard case .ready(let image) = state,
              image.size.width > 0, image.size.height > 0
        else { return panelHeight }
        let drawnWidth = min(width, image.size.width)
        let height = drawnWidth * image.size.height / image.size.width
        return max(1, min(height, maximumHeight))
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
    /// How far past the viewport a resize reaches. Deliberately much smaller
    /// than `mountAhead`: mounting ahead buys smooth scrolling, while
    /// restyling ahead only buys work the reader cannot see yet — and a
    /// resize is a keypress, so what it costs is what it feels like.
    private static let restyleAhead: CGFloat = 120
    private static let mountBatch = 8
    private static let maximumMountPasses = 24

    /// A mounted block: the view in the stack, and — for prose — the way to
    /// re-render it at another size in place.
    private struct MountedBlock {
        let view: UIView
        let restyle: ((CGFloat) -> Void)?
        /// The size this block is currently drawn at. A resize only touches
        /// what the reader can see, so the rest stay behind until they are
        /// scrolled toward.
        var scale: CGFloat
    }

    var openLink: (String) -> Void = { _ in }
    /// A pressed image placeholder: the pane decides whether that means
    /// fetching the picture or confirming a web address.
    var showImage: (String) -> Void = { _ in }
    private(set) var scrollView = UIScrollView()
    private(set) var blockStack = UIStackView()
    private var blocks: [MarkdownBlock] = []
    /// What the reader has open, by the document's own spelling of the target.
    private var imageStates: [String: FileViewerController.InlineImage] = [:]
    private var mounted: [MountedBlock] = []
    private var mountedCount = 0
    private var mounting = false
    private var restyling = false
    private var pendingRestoreOffset: CGFloat?
    private var textScale = FileViewerTextScale.default
    private var pinch: FileViewerTextScalePinch?

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
        pinch = FileViewerTextScalePinch.install(on: scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    /// The pictures the reader has open, fanned out to every mounted prose
    /// block (quotes nest, so this walks rather than indexes). Newly mounted
    /// blocks pick the same map up as they are built.
    func setImageStates(_ states: [String: FileViewerController.InlineImage]) {
        guard states != imageStates else { return }
        imageStates = states
        applyImageStates()
    }

    private func applyImageStates() {
        func walk(_ view: UIView) {
            if let block = view as? FileViewerMarkdownProseBlockView {
                block.setImages(imageStates)
                return
            }
            view.subviews.forEach(walk)
        }
        blockStack.arrangedSubviews.forEach(walk)
    }

    /// The first image target on the *mounted* stack, in document order —
    /// what a press would reach. Blocks past the mount frontier are not
    /// built yet and are not on screen either, so they are not candidates.
    func firstMountedImageDestination() -> String? {
        func scan(_ view: UIView) -> String? {
            if let text = view as? FileViewerMarkdownTextView,
               let destination = text.imageDestinations.first {
                return destination
            }
            for subview in view.subviews {
                if let found = scan(subview) { return found }
            }
            return nil
        }
        for block in blockStack.arrangedSubviews {
            if let found = scan(block) { return found }
        }
        return nil
    }

    /// Resizes what the reader can see, and lets the rest follow.
    ///
    /// Two costs make a naive resize slow, both measured on the iPad sim
    /// (2026-08-06, 160 mounted blocks): tearing the stack down and refilling
    /// it pays the whole scroll depth before the reader's own block has a
    /// position (2.7 s), and even restyling every mounted block in place
    /// still re-measures every TextKit surface in one layout pass (1.5 s).
    /// So a resize touches only the blocks within a screen of the viewport —
    /// bounded work, ~20 blocks — and marks the others behind. They catch up
    /// in `restyleNearViewport` as they are scrolled toward, each batch
    /// holding the reader's anchor block still so a block finishing above
    /// them cannot shove the page.
    func setTextScale(_ scale: CGFloat) {
        guard scale != textScale else { return }
        textScale = scale
        guard mountedCount > 0 else { return }
        restyleNearViewport()
        // A smaller size can expose blocks that were never mounted — but that
        // is the layout cycle's job, not the keypress's: every extra
        // synchronous pass over a mounted stack of hundreds of TextKit views
        // is another ~100 ms the reader waits for their own keystroke.
        setNeedsLayout()
    }

    /// Brings every mounted block within a screen of the viewport up to the
    /// current size. Cheap when there is nothing to do — the common case on
    /// a scroll tick is one comparison per mounted block.
    private func restyleNearViewport() {
        guard !restyling, mountedCount > 0 else { return }
        let top = scrollView.contentOffset.y - Self.restyleAhead
        let bottom = scrollView.contentOffset.y
            + max(scrollView.bounds.height, 1) + Self.restyleAhead
        var indexes: [Int] = []
        for index in 0..<mountedCount where mounted[index].scale != textScale {
            let frame = mounted[index].view.convert(
                mounted[index].view.bounds, to: scrollView
            )
            // The stack is ordered, so once a stale block starts below the
            // window every later one does too.
            if frame.minY > bottom { break }
            if frame.maxY >= top { indexes.append(index) }
        }
        guard !indexes.isEmpty else { return }
        restyling = true
        defer { restyling = false }

        let scale = textScale
        let anchor = currentAnchor()
        for index in indexes {
            if let restyle = mounted[index].restyle {
                restyle(scale)
                mounted[index].scale = scale
                continue
            }
            // A fence's row heights and a table's column widths are measured
            // into constraints at build time — those two are rebuilt.
            let replacement = makeBlock(blocks[index])
            let previous = mounted[index].view
            blockStack.removeArrangedSubview(previous)
            previous.removeFromSuperview()
            blockStack.insertArrangedSubview(replacement.view, at: index)
            mounted[index] = replacement
        }
        scrollView.setNeedsLayout()
        scrollView.layoutIfNeeded()
        restore(anchor)
    }

    /// The first mounted block the reader can see, and how far into it they
    /// are — the pair that survives a reflow.
    private func currentAnchor() -> (index: Int, offsetInBlock: CGFloat)? {
        let top = scrollView.contentOffset.y
        for index in 0..<mountedCount {
            let frame = mounted[index].view.convert(
                mounted[index].view.bounds, to: scrollView
            )
            if frame.maxY > top {
                return (index, top - frame.minY)
            }
        }
        return nil
    }

    private func restore(_ anchor: (index: Int, offsetInBlock: CGFloat)?) {
        guard let anchor, anchor.index < mountedCount else { return }
        let view = mounted[anchor.index].view
        let frame = view.convert(view.bounds, to: scrollView)
        let limit = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        scrollView.contentOffset = CGPoint(
            x: 0,
            y: min(max(0, frame.minY + anchor.offsetInBlock), limit)
        )
    }

    func apply(blocks: [MarkdownBlock]) {
        guard self.blocks != blocks else { return }
        self.blocks = blocks
        let oldOffset = scrollView.contentOffset
        for child in blockStack.arrangedSubviews {
            blockStack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        mounted.removeAll()
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
        restyleNearViewport()
        mountBlocksIfNeeded()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        restyleNearViewport()
        mountBlocksIfNeeded()
    }

    private func mountBlocksIfNeeded() {
        // A restyle moves the scroll offset to hold the reader's anchor, and
        // that lands here through `scrollViewDidScroll`. Mounting mid-restyle
        // would buy a second full layout pass for nothing.
        guard !mounting, !restyling, mountedCount < blocks.count else { return }
        mounting = true
        defer { mounting = false }
        // contentSize can be stale here: a width change reflows the mounted
        // text to a shorter height only during the scroll view's NEXT layout
        // pass, and reading the old (taller) height makes the reach check
        // decide the viewport is already filled — leaving a half-rendered
        // page until a scroll re-enters this method. The `setNeedsLayout` is
        // load-bearing: tearing the stack down (a resize remount) leaves the
        // scroll view itself unmarked, so `layoutIfNeeded` alone returns the
        // OLD tall height, every batch check reads the viewport as already
        // filled, and the screen stays blank until the reader scrolls.
        scrollView.setNeedsLayout()
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
                let block = makeBlock(blocks[mountedCount])
                mounted.append(block)
                blockStack.addArrangedSubview(block.view)
                mountedCount += 1
            }
            // Resolve the new content height before deciding on another batch.
            scrollView.setNeedsLayout()
            scrollView.layoutIfNeeded()
        }
    }

    /// Builds a block's view and, where the block is prose, the cheap way to
    /// re-render it at another size. A fence's row heights and a table's
    /// column widths are measured into constraints at build time, so those
    /// two are rebuilt instead.
    private func makeBlock(_ block: MarkdownBlock) -> MountedBlock {
        switch block {
        case .heading(let level, let inlines):
            let render = { (scale: CGFloat, shown: Set<String>) in
                FileViewerMarkdownInlineRenderer.render(
                    inlines,
                    baseFont: Self.headingFont(level, scale: scale),
                    scale: scale,
                    shownImages: shown
                )
            }
            let text = makeText(render(textScale, []))
            let block = proseBlock(
                content: inset(text, top: level <= 2 ? 8 : 4),
                text: text,
                render: render
            )
            return MountedBlock(
                view: block,
                restyle: { [weak block] scale in block?.setScale(scale) },
                scale: textScale
            )
        case .paragraph(let inlines):
            let render = { (scale: CGFloat, shown: Set<String>) in
                Self.proseText(inlines, scale: scale, shownImages: shown)
            }
            let text = makeText(render(textScale, []))
            let block = proseBlock(content: text, text: text, render: render)
            return MountedBlock(
                view: block,
                restyle: { [weak block] scale in block?.setScale(scale) },
                scale: textScale
            )
        case .code(let language, _, let lines):
            return MountedBlock(
                view: FileViewerMarkdownCodeFenceView(
                    language: language,
                    lines: lines,
                    scale: textScale
                ),
                restyle: nil,
                scale: textScale
            )
        case .quote(let inner):
            let bar = UIView()
            bar.backgroundColor = UIKitChassis.bezelHi
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
            let innerStack = UIStackView()
            innerStack.axis = .vertical
            innerStack.alignment = .fill
            innerStack.spacing = 10
            let mounted = inner.map { makeBlock($0) }
            mounted.forEach { innerStack.addArrangedSubview($0.view) }
            let row = UIStackView(arrangedSubviews: [bar, innerStack])
            row.axis = .horizontal
            row.alignment = .fill
            row.spacing = 12
            let restylers = mounted.map(\.restyle)
            return MountedBlock(
                view: inset(row, left: 2),
                // A quote restyles only if everything inside it can.
                restyle: restylers.allSatisfy { $0 != nil }
                    ? { scale in restylers.forEach { $0?(scale) } }
                    : nil,
                scale: textScale
            )
        case .listItem(let marker, let level, let inlines):
            let markerLabel = UILabel()
            markerLabel.text = marker
            markerLabel.font = UIKitChassis.monoFont(11 * textScale)
            markerLabel.textColor = UIKitChassis.signal3
            markerLabel.setContentHuggingPriority(.required, for: .horizontal)
            let render = { (scale: CGFloat, shown: Set<String>) in
                Self.proseText(inlines, scale: scale, shownImages: shown)
            }
            let text = makeText(render(textScale, []))
            let row = UIStackView(arrangedSubviews: [markerLabel, text])
            row.axis = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 9 * textScale
            let container = UIView()
            container.addSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            let leading = row.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: CGFloat(level) * 18 * textScale
            )
            NSLayoutConstraint.activate([
                leading,
                row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                row.topAnchor.constraint(equalTo: container.topAnchor),
                row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            let block = proseBlock(content: container, text: text, render: render)
            return MountedBlock(
                view: block,
                restyle: { [weak markerLabel, weak block, weak row] scale in
                    markerLabel?.font = UIKitChassis.monoFont(11 * scale)
                    block?.setScale(scale)
                    row?.spacing = 9 * scale
                    leading.constant = CGFloat(level) * 18 * scale
                },
                scale: textScale
            )
        case .table(let header, let rows):
            return MountedBlock(
                view: FileViewerMarkdownTableView(
                    header: header,
                    rows: rows,
                    scale: textScale,
                    openLink: openLink
                ),
                restyle: nil,
                scale: textScale
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
            // A rule carries no type; it is the same at every size.
            return MountedBlock(view: container, restyle: { _ in }, scale: textScale)
        }
    }

    /// A text view wired to both roads a run's links can take: a picture is
    /// shown in place, anything else is confirmed and opened.
    private func makeText(
        _ attributed: FileViewerMarkdownAttributedText
    ) -> FileViewerMarkdownTextView {
        let text = FileViewerMarkdownTextView(attributed: attributed, openLink: openLink)
        text.showImage = { [weak self] in self?.showImage($0) }
        return text
    }

    private func proseBlock(
        content: UIView,
        text: FileViewerMarkdownTextView,
        render: @escaping (CGFloat, Set<String>) -> FileViewerMarkdownAttributedText
    ) -> FileViewerMarkdownProseBlockView {
        let block = FileViewerMarkdownProseBlockView(
            content: content,
            text: text,
            scale: textScale,
            updateText: { [weak text] scale, shown in
                text?.update(attributed: render(scale, shown))
            },
            openFull: { [weak self] in self?.openLink($0) }
        )
        block.setImages(imageStates)
        return block
    }

    private static func proseText(
        _ inlines: [MarkdownInline],
        scale: CGFloat,
        shownImages: Set<String> = []
    ) -> FileViewerMarkdownAttributedText {
        FileViewerMarkdownInlineRenderer.render(
            inlines,
            baseFont: UIKitChassis.uiFont(13 * scale),
            lineSpacing: 3 * scale,
            scale: scale,
            shownImages: shownImages
        )
    }

    private static func headingFont(_ level: Int, scale: CGFloat) -> UIFont {
        switch level {
        case 1: UIKitChassis.uiFont(22 * scale, weight: .bold)
        case 2: UIKitChassis.uiFont(17 * scale, weight: .bold)
        case 3: UIKitChassis.uiFont(14 * scale, weight: .semibold)
        default: UIKitChassis.uiFont(13 * scale, weight: .semibold)
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

    init(
        language: CodeLanguage?,
        lines: [String],
        scale: CGFloat = FileViewerTextScale.default
    ) {
        let highlighted = CodeHighlighter.highlight(
            lines.joined(separator: "\n"),
            language: language
        )
        let font = UIKitChassis.monoFont(10.5 * scale)
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
        scale: CGFloat = FileViewerTextScale.default,
        openLink: @escaping (String) -> Void
    ) {
        super.init(frame: .zero)
        backgroundColor = .clear
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else {
            heightAnchor.constraint(equalToConstant: 1).isActive = true
            return
        }

        let headerFont = UIKitChassis.uiFont(12 * scale, weight: .semibold)
        let bodyFont = UIKitChassis.uiFont(12 * scale)
        let allRows = [header] + rows
        let rendered: [[FileViewerMarkdownAttributedText]] = allRows.enumerated().map { rowIndex, cells in
            (0..<columns).map { column in
                FileViewerMarkdownInlineRenderer.render(
                    column < cells.count ? cells[column] : [],
                    baseFont: rowIndex == 0 ? headerFont : bodyFont,
                    scale: scale
                )
            }
        }
        // The column clamp travels with the type: a 320 pt ceiling authored
        // for 12 pt text would wrap every cell at 200%.
        let widthLimit = 320 * scale
        let widths: [CGFloat] = (0..<columns).map { column in
            let widest = rendered.map { row in
                ceil(row[column].text.boundingRect(
                    with: CGSize(width: widthLimit, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                ).width) + 20
            }.max() ?? 60
            return widest.clamped(to: (60 * scale)...widthLimit)
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
            }.max() ?? 32 * scale
            rowHeights.append(max(32 * scale, height))
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
