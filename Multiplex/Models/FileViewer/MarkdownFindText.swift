import Foundation

/// The text rendered Markdown actually shows, run by run, so find can search
/// the PREVIEW instead of flipping it to source. Each run is one selectable
/// text surface of the rendered screen, in document order: a heading, a
/// paragraph, a list item's prose (its marker is decor), a fence, one table
/// cell (header row first, row-major). A rule shows no text and has no run.
///
/// The strings mirror the renderer character for character (an empty run is
/// one space; an image is its caption), because a hit's range is a range in
/// the view's own text — `FileViewerPaneUIKitTests` holds the two together.
enum MarkdownFindText {
    struct Run: Equatable {
        /// The top-level block this run belongs to — what has to be mounted
        /// before the run's view exists.
        var block: Int
        var text: String
    }

    static func runs(
        for blocks: [MarkdownBlock],
        shownImages: Set<String> = []
    ) -> [Run] {
        var runs: [Run] = []
        for (index, block) in blocks.enumerated() {
            for text in texts(block, shownImages: shownImages) {
                runs.append(Run(block: index, text: text))
            }
        }
        return runs
    }

    /// One block's runs, in the order its view holds them.
    static func texts(_ block: MarkdownBlock, shownImages: Set<String> = []) -> [String] {
        switch block {
        case .heading(_, let inlines), .paragraph(let inlines), .listItem(_, _, let inlines):
            return [inline(inlines, shownImages: shownImages)]
        case .code(let language, _, let lines):
            return [fence(language: language, lines: lines)]
        case .quote(let inner):
            return inner.flatMap { texts($0, shownImages: shownImages) }
        case .table(let header, let rows):
            let columns = max(header.count, rows.map(\.count).max() ?? 0)
            guard columns > 0 else { return [] }
            // Cells never show pictures in place (a picture would wreck the
            // column widths), so their captions are always the closed form.
            return ([header] + rows).flatMap { cells in
                (0..<columns).map { column in
                    inline(column < cells.count ? cells[column] : [], shownImages: [])
                }
            }
        case .rule:
            return []
        }
    }

    /// A run of inlines as the renderer spells it.
    static func inline(_ inlines: [MarkdownInline], shownImages: Set<String> = []) -> String {
        var result = ""
        for inline in inlines {
            switch inline {
            case .text(let value, _): result += value
            case .code(let value): result += value
            case .link(let text, _): result += text
            case .image(let alt, let destination):
                let described = "image\(alt.isEmpty ? "" : ": \(alt)")"
                result += shownImages.contains(destination) ? "⌄ \(described)" : "⟨\(described)⟩"
            }
        }
        return result.isEmpty ? " " : result
    }

    /// A fence as its view lays it out: the highlighter's lines (a trailing
    /// blank line dropped), an empty plain-text segment drawn as one space,
    /// and a fence with no lines at all as a single space.
    static func fence(language: CodeLanguage?, lines: [String]) -> String {
        let highlighted = CodeHighlighter.highlight(
            lines.joined(separator: "\n"),
            language: language
        )
        guard !highlighted.isEmpty else { return " " }
        return highlighted.map { line in
            line.segments.map { $0.text.isEmpty ? " " : $0.text }.joined()
        }.joined(separator: "\n")
    }
}
