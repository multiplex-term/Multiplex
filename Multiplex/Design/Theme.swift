import UIKit

/// UIKit-native source of truth for the TALLY palette. Every token has a
/// light and dark rendition and resolves through the current trait collection.
enum TallyPalette {
    static let chassis = UIColor(named: "AppBackground")
        ?? UIColor(light: 0xE4E8EE, dark: 0x17181A)
    static let bezel = UIColor(light: 0xF0F3F7, dark: 0x26282B)
    static let bezelHi = UIColor(light: 0xCDD3DC, dark: 0x33363A)
    static let screen = UIColor(light: 0xF9FBFD, dark: 0x0A0B0C)
    static let screenHatch = UIColor(light: 0xEDF0F4, dark: 0x101114)

    static let tally = UIColor(light: 0xC13439, dark: 0xE5484D)
    static let caution = UIColor(light: 0x966618, dark: 0xE0A33E)
    static let ok = UIColor(light: 0x3E7C58, dark: 0x7FBF9A)

    static let signal = UIColor(light: 0x191E25, dark: 0xF2F3F4)
    static let signal2 = UIColor(light: 0x515C69, dark: 0x9BA1A6)
    static let signal3 = UIColor(light: 0x87919E, dark: 0x5C6166)
    static let customCommand = UIColor(light: 0x75654C, dark: 0xB9AA98)
    static let miniText = UIColor(light: 0x3A434E, dark: 0xC8D2D6)

    static let shadowAmbient = UIColor(
        light: 0x2C3644,
        lightAlpha: 0.16,
        dark: 0x000000,
        darkAlpha: 0.34
    )
    static let shadowContact = UIColor(
        light: 0x2C3644,
        lightAlpha: 0.13,
        dark: 0x000000,
        darkAlpha: 0.18
    )
}

/// Shared UIKit typography metrics for the TALLY identity.
enum Theme {
    /// iOS-on-Mac paints the iPad point grid at 77%, so fixed chassis type is
    /// scaled to preserve its physical size there. iPad and visionOS stay 1:1.
    static let typeScale: CGFloat = ProcessInfo.processInfo.isiOSAppOnMac ? 1.3 : 1.0
}

// Terminal surface colors are the user's choice, not identity. They live in
// TerminalTheme and are selected through ThemeStore.
extension UIColor {
    convenience init(_ themeColor: ThemeColor) {
        self.init(
            red: CGFloat(themeColor.red) / 255,
            green: CGFloat(themeColor.green) / 255,
            blue: CGFloat(themeColor.blue) / 255,
            alpha: 1
        )
    }

    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    convenience init(light: UInt32, dark: UInt32) {
        self.init { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        }
    }

    convenience init(
        light: UInt32,
        lightAlpha: CGFloat,
        dark: UInt32,
        darkAlpha: CGFloat
    ) {
        self.init { traits in
            let isDark = traits.userInterfaceStyle == .dark
            return UIColor(hex: isDark ? dark : light)
                .withAlphaComponent(isDark ? darkAlpha : lightAlpha)
        }
    }
}
