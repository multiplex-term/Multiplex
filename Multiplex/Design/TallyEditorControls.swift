import UIKit

// MARK: - Shared TALLY editor controls
//
// The pieces every TALLY editor popover shares — COMMAND SETUP (agent custom
// commands) introduced them and KEY COMMANDS' CUSTOM SETUP reuses them: the
// compact captioned switch (26×14 monochrome — never the system green pill),
// the square row-action button, the ↑ ↓ 🗑 row-action trio, the legend rows,
// and the ADD · CANCEL · DONE footer.

/// Metrics the shared controls agree on.
enum TallyEditorMetrics {
    /// The one selection/thumb slide duration every editor control uses.
    static let selectionAnimationDuration: TimeInterval = 0.14
}

@MainActor
final class TallyEditorSwitch: UIControl {
    private let track: TallyEditorSwitchTrack
    private let caption: UIKitChassisLabel
    private var isOn: Bool
    private let changed: (Bool) -> Void

    /// `identifierPrefix` namespaces the accessibility identifier per editor
    /// (`customCommands` / `keyCommands`). `scale` grows the track and thumb
    /// (Key Commands passes `Theme.typeScale` so the switch keeps pace with
    /// its keycaps on the Mac); the agent editor keeps the authored 26×14.
    init(
        label: String,
        accessibilityLabel: String,
        isOn: Bool,
        identifierPrefix: String,
        scale: CGFloat = 1,
        changed: @escaping (Bool) -> Void
    ) {
        self.isOn = isOn
        self.changed = changed
        track = TallyEditorSwitchTrack(scale: scale)
        caption = UIKitChassisLabel(
            label,
            size: 8,
            color: isOn ? UIKitChassis.signal : UIKitChassis.signal2
        )
        super.init(frame: .zero)
        isAccessibilityElement = true
        // The SwiftUI row was a real `Toggle`; `.toggleButton` is UIKit's
        // equivalent identity, so the switch rotor and the spoken On/Off
        // state survive the port.
        accessibilityTraits = [.button, .toggleButton]
        self.accessibilityLabel = accessibilityLabel
        accessibilityIdentifier = "\(identifierPrefix).switch.\(label.lowercased())"
        addTarget(self, action: #selector(pressed), for: .touchUpInside)
        #if os(visionOS)
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        #endif

        let row = UIStackView(arrangedSubviews: [track, caption])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 7
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func pressed() {
        isOn.toggle()
        render(animated: true)
        changed(isOn)
    }

    /// Reflect a value set elsewhere (a row re-rendered from its model)
    /// without firing `changed`.
    func setOn(_ on: Bool, animated: Bool = false) {
        guard on != isOn else { return }
        isOn = on
        render(animated: animated)
    }

    private func render(animated: Bool = false) {
        track.setOn(isOn, animated: animated)
        caption.setInk(isOn ? UIKitChassis.signal : UIKitChassis.signal2)
        accessibilityValue = isOn ? String(localized: "On") : String(localized: "Off")
        if isOn {
            accessibilityTraits.insert(.selected)
        } else {
            accessibilityTraits.remove(.selected)
        }
    }
}

@MainActor
final class TallyEditorSwitchTrack: UIKitTallyBorderedView {
    private let thumb = UIView()
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!

    init(scale: CGFloat = 1) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: ceil(26 * scale)),
            heightAnchor.constraint(equalToConstant: ceil(14 * scale)),
        ])
        thumb.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumb)
        let inset = ceil(3 * scale)
        leading = thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset)
        trailing = thumb.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
        NSLayoutConstraint.activate([
            thumb.widthAnchor.constraint(equalToConstant: ceil(8 * scale)),
            thumb.heightAnchor.constraint(equalToConstant: ceil(8 * scale)),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading,
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func setOn(_ on: Bool, animated: Bool = false) {
        leading.isActive = false
        trailing.isActive = false
        (on ? trailing : leading).isActive = true
        let apply = {
            self.backgroundColor = on ? UIKitChassis.bezelHi : UIKitChassis.screen
            self.thumb.backgroundColor = on ? UIKitChassis.signal : UIKitChassis.signal3
            self.tallyBorderColor = on ? UIKitChassis.signal2 : UIKitChassis.bezelHi
            // The swapped constraint only moves the thumb inside an animation
            // transaction if the layout pass runs there too.
            self.layoutIfNeeded()
        }
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            apply()
            return
        }
        UIView.animate(
            withDuration: TallyEditorMetrics.selectionAnimationDuration,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState],
            animations: apply
        )
    }
}

@MainActor
final class TallyEditorRowActionButton: UIButton {
    private let action: () -> Void

    /// `scale` grows the 25×23 square (Key Commands passes `Theme.typeScale`).
    /// The glyph inside always rides `Theme.typeScale` on its own — chrome
    /// type is scaled app-wide, geometry only where a control opts in — so
    /// the agent editor's default-scale button keeps its Mac-legible symbol.
    init(
        systemImage: String,
        accessibilityLabel: String,
        enabled: Bool,
        scale: CGFloat = 1,
        action: @escaping () -> Void
    ) {
        self.action = action
        super.init(frame: .zero)
        backgroundColor = GlassPrototype.strataChassis
        layer.borderWidth = 1
        layer.borderColor = UIKitChassis.bezelHi
            .resolvedColor(with: traitCollection).cgColor
        setImage(
            UIImage(
                systemName: systemImage,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: 9 * Theme.typeScale,
                    weight: .semibold
                )
            ),
            for: .normal
        )
        tintColor = enabled ? UIKitChassis.signal2 : UIKitChassis.signal3
        isEnabled = enabled
        self.accessibilityLabel = accessibilityLabel
        addTarget(self, action: #selector(pressed), for: .touchUpInside)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: ceil(25 * scale)),
            heightAnchor.constraint(equalToConstant: ceil(23 * scale)),
        ])
        #if os(visionOS)
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func pressed() {
        action()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        layer.borderColor = UIKitChassis.bezelHi
            .resolvedColor(with: traitCollection).cgColor
    }
}

/// The ↑ ↓ 🗑 trio every numbered editor row wears: enablement from the
/// row's position, identifiers namespaced per editor and keyed by the row's
/// ID.
@MainActor
enum TallyEditorRowActions {
    struct Trio {
        let stack: UIStackView
        let up: TallyEditorRowActionButton
        let down: TallyEditorRowActionButton
        let delete: TallyEditorRowActionButton
    }

    static func make(
        index: Int,
        count: Int,
        identifierPrefix: String,
        rowID: UUID,
        scale: CGFloat = 1,
        move: @escaping (Int) -> Void,
        delete: @escaping () -> Void
    ) -> Trio {
        let up = TallyEditorRowActionButton(
            systemImage: "arrow.up",
            accessibilityLabel: String(localized: "Move command up"),
            enabled: index > 0,
            scale: scale,
            action: { move(-1) }
        )
        up.accessibilityIdentifier = "\(identifierPrefix).moveUp.\(rowID.uuidString)"
        let down = TallyEditorRowActionButton(
            systemImage: "arrow.down",
            accessibilityLabel: String(localized: "Move command down"),
            enabled: index < count - 1,
            scale: scale,
            action: { move(1) }
        )
        down.accessibilityIdentifier = "\(identifierPrefix).moveDown.\(rowID.uuidString)"
        let trash = TallyEditorRowActionButton(
            systemImage: "trash",
            accessibilityLabel: String(localized: "Delete command"),
            enabled: true,
            scale: scale,
            action: delete
        )
        trash.accessibilityIdentifier = "\(identifierPrefix).delete.\(rowID.uuidString)"
        let stack = UIStackView(arrangedSubviews: [up, down, trash])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        return Trio(stack: stack, up: up, down: down, delete: trash)
    }
}

/// A legend row: a 6-pt dot in the ink it explains, then one wrapping line
/// of mono copy. Stacked at 6 pt by the editors' footers.
@MainActor
enum TallyEditorLegend {
    static func row(color: UIColor, text: String) -> UIView {
        let dot = UIView()
        dot.backgroundColor = color
        dot.layer.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
        dot.isAccessibilityElement = false

        let label = UILabel()
        label.text = text
        label.font = UIKitChassis.monoFont(8, weight: .medium)
        label.textColor = UIKitChassis.signal2
        label.numberOfLines = 0
        // Above the list viewport's resting height, below required: the legend
        // is the last thing in the panel to give way, and a required floor here
        // would make a popover shorter than the whole panel unsatisfiable.
        label.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)

        let row = UIStackView(arrangedSubviews: [dot, label])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    static func stack(_ rows: [UIView]) -> UIStackView {
        let legend = UIStackView(arrangedSubviews: rows)
        legend.axis = .vertical
        legend.alignment = .fill
        legend.spacing = 6
        return legend
    }
}

/// ADD COMMAND · spacer · CANCEL · DONE — the editors' one action row.
@MainActor
enum TallyEditorFooter {
    /// The ADD chip's state: live; dimmed at the list's hard cap; or the
    /// tier's route past its own cap — still live, prominent, marked PRO,
    /// and `add` opens the paywall.
    enum AddState {
        case available
        case capped
        case upgrade
    }

    static func actions(
        identifierPrefix: String,
        addState: AddState = .available,
        add: @escaping () -> Void,
        cancel: @escaping () -> Void,
        done: @escaping () -> Void
    ) -> UIStackView {
        let addChip = UIKitChassisChip(
            addState == .upgrade ? "ADD COMMAND · PRO" : "ADD COMMAND",
            systemImage: "plus",
            prominent: addState == .upgrade,
            accessibilityLabel: addState == .upgrade
                ? String(localized: "Add command with Multiplex Pro")
                : String(localized: "Add command"),
            action: add
        )
        addChip.accessibilityIdentifier = "\(identifierPrefix).add"
        addChip.alpha = addState == .capped ? 0.45 : 1
        addChip.isUserInteractionEnabled = addState != .capped
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let cancelChip = UIKitChassisChip(
            "CANCEL",
            accessibilityLabel: String(localized: "Cancel"),
            action: cancel
        )
        cancelChip.accessibilityIdentifier = "\(identifierPrefix).cancel"
        let doneChip = UIKitChassisChip(
            "DONE",
            prominent: true,
            accessibilityLabel: String(localized: "Done"),
            action: done
        )
        doneChip.accessibilityIdentifier = "\(identifierPrefix).done"
        for chip in [addChip, cancelChip, doneChip] {
            chip.setContentHuggingPriority(.required, for: .horizontal)
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let row = UIStackView(arrangedSubviews: [addChip, spacer, cancelChip, doneChip])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        return row
    }
}
