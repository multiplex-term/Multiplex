import Observation
import UIKit

struct FileViewerTreeColumnSnapshot {
    var hostName: String
    var rootPath: String
    var gitRoot: String?
    var branch: String?
    var shortStat: GitShortStat
    var changedFilter: Bool
    var treeFailure: String?
    var rows: [FileTree.Row]
    var railPath: String

    @MainActor
    init(controller: FileViewerController) {
        hostName = controller.hostName
        rootPath = controller.rootPath
        gitRoot = controller.gitRoot
        branch = controller.branch
        shortStat = controller.shortStat
        changedFilter = controller.changedFilter
        treeFailure = controller.treeFailure
        rows = controller.treeRows
        railPath = controller.railPath
    }

    init(
        hostName: String,
        rootPath: String,
        gitRoot: String?,
        branch: String?,
        shortStat: GitShortStat,
        changedFilter: Bool,
        treeFailure: String?,
        rows: [FileTree.Row],
        railPath: String
    ) {
        self.hostName = hostName
        self.rootPath = rootPath
        self.gitRoot = gitRoot
        self.branch = branch
        self.shortStat = shortStat
        self.changedFilter = changedFilter
        self.treeFailure = treeFailure
        self.rows = rows
        self.railPath = railPath
    }

    var locationLabel: String {
        let root = FileTree.name(of: rootPath)
        return "\(hostName) ▸ \(root.isEmpty ? "/" : root)"
    }

    var canHoistRoot: Bool { FileTree.parent(of: rootPath) != nil }
}

/// Native WORKBENCH tree monitor. A table view preserves the former lazy-row
/// behavior for large repositories; the fixed location and git blocks remain
/// square TALLY chrome above it.
@MainActor
final class FileViewerTreeColumnView: UIView, UITableViewDataSource,
    UITableViewDelegate
{
    static let headerHorizontalInset: CGFloat = 10
    static let headerVerticalInset: CGFloat = 7
    static let rowBaseInset: CGFloat = 10
    static let rowDepthStep: CGFloat = 14
    static let rowVerticalInset: CGFloat = 4.5

    private(set) var locationSourceLabel: UIKitChassisLabel?
    private(set) var upChip: UIKitChassisChip?
    private(set) var branchLabel: UILabel?
    private(set) var countsButton: UIButton?
    private(set) var changedChip: UIKitChassisChip?
    private(set) var tableView = UITableView(frame: .zero, style: .plain)

    private let columnStack = UIStackView()
    private var gitBlock: UIView?
    private var gitDivider: UIView?
    private var chromeRendered = false
    private var snapshot = FileViewerTreeColumnSnapshot(
        hostName: "",
        rootPath: "",
        gitRoot: nil,
        branch: nil,
        shortStat: GitShortStat(),
        changedFilter: false,
        treeFailure: nil,
        rows: [],
        railPath: ""
    )
    private var displayRows: [DisplayRow] = []

    private var controller: FileViewerController?
    private var closeDrawer: () -> Void = {}
    private var observationGeneration = 0

    private var onUp: () -> Void = {}
    private var onRepoDiff: () -> Void = {}
    private var onChangedFilter: () -> Void = {}
    private var onSelect: (FileTree.Row) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIKitChassis.screen

        columnStack.axis = .vertical
        columnStack.spacing = 0
        addSubview(columnStack)
        columnStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            columnStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            columnStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            columnStack.topAnchor.constraint(equalTo: topAnchor),
            columnStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        tableView.backgroundColor = UIKitChassis.screen
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 24
        tableView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(
            FileViewerTreeRowCell.self,
            forCellReuseIdentifier: FileViewerTreeRowCell.reuseIdentifier
        )
        tableView.register(
            FileViewerTreeMessageCell.self,
            forCellReuseIdentifier: FileViewerTreeMessageCell.reuseIdentifier
        )
        tableView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        buildChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func apply(
        controller: FileViewerController,
        closeDrawer: @escaping () -> Void
    ) {
        self.controller = controller
        self.closeDrawer = closeDrawer
        observationGeneration &+= 1
        observeAndRender(generation: observationGeneration)
    }

    /// Direct rendering seam for native view tests and future controller
    /// composition. Production calls it with actions bound to the observable
    /// `FileViewerController` below.
    func render(
        snapshot: FileViewerTreeColumnSnapshot,
        onUp: @escaping () -> Void = {},
        onRepoDiff: @escaping () -> Void = {},
        onChangedFilter: @escaping () -> Void = {},
        onSelect: @escaping (FileTree.Row) -> Void = { _ in }
    ) {
        // The chrome is built once and mutated in place: `render` runs on every
        // file selection and on every watch tick, and tearing the stack down
        // would re-parent the table view under the reader's fingers (a
        // decelerating flick stops dead, VoiceOver focus resets to the top).
        let previous = chromeRendered ? self.snapshot : nil
        let previousRows = displayRows
        self.snapshot = snapshot
        self.onUp = onUp
        self.onRepoDiff = onRepoDiff
        self.onChangedFilter = onChangedFilter
        self.onSelect = onSelect
        updateChrome(previous: previous)
        chromeRendered = true
        rebuildDisplayRows()
        if displayRows != previousRows {
            tableView.reloadData()
        } else if previous?.railPath != snapshot.railPath {
            refreshCurrentRowHighlight()
        }
    }

    func selectRow(at index: Int) {
        guard displayRows.indices.contains(index),
              case .tree(let row) = displayRows[index]
        else { return }
        onSelect(row)
    }

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        displayRows.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch displayRows[indexPath.row] {
        case .failure(let message):
            let cell = tableView.dequeueReusableCell(
                withIdentifier: FileViewerTreeMessageCell.reuseIdentifier,
                for: indexPath
            ) as! FileViewerTreeMessageCell
            cell.apply(message, color: TallyPalette.caution, chassisCaps: false)
            return cell

        case .empty(let caption):
            let cell = tableView.dequeueReusableCell(
                withIdentifier: FileViewerTreeMessageCell.reuseIdentifier,
                for: indexPath
            ) as! FileViewerTreeMessageCell
            cell.apply(caption, color: UIKitChassis.signal3, chassisCaps: true)
            return cell

        case .tree(let row):
            let cell = tableView.dequeueReusableCell(
                withIdentifier: FileViewerTreeRowCell.reuseIdentifier,
                for: indexPath
            ) as! FileViewerTreeRowCell
            cell.apply(row, isCurrent: snapshot.railPath == row.entry.path)
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        selectRow(at: indexPath.row)
    }

    private func observeAndRender(generation: Int) {
        guard generation == observationGeneration, let controller else { return }
        let snapshot = withObservationTracking {
            FileViewerTreeColumnSnapshot(controller: controller)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeAndRender(generation: generation)
            }
        }
        render(
            snapshot: snapshot,
            onUp: { [weak controller] in controller?.hoistRoot() },
            onRepoDiff: { [weak controller] in
                Task { @MainActor in await controller?.showRepoDiff() }
            },
            onChangedFilter: { [weak controller] in
                controller?.changedFilter.toggle()
            },
            onSelect: { [weak self, weak controller] row in
                controller?.select(row)
                if !row.entry.isDirectory { self?.closeDrawer() }
            }
        )
    }

    private func buildChrome() {
        let location = UIKitChassisLabel(
            snapshot.locationLabel,
            size: 8,
            color: UIKitChassis.signal2
        )
        location.lineBreakMode = .byTruncatingHead
        location.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locationSourceLabel = location

        let chip = UIKitChassisChip(
            "UP",
            accessibilityLabel: "Show the parent directory",
            action: { [weak self] in self?.onUp() }
        )
        upChip = chip

        let headerStack = UIStackView(arrangedSubviews: [location])
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = 7
        headerStack.addArrangedSubview(makeFlexibleSpacer(minimumWidth: 4))
        headerStack.addArrangedSubview(chip)
        columnStack.addArrangedSubview(inset(
            headerStack,
            horizontal: Self.headerHorizontalInset,
            vertical: Self.headerVerticalInset
        ))
        columnStack.addArrangedSubview(makeDivider())

        let branch = UILabel()
        branch.font = UIKitChassis.monoFont(10, weight: .semibold)
        branch.textColor = UIKitChassis.signal
        branch.lineBreakMode = .byTruncatingTail
        branch.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        branchLabel = branch

        // The SwiftUI source used `.buttonStyle(.plain)`: the diff
        // numbers are the complete visual treatment. A system button can
        // acquire the platform's native button ground on newer releases,
        // which turns this compact readout into an unrelated pill.
        let counts = UIButton(type: .custom)
        counts.backgroundColor = .clear
        counts.contentEdgeInsets = .zero
        counts.contentHorizontalAlignment = .leading
        counts.accessibilityLabel = "Open the working tree's diff"
        counts.hoverStyle = UIHoverStyle(
            effect: .highlight,
            shape: .rect(cornerRadius: 2)
        )
        counts.addAction(UIAction { [weak self] _ in self?.onRepoDiff() }, for: .touchUpInside)
        countsButton = counts

        let changed = UIKitChassisChip(
            "CHANGED",
            accessibilityLabel: "Show only changed files",
            action: { [weak self] in self?.onChangedFilter() }
        )
        changedChip = changed

        let gitStack = UIStackView(arrangedSubviews: [branch, counts])
        gitStack.axis = .horizontal
        gitStack.alignment = .center
        gitStack.spacing = 8
        gitStack.addArrangedSubview(makeFlexibleSpacer(minimumWidth: 4))
        gitStack.addArrangedSubview(changed)
        let gitRow = inset(
            gitStack,
            horizontal: Self.headerHorizontalInset,
            vertical: Self.headerVerticalInset
        )
        let gitRule = makeDivider()
        gitBlock = gitRow
        gitDivider = gitRule
        columnStack.addArrangedSubview(gitRow)
        columnStack.addArrangedSubview(gitRule)

        columnStack.addArrangedSubview(tableView)
        updateChrome(previous: nil)
    }

    /// Field-by-field, so an unchanged watch tick touches nothing. `previous`
    /// is nil for the first pass, which then writes every value.
    private func updateChrome(previous: FileViewerTreeColumnSnapshot?) {
        let first = previous == nil
        if first || previous?.locationLabel != snapshot.locationLabel {
            locationSourceLabel?.setText(snapshot.locationLabel)
        }
        if first || previous?.canHoistRoot != snapshot.canHoistRoot {
            upChip?.isHidden = !snapshot.canHoistRoot
        }
        let hasGit = snapshot.gitRoot != nil
        if first || previous.map({ $0.gitRoot != nil }) != hasGit {
            gitBlock?.isHidden = !hasGit
            gitDivider?.isHidden = !hasGit
        }
        guard hasGit else { return }
        if first || previous?.branch != snapshot.branch {
            branchLabel?.text = "⎇ \(snapshot.branch ?? "—")"
        }
        if first || previous?.shortStat != snapshot.shortStat {
            countsButton?.setAttributedTitle(
                Self.countsText(snapshot.shortStat),
                for: .normal
            )
        }
        if first || previous?.changedFilter != snapshot.changedFilter {
            changedChip?.isProminent = snapshot.changedFilter
            changedChip?.accessibilityLabel = snapshot.changedFilter
                ? "Show the whole tree" : "Show only changed files"
        }
    }

    /// The current row's ground is snapshot state, not row state, so a rail
    /// move repaints the cells on screen instead of reloading the table.
    private func refreshCurrentRowHighlight() {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard displayRows.indices.contains(indexPath.row),
                  case .tree(let row) = displayRows[indexPath.row],
                  let cell = tableView.cellForRow(at: indexPath) as? FileViewerTreeRowCell
            else { continue }
            cell.apply(row, isCurrent: snapshot.railPath == row.entry.path)
        }
    }

    private func rebuildDisplayRows() {
        var rows: [DisplayRow] = []
        if let treeFailure = snapshot.treeFailure {
            rows.append(.failure(treeFailure))
        }
        if snapshot.rows.isEmpty, snapshot.treeFailure == nil {
            rows.append(.empty(snapshot.changedFilter ? "NOTHING CHANGED" : "EMPTY"))
        }
        rows.append(contentsOf: snapshot.rows.map(DisplayRow.tree))
        displayRows = rows
    }

    private func inset(_ content: UIView, horizontal: CGFloat, vertical: CGFloat) -> UIView {
        let container = UIView()
        container.backgroundColor = UIKitChassis.screen
        container.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontal),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontal),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: vertical),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vertical),
        ])
        return container
    }

    private func makeDivider() -> UIView {
        let divider = UIView()
        divider.backgroundColor = UIKitChassis.bezelHi
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return divider
    }

    private func makeFlexibleSpacer(minimumWidth: CGFloat) -> UIView {
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth).isActive = true
        return spacer
    }

    static func countsText(_ stat: GitShortStat) -> NSAttributedString {
        if stat.isEmpty {
            return NSAttributedString(
                string: "±0",
                attributes: [
                    .font: UIKitChassis.monoFont(9),
                    .foregroundColor: UIKitChassis.signal3,
                ]
            )
        }
        let result = NSMutableAttributedString(
            string: "+\(stat.insertions) ",
            attributes: [
                .font: UIKitChassis.monoFont(9, weight: .semibold),
                .foregroundColor: CodePalette.diffAddText,
            ]
        )
        result.append(NSAttributedString(
            string: "−\(stat.deletions)",
            attributes: [
                .font: UIKitChassis.monoFont(9, weight: .semibold),
                .foregroundColor: CodePalette.diffDeleteText,
            ]
        ))
        return result
    }

    private enum DisplayRow: Equatable {
        case failure(String)
        case empty(String)
        case tree(FileTree.Row)
    }
}

@MainActor
final class FileViewerTreeRowCell: UITableViewCell {
    static let reuseIdentifier = "FileViewerTreeRowCell"

    private(set) var disclosureLabel = UILabel()
    private(set) var nameLabel = UILabel()
    private(set) var badgeLabel = UILabel()
    private(set) var changeDot = UIView()
    private let rowStack = UIStackView()
    private var leadingConstraint: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        disclosureLabel.font = UIKitChassis.monoFont(8)
        disclosureLabel.textColor = UIKitChassis.signal3
        disclosureLabel.textAlignment = .center
        disclosureLabel.translatesAutoresizingMaskIntoConstraints = false
        disclosureLabel.widthAnchor.constraint(equalToConstant: 10).isActive = true

        nameLabel.font = UIKitChassis.monoFont(10.5)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        badgeLabel.font = UIKitChassis.monoFont(9, weight: .semibold)
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)

        changeDot.layer.cornerRadius = 2
        changeDot.backgroundColor = TallyPalette.caution.withAlphaComponent(0.7)
        changeDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            changeDot.widthAnchor.constraint(equalToConstant: 4),
            changeDot.heightAnchor.constraint(equalToConstant: 4),
        ])

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = 6
        rowStack.addArrangedSubview(disclosureLabel)
        rowStack.addArrangedSubview(nameLabel)
        rowStack.addArrangedSubview(spacer)
        rowStack.addArrangedSubview(badgeLabel)
        rowStack.addArrangedSubview(changeDot)
        contentView.addSubview(rowStack)
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        let leading = rowStack.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor,
            constant: FileViewerTreeColumnView.rowBaseInset
        )
        leadingConstraint = leading
        NSLayoutConstraint.activate([
            leading,
            rowStack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -FileViewerTreeColumnView.rowBaseInset
            ),
            rowStack.topAnchor.constraint(
                equalTo: contentView.topAnchor,
                constant: FileViewerTreeColumnView.rowVerticalInset
            ),
            rowStack.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor,
                constant: -FileViewerTreeColumnView.rowVerticalInset
            ),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func apply(_ row: FileTree.Row, isCurrent: Bool) {
        disclosureLabel.text = Self.disclosure(row)
        nameLabel.text = row.entry.name
        nameLabel.textColor = isCurrent ? UIKitChassis.signal : UIKitChassis.signal2
        contentView.backgroundColor = isCurrent ? UIKitChassis.bezelHi : .clear
        leadingConstraint?.constant = FileViewerTreeColumnView.rowBaseInset
            + CGFloat(row.depth) * FileViewerTreeColumnView.rowDepthStep

        if let badge = row.badge {
            badgeLabel.text = badge.rawValue
            badgeLabel.textColor = FileViewerTreeColumn.badgeUIColor(badge)
            badgeLabel.isHidden = false
            changeDot.isHidden = true
        } else {
            badgeLabel.text = nil
            badgeLabel.isHidden = true
            changeDot.isHidden = !row.containsChanges
        }
        accessibilityLabel = FileViewerTreeColumn.rowAccessibilityLabel(row)
    }

    static func disclosure(_ row: FileTree.Row) -> String {
        guard row.entry.isDirectory else { return "" }
        return row.isExpanded ? "▾" : "▸"
    }
}

@MainActor
final class FileViewerTreeMessageCell: UITableViewCell {
    static let reuseIdentifier = "FileViewerTreeMessageCell"
    private let messageLabel = UILabel()
    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!
    private var topConstraint: NSLayoutConstraint!
    private var bottomConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        messageLabel.numberOfLines = 0
        contentView.addSubview(messageLabel)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        leadingConstraint = messageLabel.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor,
            constant: 10
        )
        trailingConstraint = messageLabel.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor,
            constant: -10
        )
        topConstraint = messageLabel.topAnchor.constraint(
            equalTo: contentView.topAnchor,
            constant: 10
        )
        bottomConstraint = messageLabel.bottomAnchor.constraint(
            equalTo: contentView.bottomAnchor,
            constant: -10
        )
        NSLayoutConstraint.activate([
            leadingConstraint, trailingConstraint, topConstraint, bottomConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func apply(_ text: String, color: UIColor, chassisCaps: Bool) {
        // Body copy keeps Dynamic Type; the caps branch is chassis chrome at a
        // fixed size (already scaled by `Theme.typeScale`) and must not
        // compound with it.
        messageLabel.adjustsFontForContentSizeCategory = !chassisCaps
        let inset: CGFloat = chassisCaps ? 12 : 10
        leadingConstraint.constant = inset
        trailingConstraint.constant = -inset
        topConstraint.constant = inset
        bottomConstraint.constant = -inset
        if chassisCaps {
            let scaled = 8 * Theme.typeScale
            messageLabel.attributedText = NSAttributedString(
                string: text.uppercased(),
                attributes: [
                    .font: UIKitChassis.compressedLabelFont(8),
                    .kern: scaled * 0.09,
                    .foregroundColor: color,
                ]
            )
        } else {
            messageLabel.attributedText = NSAttributedString(
                string: text,
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .footnote),
                    .foregroundColor: color,
                ]
            )
        }
        isAccessibilityElement = true
        accessibilityLabel = text
    }
}

/// Pure formatting vocabulary shared by the native tree and its tests.
enum FileViewerTreeColumn {
    static func rowAccessibilityLabel(_ row: FileTree.Row) -> String {
        var label = row.entry.name
        if row.entry.isDirectory {
            label += row.isExpanded ? ", expanded folder" : ", folder"
        }
        if let badge = row.badge {
            label += ", " + badgeWord(badge)
        }
        return label
    }

    static func badgeWord(_ badge: GitFileStatus.Badge) -> String {
        switch badge {
        case .modified: "modified"
        case .added: "staged addition"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .untracked: "untracked"
        case .conflicted: "conflicted"
        }
    }

    /// UIKit source of the badge ink.
    static func badgeUIColor(_ badge: GitFileStatus.Badge) -> UIColor {
        switch badge {
        case .modified: TallyPalette.caution
        case .added: TallyPalette.ok
        case .deleted: CodePalette.diffDeleteText
        case .renamed: TallyPalette.signal2
        case .untracked: CodePalette.keyword
        case .conflicted: TallyPalette.tally
        }
    }
}
