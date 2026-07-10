import SwiftUI
import UIKit

/// Multiplex design tokens — the TALLY identity (see DESIGN.md).
/// A broadcast monitor wall: graphite chassis, screens darker than the
/// chassis that frames them, and color spent on state, never decoration.
enum Theme {
    // MARK: Chassis (ground)
    /// Window ground — warm graphite, deliberately not blue-black.
    static let chassis = Color(hex: 0x17181A)
    /// Raised surfaces: tiles, rails, the UMD bar.
    static let bezel = Color(hex: 0x26282B)
    /// Borders, dividers, inactive bezel segments.
    static let bezelHi = Color(hex: 0x33363A)
    /// The darkest thing on screen: miniature + terminal grounds. Screens
    /// sit *inside* lighter chassis — that inversion is the identity.
    static let screen = Color(hex: 0x0A0B0C)

    // MARK: Signal (state only — a color here always means something)
    /// Live/attached lamp — broadcast "on air". Always captioned (LIVE),
    /// never used for errors, never used as an accent.
    static let tally = Color(hex: 0xE5484D)
    /// Bell/activity ticks, connecting states. Small doses.
    static let caution = Color(hex: 0xE0A33E)
    /// Connected dot on host rails.
    static let ok = Color(hex: 0x7FBF9A)

    // MARK: Text on chassis
    static let signal = Color(hex: 0xF2F3F4)
    static let signal2 = Color(hex: 0x9BA1A6)
    static let signal3 = Color(hex: 0x5C6166)
    /// Dimmed mono text inside miniature screens.
    static let miniText = Color(hex: 0xC8D2D6)
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
}

// MARK: - Type roles

extension Font {
    /// Identity voice: host names, session names, addresses, counts,
    /// telemetry, and everything inside a screen.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
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
