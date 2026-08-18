import SwiftUI
import UIKit
import WidgetKit

/// TALLY tokens for the widget process. `Theme.swift` can't come along (it
/// drags the terminal-theme models and the app asset catalog), so the values
/// are mirrored here verbatim — dark graphite and the Frost light chassis.
/// Rule carried over from DESIGN.md: **no tally red in widgets** — a widget
/// cannot verify liveness, and color is state, never decoration.
///
/// iOS/iPadOS resolve per trait collection exactly like the app's tokens.
/// visionOS is pinned to the dark graphite: its widget environment reports a
/// LIGHT interface style even though the app's visionOS identity is the dark
/// chassis, so trait-following rendered the Frost palette — dark text — over
/// the system's dark glass and everything disappeared (user-reported).
enum WidgetTheme {
    static let chassis = token(light: 0xE4E8EE, dark: 0x17181A)
    static let bezel = token(light: 0xF0F3F7, dark: 0x26282B)
    static let bezelHi = token(light: 0xCDD3DC, dark: 0x33363A)
    static let screen = token(light: 0xF9FBFD, dark: 0x0A0B0C)
    static let screenHatch = token(light: 0xEDF0F4, dark: 0x101114)
    static let signal = token(light: 0x191E25, dark: 0xF2F3F4)
    static let signal2 = token(light: 0x515C69, dark: 0x9BA1A6)
    static let signal3 = token(light: 0x87919E, dark: 0x5C6166)
    static let miniText = token(light: 0x3A434E, dark: 0xC8D2D6)

    private static func token(light: UInt32, dark: UInt32) -> Color {
        #if os(visionOS)
        opaque(dark)
        #else
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
        #endif
    }

    private static func opaque(_ hex: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// The palette every widget view actually draws with, resolved from the
/// system's rendering mode. Full color = the TALLY tokens above. Accented =
/// the user picked a widget Color Theme (visionOS 26's picker, iOS tinting):
/// the system remaps custom colors by luminance, which collapsed our paired
/// customs (light mini text over the dark screen became invisible —
/// user-reported). Accented therefore draws in WHITE WITH OPACITY only —
/// the one channel the remap preserves — so the hierarchy survives every
/// theme color the picker offers.
struct WidgetPalette {
    var chassis: Color
    var bezel: Color
    var bezelHi: Color
    var screen: Color
    var screenHatch: Color
    var signal: Color
    var signal2: Color
    var signal3: Color
    /// Carries its own opacity — miniature text never multiplies another
    /// opacity on top.
    var miniText: Color

    static let fullColor = WidgetPalette(
        chassis: WidgetTheme.chassis,
        bezel: WidgetTheme.bezel,
        bezelHi: WidgetTheme.bezelHi,
        screen: WidgetTheme.screen,
        screenHatch: WidgetTheme.screenHatch,
        signal: WidgetTheme.signal,
        signal2: WidgetTheme.signal2,
        signal3: WidgetTheme.signal3,
        miniText: WidgetTheme.miniText.opacity(0.78)
    )

    static let accented = WidgetPalette(
        chassis: .clear,
        bezel: .white.opacity(0.16),
        bezelHi: .white.opacity(0.32),
        screen: .white.opacity(0.10),
        screenHatch: .white.opacity(0.05),
        signal: .white,
        signal2: .white.opacity(0.72),
        signal3: .white.opacity(0.5),
        miniText: .white.opacity(0.85)
    )
}

private struct TallyPaletteKey: EnvironmentKey {
    static let defaultValue = WidgetPalette.fullColor
}

extension EnvironmentValues {
    var tallyPalette: WidgetPalette {
        get { self[TallyPaletteKey.self] }
        set { self[TallyPaletteKey.self] = newValue }
    }
}

/// Applied at each widget's root: resolves the palette from the system's
/// rendering mode for everything below.
struct TallyThemed: ViewModifier {
    @Environment(\.widgetRenderingMode) private var renderingMode

    func body(content: Content) -> some View {
        content.environment(
            \.tallyPalette,
            renderingMode == .fullColor ? .fullColor : .accented
        )
    }
}

extension Font {
    /// Mono data voice (addresses, telemetry, miniature content).
    static func widgetMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// The compressed-caps source-label voice (the widget's `ChassisLabel`).
/// `color` nil = the palette's primary signal.
struct WidgetLabel: View {
    let text: String
    var size: CGFloat = 10
    var color: Color?

    @Environment(\.tallyPalette) private var palette

    init(_ text: String, size: CGFloat = 10, color: Color? = nil) {
        self.text = text
        self.size = size
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .bold).width(.compressed))
            .kerning(size * 0.09)
            .foregroundStyle(color ?? palette.signal)
            .lineLimit(1)
    }
}

/// A held miniature frame: last-known pane lines on a screen surface.
struct MiniatureScreen: View {
    let lines: [String]
    var fontSize: CGFloat = 8

    @Environment(\.tallyPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 1.5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.widgetMono(fontSize))
                    .foregroundStyle(palette.miniText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(7)
        .background(palette.screen)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(palette.bezelHi, lineWidth: 1)
        )
    }
}

/// The no-data screen: diagonal hatch + a captioned reason, quoting the
/// deck's NO SIGNAL composition.
struct HatchScreen: View {
    let caption: String
    var fontSize: CGFloat = 7

    @Environment(\.tallyPalette) private var palette

    var body: some View {
        ZStack {
            Canvas { context, size in
                let spacing: CGFloat = 6
                var path = Path()
                var x = -size.height
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += spacing
                }
                context.stroke(
                    path,
                    with: .color(palette.screenHatch),
                    lineWidth: 1
                )
            }
            Text(caption.uppercased())
                .font(.widgetMono(fontSize))
                .foregroundStyle(palette.signal3)
                .lineLimit(1)
                .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.screen)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(palette.bezelHi, lineWidth: 1)
        )
    }
}

/// The window spine — one cell per tmux window, active cell lit.
struct SpineRow: View {
    let names: [String]
    let activeIndex: Int
    var maxCells = 3

    @Environment(\.tallyPalette) private var palette

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(visible.enumerated()), id: \.offset) { offset, cell in
                Text(cell.name.uppercased())
                    .font(.widgetMono(6.5))
                    .kerning(0.3)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(cell.isActive ? palette.bezel : palette.screenHatch)
                    .foregroundStyle(cell.isActive ? palette.signal : palette.signal3)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(palette.bezelHi, lineWidth: 1)
                    )
                    .id(offset)
            }
            Spacer(minLength: 0)
        }
    }

    private var visible: [(name: String, isActive: Bool)] {
        let cells = names.enumerated().map { index, name in
            (name: "\(index) \(name)", isActive: index == activeIndex)
        }
        guard cells.count > maxCells else { return cells }
        // Keep the active window visible when the spine is clipped.
        if activeIndex < maxCells { return Array(cells.prefix(maxCells)) }
        return Array(cells.prefix(maxCells - 1)) + [cells[activeIndex]]
    }
}

/// A Switchboard action key (quotes the iPad key rail).
struct ActionKey: View {
    let glyph: String
    let caption: String
    var sub: String?
    var glyphSize: CGFloat = 14

    @Environment(\.tallyPalette) private var palette

    var body: some View {
        VStack(spacing: 3) {
            Text(glyph)
                .font(.widgetMono(glyphSize))
                .foregroundStyle(palette.signal)
            WidgetLabel(caption, size: 8)
            if let sub {
                Text(sub.uppercased())
                    .font(.widgetMono(6.5))
                    .kerning(0.3)
                    .foregroundStyle(palette.signal3)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bezel)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(palette.bezelHi, lineWidth: 1)
        )
    }
}

/// The honesty stamp: relative, auto-updating recency (never a liveness
/// claim). nil = the app has never probed this host.
struct SeenStamp: View {
    let date: Date?
    var fontSize: CGFloat = 7.5

    @Environment(\.tallyPalette) private var palette

    var body: some View {
        Group {
            if let date {
                HStack(spacing: 3) {
                    Text(verbatim: "SEEN")
                    Text(date, style: .relative)
                        .lineLimit(1)
                }
            } else {
                Text(verbatim: "NEVER SEEN")
            }
        }
        .font(.widgetMono(fontSize))
        .textCase(.uppercase)
        .foregroundStyle(palette.signal3)
    }
}

/// First-run / no-snapshot content: the widget can't know any hosts until
/// the app has published once.
struct AwaitingDataView: View {
    @Environment(\.tallyPalette) private var palette

    var body: some View {
        VStack(spacing: 8) {
            HatchScreen(caption: String(localized: "Awaiting data"))
            WidgetLabel(String(localized: "Open Multiplex once"), size: 8.5, color: palette.signal2)
        }
    }
}
