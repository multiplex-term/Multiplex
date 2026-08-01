import UIKit
import XCTest
@testable import Multiplex

@MainActor
final class TallyPaletteTests: XCTestCase {
    func testUIKitPalettePreservesEveryTallyLightAndDarkToken() throws {
        let tokens: [(UIColor, UInt32, UInt32)] = [
            (TallyPalette.bezel, 0xF0F3F7, 0x26282B),
            (TallyPalette.bezelHi, 0xCDD3DC, 0x33363A),
            (TallyPalette.screen, 0xF9FBFD, 0x0A0B0C),
            (TallyPalette.screenHatch, 0xEDF0F4, 0x101114),
            (TallyPalette.tally, 0xC13439, 0xE5484D),
            (TallyPalette.caution, 0x966618, 0xE0A33E),
            (TallyPalette.ok, 0x3E7C58, 0x7FBF9A),
            (TallyPalette.signal, 0x191E25, 0xF2F3F4),
            (TallyPalette.signal2, 0x515C69, 0x9BA1A6),
            (TallyPalette.signal3, 0x87919E, 0x5C6166),
            (TallyPalette.customCommand, 0x75654C, 0xB9AA98),
            (TallyPalette.miniText, 0x3A434E, 0xC8D2D6),
        ]

        for (color, light, dark) in tokens {
            try assert(color, resolvesTo: light, alpha: 1, style: .light)
            try assert(color, resolvesTo: dark, alpha: 1, style: .dark)
        }
    }

    func testUIKitPalettePreservesAppearanceSpecificShadowStrength() throws {
        try assert(
            TallyPalette.shadowAmbient,
            resolvesTo: 0x2C3644,
            alpha: 0.16,
            style: .light
        )
        try assert(
            TallyPalette.shadowAmbient,
            resolvesTo: 0x000000,
            alpha: 0.34,
            style: .dark
        )
        try assert(
            TallyPalette.shadowContact,
            resolvesTo: 0x2C3644,
            alpha: 0.13,
            style: .light
        )
        try assert(
            TallyPalette.shadowContact,
            resolvesTo: 0x000000,
            alpha: 0.18,
            style: .dark
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
        style: UIUserInterfaceStyle,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let resolved = color.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: style)
        )
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
