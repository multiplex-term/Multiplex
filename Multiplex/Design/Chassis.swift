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
    var color: Color?

    init(
        _ label: String,
        systemImage: String? = nil,
        prominent: Bool = false,
        color: Color? = nil
    ) {
        self.label = label
        self.systemImage = systemImage
        self.prominent = prominent
        self.color = color
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            if !label.isEmpty {
                Text(label)
                    .font(.mono(9, weight: .semibold))
                    .kerning(1.1)
            }
        }
        .foregroundStyle(color ?? (prominent ? Theme.signal : Theme.signal2))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Theme.chassis)
        .overlay(Rectangle().strokeBorder(
            prominent ? Theme.signal2 : Theme.bezelHi, lineWidth: 1))
    }
}

/// Chassis slide switch — TALLY's replacement for the system Toggle, whose
/// green pill is decoration in a system where color is state. Anatomy
/// follows TallyLamp: indicator first, caps caption at a fixed gap, both
/// brightening together. OFF is a dark screen well holding a dim thumb;
/// ON fills the track face, slides the thumb over, and lights it to full
/// signal — monochrome on purpose (an enabled option is not "on air").
struct ChassisSwitch: View {
    var label: String
    @Binding var isOn: Bool
    /// Spoken description when the caps label is terse (SUBMIT → "Auto Submit").
    var accessibilityLabel: String?

    @Environment(\.isEnabled) private var isEnabled

    init(_ label: String, isOn: Binding<Bool>, accessibilityLabel: String? = nil) {
        self.label = label
        _isOn = isOn
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 7) {
                track
                ChassisLabel(label, size: 8, color: isOn ? Theme.signal : Theme.signal2)
            }
        }
        .buttonStyle(.plain)
        .chassisHover(2)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.easeOut(duration: 0.14), value: isOn)
        .accessibilityRepresentation {
            Toggle(accessibilityLabel ?? label.capitalized, isOn: $isOn)
        }
    }

    private var track: some View {
        Rectangle()
            .fill(isOn ? Theme.bezelHi : Theme.screen)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Rectangle()
                    .fill(isOn ? Theme.signal : Theme.signal3)
                    .frame(width: 8, height: 8)
                    .padding(3)
            }
            .overlay(Rectangle().strokeBorder(
                isOn ? Theme.signal2 : Theme.bezelHi, lineWidth: 1))
            .frame(width: 26, height: 14)
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
