import Foundation

/// Find on the ▤ text screens (code, diff, markdown source): a literal,
/// case-insensitive search over exactly the text the selectable screen holds,
/// so a match's range is a range the screen can wash and scroll to. Ranges are
/// UTF-16 (`NSRange`) because that is what TextKit offsets count.
///
/// Literal on purpose: a reader's query is a word they can see, not a
/// pattern, and `.` / `(` are everywhere in code.
enum FileViewerFind {
    struct Result: Equatable {
        var ranges: [NSRange]
        /// The search stopped at `limit`: the count reads `limit+`, never a
        /// number that pretends to be the whole file.
        var truncated: Bool

        static let empty = Result(ranges: [], truncated: false)
    }

    /// Enough for any count a reader steps through; a one-letter query over a
    /// 1.5 MB file would otherwise allocate hundreds of thousands of ranges.
    static let defaultLimit = 5000

    /// Every non-overlapping occurrence of `query` in `text`, in order.
    /// An empty query matches nothing (the bar reads blank, not "0 OF 0").
    static func matches(
        of query: String,
        in text: String,
        limit: Int = defaultLimit
    ) -> Result {
        let haystack = text as NSString
        var ranges: [NSRange] = []
        let truncated = collect(
            query, in: haystack,
            within: NSRange(location: 0, length: haystack.length),
            limit: limit, into: &ranges
        )
        return Result(ranges: ranges, truncated: truncated)
    }

    /// Appends the hits inside `within` to `ranges`; true when `limit` cut
    /// the search short.
    fileprivate static func collect(
        _ query: String,
        in haystack: NSString,
        within: NSRange,
        limit: Int,
        into ranges: inout [NSRange]
    ) -> Bool {
        guard !query.isEmpty, limit > 0 else { return false }
        let options: NSString.CompareOptions = [.caseInsensitive]
        let end = NSMaxRange(within)
        var location = within.location
        while location < end {
            let found = haystack.range(
                of: query,
                options: options,
                range: NSRange(location: location, length: end - location)
            )
            guard found.location != NSNotFound, found.length > 0 else { break }
            if ranges.count >= limit { return true }
            ranges.append(found)
            location = NSMaxRange(found)
        }
        return false
    }

    /// The match a fresh search lands on: the first one at or after `offset`
    /// (where the reader was), wrapping to the first match.
    static func index(atOrAfter offset: Int, in ranges: [NSRange]) -> Int? {
        guard !ranges.isEmpty else { return nil }
        var low = 0, high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].location < offset { low = mid + 1 } else { high = mid }
        }
        return low < ranges.count ? low : 0
    }

    /// One step forward or back, wrapping at either end.
    static func step(from index: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return delta < 0 ? count - 1 : 0 }
        return ((index + delta) % count + count) % count
    }

    /// The bar's readout: `3/41`, `3/5000+` when truncated, `NO MATCH` for a
    /// query that found nothing, blank for no query.
    static func countText(current: Int?, result: Result, query: String) -> String {
        guard !query.isEmpty else { return "" }
        guard !result.ranges.isEmpty else { return "NO MATCH" }
        let total = "\(result.ranges.count)" + (result.truncated ? "+" : "")
        let position = current.map { "\($0 + 1)" } ?? "–"
        return "\(position)/\(total)"
    }
}

/// What a find searches: one or more runs of text, each a separate surface on
/// screen, joined into a single offset space so ranges, landing, and stepping
/// stay plain `NSRange` arithmetic. A code screen is one run; rendered
/// Markdown is one run per text block (a paragraph, a heading, a fence, a
/// table cell). A hit never spans two runs — the reader can't see a word
/// that starts in one paragraph and ends in the next.
struct FileViewerFindCorpus: Equatable {
    /// The runs joined by `separator`.
    let text: String
    /// Each run's first UTF-16 offset in `text`, ascending.
    let runStarts: [Int]
    let runLengths: [Int]

    static let separator = "\n"

    init(runs: [String]) {
        var starts: [Int] = []
        var lengths: [Int] = []
        var offset = 0
        for run in runs {
            let length = (run as NSString).length
            starts.append(offset)
            lengths.append(length)
            offset += length + 1
        }
        text = runs.joined(separator: Self.separator)
        runStarts = starts
        runLengths = lengths
    }

    init(text: String) { self.init(runs: [text]) }

    var length: Int { (text as NSString).length }

    func matches(of query: String, limit: Int = FileViewerFind.defaultLimit) -> FileViewerFind.Result {
        let haystack = text as NSString
        var ranges: [NSRange] = []
        var truncated = false
        for (start, length) in zip(runStarts, runLengths) where !truncated {
            truncated = FileViewerFind.collect(
                query, in: haystack,
                within: NSRange(location: start, length: length),
                limit: limit, into: &ranges
            )
        }
        return FileViewerFind.Result(ranges: ranges, truncated: truncated)
    }

    /// The run a range sits in, and the range in that run's own offsets.
    func locate(_ range: NSRange) -> (run: Int, range: NSRange)? {
        var low = 0, high = runStarts.count
        while low < high {
            let mid = (low + high) / 2
            if runStarts[mid] <= range.location { low = mid + 1 } else { high = mid }
        }
        let run = low - 1
        guard runStarts.indices.contains(run) else { return nil }
        let local = NSRange(location: range.location - runStarts[run], length: range.length)
        guard NSMaxRange(local) <= runLengths[run] else { return nil }
        return (run, local)
    }
}
