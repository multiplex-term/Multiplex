#if os(visionOS)
import SwiftTerm
import UIKit

/// Gaze hover for links on visionOS.
///
/// The system renders gaze hover out of process — the app never learns where
/// the user looks — so the only way to light a URL under the eye is to stand
/// hover-effect regions over the places links actually are. This overlay
/// rides as a subview of the `TerminalView` (an ancestor's gesture
/// recognizers still see touches on it, so pans/scrolls over a link keep
/// working) and rebuilds its regions from `visibleLinkRegions()` — the
/// fork's visible-screen enumerator — debounced behind output flushes and
/// scrolls.
///
/// A region is hit-testable by necessity (hover regions are derived from hit
/// testing), which makes a lit link pinch-activatable: on visionOS the glow
/// IS the system's "this activates" affordance, so a pinch runs the exact
/// same confirm path a long press does — the sheet, never the page. Long
/// press on a region stays the sheet too. Only targets the app would
/// actually confirm get a region (`TerminalLink.resolve` non-nil), so
/// filesystem paths in build logs never glow.
final class TerminalLinkHoverOverlay: UIView {
    /// Runs the pane's confirm path (`TerminalSessionController.activateLink`).
    var activate: ((String) -> Void)?

    private weak var terminalView: TerminalView?
    private var refreshScheduled = false

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    /// The overlay itself is transparent to input — only its regions hit.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view === self ? nil : view
    }

    /// Debounced: output arrives in bursts, and one rebuild per settled
    /// screen is enough for an affordance.
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            refreshScheduled = false
            refresh()
        }
    }

    func clearRegions() {
        subviews.forEach { $0.removeFromSuperview() }
    }

    private func refresh() {
        guard let terminalView, window != nil, !isHidden else {
            clearRegions()
            return
        }
        // Track the scroll view's bounds so region frames land in the same
        // space `calculateTapHit` reads.
        frame = terminalView.bounds
        clearRegions()
        for region in terminalView.visibleLinkRegions() {
            // Only what the app would confirm gets an affordance — paths
            // and prose stay dark.
            guard TerminalLink.resolve(region.target) != nil else { continue }
            for rect in region.rects {
                let control = LinkHoverRegion(target: region.target)
                control.frame = rect.insetBy(dx: -2, dy: -1)
                control.onActivate = { [weak self] target in
                    self?.activate?(target)
                }
                addSubview(control)
            }
        }
    }
}

/// One lit rectangle over one row-segment of a link. Square-chassis hover
/// shape per the app's hover discipline; tap and long press both run the
/// confirm path (a drag is claimed by the terminal's own recognizers and
/// cancels the touch, so scrolling over links is untouched).
private final class LinkHoverRegion: UIControl {
    let target: String
    var onActivate: ((String) -> Void)?

    init(target: String) {
        self.target = target
        super.init(frame: .zero)
        backgroundColor = .clear
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 4))
        addTarget(self, action: #selector(activateTarget), for: .touchUpInside)
        let longPress = UILongPressGestureRecognizer(
            target: self,
            action: #selector(longPressed(_:))
        )
        addGestureRecognizer(longPress)
        isAccessibilityElement = true
        accessibilityTraits = .link
        accessibilityLabel = target
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func activateTarget() {
        onActivate?(target)
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        onActivate?(target)
    }
}
#endif
