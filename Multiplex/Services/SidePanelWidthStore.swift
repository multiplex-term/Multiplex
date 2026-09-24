import CoreGraphics
import Foundation
import Observation

/// Remembered side-panel widths, per platform and device-local.
@MainActor
@Observable
final class SidePanelWidthStore {
    static let shared = SidePanelWidthStore()

    private static let iPadKey = "MultiplexSidePanelWidth.iPad"
    private static let visionOSKey = "MultiplexSidePanelWidth.visionOS"
    private static let visionOverhangKey = "MultiplexSidePanelOverhang.visionOS"

    private let defaults: UserDefaults
    private var iPadWidth: CGFloat
    private var visionOSWidth: CGFloat
    /// visionOS: how far the card's right edge sits past the glass's trailing
    /// edge (negative = inside the glass). Moved by the right handle.
    private(set) var visionOverhang: CGFloat

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        iPadWidth = Self.storedWidth(for: .iPad, defaults: defaults)
        visionOSWidth = Self.storedWidth(for: .visionOS, defaults: defaults)
        visionOverhang = (defaults.object(forKey: Self.visionOverhangKey) as? Double)
            .map { SidePanelWidth.clampedVisionOverhang(CGFloat($0)) }
            ?? SidePanelWidth.defaultVisionOverhang
    }

    /// The visionOS card's full geometry in at most two writes. Each value is
    /// kept sane on its own; how the pair fits the live window is the strip's
    /// business (`SidePanelWidth.clampedVisionGeometry`).
    func setVisionGeometry(width: CGFloat, overhang: CGFloat) {
        let clampedWidth = SidePanelWidth.clampedVision(width)
        if clampedWidth != visionOSWidth {
            visionOSWidth = clampedWidth
            defaults.set(Double(clampedWidth), forKey: Self.visionOSKey)
        }
        let clampedOverhang = SidePanelWidth.clampedVisionOverhang(overhang)
        if clampedOverhang != visionOverhang {
            visionOverhang = clampedOverhang
            defaults.set(Double(clampedOverhang), forKey: Self.visionOverhangKey)
        }
    }

    func width(for platform: SidePanelPlatform) -> CGFloat {
        switch platform {
        case .iPad:
            iPadWidth
        case .visionOS:
            visionOSWidth
        }
    }

    func setWidth(_ width: CGFloat, for platform: SidePanelPlatform) {
        guard platform == .iPad else {
            return setVisionGeometry(width: width, overhang: visionOverhang)
        }
        let normalized = SidePanelWidth.clampedStored(width, for: .iPad)
        guard normalized != iPadWidth else { return }
        iPadWidth = normalized
        defaults.set(Double(normalized), forKey: Self.iPadKey)
    }

    private static func key(for platform: SidePanelPlatform) -> String {
        platform == .iPad ? iPadKey : visionOSKey
    }

    private static func storedWidth(for platform: SidePanelPlatform, defaults: UserDefaults) -> CGFloat {
        guard let stored = defaults.object(forKey: key(for: platform)) as? Double else {
            return SidePanelWidth.defaultWidth(for: platform)
        }
        return SidePanelWidth.clampedStored(CGFloat(stored), for: platform)
    }
}
