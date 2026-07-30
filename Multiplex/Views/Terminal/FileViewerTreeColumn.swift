import SwiftUI

/// The tree monitor — the WORKBENCH's right screen. Location header
/// (HOST ▸ ROOT + UP), the git block (branch, ± counts opening the repo
/// diff, CHANGED filter), then lazy-expanding rows with letter badges.
/// The same view docks as a standing column at regular widths and rides
/// the compact drawer.
struct FileViewerTreeColumn: View {
    @Bindable var controller: FileViewerController
    /// Compact drawer only: picking a file dismisses the drawer so the
    /// content it chose is visible. No-op when docked.
    var closeDrawer: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.bezelHi).frame(height: 1)
            if controller.gitRoot != nil {
                gitBlock
                Rectangle().fill(Theme.bezelHi).frame(height: 1)
            }
            rows
        }
        .background(Theme.screen)
    }

    private var header: some View {
        HStack(spacing: 7) {
            ChassisLabel(
                locationLabel,
                size: 8,
                color: Theme.signal2
            )
            .lineLimit(1)
            .truncationMode(.head)
            Spacer(minLength: 4)
            if FileTree.parent(of: controller.rootPath) != nil {
                ChassisChip("UP") { controller.hoistRoot() }
                    .fixedSize()
                    .accessibilityLabel("Show the parent directory")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var locationLabel: String {
        let root = FileTree.name(of: controller.rootPath)
        return "\(controller.hostName) ▸ \(root.isEmpty ? "/" : root)"
    }

    private var gitBlock: some View {
        HStack(spacing: 8) {
            Text("⎇ \(controller.branch ?? "—")")
                .font(.mono(10, weight: .semibold))
                .foregroundStyle(Theme.signal)
                .lineLimit(1)
            Button {
                Task { await controller.showRepoDiff() }
            } label: {
                countsText
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .chassisHover(2)
            .accessibilityLabel("Open the working tree's diff")
            Spacer(minLength: 4)
            ChassisChip("CHANGED", prominent: controller.changedFilter) {
                controller.changedFilter.toggle()
            }
            .fixedSize()
            .accessibilityLabel(
                controller.changedFilter
                    ? "Show the whole tree" : "Show only changed files"
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var countsText: Text {
        if controller.shortStat.isEmpty {
            return Text("±0")
                .font(.mono(9))
                .foregroundColor(Theme.signal3)
        }
        return (Text("+\(controller.shortStat.insertions) ")
            .foregroundColor(CodePalette.diffAddText)
            + Text("−\(controller.shortStat.deletions)")
            .foregroundColor(CodePalette.diffDeleteText))
            .font(.mono(9, weight: .semibold))
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let failure = controller.treeFailure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(Theme.caution)
                        .padding(10)
                }
                let treeRows = controller.treeRows
                if treeRows.isEmpty, controller.treeFailure == nil {
                    ChassisLabel(
                        controller.changedFilter ? "NOTHING CHANGED" : "EMPTY",
                        size: 8,
                        color: Theme.signal3
                    )
                    .padding(12)
                }
                ForEach(treeRows) { row in
                    rowView(row)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func rowView(_ row: FileTree.Row) -> some View {
        Button {
            controller.select(row)
            if !row.entry.isDirectory { closeDrawer() }
        } label: {
            HStack(spacing: 6) {
                Text(disclosure(row))
                    .font(.mono(8))
                    .foregroundStyle(Theme.signal3)
                    .frame(width: 10)
                Text(row.entry.name)
                    .font(.mono(10.5))
                    .foregroundStyle(isCurrent(row) ? Theme.signal : Theme.signal2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let badge = row.badge {
                    Text(badge.rawValue)
                        .font(.mono(9, weight: .semibold))
                        .foregroundStyle(Self.badgeColor(badge))
                } else if row.containsChanges {
                    Circle()
                        .fill(Theme.caution.opacity(0.7))
                        .frame(width: 4, height: 4)
                        .accessibilityLabel("Contains changes")
                }
            }
            .padding(.leading, 10 + CGFloat(row.depth) * 14)
            .padding(.trailing, 10)
            .padding(.vertical, 4.5)
            .background(isCurrent(row) ? Theme.bezelHi : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chassisHover(2)
        .accessibilityLabel(rowAccessibilityLabel(row))
    }

    private func disclosure(_ row: FileTree.Row) -> String {
        guard row.entry.isDirectory else { return "" }
        return row.isExpanded ? "▾" : "▸"
    }

    private func isCurrent(_ row: FileTree.Row) -> Bool {
        controller.railPath == row.entry.path
    }

    private func rowAccessibilityLabel(_ row: FileTree.Row) -> String {
        var label = row.entry.name
        if row.entry.isDirectory {
            label += row.isExpanded ? ", expanded folder" : ", folder"
        }
        if let badge = row.badge {
            label += ", " + badgeWord(badge)
        }
        return label
    }

    private func badgeWord(_ badge: GitFileStatus.Badge) -> String {
        switch badge {
        case .modified: "modified"
        case .added: "staged addition"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .untracked: "untracked"
        case .conflicted: "conflicted"
        }
    }

    /// The badge letters' ink — state colors, captioned by the letter
    /// itself (the deck's telemetry voice at tree scale).
    static func badgeColor(_ badge: GitFileStatus.Badge) -> Color {
        switch badge {
        case .modified: Theme.caution
        case .added: Theme.ok
        case .deleted: CodePalette.diffDeleteText
        case .renamed: Theme.signal2
        case .untracked: CodePalette.keyword
        case .conflicted: Theme.tally
        }
    }
}
