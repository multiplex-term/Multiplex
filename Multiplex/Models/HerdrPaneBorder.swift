import Foundation

/// Decides whether a terminal cell can be a herdr pane border — the gate for
/// claiming a long press as a remote resize drag instead of the selection
/// menu.
///
/// herdr draws its pane dividers with Unicode box-drawing glyphs and moves
/// them by mouse drag (verified against herdr 0.7.5: an attached client's SGR
/// press → motion → release on a divider column changes the split ratio). The
/// app cannot know where the dividers are — layout lives host-side — but the
/// glyph under the finger is a local, immediate discriminator: every divider
/// cell is a box-drawing character, so everything else keeps the long press's
/// existing meaning (links, the selection menu).
///
/// Accepted trade: a TUI running *inside* a pane can draw its own box borders
/// (an agent's input frame), and a long press there also becomes a mouse
/// drag. herdr receives it as an ordinary in-pane drag — selection or a
/// forwarded mouse event, never destructive — and a plain long press one cell
/// away still reaches the menu.
enum HerdrPaneBorder {
    /// The Unicode Box Drawing block (U+2500–U+257F): light/heavy/double
    /// lines, every junction, and the rounded corners herdr's rounded panes
    /// use.
    static func isBorderCell(_ content: Character?) -> Bool {
        guard let content, let scalar = content.unicodeScalars.first,
              content.unicodeScalars.count == 1
        else { return false }
        return (0x2500...0x257F).contains(scalar.value)
    }

    /// The vertical-divider glyphs a headless validation drag can aim at —
    /// deterministic targets for a horizontal drag (`debug.resizedrag`).
    static func isVerticalBar(_ content: Character?) -> Bool {
        guard let content else { return false }
        return content == "│" || content == "┃" || content == "║"
    }
}
