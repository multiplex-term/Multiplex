import CoreGraphics
import Foundation

/// The file viewer's reader-chosen text size, as a multiplier over the
/// authored content sizes. Pure: the ladder, its clamp, and how a continuous
/// pinch lands on a rung.
///
/// Deliberately a small ladder rather than a free multiplier — every rebuild
/// re-assembles the whole attributed screen (a truncated file is 1.5 MB), so a
/// pinch must cross a rung before it costs anything. It multiplies the
/// *authored* size only; `Theme.typeScale` still applies on top, so the Mac's
/// point-grid correction and the reader's choice never compound into each
/// other's job.
enum FileViewerTextScale {
    static let `default`: CGFloat = 1

    /// Roughly a 1.15× ladder around the authored default, cut off where 11 pt
    /// code stops being legible (8.25 pt) and where a phone pane holds too few
    /// columns to read code at all (22 pt).
    static let steps: [CGFloat] = [0.75, 0.85, 1, 1.15, 1.3, 1.5, 1.75, 2]

    static var minimum: CGFloat { steps[0] }
    static var maximum: CGFloat { steps[steps.count - 1] }

    static func clamped(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return `default` }
        return min(maximum, max(minimum, value))
    }

    /// The rung nearest `value` — how a continuous pinch magnitude becomes a
    /// size the screens can be rebuilt at.
    static func snapped(_ value: CGFloat) -> CGFloat {
        let target = clamped(value)
        return steps.min { abs($0 - target) < abs($1 - target) } ?? `default`
    }

    /// One rung up (`delta > 0`) or down, from wherever `value` sits. A value
    /// between rungs moves to the next rung in that direction, so a pinch
    /// followed by a button press never stalls.
    static func stepping(_ value: CGFloat, by delta: Int) -> CGFloat {
        guard delta != 0 else { return clamped(value) }
        let current = clamped(value)
        if delta > 0 {
            return steps.first { $0 > current + 0.001 } ?? maximum
        }
        return steps.last { $0 < current - 0.001 } ?? minimum
    }

    static func canStep(_ value: CGFloat, by delta: Int) -> Bool {
        stepping(value, by: delta) != clamped(value)
    }

    /// Rail readout: `100%`, `130%`.
    static func percentLabel(_ value: CGFloat) -> String {
        "\(Int((clamped(value) * 100).rounded()))%"
    }
}
