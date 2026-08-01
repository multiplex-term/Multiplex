import UIKit

// The code and diff screens share one selectable UITextView, so selection can
// cross lines. Line numbers, diff old/new numbers, row grounds, and the target
// highlight are decor drawn by companion views, never copied. The text itself
// is exactly what copy should carry: file characters or real unified-diff
// lines with ASCII prefixes and hunk headers.

// MARK: - Content model

/// A built screen: the selectable text plus per-line decor. Pure value
/// assembled off-main (a truncated-cap file is ~1.5 MB); fonts/colors are
/// resolved per draw so appearance stays trait-dynamic.
struct FileViewerTextContent {
    struct Row {
        /// Preformatted gutter readout (line number, diff `old new`),
        /// drawn right-aligned — never part of the text.
        var gutter: String?
        var gutterColor: UIColor?
        /// Full-width row ground (diff add/delete tints, hunk headers,
        /// the target line's caution wash).
        var ground: UIColor?
    }

    let text: NSAttributedString
    /// UTF-16 offset of each line's start in `text`, ascending — how a
    /// layout fragment finds its row.
    let lineStarts: [Int]
    let rows: [Row]
    let gutterWidth: CGFloat
    let gutterFont: UIFont
    let bodyFont: UIFont

    /// The row owning a text offset: last line start ≤ offset.
    func lineIndex(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private static let gutterInk = CodePalette.gutter
    private static let plainInk = CodePalette.plain

    private static func mono(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        .monospacedSystemFont(ofSize: size * Theme.typeScale, weight: weight)
    }

    private static func italic(_ font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic)
        else { return font }
        return UIFont(descriptor: descriptor, size: 0)
    }

    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        return style
    }()

    /// Shared assembly: appends one visual line + its decor row, keeping
    /// `lineStarts` true to the joined text.
    private struct Builder {
        let text = NSMutableAttributedString()
        var lineStarts: [Int] = []
        var rows: [Row] = []

        mutating func line(
            _ pieces: [(String, UIFont, UIColor)],
            gutter: String? = nil,
            gutterColor: UIColor? = nil,
            ground: UIColor? = nil
        ) {
            if !lineStarts.isEmpty {
                text.append(NSAttributedString(string: "\n"))
            }
            lineStarts.append(text.length)
            rows.append(Row(gutter: gutter, gutterColor: gutterColor, ground: ground))
            for (string, font, color) in pieces {
                text.append(NSAttributedString(
                    string: string,
                    attributes: [.font: font, .foregroundColor: color]
                ))
            }
        }

        func finish() -> NSAttributedString {
            text.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: NSRange(location: 0, length: text.length)
            )
            return text
        }
    }

    static func code(_ lines: [HighlightedLine], targetLine: Int?) -> FileViewerTextContent {
        let font = mono(11)
        let comment = italic(font)
        let target = TallyPalette.caution
        let targetGround = TallyPalette.caution.withAlphaComponent(0.12)
        let inks: [CodeTokenKind: UIColor] = tokenInks()

        var builder = Builder()
        for (index, line) in lines.enumerated() {
            let number = index + 1
            builder.line(
                line.segments.map {
                    ($0.text, $0.kind == .comment ? comment : font, inks[$0.kind] ?? plainInk)
                },
                gutter: "\(number)",
                gutterColor: number == targetLine ? target : gutterInk,
                ground: number == targetLine ? targetGround : nil
            )
        }
        return FileViewerTextContent(
            text: builder.finish(),
            lineStarts: builder.lineStarts,
            rows: builder.rows,
            gutterWidth: 56,
            gutterFont: mono(9),
            bodyFont: font
        )
    }

    static func diff(_ diff: GitDiff, repoScope: Bool) -> FileViewerTextContent {
        let font = mono(10.5)
        let fileFont = mono(10.5, weight: .semibold)
        let headerFont = mono(9)
        let signFont = mono(10.5, weight: .semibold)
        let inks: [CodeTokenKind: UIColor] = tokenInks()
        let addInk = CodePalette.diffAddText
        let deleteInk = CodePalette.diffDeleteText
        let addGround = CodePalette.diffAddGround
        let deleteGround = CodePalette.diffDeleteGround
        let headerInk = CodePalette.hunkHeader
        let headerGround = TallyPalette.bezel.withAlphaComponent(0.5)
        let fileInk = TallyPalette.signal
        let fileGround = TallyPalette.bezel
        let quietInk = TallyPalette.signal3

        func pad(_ number: Int?) -> String {
            let text = number.map(String.init) ?? ""
            return String(repeating: " ", count: max(0, 5 - text.count)) + text
        }

        var builder = Builder()
        for file in diff.files {
            let language: CodeLanguage? = {
                if case .code(let detected) = FileKind.classify(
                    fileName: FileTree.name(of: file.displayPath)
                ) { return detected }
                return nil
            }()
            let rules = language.flatMap { CodeHighlighter.rules(for: $0) }

            if repoScope {
                var pieces: [(String, UIFont, UIColor)] = [
                    (file.displayPath, fileFont, fileInk)
                ]
                if file.kind == .renamed {
                    pieces.append(("  RENAMED", headerFont, quietInk))
                }
                if file.additions > 0 || file.deletions > 0 {
                    pieces.append(("  +\(file.additions)", headerFont, addInk))
                    pieces.append((" −\(file.deletions)", headerFont, deleteInk))
                }
                builder.line(pieces, ground: fileGround)
            }
            if file.isBinary {
                builder.line([("Binary files differ.", font, quietInk)])
            } else if file.hunks.isEmpty {
                builder.line([(
                    file.kind == .renamed
                        ? "Rename only — contents unchanged."
                        : "No textual hunks.",
                    font, quietInk
                )])
            }
            for hunk in file.hunks {
                builder.line(
                    [(hunk.header, headerFont, headerInk)],
                    ground: headerGround
                )
                for line in hunk.lines {
                    // Stateless per-row highlight — the lazy screens'
                    // accepted trade (a row mid-block-comment loses
                    // comment color), recorded in local-plan/file-viewer.md.
                    var state = CodeHighlighter.LineState.normal
                    let highlighted: HighlightedLine =
                        if let rules {
                            CodeHighlighter.highlightLine(line.text, state: &state, rules: rules)
                        } else {
                            HighlightedLine(segments: [.init(text: line.text, kind: .plain)])
                        }
                    let (sign, signInk, ground): (String, UIColor, UIColor?) =
                        switch line.kind {
                        case .addition: ("+", addInk, addGround)
                        case .deletion: ("-", deleteInk, deleteGround)
                        case .context: (" ", gutterInk, nil)
                        }
                    builder.line(
                        [(sign, signFont, signInk)] + highlighted.segments.map {
                            ($0.text, font, inks[$0.kind] ?? plainInk)
                        },
                        gutter: pad(line.oldNumber) + " " + pad(line.newNumber),
                        gutterColor: gutterInk,
                        ground: ground
                    )
                }
            }
        }
        return FileViewerTextContent(
            text: builder.finish(),
            lineStarts: builder.lineStarts,
            rows: builder.rows,
            gutterWidth: 84,
            gutterFont: mono(8.5),
            bodyFont: font
        )
    }

    private static func tokenInks() -> [CodeTokenKind: UIColor] {
        let kinds: [CodeTokenKind] = [
            .plain, .keyword, .type, .string, .comment,
            .number, .function, .property, .meta,
        ]
        return Dictionary(uniqueKeysWithValues: kinds.map {
            ($0, CodePalette.color(for: $0))
        })
    }
}

// MARK: - The text view + decor

/// Read-only selectable UITextView with two pinned companion views: a
/// backdrop below the text canvas painting full-width row grounds, and a
/// gutter painting line numbers into the left text-container inset. Both
/// re-pin and redraw from `layoutSubviews`, which UIScrollView runs on
/// every scroll tick. Non-editable, so selecting never summons a keyboard
/// and the view stays out of `TerminalFocusArbiter`'s world.
final class FileViewerTextView: UITextView {
    private(set) var content: FileViewerTextContent?
    private let backdrop = DecorView()
    private let gutter = DecorView()
    private var pendingTargetLine: Int?
    /// Keeps the hand-built TextKit 2 stack alive: the storage retains its
    /// layout managers, which retain the container.
    private let storage: NSTextContentStorage

    /// Builds the TextKit 2 stack by hand. The `usingTextLayoutManager:`
    /// convenience init constructs the instance outside the subclass's
    /// Swift-designated init, leaving stored properties uninitialized
    /// (crashed on first use); handing the designated init a container
    /// already attached to an NSTextLayoutManager is the supported way to
    /// get a TextKit 2 view from a subclass.
    init() {
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: .zero)
        container.widthTracksTextView = true
        layoutManager.textContainer = container
        let storage = NSTextContentStorage()
        storage.addTextLayoutManager(layoutManager)
        self.storage = storage
        super.init(frame: .zero, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not restorable") }

    func installDecor() {
        for view in [backdrop, gutter] {
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.contentMode = .redraw
        }
        backdrop.draws = { [weak self] rect in self?.drawGrounds(in: rect) }
        gutter.draws = { [weak self] rect in self?.drawGutter(in: rect) }
        // Below the TextKit canvas subview, so selection highlights and
        // glyphs render over the grounds.
        insertSubview(backdrop, at: 0)
        addSubview(gutter)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (view: FileViewerTextView, _: UITraitCollection) in
            // Re-setting the text re-resolves its dynamic inks — TextKit
            // caches attributed colors and an appearance flip must reach
            // token colors, not just the drawn decor.
            if let content = view.content {
                view.setContent(content, targetLine: nil, preservingOffset: true)
            }
        }
    }

    func setContent(
        _ content: FileViewerTextContent,
        targetLine: Int?,
        preservingOffset: Bool = false
    ) {
        let offset = contentOffset
        self.content = content
        textContainerInset = UIEdgeInsets(
            top: 10, left: content.gutterWidth, bottom: 12, right: 14
        )
        attributedText = content.text
        if preservingOffset {
            let limit = max(0, contentSize.height - bounds.height)
            contentOffset = CGPoint(x: 0, y: min(offset.y, limit))
        } else if let targetLine, targetLine > 1 {
            pendingTargetLine = targetLine
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let origin = bounds.origin
        backdrop.frame = CGRect(origin: origin, size: bounds.size)
        gutter.frame = CGRect(
            origin: origin,
            size: CGSize(width: content?.gutterWidth ?? 0, height: bounds.height)
        )
        backdrop.setNeedsDisplay()
        gutter.setNeedsDisplay()
        // One main-queue hop after the first real layout pass: applying
        // inside this pass reads pre-settle container geometry and the
        // centered offset lands short.
        if pendingTargetLine != nil, bounds.height > 0, bounds.width > 0 {
            let line = pendingTargetLine
            pendingTargetLine = nil
            DispatchQueue.main.async { [weak self] in
                self?.scrollToLineCentered(line)
            }
        }
    }

    /// Visible layout fragments → (row index, row rect in content
    /// coordinates). One walk shared by both decor draws.
    private func forEachVisibleRow(_ body: (Int, CGRect) -> Void) {
        guard let content,
              !content.lineStarts.isEmpty,
              let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager
        else { return }
        let insetTop = textContainerInset.top
        let visibleTop = bounds.origin.y - insetTop
        let visibleBottom = visibleTop + bounds.height
        let start = layoutManager.textLayoutFragment(
            for: CGPoint(x: 0, y: max(0, visibleTop))
        )?.rangeInElement.location ?? layoutManager.documentRange.location
        layoutManager.enumerateTextLayoutFragments(
            from: start, options: [.ensuresLayout]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY > visibleBottom { return false }
            if frame.maxY >= visibleTop {
                let offset = contentManager.offset(
                    from: layoutManager.documentRange.location,
                    to: fragment.rangeInElement.location
                )
                body(
                    content.lineIndex(at: offset),
                    CGRect(
                        x: 0, y: frame.minY + insetTop,
                        width: bounds.width, height: frame.height
                    )
                )
            }
            return true
        }
    }

    private func drawGrounds(in _: CGRect) {
        guard let content else { return }
        let shift = bounds.origin.y
        forEachVisibleRow { line, frame in
            guard line < content.rows.count,
                  let ground = content.rows[line].ground
            else { return }
            ground.resolvedColor(with: traitCollection).setFill()
            UIRectFillUsingBlendMode(
                CGRect(
                    x: 0, y: frame.minY - shift,
                    width: backdrop.bounds.width, height: frame.height
                ),
                .normal
            )
        }
    }

    private func drawGutter(in _: CGRect) {
        guard let content else { return }
        let shift = bounds.origin.y
        // Align the gutter's first line with the row's first text line.
        let baselineNudge = content.bodyFont.ascender - content.gutterFont.ascender
        forEachVisibleRow { line, frame in
            guard line < content.rows.count,
                  let text = content.rows[line].gutter
            else { return }
            let color = content.rows[line].gutterColor ?? CodePalette.gutter
                .resolvedColor(with: traitCollection)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: content.gutterFont, .foregroundColor: color,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(
                at: CGPoint(
                    x: content.gutterWidth - 12 - size.width,
                    y: frame.minY - shift + baselineNudge
                ),
                withAttributes: attributes
            )
        }
    }

    /// A `path:12` press scrolls its line to center, once.
    private func scrollToLineCentered(_ line: Int?) {
        guard let targetLine = line,
              let content,
              targetLine - 1 < content.lineStarts.count,
              let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let location = contentManager.location(
                  layoutManager.documentRange.location,
                  offsetBy: content.lineStarts[targetLine - 1]
              )
        else { return }
        // Realize layout up to the target so its frame is exact, not an
        // estimate that lands the scroll somewhere nearby.
        if let range = NSTextRange(
            location: layoutManager.documentRange.location, end: location
        ) {
            layoutManager.ensureLayout(for: range)
        }
        var targetFrame: CGRect?
        layoutManager.enumerateTextLayoutFragments(
            from: location, options: [.ensuresLayout]
        ) { fragment in
            targetFrame = fragment.layoutFragmentFrame
            return false
        }
        guard let targetFrame else { return }
        let centered = targetFrame.minY + textContainerInset.top
            - (bounds.height - targetFrame.height) / 2
        let limit = max(0, contentSize.height - bounds.height)
        setContentOffset(
            CGPoint(x: 0, y: min(max(0, centered), limit)), animated: false
        )
    }
}

/// A pinned overlay that delegates its drawing to the owning text view.
private final class DecorView: UIView {
    var draws: ((CGRect) -> Void)?

    override func draw(_ rect: CGRect) {
        draws?(rect)
    }
}
