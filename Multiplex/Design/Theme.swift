import SwiftUI

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

    // MARK: Terminal surface
    static let terminalBackground: (red: UInt8, green: UInt8, blue: UInt8) = (0x0C, 0x0E, 0x13)
    static let terminalForeground: (red: UInt8, green: UInt8, blue: UInt8) = (0xE9, 0xE4, 0xD8)
    static let terminalCursor: (red: UInt8, green: UInt8, blue: UInt8) = (0xFF, 0xB0, 0x00)

    /// 16-color ANSI palette tuned to sit on `ink` — warm signal colors, cool grays.
    static let ansiPalette: [UInt32] = [
        0x1B202B, // 0 black
        0xEA6962, // 1 red
        0xA9B665, // 2 green
        0xD8A657, // 3 yellow
        0x7DAEA3, // 4 blue
        0xD3869B, // 5 magenta
        0x89B482, // 6 cyan
        0xC5BDA8, // 7 white
        0x566073, // 8 bright black
        0xF28B82, // 9 bright red
        0xB8C77D, // 10 bright green
        0xE9B858, // 11 bright yellow
        0x93C0B5, // 12 bright blue
        0xE19BB0, // 13 bright magenta
        0x9CC79A, // 14 bright cyan
        0xE9E4D8, // 15 bright white
    ]
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
