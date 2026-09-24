import UIKit

/// Pinch-to-resize for the file viewer's reading surfaces.
///
/// Every screen a pinch can land on rebuilds its whole attributed text (a
/// truncated file is 1.5 MB), so the gesture is *quantized*: the live
/// magnitude picks the nearest `FileViewerTextScale` rung and the store is
/// written only when the rung changes. A continuous multiplier would rebuild
/// on every touch delivery.
///
/// The recognizer holds its target weakly, so the installing view must keep
/// the returned object alive.
@MainActor
final class FileViewerTextScalePinch: NSObject {
    /// Designed-for-iPad reads a trackpad pinch as this gesture too, but the
    /// Mac's road is the rail's A− / A+ chips — a pointer user gets a button,
    /// which is also the only surface that states the current size there.
    static var isSupported: Bool { !ProcessInfo.processInfo.isiOSAppOnMac }

    private let store: FileViewerTextScaleStore
    private var scaleAtBegin = FileViewerTextScale.default

    private init(store: FileViewerTextScaleStore) {
        self.store = store
    }

    /// Installs the gesture and returns the handler to retain, or nil where
    /// the platform uses chips instead.
    @discardableResult
    static func install(
        on view: UIView,
        store: FileViewerTextScaleStore = .shared
    ) -> FileViewerTextScalePinch? {
        guard isSupported else { return nil }
        let handler = FileViewerTextScalePinch(store: store)
        let recognizer = UIPinchGestureRecognizer(
            target: handler,
            action: #selector(handlePinch)
        )
        view.addGestureRecognizer(recognizer)
        return handler
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            scaleAtBegin = store.scale
        case .changed:
            store.set(scaleAtBegin * recognizer.scale)
        default:
            break
        }
    }
}
