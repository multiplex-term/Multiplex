import UIKit

/// The ✳ Agent Gallery pane — the herdr chat surface: agent rail on the
/// left (every agent pane on the host, with live herdr states), the
/// selected agent's visible screen on the right, and the composer in the
/// pane's TOP contextual slot (the viewport address-editor precedent: this
/// window opts out of SwiftUI keyboard avoidance for the terminal's sake,
/// and a bottom field would sit under a docked keyboard).
///
/// Auxiliary-pane rules, shared with the viewport and file viewer: no
/// `TerminalFocusArbiter` claim, no tally dot, controller-owned state that
/// survives merge/split, and the whole tab is summoned, never restored.
@MainActor
final class AgentGalleryPaneViewController: UIViewController, UITextFieldDelegate {
    private let controller: AgentGalleryController
    private let model: HostConnectionModel
    private var contentSafeArea: UIEdgeInsets
    private var close: () -> Void
    private var openTerminal: (TerminalRoute.Mode) -> Void

    private let composerBar = UIView()
    private let composerField = UITextField()
    private var sendChip: UIKitChassisChip!
    private let deliveryLabel = UIKitChassisLabel("", size: 10, color: TallyPalette.caution)
    private let railScroll = UIScrollView()
    private let railStack = UIStackView()
    private let screenView = UITextView()
    private let bannerView = UIView()
    private let bannerLabel = UIKitChassisLabel("", size: 11, color: TallyPalette.caution)
    private var bannerTerminalChip: UIKitChassisChip!
    private let emptyLabel = UILabel()

    private var agents: [GalleryAgent] = []
    private var watchTask: Task<Void, Never>?
    private var isActivePane = false

    init(
        controller: AgentGalleryController,
        model: HostConnectionModel,
        contentSafeArea: UIEdgeInsets,
        isActive: Bool,
        close: @escaping () -> Void,
        openTerminal: @escaping (TerminalRoute.Mode) -> Void
    ) {
        self.controller = controller
        self.model = model
        self.contentSafeArea = contentSafeArea
        self.close = close
        self.openTerminal = openTerminal
        self.isActivePane = isActive
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    func update(
        contentSafeArea: UIEdgeInsets,
        isActive: Bool,
        close: @escaping () -> Void,
        openTerminal: @escaping (TerminalRoute.Mode) -> Void
    ) {
        self.contentSafeArea = contentSafeArea
        self.close = close
        self.openTerminal = openTerminal
        if isActivePane != isActive {
            isActivePane = isActive
            if isActive {
                startWatching()
            } else {
                stopWatching()
            }
        }
    }

    func prepareForRemoval() {
        stopWatching()
    }

    deinit {
        watchTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIKitChassis.chassis

        // Composer — the TOP contextual slot.
        composerBar.backgroundColor = UIKitChassis.bezel
        composerField.font = UIKitChassis.monoFont(12)
        composerField.textColor = UIKitChassis.signal
        composerField.attributedPlaceholder = NSAttributedString(
            string: "Prompt the selected agent…",
            attributes: [.foregroundColor: UIKitChassis.signal3]
        )
        composerField.autocorrectionType = .no
        composerField.autocapitalizationType = .none
        composerField.returnKeyType = .send
        composerField.delegate = self
        composerField.accessibilityLabel = "Agent prompt"
        sendChip = UIKitChassisChip(
            "SEND", accessibilityLabel: "Send prompt"
        ) { [weak self] in self?.sendPrompt() }
        deliveryLabel.numberOfLines = 1

        let composerStack = UIStackView(
            arrangedSubviews: [composerField, sendChip])
        composerStack.axis = .horizontal
        composerStack.spacing = 8
        composerStack.alignment = .center
        composerBar.addSubview(composerStack)
        composerBar.addSubview(deliveryLabel)
        composerStack.translatesAutoresizingMaskIntoConstraints = false
        deliveryLabel.translatesAutoresizingMaskIntoConstraints = false

        // Rail.
        railStack.axis = .vertical
        railStack.spacing = 1
        railStack.alignment = .fill
        railScroll.addSubview(railStack)
        railStack.translatesAutoresizingMaskIntoConstraints = false

        // Screen.
        screenView.isEditable = false
        screenView.backgroundColor = UIKitChassis.screen
        screenView.font = UIKitChassis.monoFont(11)
        screenView.textColor = TallyPalette.miniText
        screenView.textContainerInset = UIEdgeInsets(
            top: 8, left: 8, bottom: 8, right: 8)
        screenView.accessibilityLabel = "Agent screen"

        // Blocked banner.
        bannerView.backgroundColor = UIKitChassis.bezel
        bannerTerminalChip = UIKitChassisChip(
            "TERMINAL", accessibilityLabel: "Open this agent's terminal"
        ) { [weak self] in self?.openSelectedTerminal() }
        let typeChip = UIKitChassisChip(
            "TYPE…", accessibilityLabel: "Answer in the composer"
        ) { [weak self] in self?.composerField.becomeFirstResponder() }
        let bannerStack = UIStackView(
            arrangedSubviews: [bannerLabel, UIView(), bannerTerminalChip, typeChip])
        bannerStack.axis = .horizontal
        bannerStack.spacing = 8
        bannerStack.alignment = .center
        bannerView.addSubview(bannerStack)
        bannerStack.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .preferredFont(forTextStyle: .footnote)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = UIKitChassis.signal2
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.text = "No agents detected on this host yet — start one "
            + "in a workspace and it appears here."

        [composerBar, railScroll, bannerView, screenView, emptyLabel].forEach {
            view.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            composerBar.topAnchor.constraint(equalTo: view.topAnchor),
            composerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBar.heightAnchor.constraint(equalToConstant: 58),
            composerStack.leadingAnchor.constraint(
                equalTo: composerBar.leadingAnchor, constant: 10),
            composerStack.trailingAnchor.constraint(
                equalTo: composerBar.trailingAnchor, constant: -10),
            composerStack.topAnchor.constraint(
                equalTo: composerBar.topAnchor, constant: 8),
            deliveryLabel.leadingAnchor.constraint(
                equalTo: composerBar.leadingAnchor, constant: 10),
            deliveryLabel.bottomAnchor.constraint(
                equalTo: composerBar.bottomAnchor, constant: -3),

            railScroll.topAnchor.constraint(equalTo: composerBar.bottomAnchor),
            railScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            railScroll.widthAnchor.constraint(equalToConstant: 210),
            railScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            railStack.topAnchor.constraint(equalTo: railScroll.contentLayoutGuide.topAnchor),
            railStack.leadingAnchor.constraint(
                equalTo: railScroll.contentLayoutGuide.leadingAnchor),
            railStack.trailingAnchor.constraint(
                equalTo: railScroll.contentLayoutGuide.trailingAnchor),
            railStack.bottomAnchor.constraint(
                equalTo: railScroll.contentLayoutGuide.bottomAnchor),
            railStack.widthAnchor.constraint(equalTo: railScroll.frameLayoutGuide.widthAnchor),

            bannerView.topAnchor.constraint(equalTo: composerBar.bottomAnchor),
            bannerView.leadingAnchor.constraint(equalTo: railScroll.trailingAnchor, constant: 1),
            bannerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bannerStack.leadingAnchor.constraint(
                equalTo: bannerView.leadingAnchor, constant: 10),
            bannerStack.trailingAnchor.constraint(
                equalTo: bannerView.trailingAnchor, constant: -10),
            bannerStack.topAnchor.constraint(equalTo: bannerView.topAnchor, constant: 6),
            bannerStack.bottomAnchor.constraint(equalTo: bannerView.bottomAnchor, constant: -6),

            screenView.topAnchor.constraint(equalTo: bannerView.bottomAnchor),
            screenView.leadingAnchor.constraint(
                equalTo: railScroll.trailingAnchor, constant: 1),
            screenView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            screenView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: screenView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: screenView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])

        renderAll()
        if isActivePane { startWatching() }
    }

    // MARK: Watch (file-viewer discipline: active tab + active app only)

    private func startWatching() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if UIApplication.shared.applicationState == .active {
                    self.renderAll()
                    await self.controller.refreshScreen()
                    self.renderScreen()
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    // MARK: Render

    private func renderAll() {
        let rows = AgentGallery.agents(
            sessions: model.tmux.sessions,
            statuses: model.herdrStatuses()
        )
        let selection = AgentGallery.resolvedSelection(
            previous: controller.selectedPaneID, agents: rows)
        if selection != controller.selectedPaneID {
            controller.select(selection)
        }
        if rows != agents {
            agents = rows
            renderRail()
        }
        renderBanner()
        renderScreen()
        emptyLabel.isHidden = !rows.isEmpty
    }

    private func renderRail() {
        railStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for agent in agents {
            railStack.addArrangedSubview(makeRailRow(agent))
        }
    }

    private func makeRailRow(_ agent: GalleryAgent) -> UIView {
        let selected = agent.paneID == controller.selectedPaneID
        let row = UIButton(type: .custom)
        row.backgroundColor = selected ? UIKitChassis.bezelHi : UIKitChassis.bezel
        row.hoverStyle = UIHoverStyle(
            effect: .highlight,
            shape: .rect(cornerRadius: 2)
        )
        let name = UIKitChassisLabel(agent.displayName, size: 11)
        let place = UIKitChassisLabel(
            agent.workspaceName, size: 9, color: UIKitChassis.signal2)
        let status = UIKitChassisLabel(
            agent.statusWord, size: 9,
            color: agent.needsYou ? TallyPalette.caution : UIKitChassis.signal3
        )
        let stack = UIStackView(arrangedSubviews: [name, place, status])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.isUserInteractionEnabled = false
        row.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8),
        ])
        row.accessibilityLabel = "\(agent.displayName) in \(agent.workspaceName), \(agent.statusWord)"
        row.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.controller.select(agent.paneID)
            self.renderAll()
        }, for: .touchUpInside)
        return row
    }

    private var selectedAgent: GalleryAgent? {
        agents.first { $0.paneID == controller.selectedPaneID }
    }

    private func renderBanner() {
        guard let selected = selectedAgent, selected.needsYou else {
            bannerView.isHidden = true
            return
        }
        bannerView.isHidden = false
        // 0.7.5 surfaces no blocked message anywhere readable, so the
        // banner states the fact and offers the two honest doors.
        bannerLabel.setText("NEEDS YOU — \(selected.displayName) is waiting")
    }

    private func renderScreen() {
        if let note = controller.screenNote {
            screenView.text = note
            return
        }
        let text = controller.screenLines.joined(separator: "\n")
        if screenView.text != text { screenView.text = text }
        if let note = controller.deliveryNote {
            deliveryLabel.setText(note)
            deliveryLabel.isHidden = false
        } else {
            deliveryLabel.isHidden = true
        }
        sendChip.alpha = controller.isSending ? 0.4 : 1
    }

    private func openSelectedTerminal() {
        guard let selected = selectedAgent else { return }
        // Decision #4's agent door: the scoped, chrome-free single-agent
        // attach — never the full client (that's the deck tile's road).
        openTerminal(.herdrAgentAttach(
            target: selected.paneID,
            label: "\(selected.herdrKind) · \(selected.workspaceName)"
        ))
    }

    private func sendPrompt() {
        guard let text = composerField.text,
              !text.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        composerField.text = ""
        Task { [weak self] in
            await self?.controller.send(prompt: text)
            self?.renderScreen()
        }
    }

    // MARK: UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendPrompt()
        return false
    }
}
