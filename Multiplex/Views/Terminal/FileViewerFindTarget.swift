import UIKit

/// A ▤ screen an open find can read: the code / diff / source text screen
/// (one run), or the rendered Markdown preview (one run per text block). The
/// pane drives the query, the readout, and stepping; the screen owns its
/// text, its washes, and how a hit is brought on screen.
@MainActor
protocol FileViewerFindTarget: AnyObject {
    /// What a find searches — nil while the screen holds no text yet.
    var findCorpus: FileViewerFindCorpus? { get }
    /// Fired when the corpus changes under an open find (a rescale, an
    /// appearance flip, a QUIET watch swap, a picture shown in place).
    var findCorpusDidChange: (() -> Void)? { get set }
    /// Washes `ranges` (corpus offsets), `current` stronger.
    func setFindMatches(_ ranges: [NSRange], current: Int?)
    /// Brings a hit on screen: untouched if already in view, else centered.
    func revealFindMatch(_ index: Int)
    /// Corpus offset where the reader is — a fresh search lands at or after it.
    func firstVisibleFindOffset() -> Int
}

extension FileViewerTextView: FileViewerFindTarget {
    var findCorpus: FileViewerFindCorpus? {
        content.map { FileViewerFindCorpus(text: $0.text.string) }
    }

    var findCorpusDidChange: (() -> Void)? {
        get { contentDidChange }
        set { contentDidChange = newValue }
    }

    func firstVisibleFindOffset() -> Int { firstVisibleOffset() }
}

/// The find washes for one rendered-Markdown text surface: decor BEHIND the
/// TextKit canvas (glyphs and the selection draw over it, and a copy never
/// carries it), so a hit reads the same as on the code screen. It lives
/// inside the text view, so a fence or table scrolled sideways carries its
/// washes with it and its own clipping trims them.
@MainActor
final class FileViewerFindWashView: UIView {
    private weak var textView: UITextView?
    /// Ranges in the text view's own offsets.
    private(set) var hits: [NSRange] = []
    private(set) var current: Int?

    /// The two inks every ▤ find wash wears.
    static func ink(current: Bool, traits: UITraitCollection) -> UIColor {
        TallyPalette.caution.withAlphaComponent(current ? 0.7 : 0.28)
            .resolvedColor(with: traits)
    }

    private init(textView: UITextView) {
        self.textView = textView
        super.init(frame: textView.bounds)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    static func existing(on textView: UITextView) -> FileViewerFindWashView? {
        textView.subviews.lazy.compactMap { $0 as? FileViewerFindWashView }.first
    }

    /// Washes `hits` on `textView`; an empty list removes the decor.
    static func apply(_ hits: [NSRange], current: Int?, on textView: UITextView) {
        if hits.isEmpty {
            existing(on: textView)?.removeFromSuperview()
            return
        }
        let wash = existing(on: textView) ?? {
            let wash = FileViewerFindWashView(textView: textView)
            textView.insertSubview(wash, at: 0)
            return wash
        }()
        wash.hits = hits
        wash.current = current
        wash.track()
    }

    /// Re-fits the decor to its text view after a reflow or a re-feed.
    static func track(on textView: UITextView) {
        existing(on: textView)?.track()
    }

    private func track() {
        guard let textView else { return }
        frame = CGRect(origin: .zero, size: textView.bounds.size)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let textView else { return }
        for (index, range) in hits.enumerated() {
            Self.ink(current: index == current, traits: traitCollection).setFill()
            for segment in Self.rects(for: range, in: textView) where segment.intersects(rect) {
                UIBezierPath(roundedRect: segment.insetBy(dx: -1, dy: 0), cornerRadius: 2).fill()
            }
        }
    }

    /// One rect per visual line a range covers, in the text view's bounds.
    static func rects(for range: NSRange, in textView: UITextView) -> [CGRect] {
        guard let start = textView.position(
                  from: textView.beginningOfDocument, offset: range.location
              ),
              let end = textView.position(from: start, offset: range.length),
              let textRange = textView.textRange(from: start, to: end)
        else { return [] }
        return textView.selectionRects(for: textRange).map(\.rect).filter {
            !$0.isNull && !$0.isInfinite && $0.width > 0 && $0.height > 0
        }
    }
}
