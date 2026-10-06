import Observation
import UIKit

/// Settings → Voice input: the RNNoise model's lifecycle and the switch that
/// puts it in front of dictation. It observes the model store itself, so a
/// download's progress re-renders this card alone, never the whole form
/// (`SettingsViewController` keeps one instance across its re-renders) — and
/// within the card a progress tick only swaps the percent badge, so
/// VoiceOver keeps its place.
@MainActor
final class SettingsVoiceInputSection: UIView {
    private static let downloadSize = ByteCountFormatter.string(
        fromByteCount: Int64(RNNoiseModelSource.archiveByteCount),
        countStyle: .file
    )

    private let store: RNNoiseModelStore
    private var renderedPhase: Phase?
    private var section: UIView?
    /// The downloading row, whose badge each progress tick replaces.
    private var progressRow: (inset: UIView, stack: UIStackView, badge: UIView)?

    /// What the card's layout follows: the store's state without the
    /// download's fraction.
    private enum Phase: Equatable {
        case absent, downloading, installing, ready, failed(String)

        init(_ state: RNNoiseModelStore.State) {
            switch state {
            case .absent: self = .absent
            case .downloading: self = .downloading
            case .installing: self = .installing
            case .ready: self = .ready
            case .failed(let message): self = .failed(message)
            }
        }
    }

    init(store: RNNoiseModelStore = .shared) {
        self.store = store
        super.init(frame: .zero)
        accessibilityIdentifier = "settings.voiceInput"
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    /// Observation callbacks are one-shot; each change re-registers.
    private func observe() {
        let state = withObservationTracking {
            store.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        render(state)
    }

    private func render(_ state: RNNoiseModelStore.State) {
        if case .downloading(let fraction) = state, renderedPhase == .downloading {
            showProgress(fraction)
            return
        }
        let phase = Phase(state)
        guard phase != renderedPhase else { return }
        renderedPhase = phase
        progressRow = nil
        section?.removeFromSuperview()
        let section = SettingsSectionView(
            title: String(localized: "Voice input"),
            detail: String(localized: """
                Filters steady background noise — fans, traffic, a headset's hiss — out of the \
                microphone with RNNoise before dictation hears it, in the message box and on the \
                key rail. The model is a one-time \(Self.downloadSize) download from xiph.org, \
                checked against its published SHA-256 and kept on this device only.
                """),
            rows: rows(for: phase)
        )
        addSubview(section)
        section.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: leadingAnchor),
            section.trailingAnchor.constraint(equalTo: trailingAnchor),
            section.topAnchor.constraint(equalTo: topAnchor),
            section.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.section = section
        if case .downloading(let fraction) = state { showProgress(fraction) }
    }

    private func showProgress(_ fraction: Double) {
        guard let row = progressRow else { return }
        let text = "\(Int((fraction * 100).rounded(.down)))%"
        let badge = SettingsBadgeView(text)
        row.stack.removeArrangedSubview(row.badge)
        row.badge.removeFromSuperview()
        row.stack.addArrangedSubview(badge)
        row.inset.accessibilityValue = text
        progressRow = (row.inset, row.stack, badge)
    }

    private func rows(for phase: Phase) -> [UIView] {
        let title = String(localized: "Noise reduction")
        switch phase {
        case .ready:
            // Defaults-backed, like the renderer switch: nothing else
            // observes it, and a take reads it when it starts.
            let toggle = SettingsBooleanRow(
                title: title,
                isOn: NoiseReductionSetting.isEnabled()
            ) { enabled in
                NoiseReductionSetting.setEnabled(enabled)
            }
            toggle.accessibilityIdentifier = "settings.noiseReduction"
            return [
                toggle,
                settingsChipRow(
                    "DELETE MODEL",
                    accessibilityLabel: String(localized: "Delete the noise reduction model")
                ) { [weak self] in self?.store.delete() },
            ]
        case .absent:
            return [
                statusRow(title, badge: "NOT INSTALLED").inset,
                settingsChipRow(
                    "DOWNLOAD \(Self.downloadSize)",
                    prominent: true,
                    accessibilityLabel: String(
                        localized: "Download the noise reduction model, \(Self.downloadSize)"
                    )
                ) { [weak self] in self?.store.download() },
            ]
        case .downloading:
            let row = statusRow(String(localized: "Downloading model"), badge: "0%")
            progressRow = row
            return [row.inset, cancelRow()]
        case .installing:
            return [statusRow(String(localized: "Verifying model"), badge: "VERIFYING").inset, cancelRow()]
        case .failed(let message):
            return [
                statusRow(message, badge: "FAILED", multiline: true).inset,
                settingsChipRow(
                    "RETRY",
                    prominent: true,
                    accessibilityLabel: String(localized: "Retry the model download")
                ) { [weak self] in self?.store.download() },
            ]
        }
    }

    private func cancelRow() -> UIView {
        settingsChipRow(
            "CANCEL",
            accessibilityLabel: String(localized: "Cancel the model download")
        ) { [weak self] in
            self?.store.cancel()
        }
    }

    private func statusRow(
        _ text: String,
        badge badgeText: String,
        multiline: Bool = false
    ) -> (inset: UIView, stack: UIStackView, badge: UIView) {
        let label = UILabel()
        label.text = text
        label.font = UIKitChassis.uiFont(12, weight: .semibold)
        label.textColor = UIKitChassis.signal
        label.numberOfLines = multiline ? 0 : 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let badge = SettingsBadgeView(badgeText)
        let stack = UIStackView(arrangedSubviews: [label, settingsFlexibleSpacer(), badge])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        let inset = SettingsInsetRow(contentView: stack)
        inset.isAccessibilityElement = true
        inset.accessibilityLabel = text
        inset.accessibilityValue = badgeText
        return (inset, stack, badge)
    }
}
