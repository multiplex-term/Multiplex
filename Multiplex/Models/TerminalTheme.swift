import Foundation

/// One sRGB color in a terminal theme. Serializes as a `#RRGGBB` hex string
/// so themes.json reads like any familiar palette file and can be hand-edited.
struct ThemeColor: Equatable, Hashable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ hex: UInt32) {
        self.init(
            red: UInt8((hex >> 16) & 0xFF),
            green: UInt8((hex >> 8) & 0xFF),
            blue: UInt8(hex & 0xFF)
        )
    }

    init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(value)
    }

    var hexString: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// WCAG relative luminance — decides whether a theme reads as dark
    /// (keyboard appearance, contrast choices).
    var luminance: Double {
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
}

extension ThemeColor: Codable {
    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let color = ThemeColor(hexString: text) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Expected #RRGGBB, got \(text)"
            ))
        }
        self = color
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }
}

/// A complete terminal color scheme: surface, cursor, and the 16 ANSI colors.
/// Pure model — the app accent (`Theme`) is identity and never changes; this
/// is the user's choice for what runs *inside* the terminal.
struct TerminalTheme: Codable, Hashable, Identifiable {
    /// Built-ins carry semantic ids ("multiplex"); user themes "custom-<uuid>".
    var id: String
    var name: String
    var background: ThemeColor
    var foreground: ThemeColor
    var cursor: ThemeColor
    /// Exactly 16 entries: ANSI 0–7 normal, 8–15 bright.
    var ansi: [ThemeColor]

    var isBuiltIn: Bool { !id.hasPrefix(Self.customIDPrefix) }
    var isDark: Bool { background.luminance < 0.5 }

    /// A decoded theme is usable only with a full ANSI table.
    var isValid: Bool { ansi.count == 16 }

    static let customIDPrefix = "custom-"

    /// Start a user theme from any existing theme's colors.
    func asCustom(named newName: String) -> TerminalTheme {
        var copy = self
        copy.id = Self.customIDPrefix + UUID().uuidString
        copy.name = newName
        return copy
    }

    static let ansiNames: [String] = [
        "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
        "Bright Black", "Bright Red", "Bright Green", "Bright Yellow",
        "Bright Blue", "Bright Magenta", "Bright Cyan", "Bright White",
    ]
}

// MARK: - Built-in themes

extension TerminalTheme {
    static let builtIns: [TerminalTheme] = [
        .tally, .multiplex, .gruvboxDark, .dracula, .nord, .solarizedDark, .solarizedLight,
    ]

    static func builtIn(id: String) -> TerminalTheme? {
        builtIns.first { $0.id == id }
    }

    /// The original amber-on-ink identity, kept as an optional theme.
    static let multiplex = TerminalTheme(
        id: "multiplex",
        name: "Multiplex",
        background: ThemeColor(0x0C0E13),
        foreground: ThemeColor(0xE9E4D8),
        cursor: ThemeColor(0xFFB000),
        ansi: palette([
            0x1B202B, 0xEA6962, 0xA9B665, 0xD8A657, 0x7DAEA3, 0xD3869B, 0x89B482, 0xC5BDA8,
            0x566073, 0xF28B82, 0xB8C77D, 0xE9B858, 0x93C0B5, 0xE19BB0, 0x9CC79A, 0xE9E4D8,
        ])
    )

    /// The house theme and app default — DESIGN.md's Tally: screen ground,
    /// signal text, tally-red cursor; ANSI tuned so red/amber match the
    /// chrome's lamp semantics.
    static let tally = TerminalTheme(
        id: "tally",
        name: "Tally",
        background: ThemeColor(0x0A0B0C),
        foreground: ThemeColor(0xE6E9EA),
        cursor: ThemeColor(0xE5484D),
        ansi: palette([
            0x17181A, 0xE5484D, 0x7FBF9A, 0xE0A33E, 0x7AA5C4, 0xB88FB0, 0x8FBFC4, 0xC9CDD1,
            0x5C6166, 0xF27074, 0x98D4B2, 0xEDBB66, 0x98BFDC, 0xCFA7C7, 0xABD6DA, 0xF2F3F4,
        ])
    )

    static let gruvboxDark = TerminalTheme(
        id: "gruvbox-dark",
        name: "Gruvbox Dark",
        background: ThemeColor(0x282828),
        foreground: ThemeColor(0xEBDBB2),
        cursor: ThemeColor(0xEBDBB2),
        ansi: palette([
            0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
            0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
        ])
    )

    static let dracula = TerminalTheme(
        id: "dracula",
        name: "Dracula",
        background: ThemeColor(0x282A36),
        foreground: ThemeColor(0xF8F8F2),
        cursor: ThemeColor(0xF8F8F2),
        ansi: palette([
            0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
            0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
        ])
    )

    static let nord = TerminalTheme(
        id: "nord",
        name: "Nord",
        background: ThemeColor(0x2E3440),
        foreground: ThemeColor(0xD8DEE9),
        cursor: ThemeColor(0xD8DEE9),
        ansi: palette([
            0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
            0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4,
        ])
    )

    static let solarizedDark = TerminalTheme(
        id: "solarized-dark",
        name: "Solarized Dark",
        background: ThemeColor(0x002B36),
        foreground: ThemeColor(0x839496),
        cursor: ThemeColor(0x93A1A1),
        ansi: solarizedANSI
    )

    static let solarizedLight = TerminalTheme(
        id: "solarized-light",
        name: "Solarized Light",
        background: ThemeColor(0xFDF6E3),
        foreground: ThemeColor(0x657B83),
        cursor: ThemeColor(0x586E75),
        ansi: solarizedANSI
    )

    /// Solarized maps its accents onto both halves of the ANSI table; the
    /// same 16 serve dark and light variants by design.
    private static let solarizedANSI = palette([
        0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
        0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
    ])

    private static func palette(_ values: [UInt32]) -> [ThemeColor] {
        values.map(ThemeColor.init)
    }
}
