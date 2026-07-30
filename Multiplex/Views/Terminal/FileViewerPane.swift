import SwiftUI

/// One file-viewer tab's surface — the bake-off verdict (see
/// local-plan/file-viewer-bakeoff): the WORKBENCH split wearing the
/// REGISTER rail. Content screen left; the tree stands on its own screen
/// ground to the right while the window affords it (≥ 700 pt) and yields
/// to a drawer summoned from the rail below that. The bottom rail keeps
/// identical instrumentation across every render: SOURCE | DIFF where git
/// has a verdict, the breadcrumb readout, the host tag, REFRESH, CLOSE.
///
/// Color discipline: everything inside the screens is *content* (syntax
/// classes, diff tints — appearance-dynamic, deliberately not chrome
/// tokens), while every frame, rail, and caption stays on `Theme`.
struct FileViewerPane: View {
    @Bindable var controller: FileViewerController
    var contentSafeArea = EdgeInsets()
    let close: () -> Void

    /// The standing column's presence at regular widths.
    @State private var treeDocked = true
    /// The drawer's presence at compact widths.
    @State private var drawerOpen = false
    /// A markdown link awaiting the link sheet's confirmation — the same
    /// gate a pane press gets; a document never opens anything itself.
    @State private var confirmingLink: TerminalLink?

    private static let treeWidth: CGFloat = 236
    private static let compactThreshold: CGFloat = 700

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < Self.compactThreshold
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    contentColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !compact, treeDocked {
                        Rectangle().fill(Theme.bezelHi).frame(width: 1)
                        treeColumn
                            .frame(width: Self.treeWidth)
                    }
                }
                .overlay(alignment: .trailing) {
                    if compact, drawerOpen {
                        treeColumn
                            .frame(width: min(Self.treeWidth + 24, geometry.size.width - 56))
                            .background(Theme.bezel)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(Theme.bezelHi).frame(width: 1)
                            }
                            .shadow(color: .black.opacity(0.35), radius: 18, x: -8, y: 0)
                            .transition(.move(edge: .trailing))
                    }
                }
                rail(compact: compact)
            }
            .animation(.easeOut(duration: 0.18), value: drawerOpen)
        }
        .background(Theme.screen)
        .task { await controller.start() }
        .sheet(item: $confirmingLink) { link in
            TerminalLinkSheet(
                link: link,
                onOpen: {
                    if let url = link.openableURL { UIApplication.shared.open(url) }
                },
                onCopy: { UIPasteboard.general.string = link.raw }
            )
        }
    }

    // MARK: Content column

    private var contentColumn: some View {
        VStack(spacing: 0) {
            fileHeader
            Rectangle().fill(Theme.bezelHi).frame(height: 1)
            contentBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.screen)
    }

    @ViewBuilder
    private var contentBody: some View {
        switch controller.content {
        case .idle:
            emptyState
        case .loading(let label):
            loadingState(label)
        case .document(let document):
            documentBody(document)
        case .diff(let diff, let scope):
            FileViewerDiffView(diff: diff, scope: scope, controller: controller)
        case .failure(let title, let message):
            failurePanel(title: title, message: message)
        }
    }

    @ViewBuilder
    private func documentBody(_ document: FileViewerController.Document) -> some View {
        if document.isBinary {
            binaryPanel(document)
        } else if let imageData = document.imageData {
            imageBody(document, data: imageData)
        } else if !document.markdown.isEmpty {
            FileViewerMarkdownView(
                blocks: document.markdown,
                openLink: { destination in
                    // External targets are untrusted document text — the
                    // link sheet decides, exactly like a pane press. A
                    // scheme-less relative target is in-document
                    // navigation (docs/setup.md), which stays inside the
                    // already-confirmed viewer.
                    if let link = TerminalLink.resolve(destination) {
                        confirmingLink = link
                    } else if !destination.contains(":"),
                              let current = controller.lastDocument {
                        let base = FileTree.parent(of: current.path) ?? "/"
                        Task {
                            await controller.open(
                                path: FileTree.join(base, destination),
                                line: nil
                            )
                        }
                    }
                }
            )
        } else {
            FileViewerCodeView(
                lines: document.codeLines,
                truncated: document.truncated,
                targetLine: document.targetLine
            )
        }
    }

    // MARK: File header

    private var fileHeader: some View {
        HStack(spacing: 8) {
            Text(headerName)
                .font(.mono(11, weight: .semibold))
                .foregroundStyle(Theme.signal)
                .lineLimit(1)
                .truncationMode(.middle)
            ChassisLabel(headerMeta, size: 8, color: Theme.signal3)
                .lineLimit(1)
            Spacer(minLength: 6)
            if case .document(let document) = controller.content,
               let badge = controller.badges[document.path] {
                ChassisLabel(
                    badgeCaption(badge),
                    size: 8,
                    color: FileViewerTreeColumn.badgeColor(badge)
                )
                .fixedSize()
            }
            if let counts = headerCounts {
                counts.fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.screen)
    }

    private var headerName: String {
        switch controller.content {
        case .document(let document): document.name
        case .diff(_, .repo): "Working tree vs HEAD"
        case .diff(_, .file(let path)): FileTree.name(of: path)
        case .loading(let label): label
        case .failure: "—"
        case .idle: FileTree.name(of: controller.rootPath)
        }
    }

    private var headerMeta: String {
        switch controller.content {
        case .document(let document):
            var parts: [String] = []
            if case .code(let language) = document.kind {
                parts.append(language?.rawValue ?? "TEXT")
            } else if document.kind == .markdown {
                parts.append(controller.markdownRaw ? "MARKDOWN · RAW" : "MARKDOWN")
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
            return controller.hostName.uppercased()
        }
    }

    private var headerCounts: Text? {
        switch controller.content {
        case .diff(let diff, _) where !(diff.additions == 0 && diff.deletions == 0):
            return plusMinus(diff.additions, diff.deletions)
        case .document where controller.documentDiffBadge != nil:
            guard case .document(let document) = controller.content,
                  controller.badges[document.path] != nil,
                  !controller.shortStat.isEmpty
            else { return nil }
            return nil
        default:
            return nil
        }
    }

    private func plusMinus(_ additions: Int, _ deletions: Int) -> Text {
        (Text("+\(additions) ").foregroundColor(CodePalette.diffAddText)
            + Text("−\(deletions)").foregroundColor(CodePalette.diffDeleteText))
            .font(.mono(9, weight: .semibold))
    }

    private func badgeCaption(_ badge: GitFileStatus.Badge) -> String {
        switch badge {
        case .modified: "MODIFIED"
        case .added: "STAGED ADD"
        case .deleted: "DELETED"
        case .renamed: "RENAMED"
        case .untracked: "UNTRACKED"
        case .conflicted: "CONFLICT"
        }
    }

    // MARK: States

    private var emptyState: some View {
        VStack(spacing: 12) {
            ChassisLabel("NO FILE ON SCREEN", size: 10, color: Theme.signal3)
            Text("Pick a file from the tree\(controller.gitRoot != nil ? ", or open the branch's diff from its ± counts" : "").")
                .font(.footnote)
                .foregroundStyle(Theme.signal3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadingState(_ label: String) -> some View {
        VStack(spacing: 10) {
            ChassisLabel("LOADING", size: 9, color: Theme.caution)
            Text(label)
                .font(.mono(11))
                .foregroundStyle(Theme.signal2)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func binaryPanel(_ document: FileViewerController.Document) -> some View {
        VStack(spacing: 14) {
            TallyLamp(caption: "BINARY", color: Theme.caution)
            Text("\(document.name) · \(FileViewerController.formatBytes(document.size))")
                .font(.mono(12))
                .foregroundStyle(Theme.signal2)
            Text("Not text — Multiplex won't render it as code.")
                .font(.footnote)
                .foregroundStyle(Theme.signal3)
        }
        .padding(28)
        .background(Theme.bezel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.bezelHi, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func imageBody(_ document: FileViewerController.Document, data: Data) -> some View {
        Group {
            if let image = UIImage(data: data) {
                FileViewerImageView(image: image)
            } else {
                failurePanel(
                    title: "CAN'T DECODE",
                    message: "\(document.name) didn't decode as an image."
                )
            }
        }
    }

    private func failurePanel(title: String, message: String) -> some View {
        VStack(spacing: 14) {
            TallyLamp(caption: title, color: Theme.caution)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.signal2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            ChassisChip("REFRESH", prominent: true) { controller.refresh() }
        }
        .padding(30)
        .background(Theme.bezel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.bezelHi, lineWidth: 1)
        )
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Tree column

    private var treeColumn: some View {
        FileViewerTreeColumn(
            controller: controller,
            closeDrawer: { drawerOpen = false }
        )
    }

    // MARK: Rail

    private func rail(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if controller.documentDiffBadge != nil {
                modeChips
            }
            pathReadout
            ChassisBadge(controller.hostName.uppercased())
                .fixedSize()
                .accessibilityLabel("Files on \(controller.hostName)")
            if compact {
                ChassisChip(drawerOpen ? "HIDE" : "TREE") { drawerOpen.toggle() }
                    .fixedSize()
                    .accessibilityLabel(drawerOpen ? "Hide the file tree" : "Show the file tree")
            } else {
                ChassisChip(treeDocked ? "HIDE" : "TREE") { treeDocked.toggle() }
                    .fixedSize()
                    .accessibilityLabel(treeDocked ? "Hide the file tree" : "Show the file tree")
            }
            ChassisChip("REFRESH") { controller.refresh() }
                .fixedSize()
                .disabled(controller.isBusy)
                .opacity(controller.isBusy ? 0.5 : 1)
            ChassisChip("CLOSE", prominent: true, action: close)
                .fixedSize()
                .accessibilityLabel("Close file viewer")
        }
        .padding(.leading, 10 + contentSafeArea.leading)
        .padding(.trailing, 10 + contentSafeArea.trailing)
        .padding(.top, 8)
        .padding(.bottom, 8 + contentSafeArea.bottom)
        .background(Theme.bezel)
        .overlay(alignment: .top) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.bezelHi).frame(height: 1)
                if isWorking {
                    Rectangle()
                        .fill(Theme.caution)
                        .frame(height: 2)
                        .frame(maxWidth: 90)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var isWorking: Bool {
        if controller.isBusy { return true }
        if case .loading = controller.content { return true }
        return false
    }

    private var modeChips: some View {
        HStack(spacing: 4) {
            ChassisChip("SOURCE", prominent: isSourceMode) {
                controller.showSource()
            }
            .fixedSize()
            ChassisChip("DIFF", prominent: !isSourceMode) {
                if case .document(let document) = controller.content {
                    Task { await controller.showFileDiff(path: document.path) }
                }
            }
            .fixedSize()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Source or diff")
    }

    private var isSourceMode: Bool {
        if case .document = controller.content { return true }
        return false
    }

    /// Monospace readout, the file bright, its directory dim — the
    /// viewport rail's voice aimed at a path.
    private var pathReadout: some View {
        Text(readoutText)
            .font(.mono(10))
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(controller.railPath)
    }

    private var readoutText: AttributedString {
        let path = controller.railPath
        let name = FileTree.name(of: path)
        let directory = String(path.dropLast(name.count))
        var head = AttributedString(directory)
        head.foregroundColor = Theme.signal3
        var tail = AttributedString(name)
        tail.foregroundColor = Theme.signal
        tail.font = .mono(10, weight: .semibold)
        return head + tail
    }
}

// MARK: - Syntax + diff palette (screen content, not chrome)

/// The content screens' color vocabulary. Deliberately not `Theme` tokens:
/// these color *what the file says*, the way a terminal theme colors a
/// pane — appearance-dynamic so Frost gets legible ink, but never spent on
/// chrome.
enum CodePalette {
    static let keyword = Color(light: 0x2E6E8E, dark: 0x7FB4C9)
    static let type = Color(light: 0x966618, dark: 0xE0A33E)
    static let string = Color(light: 0x3E7C58, dark: 0x7FBF9A)
    static let comment = Color(light: 0x87919E, dark: 0x5C6166)
    static let number = Color(light: 0x8A6D3B, dark: 0xC9A26D)
    static let function = Color(light: 0x191E25, dark: 0xF2F3F4)
    static let property = Color(light: 0x44618F, dark: 0x8FA8D0)
    static let meta = Color(light: 0x7A4E75, dark: 0xC08CB8)
    static let plain = Color(light: 0x3A434E, dark: 0xC8D2D6)
    static let gutter = Color(light: 0x87919E, dark: 0x5C6166)

    static let diffAddText = Color(light: 0x3E7C58, dark: 0x7FBF9A)
    static let diffDeleteText = Color(light: 0xC13439, dark: 0xE5484D)
    static let diffAddGround = Color(light: 0x3E7C58, dark: 0x7FBF9A).opacity(0.10)
    static let diffDeleteGround = Color(light: 0xC13439, dark: 0xE5484D).opacity(0.09)
    static let hunkHeader = Color(light: 0x2E6E8E, dark: 0x7FB4C9).opacity(0.8)
    static let link = Color(light: 0x2E6E8E, dark: 0x7FB4C9)

    static func color(for kind: CodeTokenKind) -> Color {
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

    static func attributed(
        _ line: HighlightedLine,
        baseSize: CGFloat = 11
    ) -> AttributedString {
        var result = AttributedString()
        for segment in line.segments {
            var piece = AttributedString(segment.text)
            piece.foregroundColor = color(for: segment.kind)
            if segment.kind == .comment {
                piece.font = .mono(baseSize).italic()
            }
            result += piece
        }
        if result.characters.isEmpty {
            result = AttributedString(" ")
        }
        return result
    }
}

// MARK: - Image view

/// Fit-to-screen with pinch zoom. 1 = aspect-fit inside the visible
/// screen; pinch scales 0.25–8× around that baseline (double-tap toggles
/// fit ↔ 2×), and the surrounding ScrollView owns panning once the image
/// outgrows the viewport. The zoom readout is TALLY state — captioned,
/// tappable to reset — and appears only away from fit.
private struct FileViewerImageView: View {
    let image: UIImage

    @State private var zoom: CGFloat = 1
    /// Transient pinch factor; committed into `zoom` when the gesture ends.
    @State private var pinch: CGFloat = 1

    private static let range: ClosedRange<CGFloat> = 0.25...8

    var body: some View {
        GeometryReader { geometry in
            let fitted = fittedSize(in: geometry.size)
            let scale = min(max(zoom * pinch, Self.range.lowerBound), Self.range.upperBound)
            ScrollView([.vertical, .horizontal], showsIndicators: false) {
                Image(uiImage: image)
                    .resizable()
                    .frame(
                        width: fitted.width * scale,
                        height: fitted.height * scale
                    )
                    // Centers the image while it is smaller than the
                    // viewport; once it outgrows it, these floors are inert
                    // and the scroll view pans.
                    .frame(
                        minWidth: geometry.size.width,
                        minHeight: geometry.size.height
                    )
            }
            .scrollBounceBehavior(.basedOnSize)
            // Simultaneous, or the scroll view's pan starves the pinch.
            .simultaneousGesture(magnify)
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.18)) {
                    zoom = zoom == 1 ? 2 : 1
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if scale != 1 {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { zoom = 1 }
                        pinch = 1
                    } label: {
                        ChassisLabel("\(Int((scale * 100).rounded()))% · FIT", size: 8)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Theme.bezel)
                            .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .chassisHover(2)
                    .padding(10)
                    .accessibilityLabel("Zoom \(Int((scale * 100).rounded())) percent; resets to fit")
                }
            }
        }
        .background(Theme.screen)
        .accessibilityLabel("Image, pinch to zoom")
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                pinch = value.magnification
            }
            .onEnded { value in
                zoom = min(
                    max(zoom * value.magnification, Self.range.lowerBound),
                    Self.range.upperBound
                )
                pinch = 1
            }
    }

    /// Aspect-fit inside the viewport, with breathing room; zoom multiplies
    /// this baseline so 100% always means "fits the screen".
    private func fittedSize(in container: CGSize) -> CGSize {
        let available = CGSize(
            width: max(40, container.width - 24),
            height: max(40, container.height - 24)
        )
        let size = image.size
        guard size.width > 0, size.height > 0 else { return available }
        let ratio = min(
            available.width / size.width,
            available.height / size.height,
            // Small images render at natural size instead of blowing up
            // to fill a wall-sized window.
            1
        )
        return CGSize(width: size.width * ratio, height: size.height * ratio)
    }
}

// MARK: - Code view

struct FileViewerCodeView: View {
    let lines: [HighlightedLine]
    var truncated = false
    var targetLine: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if truncated {
                        truncatedBanner
                    }
                    ForEach(lines.indices, id: \.self) { index in
                        codeRow(number: index + 1, line: lines[index])
                            .id(index + 1)
                    }
                }
                .padding(.vertical, 10)
            }
            .onAppear {
                if let targetLine, targetLine > 1, targetLine <= lines.count {
                    proxy.scrollTo(targetLine, anchor: .center)
                }
            }
        }
        .background(Theme.screen)
    }

    private func codeRow(number: Int, line: HighlightedLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(number)")
                .font(.mono(9))
                .foregroundStyle(
                    number == targetLine ? Theme.caution : CodePalette.gutter
                )
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 12)
            Text(CodePalette.attributed(line))
                .font(.mono(11))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 14)
        }
        .padding(.vertical, 1)
        .background(
            number == targetLine ? Theme.caution.opacity(0.12) : Color.clear
        )
    }

    private var truncatedBanner: some View {
        HStack(spacing: 8) {
            ChassisLabel("TRUNCATED", size: 8, color: Theme.caution)
            Text("Showing the first \(FileViewerController.formatBytes(UInt64(FileViewerController.textByteLimit))).")
                .font(.footnote)
                .foregroundStyle(Theme.signal3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.caution.opacity(0.08))
    }
}

// MARK: - Markdown view

struct FileViewerMarkdownView: View {
    let blocks: [MarkdownBlock]
    let openLink: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(blocks.indices, id: \.self) { index in
                    MarkdownBlockView(block: blocks[index])
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Theme.screen)
        .environment(\.openURL, OpenURLAction { url in
            openLink(url.absoluteString)
            return .handled
        })
    }
}

/// One block. A struct rather than a builder function because block quotes
/// nest — a view type may recurse through its own body where an opaque
/// `some View` function cannot.
private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let inlines):
            Text(MarkdownInlineText.render(inlines, baseFont: Self.headingFont(level)))
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let inlines):
            Text(MarkdownInlineText.render(inlines, baseFont: .ui(13)))
                .lineSpacing(3)
                .textSelection(.enabled)
        case .code(let language, _, let lines):
            fence(language: language, lines: lines)
        case .quote(let inner):
            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(Theme.bezelHi).frame(width: 3)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(inner.indices, id: \.self) { index in
                        MarkdownBlockView(block: inner[index])
                    }
                }
            }
            .padding(.leading, 2)
        case .listItem(let marker, let level, let inlines):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(marker)
                    .font(.mono(11))
                    .foregroundStyle(Theme.signal3)
                Text(MarkdownInlineText.render(inlines, baseFont: .ui(13)))
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(level) * 18)
        case .table(let header, let rows):
            tableView(header: header, rows: rows)
        case .rule:
            Rectangle().fill(Theme.bezelHi).frame(height: 1).padding(.vertical, 4)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .ui(22, weight: .bold)
        case 2: .ui(17, weight: .bold)
        case 3: .ui(14, weight: .semibold)
        default: .ui(13, weight: .semibold)
        }
    }

    private func fence(language: CodeLanguage?, lines: [String]) -> some View {
        let highlighted = CodeHighlighter.highlight(
            lines.joined(separator: "\n"),
            language: language
        )
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(highlighted.indices, id: \.self) { index in
                    Text(CodePalette.attributed(highlighted[index], baseSize: 10.5))
                        .font(.mono(10.5))
                }
            }
            .padding(10)
        }
        .background(Theme.chassis)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Theme.bezelHi, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .textSelection(.enabled)
    }

    private func tableView(header: [[MarkdownInline]], rows: [[[MarkdownInline]]]) -> some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(column < header.count
                            ? MarkdownInlineText.render(header[column], baseFont: .ui(12, weight: .semibold))
                            : AttributedString(""))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(minWidth: 60, alignment: .leading)
                            .background(Theme.bezel)
                    }
                }
                ForEach(rows.indices, id: \.self) { rowIndex in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            Text(column < rows[rowIndex].count
                                ? MarkdownInlineText.render(rows[rowIndex][column], baseFont: .ui(12))
                                : AttributedString(""))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(minWidth: 60, alignment: .leading)
                        }
                    }
                    .background(rowIndex.isMultiple(of: 2) ? Color.clear : Theme.bezel.opacity(0.4))
                }
            }
            .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
        }
    }
}

/// Inline runs → styled AttributedString, shared by paragraphs, headings,
/// list items, and table cells.
private enum MarkdownInlineText {
    static func render(_ inlines: [MarkdownInline], baseFont: Font) -> AttributedString {
        var result = AttributedString()
        for inline in inlines {
            switch inline {
            case .text(let value, let emphasis):
                var piece = AttributedString(value)
                var font = baseFont
                if emphasis.contains(.bold) { font = font.weight(.bold) }
                if emphasis.contains(.italic) { font = font.italic() }
                piece.font = font
                if emphasis.contains(.strikethrough) {
                    piece.strikethroughStyle = .single
                }
                piece.foregroundColor = CodePalette.plain
                result += piece
            case .code(let value):
                var piece = AttributedString(value)
                piece.font = .mono(11)
                piece.foregroundColor = CodePalette.string
                piece.backgroundColor = Theme.bezel
                result += piece
            case .link(let text, let destination):
                var piece = AttributedString(text)
                piece.font = baseFont
                piece.foregroundColor = CodePalette.link
                piece.underlineStyle = .single
                if let encoded = destination.addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed
                ), let url = URL(string: destination) ?? URL(string: encoded) {
                    piece.link = url
                }
                result += piece
            case .image(let alt):
                var piece = AttributedString("⟨image\(alt.isEmpty ? "" : ": \(alt)")⟩")
                piece.font = .mono(10)
                piece.foregroundColor = Theme.signal3
                result += piece
            }
        }
        if result.characters.isEmpty { result = AttributedString(" ") }
        return result
    }
}

// MARK: - Diff view

struct FileViewerDiffView: View {
    let diff: GitDiff
    let scope: FileViewerController.DiffScope
    var controller: FileViewerController

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if diff.files.isEmpty {
                    cleanState
                }
                ForEach(diff.files.indices, id: \.self) { index in
                    fileSection(diff.files[index], standalone: isRepoScope)
                }
            }
            .padding(.bottom, 12)
        }
        .background(Theme.screen)
    }

    private var isRepoScope: Bool {
        if case .repo = scope { return true }
        return false
    }

    private var cleanState: some View {
        VStack(spacing: 10) {
            ChassisLabel("NOTHING TO DIFF", size: 10, color: Theme.signal3)
            Text("The working tree matches HEAD here.")
                .font(.footnote)
                .foregroundStyle(Theme.signal3)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder
    private func fileSection(_ file: GitDiffFile, standalone: Bool) -> some View {
        if standalone {
            HStack(spacing: 8) {
                Text(file.displayPath)
                    .font(.mono(10, weight: .semibold))
                    .foregroundStyle(Theme.signal)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if file.kind == .renamed {
                    ChassisLabel("RENAMED", size: 7, color: Theme.signal3).fixedSize()
                }
                Spacer(minLength: 6)
                (Text("+\(file.additions) ").foregroundColor(CodePalette.diffAddText)
                    + Text("−\(file.deletions)").foregroundColor(CodePalette.diffDeleteText))
                    .font(.mono(9, weight: .semibold))
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.bezel)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.bezelHi).frame(height: 1)
            }
        }
        if file.isBinary {
            HStack {
                ChassisLabel("BINARY", size: 8, color: Theme.signal3)
                Text("Binary files differ.")
                    .font(.footnote)
                    .foregroundStyle(Theme.signal3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        } else if file.hunks.isEmpty {
            HStack {
                Text(file.kind == .renamed ? "Rename only — contents unchanged." : "No textual hunks.")
                    .font(.footnote)
                    .foregroundStyle(Theme.signal3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        ForEach(file.hunks.indices, id: \.self) { hunkIndex in
            hunkView(file.hunks[hunkIndex], language: language(for: file))
        }
    }

    private func language(for file: GitDiffFile) -> CodeLanguage? {
        if case .code(let language) = FileKind.classify(
            fileName: FileTree.name(of: file.displayPath)
        ) { return language }
        return nil
    }

    @ViewBuilder
    private func hunkView(_ hunk: GitDiffHunk, language: CodeLanguage?) -> some View {
        Text(hunk.header)
            .font(.mono(9))
            .foregroundStyle(CodePalette.hunkHeader)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bezel.opacity(0.5))
        ForEach(hunk.lines.indices, id: \.self) { lineIndex in
            diffRow(hunk.lines[lineIndex], language: language)
        }
    }

    private func diffRow(_ line: GitDiffLine, language: CodeLanguage?) -> some View {
        // Stateless per-row highlight: a diff row mid-block-comment loses
        // comment color — the accepted trade for lazy rows (recorded in
        // local-plan/file-viewer.md).
        var state = CodeHighlighter.LineState.normal
        let highlighted: HighlightedLine =
            if let rules = language.flatMap({ CodeHighlighter.rules(for: $0) }) {
                CodeHighlighter.highlightLine(line.text, state: &state, rules: rules)
            } else {
                HighlightedLine(segments: [.init(text: line.text, kind: .plain)])
            }
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .font(.mono(8.5))
                .foregroundStyle(CodePalette.gutter)
                .frame(width: 34, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "")
                .font(.mono(8.5))
                .foregroundStyle(CodePalette.gutter)
                .frame(width: 34, alignment: .trailing)
                .padding(.trailing, 8)
            Text(sign(for: line.kind))
                .font(.mono(10, weight: .semibold))
                .foregroundStyle(signColor(for: line.kind))
                .frame(width: 14, alignment: .center)
            Text(CodePalette.attributed(highlighted))
                .font(.mono(10.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 14)
        }
        .padding(.vertical, 0.5)
        .background(ground(for: line.kind))
    }

    private func sign(for kind: GitDiffLine.Kind) -> String {
        switch kind {
        case .addition: "+"
        case .deletion: "−"
        case .context: " "
        }
    }

    private func signColor(for kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .addition: CodePalette.diffAddText
        case .deletion: CodePalette.diffDeleteText
        case .context: CodePalette.gutter
        }
    }

    private func ground(for kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .addition: CodePalette.diffAddGround
        case .deletion: CodePalette.diffDeleteGround
        case .context: .clear
        }
    }
}

#if DEBUG
#Preview("Code + diff palette") {
    FileViewerCodeView(
        lines: CodeHighlighter.highlight(
            """
            import Foundation

            /// The probe's one exec round-trip.
            @MainActor
            struct Probe {
                let host: String
                func run(attempts: Int = 3) async -> [String] {
                    let banner = \"tmux -u list-panes\"
                    return banner.split(separator: \" \").map(String.init)
                }
            }
            """,
            language: .swift
        ),
        targetLine: 7
    )
    .frame(width: 620, height: 380)
    .preferredColorScheme(.dark)
}
#endif
