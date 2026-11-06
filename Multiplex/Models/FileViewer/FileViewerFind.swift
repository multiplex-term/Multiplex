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
        guard !query.isEmpty, limit > 0 else { return .empty }
        let haystack = text as NSString
        let options: NSString.CompareOptions = [.caseInsensitive]
        var ranges: [NSRange] = []
        var location = 0
        while location < haystack.length {
            let found = haystack.range(
                of: query,
                options: options,
                range: NSRange(location: location, length: haystack.length - location)
            )
            guard found.location != NSNotFound, found.length > 0 else { break }
            if ranges.count == limit {
                return Result(ranges: ranges, truncated: true)
            }
            ranges.append(found)
            location = NSMaxRange(found)
        }
        return Result(ranges: ranges, truncated: false)
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
