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
        // Font and kerning scale together so tracking stays proportional
        // when Theme.typeScale compensates iOS-on-Mac's 77% canvas.
        let scaled = size * Theme.typeScale
        Text(text.uppercased())
            .font(.system(size: scaled, weight: .bold).width(.compressed))
            .kerning(scaled * 0.09)
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
                    .font(.ui(9, weight: .semibold))
                    // SF Symbols have different intrinsic ascents (paperclip
                    // is taller than plus). A fixed slot keeps every chassis
                    // badge on the same control height; it tracks the type
                    // scale so the icon never outgrows its slot.
                    .frame(width: 10 * Theme.typeScale, height: 10 * Theme.typeScale)
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
                ChassisSwitchIndicator(isOn: isOn)
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
}

/// The switch face is shared by compact inline switches and full-width form
/// fields. Form controls get a larger face; neither size spends semantic color.
private struct ChassisSwitchIndicator: View {
    enum Scale {
        case compact
        case form

        var width: CGFloat { self == .compact ? 26 : 36 }
        var height: CGFloat { self == .compact ? 14 : 20 }
        var thumb: CGFloat { self == .compact ? 8 : 12 }
        var inset: CGFloat { self == .compact ? 3 : 4 }
    }

    let isOn: Bool
    var scale = Scale.compact

    var body: some View {
        Rectangle()
            .fill(isOn ? Theme.bezelHi : Theme.screen)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Rectangle()
                    .fill(isOn ? Theme.signal : Theme.signal3)
                    .frame(width: scale.thumb, height: scale.thumb)
                    .padding(scale.inset)
            }
            .overlay(Rectangle().strokeBorder(
                isOn ? Theme.signal2 : Theme.bezelHi, lineWidth: 1))
            .frame(width: scale.width, height: scale.height)
            .accessibilityHidden(true)
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
                    .font(.ui(10))
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

/// A full-width boolean setting: readable SF Pro title at the leading edge,
/// a regular TALLY switch at the trailing edge, and one 48-point press target
/// across the entire row. Compact `ChassisSwitch` remains for dense controls.
struct TallyFormBoolField: View {
    let title: String
    @Binding var isOn: Bool
    let status: String?
    let statusIsProminent: Bool
    let accessibilityLabel: String?
    let accessibilityHint: String?

    @Environment(\.isEnabled) private var isEnabled

    init(
        _ title: String,
        isOn: Binding<Bool>,
        status: String? = nil,
        statusIsProminent: Bool = false,
        accessibilityLabel: String? = nil,
        accessibilityHint: String? = nil
    ) {
        self.title = title
        _isOn = isOn
        self.status = status
        self.statusIsProminent = statusIsProminent
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(.ui(12, weight: .semibold))
                    .foregroundStyle(Theme.signal)
                    .lineLimit(1)
                    .layoutPriority(1)

                if let status {
                    ChassisBadge(status, prominent: statusIsProminent)
                }

                Spacer(minLength: 12)

                ChassisSwitchIndicator(isOn: isOn, scale: .form)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(TallyFormBoolFieldButtonStyle())
        .chassisHover(2)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.easeOut(duration: 0.14), value: isOn)
        .accessibilityRepresentation {
            Toggle(accessibilityLabel ?? title, isOn: $isOn)
                .accessibilityHint(accessibilityHint ?? "")
        }
    }
}

private struct TallyFormBoolFieldButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.bezel : Theme.chassis)
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
                    .font(.ui(10, weight: .semibold))
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
                // The dot tracks the type scale with its caption so the
                // lamp keeps its proportions on iOS-on-Mac.
                .frame(width: 7 * Theme.typeScale, height: 7 * Theme.typeScale)
                .shadow(color: color.opacity(0.7), radius: 4)
            Text(caption)
                .font(.mono(9, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(color)
                // The caption is the lamp's meaning — it must win layout
                // compression, or a crowded row shows an uncaptioned red dot.
                .fixedSize()
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

    /// Opaque chassis ground for a form dialog's scroll content, navigation
    /// bar included — Settings, the host and session forms, FAQ, the theme
    /// editor, the paywall. One shared surface on every platform: the tokens
    /// inside these forms are trait-dynamic, so the ground must flip with
    /// the appearance choice too. visionOS sheets used to keep native glass
    /// here, which left a pinned LIGHT appearance reading as a washed gray
    /// platter — light wells floating on room-tinted glass with no light
    /// chassis anywhere (user-reported). The appearance follow-through rides
    /// along because a visionOS sheet's own window misses the scene override
    /// in place when it presents (see `AppearanceApplicator`).
    func chassisSheetGround() -> some View {
        self
            .background(Theme.chassis.ignoresSafeArea())
            .toolbarBackground(Theme.chassis, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .followsAppAppearance()
    }
}

/// The visionOS sheet bar ignores window traits: its system title and plain
/// button labels render vibrant white whatever the chassis polarity, which
/// washes out over a light ground. Per-item content IS honored, so chassis
/// sheets restate their bar in ink explicitly — a `ChassisSheetTitle`
/// replacing the system title on visionOS (iPad keeps the system inline
/// title), and `ChassisBarButton`s whose labels carry the trait-resolved
/// signal tokens on every platform.
struct ChassisSheetTitle: ToolbarContent {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some ToolbarContent {
        #if os(visionOS)
        ToolbarItem(placement: .principal) {
            ChassisLabel(title, size: 12)
        }
        #else
        // Xcode 26's ToolbarContentBuilder has no empty buildBlock overload.
        ToolbarItem(placement: .automatic) {
            EmptyView()
        }
        #endif
    }
}

/// System bar-button shell (pill, placement, disabled hit behavior) with the
/// label ink drawn from chassis tokens; `isEnabled` keeps the disabled
/// affordance the explicit color would otherwise defeat.
struct ChassisBarButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(isEnabled ? Theme.signal : Theme.signal3)
        }
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

private struct TallyFormBoolFieldPreviewHarness: View {
    @State private var isOn = false

    var body: some View {
        TallyFormBoolField(
            "Agent alerts",
            isOn: $isOn,
            status: "PRO",
            statusIsProminent: true,
            accessibilityHint: "Requires Multiplex Pro"
        )
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

#Preview("Tally Bool Field") {
    TallyFormBoolFieldPreviewHarness()
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
