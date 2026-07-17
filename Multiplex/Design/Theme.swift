import SwiftUI
import UIKit

/// Multiplex design tokens — the TALLY identity (see DESIGN.md).
/// A broadcast monitor wall: graphite chassis, screens darker than the
/// chassis that frames them, and color spent on state, never decoration.
///
/// Every token carries a dark and a light rendition and resolves through the
/// trait collection, so the whole chassis follows the appearance chosen in
/// Settings (`ThemeStore.appearance` → `PlatformChrome`). The light chassis is
/// the "Frost" design — cool platinum, screens *brighter* than the frames
/// that hold them (the identity's inversion flips with the studio lights; the
/// Paper/Ivory alternates are recorded in DESIGN.md). State colors deepen in
/// light so the lamp captions keep the dark chassis's contrast ratio.
enum Theme {
    // MARK: Chassis (ground)
    /// Window ground — warm graphite in the dark, silver in the light,
    /// deliberately never blue-black. Lives in the asset catalog because the
    /// system launch screen shares it, so startup hands off without an
    /// opposite-polarity flash before SwiftUI paints the deck.
    static let chassis = Color("AppBackground")
    /// Raised surfaces: tiles, rails, the UMD bar.
    static let bezel = Color(light: 0xF0F3F7, dark: 0x26282B)
    /// Borders, dividers, inactive bezel segments — the visible line. It is
    /// the brightest chassis value in the dark and the darkest in the light;
    /// either way it is the edge that draws the hardware.
    static let bezelHi = Color(light: 0xCDD3DC, dark: 0x33363A)
    /// Miniature + input-well grounds. Dark: the darkest thing on screen —
    /// screens sit *inside* lighter chassis. Light: the brightest — a lit
    /// frost screen inside a platinum frame. The inversion is the identity.
    static let screen = Color(light: 0xF9FBFD, dark: 0x0A0B0C)
    /// The no-signal hatch stroke on `screen` (barely raised off it).
    static let screenHatch = Color(light: 0xEDF0F4, dark: 0x101114)

    // MARK: Signal (state only — a color here always means something)
    /// Live/attached lamp — broadcast "on air". Always captioned (LIVE),
    /// never used for errors, never used as an accent.
    static let tally = Color(light: 0xC13439, dark: 0xE5484D)
    /// Bell/activity ticks, connecting states. Small doses.
    static let caution = Color(light: 0x966618, dark: 0xE0A33E)
    /// Connected dot on host rails.
    static let ok = Color(light: 0x3E7C58, dark: 0x7FBF9A)

    // MARK: Text on chassis
    static let signal = Color(light: 0x191E25, dark: 0xF2F3F4)
    static let signal2 = Color(light: 0x515C69, dark: 0x9BA1A6)
    static let signal3 = Color(light: 0x87919E, dark: 0x5C6166)
    /// Warm neutral reserved for user-authored command copy. It distinguishes
    /// custom chips from the stock set without borrowing a semantic state
    /// color (tally/caution/ok) or making them read as more important.
    static let customCommand = Color(light: 0x75654C, dark: 0xB9AA98)
    /// Dimmed mono text inside miniature screens.
    static let miniText = Color(light: 0x3A434E, dark: 0xC8D2D6)

    // MARK: Type scale
    /// iOS-on-Mac ("Designed for iPad") paints the iPad point grid at 77%
    /// with no opt-out for non-game apps, so chassis type authored at
    /// 8–12 pt lands under 10 physical points there. Every fixed-size type
    /// role (`Font.mono`, `Font.ui`, `ChassisLabel`) multiplies by this
    /// scale to restore physical parity on the Mac; iPad and visionOS stay
    /// 1:1. Only type and type-locked accents (badge icon slot, lamp dot)
    /// scale — control chrome (padding, key sizes, switch tracks) keeps its
    /// authored geometry. Semantic text styles (`.footnote` …) keep Dynamic
    /// Type instead and are boosted once at the scene root (`PlatformChrome`).
    static let typeScale: CGFloat = ProcessInfo.processInfo.isiOSAppOnMac ? 1.3 : 1.0
}

// Terminal surface colors are the user's choice, not identity — they live in
// `TerminalTheme` (Models) and are selected through `ThemeStore`.

extension Color {
    init(_ themeColor: ThemeColor) {
        self.init(
            .sRGB,
            red: Double(themeColor.red) / 255,
            green: Double(themeColor.green) / 255,
            blue: Double(themeColor.blue) / 255
        )
    }
}

extension UIColor {
    convenience init(_ themeColor: ThemeColor) {
        self.init(
            red: CGFloat(themeColor.red) / 255,
            green: CGFloat(themeColor.green) / 255,
            blue: CGFloat(themeColor.blue) / 255,
            alpha: 1
        )
    }
}

extension ThemeColor {
    /// sRGB snapshot of a SwiftUI color — how ColorPicker output becomes a
    /// theme value. Opacity is discarded; terminals paint opaque cells.
    init?(_ color: Color) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        func unit(_ value: CGFloat) -> UInt8 {
            UInt8(max(0, min(255, (value * 255).rounded())))
        }
        self.init(red: unit(red), green: unit(green), blue: unit(blue))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// An appearance-following chassis token: resolves per trait collection,
    /// so UIKit-hosted chrome (popover backgrounds, the terminal gutter)
    /// adapts alongside SwiftUI when the color scheme changes.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Type roles

extension Font {
    /// Identity voice: host names, session names, addresses, counts,
    /// telemetry, and everything inside a screen. Sizes are authored in
    /// iPad points; `Theme.typeScale` restores physical size on iOS-on-Mac.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * Theme.typeScale, weight: weight, design: .monospaced)
    }

    /// Body/label voice for chassis chrome authored at a fixed point size —
    /// SF Pro riding the same platform type scale as `mono`. Use this instead
    /// of `.system(size:)` anywhere in app chrome; semantic text styles
    /// (`.footnote` …) stay as they are and scale via the scene root.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * Theme.typeScale, weight: weight)
    }
}

/// Small-caps eyebrow label for form sections: `TERMINAL THEME`.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .kerning(1.4)
            .foregroundStyle(.secondary)
    }
}

#if DEBUG
#Preview("Eyebrow") {
    Eyebrow("Terminal theme")
        .padding()
        .background(Theme.chassis)
        .preferredColorScheme(.dark)
}
#endif
