import SwiftUI

/// The Tally identity's chassis components — the vocabulary every surface
/// speaks: compressed-caps source labels, square bordered chips, and the
/// captioned tally lamp. See DESIGN.md.

/// Compressed-caps chassis label — the multiviewer source-label voice.
/// Used for the app mark, host rails, tile names, and UMD titles.
struct ChassisLabel: View {
    var text: String
    var size: CGFloat = 12
    var color: Color = Theme.signal

    init(_ text: String, size: CGFloat = 12, color: Color = Theme.signal) {
        self.text = text
        self.size = size
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .bold).width(.compressed))
            .kerning(size * 0.09)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// Square chassis chip — Tally's action language. Color never carries an
/// action; prominence is a border weight.
struct ChassisChip: View {
    var label: String
    var systemImage: String?
    var prominent = false
    var action: () -> Void

    init(_ label: String, systemImage: String? = nil, prominent: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ChassisBadge(label, systemImage: systemImage, prominent: prominent)
        }
        .buttonStyle(.plain)
        .chassisHover(2)
        .accessibilityLabel(label.capitalized)
    }
}

/// The chip's face, usable without a button (state badges like ATTACH).
struct ChassisBadge: View {
    var label: String
    var systemImage: String?
    var prominent = false

    init(_ label: String, systemImage: String? = nil, prominent: Bool = false) {
        self.label = label
        self.systemImage = systemImage
        self.prominent = prominent
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(label)
                .font(.mono(9, weight: .semibold))
                .kerning(1.1)
        }
        .foregroundStyle(prominent ? Theme.signal : Theme.signal2)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Theme.chassis)
        .overlay(Rectangle().strokeBorder(
            prominent ? Theme.signal2 : Theme.bezelHi, lineWidth: 1))
    }
}

/// The lit lamp + caption. Tally red is always captioned so it can never
/// read as an error; other states reuse the same anatomy.
struct TallyLamp: View {
    var caption = "LIVE"
    var color = Theme.tally

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.7), radius: 4)
            Text(caption)
                .font(.mono(9, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption.lowercased())
    }
}

extension View {
    /// Square-cornered gaze-hover highlight. The default visionOS platter is
    /// heavily rounded and fights the chassis geometry; buttonBorderShape
    /// reshapes the automatic button hover, and the explicit hoverEffect +
    /// hover content shape covers styles that ignore it. Must be applied to
    /// the Button/Menu itself, not its label.
    func chassisHover(_ cornerRadius: CGFloat) -> some View {
        self
            .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: cornerRadius))
            .hoverEffect(.highlight)
    }
}
