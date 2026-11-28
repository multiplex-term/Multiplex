import UIKit.UIGestureRecognizerSubclass

/// Recognizes the moment a touch lands and never holds it: nothing is
/// cancelled or delayed, so every other gesture on the view carries on as
/// if this were not there. A tap would be too late for its one use — a
/// pane has to take the tab's focus before a long press on it resolves.
final class TouchDownGestureRecognizer: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if state == .possible { state = .recognized }
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}
