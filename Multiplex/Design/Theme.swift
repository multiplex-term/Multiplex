import SwiftUI
import UIKit

/// Multiplex design tokens. See DESIGN.md.
/// One accent — P3 phosphor amber — on deep blue-black ink.
enum Theme {
    // MARK: Ground
    static let ink = Color(hex: 0x0C0E13)
    static let inkRaised = Color(hex: 0x141823)
    static let line = Color(hex: 0x262C3D)

    // MARK: Signal
    static let phosphor = Color(hex: 0xFFB000)
    static let phosphorDim = Color(hex: 0x8F6A1D)

    // MARK: Text on ink
    static let textPrimary = Color(hex: 0xE9E4D8)
    static let textSecondary = Color(hex: 0x98A1B4)
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
    /// Identity voice: host names, session names, addresses, counts.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Small-caps eyebrow label: `HOSTS`, `TMUX SESSIONS`.
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
