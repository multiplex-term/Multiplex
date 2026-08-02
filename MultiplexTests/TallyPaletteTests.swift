import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class TallyPaletteTests: XCTestCase {
    func testGlassTokensResolveOnlyForTheDarkGlassTrait() throws {
        guard GlassPrototype.enabled else { return }
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let darkGlass = dark.replacing(GlassAppearanceTrait.self, value: true)

        try assert(
            UIKitChassis.bezel,
            resolvesTo: 0xFFFFFF,
            alpha: 0.05,
            traits: darkGlass
        )
        try assert(
            UIKitChassis.signal2,
            resolvesTo: 0xEEF2F5,
            alpha: 0.60,
            traits: darkGlass
        )

        try assert(
            UIKitChassis.bezel,
            resolvesTo: 0x26282B,
            alpha: 1,
            traits: dark
        )

        let lightGlass = UITraitCollection(userInterfaceStyle: .light)
            .replacing(GlassAppearanceTrait.self, value: true)
        try assert(
            UIKitChassis.bezel,
            resolvesTo: 0xF0F3F7,
            alpha: 1,
            traits: lightGlass
        )
    }

    func testDeferredAppearanceRefreshReappliesMountedLabelInk() async {
        let controller = UIViewController()
        controller.loadViewIfNeeded()
        let plain = PlainInkWriteProbeLabel()
        plain.text = "Plain"
        plain.textColor = TallyPalette.signal2
        let attributed = AttributedInkWriteProbeLabel()
        attributed.attributedText = NSAttributedString(
            string: "Tracked",
            attributes: [.foregroundColor: TallyPalette.signal2]
        )
        controller.view.addSubview(plain)
        controller.view.addSubview(attributed)
        plain.resetWriteCount()
        attributed.resetWriteCount()

        controller.overrideUserInterfaceStyle = .light
        controller.refreshDynamicTextColorsAfterTraitPropagation()
        for _ in 0..<4 { await Task.yield() }

        XCTAssertGreaterThan(plain.textColorWriteCount, 0)
        XCTAssertGreaterThan(attributed.attributedTextWriteCount, 0)
    }

    private func assert(
        _ color: UIColor,
        resolvesTo hex: UInt32,
        alpha expectedAlpha: CGFloat,
        traits: UITraitCollection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let resolved = color.resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(
            resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha),
            file: file,
            line: line
        )
        XCTAssertEqual(red, CGFloat((hex >> 16) & 0xFF) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(green, CGFloat((hex >> 8) & 0xFF) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(blue, CGFloat(hex & 0xFF) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(alpha, expectedAlpha, accuracy: 0.001, file: file, line: line)
    }
}

@MainActor
private final class PlainInkWriteProbeLabel: UILabel {
    private(set) var textColorWriteCount = 0

    override var textColor: UIColor! {
        didSet { textColorWriteCount += 1 }
    }

    func resetWriteCount() {
        textColorWriteCount = 0
    }
}

@MainActor
private final class AttributedInkWriteProbeLabel: UILabel {
    private(set) var attributedTextWriteCount = 0

    override var attributedText: NSAttributedString? {
        didSet { attributedTextWriteCount += 1 }
    }

    func resetWriteCount() {
        attributedTextWriteCount = 0
    }
}
