import Foundation

/// The wrapped-row glue detector: decides whether a pressed match that
/// crossed a hard-wrap seam is one wrapped target or a sentence's tail glued
/// to the path or address below it.
///
/// The fork reassembles wrapped rows before matching — necessary, because a
/// long URL or path legitimately wraps — but a hard wrap leaves no space at
/// the seam, so a source line ending `…and` above `local-plan/x` reaches the
/// resolvers as `andlocal-plan/x`, one plausible-looking relative path. The
/// joined *text* cannot tell those apart (`andlocal-plan` is a legal
/// directory name); the seam position can, and the fork now hands it over
/// as per-row fragments.
///
/// The tell is the run of characters between the last space and the seam:
/// a genuine wrapped target contributes path/address structure there — a
/// `/` (`/Users/jhen/wor`⏎`kspace2/x`) or a `.` (`example.c`⏎`om/x`) —
/// while a glued sentence butts a plain word against the seam (`and`,
/// `table`). A word carrying neither means the rows below start their own
/// target, so resolution should begin at the seam.
///
/// Accepted trade, on record: a bare-relative path whose entire first
/// segment sat on the upper row (`local-p`⏎`lan/x`) is indistinguishable
/// from glue and gets cut to `lan/x` — wrong, but visible in the sheet's
/// editable field, and far rarer than hard-wrapped prose above a path
/// (any doc or agent transcript wrapped at pane width produces those).
enum WrappedRowGlue {
    /// The target to resolve *instead of* the joined text, cut at the first
    /// prose-glue seam. nil when no seam qualifies — resolve the join as
    /// always. Callers fall back to the join when the cut resolves to
    /// nothing; a wrong cut must not turn a working press into a dead one.
    static func cutTarget(fragments: [String]) -> String? {
        guard fragments.count >= 2 else { return nil }
        var prefix = ""
        for index in 0..<(fragments.count - 1) {
            prefix += fragments[index]
            // The chunk butting this seam: everything after the last space
            // (the whole prefix when it carries none).
            let chunk = prefix.lastIndex(of: " ").map {
                String(prefix[prefix.index(after: $0)...])
            } ?? prefix
            // Empty means the row ended on a space — no glue evidence, and
            // a spaced path can genuinely wrap right after its space.
            guard !chunk.isEmpty else { continue }
            if !chunk.contains("/"), !chunk.contains(".") {
                let suffix = fragments[(index + 1)...].joined()
                return suffix.isEmpty ? nil : suffix
            }
        }
        return nil
    }
}
