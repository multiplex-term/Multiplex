import CoreGraphics
import Foundation

/// The iPad/iPhone key rail's slots — one per key face the rail can carry,
/// listed in the shipped order. A slot names a POSITION, never its occupant:
/// `keyboard` is the keyboard-toggle / dictation-mic slot (whichever the
/// hardware picks), `shortcuts` the TMUX / HRDR slot — so an order survives a
/// hardware keyboard coming and going and a backend switch unchanged. The raw
/// values are the persisted tokens; never rename one.
enum KeyBarSlot: String, CaseIterable, Hashable {
    case escape
    case control
    case tab
    case tilde
    case pipe
    case slash
    case hyphen
    case pageUp
    case pageDown
    case left
    case up
    case down
    case right
    case returnKey = "return"
    case talkback
    case keyboard
    case shortcuts
}

/// The user's order over every slot — always a full permutation of
/// `KeyBarSlot.allCases`, whatever was stored (unknown tokens drop,
/// duplicates drop, missing slots append in shipped order).
///
/// A tier renders the subsequence it carries (`arrange`); the gaps stay
/// where the tier puts them (three keys · the symbols · the rest), so the
/// order permutes keys across a tier's slots and never changes the row's
/// rhythm or its width ladder.
struct KeyBarOrder: Equatable {
    private(set) var slots: [KeyBarSlot]

    /// The shipped order: `KeyBarSlot.allCases` as declared.
    static let standard = KeyBarOrder(slots: KeyBarSlot.allCases)

    init(slots: [KeyBarSlot]) {
        self.slots = Self.normalized(slots)
    }

    /// From persisted tokens; anything unrecognized is ignored.
    init(tokens: [String]) {
        self.init(slots: tokens.compactMap(KeyBarSlot.init(rawValue:)))
    }

    var tokens: [String] { slots.map(\.rawValue) }

    var isStandard: Bool { self == .standard }

    /// Dedupe, then append every slot the list forgot, in shipped order.
    static func normalized(_ slots: [KeyBarSlot]) -> [KeyBarSlot] {
        var seen = Set<KeyBarSlot>()
        var result = slots.filter { seen.insert($0).inserted }
        result += KeyBarSlot.allCases.filter { !seen.contains($0) }
        return result
    }

    /// The keys a tier carries, in this order.
    func arrange(_ present: [KeyBarSlot]) -> [KeyBarSlot] {
        let present = Set(present)
        return slots.filter { present.contains($0) }
    }

    /// Moves one visible key to a new index among the keys the tier shows
    /// (`visible`, in its current arrangement). Hidden slots — keys a
    /// narrower tier dropped — keep their places: a rightward move lands the
    /// key just after the visible neighbour it passed last, a leftward move
    /// just before it, so only the dragged key moves in the full order and
    /// every wider tier shows it beside the key it was dropped against.
    func moving(
        _ slot: KeyBarSlot,
        toVisibleIndex target: Int,
        among visible: [KeyBarSlot]
    ) -> KeyBarOrder {
        guard let from = visible.firstIndex(of: slot), visible.count > 1 else { return self }
        let to = min(max(0, target), visible.count - 1)
        guard to != from else { return self }
        var remaining = visible
        remaining.remove(at: from)
        var rest = slots.filter { $0 != slot }
        let anchor: Int
        if to > from {
            let neighbour = remaining[to - 1]
            anchor = (rest.firstIndex(of: neighbour) ?? rest.count - 1) + 1
        } else {
            let neighbour = remaining[to]
            anchor = rest.firstIndex(of: neighbour) ?? 0
        }
        rest.insert(slot, at: anchor)
        return KeyBarOrder(slots: rest)
    }
}

/// Which item a drop lands on, for any row of drop targets (the tab strip,
/// the iPad key rail, the visionOS slabs — frames in one coordinate space):
/// the nearest OTHER item by centre along the row, so a drop over a gap
/// lands beside the item it is nearer. Over the dragged item's own slot
/// (widened by `slack` a side) there is nothing to land on.
enum RowDropGeometry {
    static func dropTargetIndex(
        x: CGFloat,
        restingFrames: [CGRect],
        sourceIndex: Int,
        slack: CGFloat = 3
    ) -> Int? {
        guard restingFrames.count > 1 else { return nil }
        if restingFrames.indices.contains(sourceIndex) {
            let own = restingFrames[sourceIndex]
            if x >= own.minX - slack, x <= own.maxX + slack { return nil }
        }
        return restingFrames.indices
            .filter { $0 != sourceIndex }
            .min { abs(x - restingFrames[$0].midX) < abs(x - restingFrames[$1].midX) }
    }
}
