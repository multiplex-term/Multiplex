#if canImport(CTailscaleRS)
import UIKit

/// Settings › Tailscale: the embedded node's auth key, an optional Headscale
/// control URL, and a live status lamp. Edits stay local until Done, which
/// saves them (the owner holds the sheet open while dirty).
@MainActor
final class SettingsTailscaleSection: UIView {
    var onDirtyChange: ((Bool) -> Void)?

    private var authKey = ""
    private var controlURL = ""
    /// nil until the Keychain read lands; the fields stay disabled until then
    /// so a save can never overwrite a key it hasn't seen.
    private var saved: TailscaleTunnel.Configuration?
    private let authKeyField: AddHostRevealableSecretField
    private let controlURLField = UITextField()
    private let lampHolder = UIView()
    private let addressLabel = UILabel()
    private var stateTask: Task<Void, Never>?

    var isDirty: Bool {
        guard let saved else { return false }
        return current != saved
    }

    private var current: TailscaleTunnel.Configuration {
        TailscaleTunnel.Configuration(authKey: authKey, controlURL: controlURL)
    }

    init() {
        var sink: ((String) -> Void)?
        authKeyField = AddHostRevealableSecretField(
            title: String(localized: "Tailscale auth key"),
            prompt: "tskey-auth-…",
            text: ""
        ) { sink?($0) }
        super.init(frame: .zero)
        sink = { [weak self] text in
            self?.authKey = text
            self?.dirtyChanged()
        }

        controlURLField.font = UIKitChassis.monoFont(12)
        controlURLField.textColor = UIKitChassis.signal
        controlURLField.tintColor = UIKitChassis.signal
        controlURLField.attributedPlaceholder = NSAttributedString(
            string: String(localized: "Optional · Headscale URL"),
            attributes: [.foregroundColor: UIKitChassis.signal3]
        )
        controlURLField.keyboardType = .URL
        controlURLField.autocorrectionType = .no
        controlURLField.autocapitalizationType = .none
        controlURLField.accessibilityLabel = String(localized: "Control URL")
        controlURLField.addTarget(self, action: #selector(controlURLChanged), for: .editingChanged)

        addressLabel.font = UIKitChassis.monoFont(10, weight: .medium)
        addressLabel.textColor = UIKitChassis.signal2
        addressLabel.textAlignment = .right
        addressLabel.numberOfLines = 0
        let status = UIStackView(arrangedSubviews: [lampHolder, UIView(), addressLabel])
        status.axis = .horizontal
        status.alignment = .center
        status.spacing = 12

        let section = SettingsSectionView(
            title: "Tailscale",
            detail: String(localized: """
                Experimental. Use a reusable auth key — it syncs through iCloud Keychain, and \
                each device joins as its own tailnet node. The optional Headscale control URL \
                stays on this device. Changes apply the next time the embedded node starts.
                """),
            rows: [
                AddHostFieldRow(label: String(localized: "Auth key"), inputView: authKeyField),
                AddHostFieldRow(label: String(localized: "Control URL"), inputView: controlURLField),
                SettingsInsetRow(contentView: status),
            ]
        )
        addSubview(section)
        section.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: leadingAnchor),
            section.trailingAnchor.constraint(equalTo: trailingAnchor),
            section.topAnchor.constraint(equalTo: topAnchor),
            section.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setEditable(false)
        render(.stopped)
        load()
        observeState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        stateTask?.cancel()
    }

    func save() async {
        guard isDirty else { return }
        setEditable(false)
        let configuration = current
        await TailscaleTunnel.saveConfiguration(configuration)
        saved = configuration
        setEditable(true)
        dirtyChanged()
    }

    private func load() {
        Task { @MainActor [weak self] in
            let configuration = await TailscaleTunnel.loadConfiguration()
            guard let self else { return }
            self.authKey = configuration.authKey
            self.controlURL = configuration.controlURL
            self.saved = configuration
            self.authKeyField.setText(configuration.authKey)
            self.controlURLField.text = configuration.controlURL
            self.setEditable(true)
        }
    }

    private func observeState() {
        stateTask = Task { @MainActor [weak self] in
            let updates = await TailscaleTunnel.shared.stateUpdates()
            for await update in updates {
                guard !Task.isCancelled else { return }
                self?.render(update)
            }
        }
    }

    private func render(_ state: TailscaleTunnel.State) {
        let (caption, color): (String, UIColor) = switch state {
        case .stopped: ("STOPPED", UIKitChassis.signal3)
        case .starting: ("STARTING", TallyPalette.caution)
        case .running: ("RUNNING", TallyPalette.ok)
        }
        lampHolder.subviews.forEach { $0.removeFromSuperview() }
        let lamp = UIKitTallyLamp(caption: caption, color: color)
        lampHolder.addSubview(lamp)
        lamp.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            lamp.leadingAnchor.constraint(equalTo: lampHolder.leadingAnchor),
            lamp.trailingAnchor.constraint(equalTo: lampHolder.trailingAnchor),
            lamp.topAnchor.constraint(equalTo: lampHolder.topAnchor),
            lamp.bottomAnchor.constraint(equalTo: lampHolder.bottomAnchor),
        ])
        if case .running(let ips) = state {
            addressLabel.text = ips.isEmpty ? "TAILNET READY" : ips.joined(separator: " · ")
        } else {
            addressLabel.text = nil
        }
    }

    private func setEditable(_ editable: Bool) {
        authKeyField.isUserInteractionEnabled = editable
        controlURLField.isEnabled = editable
        alpha = editable ? 1 : 0.6
    }

    private func dirtyChanged() {
        onDirtyChange?(isDirty)
    }

    @objc private func controlURLChanged() {
        controlURL = controlURLField.text ?? ""
        dirtyChanged()
    }
}
#endif
