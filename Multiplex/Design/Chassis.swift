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
                    // SF Symbols have different intrinsic ascents (paperclip
                    // is taller than plus). A fixed slot keeps every chassis
                    // badge on the same control height.
                    .frame(width: 10, height: 10)
            }
            if !label.isEmpty {
                Text(label)
                    .font(.mono(9, weight: .semibold))
                    .kerning(1.1)
                    .lineLimit(1)
                    .fixedSize()
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

// MARK: - TALLY forms

/// A section inside a native sheet. The presentation remains a system sheet;
/// the task surface inside it uses the same squared chassis, divider, and
/// source-label anatomy as the wall and terminal controls.
struct TallyFormSection<Content: View>: View {
    let title: String
    let detail: String?
    let content: Content

    init(
        _ title: String,
        detail: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                ChassisLabel(title, size: 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Theme.bezel)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isHeader)

                Rectangle()
                    .fill(Theme.bezelHi)
                    .frame(height: 1)

                VStack(spacing: 1) {
                    content
                }
                .background(Theme.bezelHi)
            }
            .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))

            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.signal2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// One full-width row in a Tally form section.
struct TallyFormRow<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.chassis)
    }
}

/// Persistent SF Pro field label over a mono, screen-dark input well.
/// Callers own keyboard/autocorrection behavior on the supplied field.
struct TallyFormField<Field: View>: View {
    let label: String
    let field: Field

    init(_ label: String, @ViewBuilder field: () -> Field) {
        self.label = label
        self.field = field()
    }

    var body: some View {
        TallyFormRow {
            VStack(alignment: .leading, spacing: 7) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.signal2)
                field
                    .font(.mono(12))
                    .foregroundStyle(Theme.signal)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(Theme.screen)
                    .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
            }
        }
    }
}

/// Square, neutral segmented choice. Selection changes border/face weight,
/// never semantic color. Each segment is a real button for gaze and touch.
struct TallyChoiceBar<Value: Hashable>: View {
    let choices: [(label: String, value: Value)]
    @Binding var selection: Value

    init(
        _ choices: [(String, Value)],
        selection: Binding<Value>
    ) {
        self.choices = choices
        _selection = selection
    }

    var body: some View {
        HStack(spacing: 1) {
            ForEach(choices.indices, id: \.self) { index in
                let choice = choices[index]
                let selected = selection == choice.value
                Button {
                    selection = choice.value
                } label: {
                    ChassisLabel(
                        choice.label,
                        size: 9,
                        color: selected ? Theme.signal : Theme.signal2
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(selected ? Theme.bezelHi : Theme.chassis)
                    .overlay(Rectangle().strokeBorder(
                        selected ? Theme.signal2 : Theme.bezelHi,
                        lineWidth: 1
                    ))
                }
                .buttonStyle(.plain)
                .chassisHover(2)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .background(Theme.bezelHi)
        .animation(.easeOut(duration: 0.14), value: selection)
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

#if DEBUG
private struct ChassisSwitchPreviewHarness: View {
    @State private var isOn = true

    var body: some View {
        ChassisSwitch("SUBMIT", isOn: $isOn, accessibilityLabel: "Auto Submit")
    }
}

private struct TallyFormFieldPreviewHarness: View {
    @State private var value = "devbox"

    var body: some View {
        TallyFormField("Name") {
            TextField("Host name", text: $value)
        }
    }
}

private struct TallyChoiceBarPreviewHarness: View {
    private enum Choice: Hashable {
        case shell
        case codex
    }

    @State private var selection = Choice.shell

    var body: some View {
        TallyChoiceBar(
            [("SHELL", Choice.shell), ("CODEX", Choice.codex)],
            selection: $selection
        )
    }
}

#Preview("Chassis Label") {
    ChassisLabel("devbox · production", size: 12)
        .padding()
        .background(Theme.chassis)
}

#Preview("Chassis Chip") {
    HStack(spacing: 10) {
        ChassisChip("DECK", action: {})
        ChassisChip("ATTACH", systemImage: "play.fill", prominent: true, action: {})
    }
    .padding()
    .background(Theme.chassis)
}

#Preview("Chassis Badge") {
    HStack(spacing: 10) {
        ChassisBadge("SSH")
        ChassisBadge("LIVE", prominent: true)
    }
    .padding()
    .background(Theme.chassis)
}

#Preview("Chassis Switch") {
    ChassisSwitchPreviewHarness()
        .padding()
        .background(Theme.chassis)
}

#Preview("Tally Form Section") {
    TallyFormSection(
        "Host identity",
        detail: "The source label and address shown on the fleet wall."
    ) {
        TallyFormRow {
            ChassisLabel("devbox", size: 11)
        }
    }
    .padding()
    .frame(width: 420)
    .background(Theme.chassis)
}

#Preview("Tally Form Row") {
    TallyFormRow {
        HStack {
            ChassisLabel("Transport", size: 10)
            Spacer()
            ChassisBadge("MOSH")
        }
    }
    .frame(width: 380)
    .padding()
    .background(Theme.chassis)
}

#Preview("Tally Form Field") {
    TallyFormFieldPreviewHarness()
        .frame(width: 380)
        .padding()
        .background(Theme.chassis)
}

#Preview("Tally Choice Bar") {
    TallyChoiceBarPreviewHarness()
        .frame(width: 300)
        .padding()
        .background(Theme.chassis)
}

#Preview("Tally Lamp") {
    HStack(spacing: 18) {
        TallyLamp()
        TallyLamp(caption: "LINK", color: Theme.caution)
        TallyLamp(caption: "READY", color: Theme.ok)
    }
    .padding()
    .background(Theme.chassis)
}
#endif
