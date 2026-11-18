import UIKit

/// The ▤ find bar: one chassis row under the viewer's header — FIND, the
/// query field, the match readout, ◂ ▸, DONE. It sits at the TOP of the
/// screen on every platform so a raised keyboard can never cover it, and it
/// is pane chrome (not a rail group) so the in-window rail, the visionOS
/// ornament, and the side-panel header only need a FIND chip to summon it.
///
/// Return steps forward, ⇧Return back, Esc closes; ⌘G / ⇧⌘G arrive through
/// the responder chain (the pane owns `findNext:` / `findPrevious:`).
@MainActor
final class FileViewerFindBarView: UIView, UITextFieldDelegate {
    private(set) var textField = FileViewerFindField()
    private(set) var countLabel = UIKitChassisMonoLabel(
        "",
        font: UIKitChassis.monoFont(10),
        color: UIKitChassis.signal2
    )
    private(set) var previousChip: UIKitChassisChip!
    private(set) var nextChip: UIKitChassisChip!
    private(set) var doneChip: UIKitChassisChip!

    private let queryChanged: (String) -> Void
    private let step: (Int) -> Void
    private let close: () -> Void

    init(
        queryChanged: @escaping (String) -> Void,
        step: @escaping (Int) -> Void,
        close: @escaping () -> Void
    ) {
        self.queryChanged = queryChanged
        self.step = step
        self.close = close
        super.init(frame: .zero)
        backgroundColor = UIKitChassis.bezel

        let caption = UIKitChassisLabel("FIND", size: 9, color: UIKitChassis.signal3)
        caption.setContentHuggingPriority(.required, for: .horizontal)
        caption.isAccessibilityElement = false

        textField.placeholder = String(localized: "Find in file")
        textField.accessibilityLabel = String(localized: "Find in file")
        textField.font = UIKitChassis.monoFont(12)
        textField.textColor = UIKitChassis.signal
        textField.tintColor = UIKitChassis.signal
        textField.borderStyle = .none
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.smartQuotesType = .no
        textField.smartDashesType = .no
        textField.returnKeyType = .search
        // No system clear button: it is off-identity (and outsized on visionOS),
        // and focus selects the query, so typing replaces it.
        textField.clearButtonMode = .never
        textField.delegate = self
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        textField.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.queryChanged(self.textField.text ?? "")
        }, for: .editingChanged)
        textField.escape = { [weak self] in self?.close() }
        textField.stepBack = { [weak self] in self?.step(-1) }

        countLabel.isAccessibilityElement = true
        countLabel.accessibilityTraits = .updatesFrequently
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        previousChip = Self.chip("◂", String(localized: "Previous match")) { [weak self] in
            self?.step(-1)
        }
        previousChip.accessibilityIdentifier = "fileViewer.find.previous"
        nextChip = Self.chip("▸", String(localized: "Next match")) { [weak self] in
            self?.step(1)
        }
        nextChip.accessibilityIdentifier = "fileViewer.find.next"
        doneChip = Self.chip("DONE", String(localized: "Close find")) { [weak self] in
            self?.close()
        }
        doneChip.accessibilityIdentifier = "fileViewer.find.done"
        let steps = UIStackView(arrangedSubviews: [previousChip, nextChip])
        steps.axis = .horizontal
        steps.alignment = .center
        steps.spacing = 4

        let row = UIStackView(arrangedSubviews: [caption, textField, countLabel, steps, doneChip])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        let divider = UIView()
        divider.backgroundColor = UIKitChassis.bezelHi
        addSubview(divider)
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
        accessibilityElements = [textField, countLabel, previousChip!, nextChip!, doneChip!]
        apply(count: "", hasMatches: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    var query: String { textField.text ?? "" }

    /// The readout and the step chips together: ◂ ▸ only mean something
    /// while there is a match to step to. `NO MATCH` wears caution — a query
    /// that found nothing is a state, not a number.
    func apply(count: String, hasMatches: Bool) {
        let noMatch = !count.isEmpty && !hasMatches
        countLabel.setText(count, ink: noMatch ? TallyPalette.caution : UIKitChassis.signal2)
        countLabel.accessibilityLabel = count
        countLabel.isHidden = count.isEmpty
        for chip in [previousChip!, nextChip!] {
            chip.isUserInteractionEnabled = hasMatches
            chip.alpha = hasMatches ? 1 : 0.5
            chip.accessibilityTraits = hasMatches ? .button : [.button, .notEnabled]
        }
    }

    /// Focus the field with its query selected, so ⌘F-and-type replaces it
    /// (the system find bars' convention).
    func focus() {
        textField.becomeFirstResponder()
        if let text = textField.text, !text.isEmpty {
            textField.selectedTextRange = textField.textRange(
                from: textField.beginningOfDocument,
                to: textField.endOfDocument
            )
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        step(1)
        return false
    }

    private static func chip(
        _ caption: String,
        _ accessibility: String,
        action: @escaping () -> Void
    ) -> UIKitChassisChip {
        let chip = UIKitChassisChip(caption, accessibilityLabel: accessibility, action: action)
        chip.setContentHuggingPriority(.required, for: .horizontal)
        chip.setContentCompressionResistancePriority(.required, for: .horizontal)
        return chip
    }
}

/// The query field's own keys: Esc closes the bar and ⇧Return steps back —
/// both only mean something while the field holds focus, so they live here
/// rather than on the pane.
@MainActor
final class FileViewerFindField: UITextField {
    var escape: () -> Void = {}
    var stepBack: () -> Void = {}

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(
            input: UIKeyCommand.inputEscape,
            modifierFlags: [],
            action: #selector(pressedEscape)
        )
        escape.wantsPriorityOverSystemBehavior = true
        let back = UIKeyCommand(
            input: "\r",
            modifierFlags: .shift,
            action: #selector(pressedShiftReturn)
        )
        back.wantsPriorityOverSystemBehavior = true
        return [escape, back]
    }

    @objc private func pressedEscape() { escape() }
    @objc private func pressedShiftReturn() { stepBack() }
}
