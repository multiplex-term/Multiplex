import Observation
import os
import UIKit
#if DEBUG
import notify
#endif

/// Everything the window hands the composer. The controller is the identity
/// (whose draft the box renders and edits); `presentation` is the chrome the
/// eyebrow and geometry follow, comparable so a window render that changed
/// nothing costs nothing; the closures are the two ways out.
@MainActor
struct TalkbackComposerConfiguration {
    var controller: TerminalSessionController
    var presentation: TalkbackComposerPresentation
    /// The header's ✕ and the talk key: close the box (the draft survives).
    var close: () -> Void
    /// A hardware Escape in the field: hand the keyboard back to the pane.
    var focusTerminal: () -> Void
}

/// The comparable half of the configuration.
struct TalkbackComposerPresentation: Equatable {
    /// The UMD's source label — `MAIN · DEVBOX`.
    var targetLabel: String
    var agent: AgentKind?
    /// Fail-soft telemetry for the eyebrow: `.busy` reads RUNNING, `.needsYou`
    /// lights the amber lamp, anything else says nothing.
    var agentState: PaneAgentState?
    /// The phone's previews: 28 pt photo thumbs and compact document chips
    /// instead of 46 pt squares (Jhen, 2026-08-17).
    var compactPreviews: Bool
    /// visionOS: the card rides an ornament slab, so the band around it is
    /// the slab's own ground rather than the window's bezel strip.
    var floating: Bool
    /// The width the box lays out for — the window's, or the ornament's
    /// console clamp. The field's line count (and so the box's height) is
    /// derived from it, which keeps `fittingContentSize` arithmetic.
    var availableWidth: CGFloat
    var contentSafeArea: UIEdgeInsets
}

/// Candidate B — MESSAGE CARD. A rounded card on the chassis band above the
/// key rail (iPad · iPhone) or in its own slab under the visionOS console:
/// an eyebrow naming the target, previews of the attachments, a round
/// paperclip, a native text field, and a filled ↑ that sends. The field owns
/// the keyboard while the rail keeps driving the pane; SEND is one paste plus
/// a CR through the ordered pump. Design record: `local-plan/talkback-bakeoff/`.
@MainActor
final class TalkbackComposerViewController: UIViewController, UITextViewDelegate {
    static let cardCornerRadius: CGFloat = 14
    static let roundButtonDiameter: CGFloat = 30
    static let previewSize: CGFloat = 46
    static let compactPreviewSize: CGFloat = 28
    static let bandHorizontalInset: CGFloat = 10
    static let bandTopInset: CGFloat = 8
    static let bandBottomInset: CGFloat = 9
    static let cardPadding = UIEdgeInsets(top: 8, left: 10, bottom: 9, right: 10)
    static let rowSpacing: CGFloat = 7
    static let lineSpacing: CGFloat = 8
    static let headerHeight: CGFloat = 20
    static let fieldInsets = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
    /// The card fades while the pane owns the keyboard — the draft and the
    /// ↑ stay live, the box just steps back.
    static let unfocusedAlpha: CGFloat = 0.72

    /// The composer is the only witness to its own height changes (a line
    /// typed, a chip attached); the window re-insets the pane on this.
    var onContentSizeChange: (() -> Void)?

    private(set) var configuration: TalkbackComposerConfiguration
    private var observationGeneration = 0
    private var renderedKey: RenderKey?
    private var renderedPreviewKey: PreviewKey?
    private var renderedAttachKey: AttachKey?
    private var pendingFocus = false
    private var lastReportedSize: CGSize = .zero
    /// One TextKit measurement per (text, width) — every sizing question in a
    /// pass reads it instead of re-laying the body out.
    private var measuredField: FieldMeasurement?

    private let band = UIView()
    private let bandRule = UIView()
    private let card = UIKitTallyBorderedView()
    private let content = UIStackView()
    private let header = UIStackView()
    private let toLabel = UIKitChassisMonoLabel()
    private let targetLabel = UILabel()
    private let agentLabel = UILabel()
    private let stateLabel = UIKitChassisMonoLabel()
    private var needsYouLamp: UIKitTallyLamp?
    private let closeButton = TalkbackRoundButton(diameter: 20, symbol: "xmark", pointSize: 9)
    private let previewScroll = UIScrollView()
    private let previewRow = UIStackView()
    private var previewHeightConstraint: NSLayoutConstraint?
    private let line = UIStackView()
    private let attachButton = TalkbackRoundButton(
        diameter: TalkbackComposerViewController.roundButtonDiameter,
        symbol: "paperclip",
        pointSize: 13
    )
    private let textView = TalkbackTextView()
    private let placeholder = UILabel()
    private let sendButton = TalkbackRoundButton(
        diameter: TalkbackComposerViewController.roundButtonDiameter,
        symbol: "arrow.up",
        pointSize: 13,
        weight: .bold
    )
    private var textHeightConstraint: NSLayoutConstraint?
    private var cardLeading: NSLayoutConstraint?
    private var cardTrailing: NSLayoutConstraint?
    /// The paperclip's pickers: FILE's own presenter, with its deliveries
    /// routed into the target's draft instead of the pane.
    private let attachPresenter = FileAttachPickerPresenterViewController()
    private var keyWindowObserver: NSObjectProtocol?
    #if DEBUG
    private var debugObservers: [NSObjectProtocol] = []
    private static let keyboardLogger = Logger(
        subsystem: "app.multiplexterm.multiplex",
        category: "kbd"
    )
    #endif

    private struct RenderKey: Equatable {
        var presentation: TalkbackComposerPresentation
        var controllerID: ObjectIdentifier
        var state: TalkbackObservedState
    }

    private struct PreviewKey: Equatable {
        var ids: [UUID]
        var compact: Bool
    }

    private struct AttachKey: Equatable {
        var controllerID: ObjectIdentifier
        var enabled: Bool
    }

    private struct FieldMeasurement {
        var text: String
        var width: CGFloat
        var height: CGFloat
        var scrolls: Bool
    }

    init(configuration: TalkbackComposerConfiguration) {
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
        }
        #if DEBUG
        for observer in debugObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    // MARK: Lifecycle

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .clear
        view = root
        buildHierarchy()
        installAttachPresenter()
        installKeyWindowObserver()
        #if DEBUG
        installDebugObservers()
        #endif
        renderAndObserve()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        focusPendingFieldIfNeeded()
        reportSizeIfChanged()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        focusPendingFieldIfNeeded()
    }

    /// Store everything (the closures are fresh each render); re-render only
    /// when the comparable half or the controller changed — `render` gates
    /// on the same key.
    func update(configuration: TalkbackComposerConfiguration) {
        let identityChanged = configuration.controller !== self.configuration.controller
        let presentationChanged = configuration.presentation != self.configuration.presentation
        self.configuration = configuration
        guard isViewLoaded, identityChanged || presentationChanged else { return }
        renderAndObserve()
    }

    /// The window is about to drop the composer: stop observing so a late
    /// render can't touch a controller that moved on. Reports whether the
    /// field held the keyboard, so the caller can hand it back to the pane.
    @discardableResult
    func prepareForRemoval() -> Bool {
        observationGeneration &+= 1
        let hadKeyboard = textView.isFirstResponder
        if hadKeyboard { textView.resignFirstResponder() }
        return hadKeyboard
    }

    /// Take the keyboard — now if the view is on screen, else at the first
    /// layout after it lands (the ornament mounts on SwiftUI's next turn).
    private func focusField() {
        guard isViewLoaded, view.window != nil else {
            pendingFocus = true
            return
        }
        guard !textView.isFirstResponder else { return }
        textView.becomeFirstResponder()
    }

    private func focusPendingFieldIfNeeded() {
        guard pendingFocus, view.window != nil else { return }
        pendingFocus = false
        focusField()
    }

    // MARK: Sizing

    /// The box's height for a width, from the same arithmetic the layout
    /// uses — the window insets the pane by this before UIKit lays anything
    /// out, so it can never disagree with what appears. Defaults to the
    /// width the configuration handed in.
    func fittingContentSize(for width: CGFloat? = nil) -> CGSize {
        loadViewIfNeeded()
        let width = max(1, width ?? configuration.presentation.availableWidth)
        var height = Self.bandTopInset + Self.bandBottomInset
            + Self.cardPadding.top + Self.cardPadding.bottom
            + Self.headerHeight
        if !configuration.controller.talkback.attachments.isEmpty {
            height += Self.rowSpacing + previewSize
        }
        height += Self.rowSpacing + max(Self.roundButtonDiameter, fieldMetrics(forWidth: width).height)
        return CGSize(width: width, height: ceil(height))
    }

    private var previewSize: CGFloat {
        configuration.presentation.compactPreviews ? Self.compactPreviewSize : Self.previewSize
    }

    /// FILE's rule: an SSH-backed session tab can upload; mosh and plain
    /// shells hide the paperclip (text still works there). A per-tab fact.
    private var showsAttachButton: Bool {
        FileAttachAvailability.canOffer(for: configuration.controller)
    }

    private var bandHorizontalInsets: (left: CGFloat, right: CGFloat) {
        let presentation = configuration.presentation
        let base = presentation.floating ? 8 : Self.bandHorizontalInset
        return (
            base + presentation.contentSafeArea.left,
            base + presentation.contentSafeArea.right
        )
    }

    /// The field's width for a box width: everything else in the line row is
    /// fixed — two round buttons and their gaps (one button when the tab
    /// can't attach).
    private func fieldWidth(forWidth width: CGFloat) -> CGFloat {
        let insets = bandHorizontalInsets
        var fixed = insets.left + insets.right
            + Self.cardPadding.left + Self.cardPadding.right
            + Self.roundButtonDiameter + Self.lineSpacing
        if showsAttachButton {
            fixed += Self.roundButtonDiameter + Self.lineSpacing
        }
        return max(40, width - fixed)
    }

    /// The field's height at a width — one line at least, five at most, and
    /// whether it scrolls inside itself past that. Measured once per
    /// (text, width) and reused by every sizing question in the pass.
    private func fieldMetrics(forWidth width: CGFloat) -> (height: CGFloat, scrolls: Bool) {
        let fieldWidth = fieldWidth(forWidth: width)
        let text = textView.text ?? ""
        if let measured = measuredField, measured.text == text, measured.width == fieldWidth {
            return (measured.height, measured.scrolls)
        }
        let lineHeight = textView.font?.lineHeight ?? 18
        let insets = Self.fieldInsets.top + Self.fieldInsets.bottom
        let minimum = ceil(lineHeight + insets)
        let maximum = ceil(lineHeight * CGFloat(TalkbackMessage.maximumVisibleLines) + insets)
        let content = ceil(textView.sizeThatFits(
            CGSize(width: fieldWidth, height: .greatestFiniteMagnitude)
        ).height)
        let measurement = FieldMeasurement(
            text: text,
            width: fieldWidth,
            height: min(maximum, max(minimum, content)),
            scrolls: content > maximum
        )
        measuredField = measurement
        return (measurement.height, measurement.scrolls)
    }

    private func refreshFieldHeight() {
        let metrics = fieldMetrics(forWidth: configuration.presentation.availableWidth)
        if textView.isScrollEnabled != metrics.scrolls { textView.isScrollEnabled = metrics.scrolls }
        if textHeightConstraint?.constant != metrics.height {
            textHeightConstraint?.constant = metrics.height
            view.setNeedsLayout()
        }
    }

    private func reportSizeIfChanged() {
        let size = fittingContentSize()
        guard size != lastReportedSize else { return }
        lastReportedSize = size
        if preferredContentSize != size { preferredContentSize = size }
        onContentSizeChange?()
    }

    // MARK: Hierarchy

    private func buildHierarchy() {
        band.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(band)
        NSLayoutConstraint.activate([
            band.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            band.topAnchor.constraint(equalTo: view.topAnchor),
            band.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        bandRule.translatesAutoresizingMaskIntoConstraints = false
        band.addSubview(bandRule)
        NSLayoutConstraint.activate([
            bandRule.leadingAnchor.constraint(equalTo: band.leadingAnchor),
            bandRule.trailingAnchor.constraint(equalTo: band.trailingAnchor),
            bandRule.topAnchor.constraint(equalTo: band.topAnchor),
            bandRule.heightAnchor.constraint(equalToConstant: 1),
        ])

        card.layer.cornerRadius = Self.cardCornerRadius
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.accessibilityIdentifier = "terminal.talkback.card"
        card.translatesAutoresizingMaskIntoConstraints = false
        band.addSubview(card)
        let leading = card.leadingAnchor.constraint(equalTo: band.leadingAnchor)
        let trailing = card.trailingAnchor.constraint(equalTo: band.trailingAnchor)
        cardLeading = leading
        cardTrailing = trailing
        NSLayoutConstraint.activate([
            leading,
            trailing,
            card.topAnchor.constraint(equalTo: band.topAnchor, constant: Self.bandTopInset),
            card.bottomAnchor.constraint(equalTo: band.bottomAnchor, constant: -Self.bandBottomInset),
        ])

        content.axis = .vertical
        content.spacing = Self.rowSpacing
        content.alignment = .fill
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(
                equalTo: card.leadingAnchor,
                constant: Self.cardPadding.left
            ),
            content.trailingAnchor.constraint(
                equalTo: card.trailingAnchor,
                constant: -Self.cardPadding.right
            ),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: Self.cardPadding.top),
            content.bottomAnchor.constraint(
                equalTo: card.bottomAnchor,
                constant: -Self.cardPadding.bottom
            ),
        ])

        buildHeader()
        buildPreviewRow()
        buildLine()
        content.addArrangedSubview(header)
        content.addArrangedSubview(previewScroll)
        content.addArrangedSubview(line)
    }

    private func buildHeader() {
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 8
        header.heightAnchor.constraint(equalToConstant: Self.headerHeight).isActive = true

        toLabel.configure(
            "TO",
            font: UIKitChassis.monoFont(9, weight: .semibold),
            color: UIKitChassis.signal3,
            kern: 0.9
        )
        toLabel.setContentHuggingPriority(.required, for: .horizontal)
        toLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // The eyebrow keeps B's sans voice (the bake-off's chat grammar); the
        // target's words are the UMD's, uppercased to match its case.
        targetLabel.font = UIKitChassis.uiFont(11)
        targetLabel.textColor = UIKitChassis.signal2
        targetLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        targetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        targetLabel.lineBreakMode = .byTruncatingTail

        agentLabel.font = UIKitChassis.uiFont(11, weight: .semibold)
        agentLabel.textColor = UIKitChassis.signal
        agentLabel.setContentHuggingPriority(.required, for: .horizontal)
        agentLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        stateLabel.configure(
            "",
            font: UIKitChassis.monoFont(9, weight: .semibold),
            color: UIKitChassis.signal3,
            kern: 0.9
        )
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)
        stateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.accessibilityLabel = "Close message box"
        closeButton.accessibilityIdentifier = "terminal.talkback.close"
        closeButton.addTarget(self, action: #selector(closePressed), for: .touchUpInside)

        for view in [toLabel, targetLabel, agentLabel, stateLabel, spacer, closeButton] {
            header.addArrangedSubview(view)
        }
    }

    private func buildPreviewRow() {
        previewScroll.showsHorizontalScrollIndicator = false
        previewScroll.alwaysBounceHorizontal = false
        previewScroll.clipsToBounds = false
        previewScroll.accessibilityIdentifier = "terminal.talkback.previews"
        previewRow.axis = .horizontal
        previewRow.alignment = .center
        previewRow.spacing = 8
        previewRow.translatesAutoresizingMaskIntoConstraints = false
        previewScroll.addSubview(previewRow)
        NSLayoutConstraint.activate([
            previewRow.leadingAnchor.constraint(equalTo: previewScroll.contentLayoutGuide.leadingAnchor),
            previewRow.trailingAnchor.constraint(equalTo: previewScroll.contentLayoutGuide.trailingAnchor),
            previewRow.topAnchor.constraint(equalTo: previewScroll.contentLayoutGuide.topAnchor),
            previewRow.bottomAnchor.constraint(equalTo: previewScroll.contentLayoutGuide.bottomAnchor),
            previewRow.heightAnchor.constraint(equalTo: previewScroll.frameLayoutGuide.heightAnchor),
        ])
        let height = previewScroll.heightAnchor.constraint(equalToConstant: Self.previewSize)
        height.isActive = true
        previewHeightConstraint = height
        previewScroll.isHidden = true
    }

    private func buildLine() {
        line.axis = .horizontal
        line.alignment = .bottom
        line.spacing = Self.lineSpacing

        attachButton.accessibilityLabel = "Attach a file"
        attachButton.accessibilityIdentifier = "terminal.talkback.attach"
        attachButton.showsMenuAsPrimaryAction = true

        textView.delegate = self
        textView.accessibilityIdentifier = "terminal.talkback.field"
        textView.accessibilityLabel = "Message"
        textView.font = UIKitChassis.uiFont(15)
        textView.textColor = UIKitChassis.signal
        textView.backgroundColor = .clear
        textView.textContainerInset = Self.fieldInsets
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.keyboardType = .default
        textView.returnKeyType = .default
        textView.autocorrectionType = .default
        textView.spellCheckingType = .default
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardAppearance = .default
        textView.onSend = { [weak self] in self?.send(submit: true) }
        textView.onEscape = { [weak self] in self?.configuration.focusTerminal() }
        let textHeight = textView.heightAnchor.constraint(equalToConstant: 30)
        textHeight.priority = .required
        textHeight.isActive = true
        textHeightConstraint = textHeight

        placeholder.font = textView.font
        placeholder.textColor = UIKitChassis.signal3
        placeholder.isUserInteractionEnabled = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(
                equalTo: textView.leadingAnchor,
                constant: Self.fieldInsets.left
            ),
            placeholder.topAnchor.constraint(
                equalTo: textView.topAnchor,
                constant: Self.fieldInsets.top
            ),
        ])

        sendButton.accessibilityLabel = "Send"
        sendButton.accessibilityIdentifier = "terminal.talkback.send"
        sendButton.addTarget(self, action: #selector(sendPressed), for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(sendHeld(_:)))
        hold.minimumPressDuration = 0.5
        sendButton.addGestureRecognizer(hold)

        line.addArrangedSubview(attachButton)
        line.addArrangedSubview(textView)
        line.addArrangedSubview(sendButton)
    }

    /// The pane taking the keyboard back is a window becoming key on
    /// visionOS (the card lives in the ornament's own window, the terminal in
    /// the scene's): the field then steps down so the card dims and a later
    /// tap on it starts a fresh hand-over. Only ANOTHER window counts — the
    /// iPad card shares the terminal's window, and Stage Manager flips a
    /// window's key state transiently while it is moved.
    private func installKeyWindowObserver() {
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let window = note.object as? UIWindow,
                      window !== self.textView.window,
                      window === self.configuration.controller.terminalView?.window,
                      self.textView.isFirstResponder
                else { return }
                self.textView.resignFirstResponder()
            }
        }
    }

    private func installAttachPresenter() {
        addChild(attachPresenter)
        attachPresenter.view.frame = .zero
        attachPresenter.view.isHidden = true
        view.addSubview(attachPresenter.view)
        attachPresenter.didMove(toParent: self)
        // The presenter snapshotted its target when the picker opened; the
        // bytes go to that tab's draft even if this composer moved on.
        attachPresenter.deliver = { target, files in
            target.attachTalkbackFiles(files)
        }
    }

    // MARK: Render

    private func renderAndObserve(generation: Int? = nil) {
        let generation = generation ?? {
            observationGeneration &+= 1
            return observationGeneration
        }()
        guard generation == observationGeneration else { return }
        let controller = configuration.controller
        // The draft's text is deliberately not part of this snapshot: the
        // field is its writer, and a keystroke must not re-render the box.
        let snapshot = withObservationTracking {
            TalkbackObservedState(
                attachments: controller.talkback.attachments,
                focusRequest: controller.talkback.focusRequest,
                sendState: controller.talkbackSendState,
                canAttachNow: FileAttachMenuAvailability(controller: controller).actionsEnabled
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.renderAndObserve(generation: generation)
            }
        }
        render(snapshot)
    }

    private func render(_ state: TalkbackObservedState) {
        let controller = configuration.controller
        let key = RenderKey(
            presentation: configuration.presentation,
            controllerID: ObjectIdentifier(controller),
            state: state
        )
        guard key != renderedKey else { return }
        let controllerChanged = key.controllerID != renderedKey?.controllerID
        renderedKey = key

        if controllerChanged {
            attachPresenter.update(controller: controller)
            // The draft is the text of record across a tab switch; the field
            // is its writer otherwise (SEND clears both).
            textView.text = controller.talkback.text
            placeholder.isHidden = !textView.text.isEmpty
        }
        renderChrome()
        renderHeader()
        placeholder.text = TalkbackMessage.placeholder(
            agentName: configuration.presentation.agent?.displayName
        )
        renderPreviews(state.attachments)
        renderButtons(state)
        refreshFieldHeight()

        // The talk key asked for the keyboard; a tab switch back to an
        // open box did not (the request is per tab and consumed once).
        if controller.consumeTalkbackFocusRequest() {
            focusField()
        }
        view.setNeedsLayout()
        reportSizeIfChanged()
    }

    private func renderChrome() {
        let insets = bandHorizontalInsets
        cardLeading?.constant = insets.left
        cardTrailing?.constant = -insets.right
        // PROTOTYPE(GLASS): the card is a raised strata face over the
        // ornament slab or the window's bezel band; chassis everywhere else.
        card.backgroundColor = GlassPrototype.strataChassis
        card.tallyBorderColor = UIKitChassis.bezelHi
        if configuration.presentation.floating {
            band.backgroundColor = .clear
            bandRule.isHidden = true
        } else {
            band.backgroundColor = UIKitChassis.bezel
            bandRule.isHidden = false
            bandRule.backgroundColor = UIKitChassis.bezelHi
        }
    }

    private func renderHeader() {
        let presentation = configuration.presentation
        targetLabel.text = presentation.targetLabel.uppercased()
        if let agent = presentation.agent {
            // U+FE0E pins the text presentation: ✳ has an emoji twin the
            // system font would otherwise pick.
            agentLabel.text = "\(agent.glyph)\u{FE0E} \(agent.displayName)"
            agentLabel.isHidden = false
        } else {
            agentLabel.text = nil
            agentLabel.isHidden = true
        }
        let running = presentation.agentState == .busy
        stateLabel.setText(running ? "RUNNING" : "")
        stateLabel.isHidden = !running
        var needsYou = false
        if case .needsYou = presentation.agentState { needsYou = true }
        if needsYou, needsYouLamp == nil {
            let lamp = UIKitTallyLamp(caption: "NEEDS YOU", color: TallyPalette.caution)
            lamp.accessibilityIdentifier = "terminal.talkback.needsYou"
            header.insertArrangedSubview(lamp, at: header.arrangedSubviews.count - 2)
            needsYouLamp = lamp
        } else if !needsYou, let lamp = needsYouLamp {
            header.removeArrangedSubview(lamp)
            lamp.removeFromSuperview()
            needsYouLamp = nil
        }
        header.accessibilityLabel = [
            "To", presentation.targetLabel,
            presentation.agent?.displayName,
            running ? "running" : nil,
            needsYou ? "needs you" : nil,
        ].compactMap { $0 }.joined(separator: " ")
    }

    private func renderPreviews(_ attachments: [TalkbackAttachment]) {
        let compact = configuration.presentation.compactPreviews
        previewHeightConstraint?.constant = previewSize
        previewRow.spacing = compact ? 6 : 8
        let key = PreviewKey(ids: attachments.map(\.id), compact: compact)
        if key != renderedPreviewKey {
            for view in previewRow.arrangedSubviews {
                previewRow.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for attachment in attachments {
                let view = TalkbackAttachmentView(
                    attachment: attachment,
                    size: previewSize,
                    compact: compact,
                    remove: { [weak self] id in
                        self?.configuration.controller.removeTalkbackAttachment(id)
                    },
                    retry: { [weak self] id in
                        self?.configuration.controller.retryTalkbackAttachment(id)
                    }
                )
                previewRow.addArrangedSubview(view)
            }
            renderedPreviewKey = key
        } else {
            for (view, attachment) in zip(previewRow.arrangedSubviews, attachments) {
                (view as? TalkbackAttachmentView)?.update(attachment)
            }
        }
        let hidden = attachments.isEmpty
        if previewScroll.isHidden != hidden { previewScroll.isHidden = hidden }
    }

    private func renderButtons(_ state: TalkbackObservedState) {
        attachButton.isHidden = !showsAttachButton
        attachButton.isEnabled = state.canAttachNow
        // Three actions and three symbol lookups — rebuilt only when what
        // they render on changes.
        let attachKey = AttachKey(
            controllerID: ObjectIdentifier(configuration.controller),
            enabled: state.canAttachNow
        )
        if attachKey != renderedAttachKey {
            attachButton.menu = state.canAttachNow ? attachPresenter.makeSourceMenu() : nil
            renderedAttachKey = attachKey
        }
        switch state.sendState {
        case .ready:
            sendButton.style = .prominent
            sendButton.isEnabled = true
            sendButton.accessibilityLabel = "Send"
        case .waiting:
            sendButton.style = .waiting
            sendButton.isEnabled = false
            sendButton.accessibilityLabel = "Send, waiting for uploads"
        case .disabled:
            sendButton.style = .dim
            sendButton.isEnabled = false
            sendButton.accessibilityLabel = "Send"
        }
    }

    // MARK: Actions

    @objc private func closePressed() {
        configuration.close()
    }

    @objc private func sendPressed() {
        send(submit: true)
    }

    @objc private func sendHeld(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        send(submit: false)
    }

    /// SEND / a long-press SEND (type only). The controller composes the
    /// bytes and clears the draft; the field — its writer — clears itself
    /// (the chips follow through observation).
    func send(submit: Bool) {
        guard configuration.controller.sendTalkback(submit: submit) else { return }
        textView.text = ""
        textViewDidChange(textView)
    }

    // MARK: UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        configuration.controller.setTalkbackText(textView.text)
        refreshFieldHeight()
        view.setNeedsLayout()
    }

    /// The field takes the keyboard from the pane. UIKit resigns a previous
    /// responder only within one window — and on visionOS the card lives in
    /// the ornament's own window while the pane's terminal stays first
    /// responder in the scene's window, which is where key events go. So the
    /// terminal is suspended explicitly (ownership stays with it;
    /// `resumeAfterPresentation` hands the keyboard back on close) and the
    /// field's window is made key. Runs for a tap on the field as well as
    /// for the talk key's programmatic focus.
    func textViewDidBeginEditing(_ textView: UITextView) {
        if let terminal = configuration.controller.terminalView,
           terminal.isFirstResponder,
           !TerminalFocusArbiter.suspendForPresentation(terminal) {
            terminal.resignFirstResponder()
        }
        if let window = textView.window, !window.isKeyWindow {
            window.makeKey()
        }
        #if DEBUG
        let terminal = configuration.controller.terminalView
        Self.keyboardLogger.debug(
            "talkback field focused key=\(textView.window?.isKeyWindow == true, privacy: .public) terminalResponder=\(terminal?.isFirstResponder == true, privacy: .public) terminalWindowKey=\(terminal?.window?.isKeyWindow == true, privacy: .public) sameWindow=\(terminal?.window === textView.window, privacy: .public)"
        )
        #endif
        setCardFocused(true)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        setCardFocused(false)
    }

    private func setCardFocused(_ focused: Bool) {
        let alpha = focused ? 1 : Self.unfocusedAlpha
        guard card.alpha != alpha else { return }
        UIView.animate(withDuration: 0.18) { self.card.alpha = alpha }
    }

    // MARK: DEBUG

    #if DEBUG
    private func installDebugObservers() {
        TalkbackDebugHook.install()
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ action: @escaping @MainActor (Notification) -> Void) {
            debugObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { note in
                MainActor.assumeIsolated { action(note) }
            })
        }
        observe(.multiplexDebugTalkbackType) { [weak self] note in
            guard let self, self.view.window != nil else { return }
            let text = (note.userInfo?["text"] as? String)
                ?? "Talkback headless proof\nsecond line"
            self.textView.text = text
            self.textViewDidChange(self.textView)
        }
        observe(.multiplexDebugTalkbackSend) { [weak self] _ in
            guard let self, self.view.window != nil else { return }
            self.send(submit: true)
        }
        observe(.multiplexDebugTalkbackAttach) { [weak self] _ in
            guard let self, self.view.window != nil else { return }
            self.configuration.controller.attachTalkbackFiles(Self.debugSampleFiles())
        }
    }

    /// A photo-shaped PNG and a text file, so one hook exercises both preview
    /// shapes, the upload queue, and the typed-paths half of SEND.
    private static func debugSampleFiles() -> [DroppedFile] {
        let size = CGSize(width: 96, height: 72)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.48, green: 0.42, blue: 0.35, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.24, green: 0.29, blue: 0.35, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 36, width: 96, height: 36))
            UIColor(red: 0.73, green: 0.67, blue: 0.6, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 60, y: 10, width: 22, height: 22))
        }
        return [
            DroppedFile(name: "talkback-proof.png", data: image.pngData() ?? Data()),
            DroppedFile(name: "talkback-proof.txt", data: Data("talkback headless attach\n".utf8)),
        ]
    }
    #endif
}

/// The values the composer re-renders on — its draft's structure (never its
/// text), the pane's input rules, and whether the paperclip may open now.
private struct TalkbackObservedState: Equatable {
    var attachments: [TalkbackAttachment]
    var focusRequest: Int
    var sendState: TalkbackDraft.SendState
    var canAttachNow: Bool
}

// MARK: - The field

/// A native text view with the hardware-keyboard chat reflexes: Return sends,
/// Shift+Return breaks a line (UIKit's default, so no command claims it),
/// ⌘Return sends everywhere, Escape hands the keyboard back to the pane.
/// The software keyboard's Return is left alone — it inserts a newline; the
/// ↑ is the only touch submit.
@MainActor
final class TalkbackTextView: UITextView {
    var onSend: (() -> Void)?
    var onEscape: (() -> Void)?

    /// Built once: UIKit asks for these on every hardware key event.
    private lazy var chatCommands: [UIKeyCommand] = {
        let send = UIKeyCommand(
            input: "\r",
            modifierFlags: [],
            action: #selector(sendFromKeyboard)
        )
        send.wantsPriorityOverSystemBehavior = true
        let commandSend = UIKeyCommand(
            input: "\r",
            modifierFlags: .command,
            action: #selector(sendFromKeyboard)
        )
        let escape = UIKeyCommand(
            input: UIKeyCommand.inputEscape,
            modifierFlags: [],
            action: #selector(escapeFromKeyboard)
        )
        escape.wantsPriorityOverSystemBehavior = true
        return [send, commandSend, escape]
    }()

    override var keyCommands: [UIKeyCommand]? {
        chatCommands + (super.keyCommands ?? [])
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(sendFromKeyboard) || action == #selector(escapeFromKeyboard) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func sendFromKeyboard() { onSend?() }
    @objc private func escapeFromKeyboard() { onEscape?() }
}

// MARK: - Round buttons

/// The card's round controls: paperclip and ✕ in the hairline style, the ↑
/// filled when armed, dashed while SEND waits on an upload, dim otherwise.
@MainActor
final class TalkbackRoundButton: UIButton {
    enum Style: Equatable {
        case plain
        case prominent
        case waiting
        case dim
    }

    var style: Style = .plain {
        didSet {
            guard style != oldValue else { return }
            refreshAppearance()
        }
    }

    private let diameter: CGFloat
    private let symbolView = UIImageView()
    private let ring = CAShapeLayer()

    init(
        diameter: CGFloat,
        symbol: String,
        pointSize: CGFloat,
        weight: UIImage.SymbolWeight = .semibold
    ) {
        self.diameter = diameter
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        layer.cornerRadius = diameter / 2
        layer.borderWidth = 1
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .circle)
        symbolView.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: pointSize * Theme.typeScale,
                weight: weight
            )
        )
        symbolView.contentMode = .center
        symbolView.isUserInteractionEnabled = false
        addSubview(symbolView)
        ring.fillColor = nil
        ring.lineWidth = 1
        ring.lineDashPattern = [3, 3]
        ring.isHidden = true
        layer.addSublayer(ring)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
        ])
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var intrinsicContentSize: CGSize { CGSize(width: diameter, height: diameter) }

    override var isHighlighted: Bool {
        didSet { refreshAppearance() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        symbolView.frame = bounds
        ring.frame = bounds
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshAppearance()
    }

    private func refreshAppearance() {
        let traits = traitCollection
        switch style {
        case .plain:
            // PROTOTYPE(GLASS): strata over the smoke, chassis otherwise —
            // the chip buttons' ground.
            backgroundColor = GlassPrototype.strataChassis
            layer.borderColor = UIKitChassis.bezelHi.resolvedColor(with: traits).cgColor
            symbolView.tintColor = UIKitChassis.signal2
            ring.isHidden = true
        case .prominent:
            backgroundColor = UIKitChassis.signal
            layer.borderColor = UIKitChassis.signal.resolvedColor(with: traits).cgColor
            symbolView.tintColor = UIKitChassis.chassis
            ring.isHidden = true
        case .waiting:
            backgroundColor = GlassPrototype.strataChassis
            layer.borderColor = UIColor.clear.cgColor
            symbolView.tintColor = UIKitChassis.signal2
            ring.strokeColor = UIKitChassis.signal2.resolvedColor(with: traits).cgColor
            ring.isHidden = false
        case .dim:
            backgroundColor = UIKitChassis.bezelHi
            layer.borderColor = UIKitChassis.bezelHi.resolvedColor(with: traits).cgColor
            symbolView.tintColor = UIKitChassis.signal3
            ring.isHidden = true
        }
        alpha = isHighlighted ? 0.7 : 1
    }
}

// MARK: - Attachment previews

/// One attachment in the card's preview row. Photos show themselves — 46 pt
/// on iPad and visionOS, 28 pt on the phone — with a progress ring while
/// they upload; documents show name and size, as a square on the wide
/// platforms and as a compact chip on the phone. A failed chip wears amber
/// with its reason and retries on tap; the ✕ badge removes any of them.
@MainActor
final class TalkbackAttachmentView: UIControl {
    private(set) var attachment: TalkbackAttachment
    let compact: Bool
    private let size: CGFloat
    private let remove: (UUID) -> Void
    private let retry: (UUID) -> Void
    /// Fixed for the chip's life — measured once.
    private let byteText: String
    private var renderedPreview: Data?
    private let tile = UIKitTallyBorderedView()
    private let imageView = UIImageView()
    private let scrim = UIView()
    private let ringTrack = CAShapeLayer()
    private let ringFill = CAShapeLayer()
    private let nameLabel = UIKitChassisMonoLabel()
    private let detailLabel = UIKitChassisMonoLabel()
    private let removeBadge = UIButton(type: .custom)

    init(
        attachment: TalkbackAttachment,
        size: CGFloat,
        compact: Bool,
        remove: @escaping (UUID) -> Void,
        retry: @escaping (UUID) -> Void
    ) {
        self.attachment = attachment
        self.size = size
        self.compact = compact
        self.remove = remove
        self.retry = retry
        byteText = ByteCountFormatter.string(
            fromByteCount: Int64(attachment.byteCount),
            countStyle: .file
        )
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityIdentifier = "terminal.talkback.attachment.\(attachment.id.uuidString)"
        build()
        update(attachment)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    private var isSquare: Bool { attachment.kind == .image || !compact }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        tile.isUserInteractionEnabled = false
        tile.layer.cornerRadius = compact ? 6 : 8
        tile.layer.cornerCurve = .continuous
        tile.clipsToBounds = true
        tile.backgroundColor = UIKitChassis.bezel
        addSubview(tile)
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.trailingAnchor.constraint(equalTo: trailingAnchor),
            tile.topAnchor.constraint(equalTo: topAnchor),
            tile.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: size),
        ])
        if isSquare {
            widthAnchor.constraint(equalToConstant: size).isActive = true
        }

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: tile.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
        ])

        let labels = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
        labels.axis = isSquare ? .vertical : .horizontal
        labels.alignment = .center
        labels.spacing = isSquare ? 1 : 5
        labels.isUserInteractionEnabled = false
        labels.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(labels)
        let fontSize: CGFloat = isSquare ? 7.5 : 9
        nameLabel.configure("", font: UIKitChassis.monoFont(fontSize), color: TallyPalette.miniText)
        nameLabel.textAlignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.configure("", font: UIKitChassis.monoFont(fontSize), color: UIKitChassis.signal3)
        detailLabel.textAlignment = .center
        let labelInset: CGFloat = isSquare ? 3 : 8
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: labelInset),
            labels.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -labelInset),
            labels.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])

        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        scrim.isUserInteractionEnabled = false
        scrim.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(scrim)
        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: tile.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
        ])
        for ring in [ringTrack, ringFill] {
            ring.fillColor = nil
            ring.lineWidth = 2.5
            ring.lineCap = .round
            scrim.layer.addSublayer(ring)
        }

        removeBadge.accessibilityLabel = "Remove attachment"
        removeBadge.setImage(
            UIImage(
                systemName: "xmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 7, weight: .bold)
            ),
            for: .normal
        )
        removeBadge.layer.cornerRadius = 7
        removeBadge.clipsToBounds = true
        removeBadge.addTarget(self, action: #selector(removePressed), for: .touchUpInside)
        addSubview(removeBadge)
        removeBadge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            removeBadge.widthAnchor.constraint(equalToConstant: 14),
            removeBadge.heightAnchor.constraint(equalToConstant: 14),
            removeBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 1),
            removeBadge.topAnchor.constraint(equalTo: topAnchor, constant: -1),
        ])
        refreshColors()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let ringSize = min(bounds.width, bounds.height) * (compact ? 0.62 : 0.5)
        let rect = CGRect(
            x: bounds.midX - ringSize / 2,
            y: bounds.midY - ringSize / 2,
            width: ringSize,
            height: ringSize
        )
        let path = UIBezierPath(
            arcCenter: CGPoint(x: rect.midX, y: rect.midY),
            radius: ringSize / 2,
            startAngle: -.pi / 2,
            endAngle: 1.5 * .pi,
            clockwise: true
        ).cgPath
        ringTrack.frame = scrim.bounds
        ringFill.frame = scrim.bounds
        ringTrack.path = path
        ringFill.path = path
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshColors()
    }

    /// The badge overhangs the tile's corner; keep it tappable there.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let badgeHit = removeBadge.frame.insetBy(dx: -6, dy: -6)
        if badgeHit.contains(point) { return removeBadge }
        return super.hitTest(point, with: event)
    }

    func update(_ attachment: TalkbackAttachment) {
        self.attachment = attachment
        let showsImage = attachment.kind == .image && attachment.preview != nil
        if showsImage, attachment.preview != renderedPreview, let preview = attachment.preview {
            imageView.image = UIImage(data: preview)
            renderedPreview = preview
        }
        imageView.isHidden = !showsImage
        // The common face; each state below overrides only what differs.
        nameLabel.isHidden = showsImage
        detailLabel.isHidden = showsImage
        nameLabel.setText(attachment.name, ink: TallyPalette.miniText)
        tile.tallyBorderColor = UIKitChassis.bezelHi
        ringTrack.isHidden = true
        ringFill.isHidden = true
        scrim.isHidden = true
        accessibilityHint = nil
        switch attachment.state {
        case .uploading(let fraction):
            scrim.isHidden = false
            ringTrack.isHidden = false
            ringFill.isHidden = false
            ringFill.strokeEnd = max(0.02, min(1, fraction))
            detailLabel.setText(byteText, ink: UIKitChassis.signal3)
            accessibilityLabel = "\(attachment.name), uploading \(Int(fraction * 100)) percent"
        case .ready:
            detailLabel.setText(
                isSquare ? byteText : "\(byteText) ✓",
                ink: UIKitChassis.signal3
            )
            accessibilityLabel = "\(attachment.name), \(byteText), attached"
        case .failed(let reason):
            // The photo stays visible under a scrim so the amber caption
            // reads; documents keep their name and say why.
            scrim.isHidden = !showsImage
            nameLabel.isHidden = false
            if showsImage {
                nameLabel.setText("FAILED", ink: TallyPalette.caution)
            } else {
                detailLabel.isHidden = false
                detailLabel.setText(
                    isSquare ? "FAILED" : "FAILED · \(reason.uppercased())",
                    ink: TallyPalette.caution
                )
            }
            tile.tallyBorderColor = TallyPalette.caution
            accessibilityLabel = "\(attachment.name), upload failed, \(reason)"
            accessibilityHint = "Retries the upload"
        }
        setNeedsLayout()
    }

    private func refreshColors() {
        let traits = traitCollection
        ringTrack.strokeColor = UIKitChassis.signal.resolvedColor(with: traits)
            .withAlphaComponent(0.25).cgColor
        ringFill.strokeColor = UIKitChassis.signal.resolvedColor(with: traits).cgColor
        removeBadge.backgroundColor = UIKitChassis.signal
        removeBadge.tintColor = UIKitChassis.chassis
    }

    @objc private func removePressed() {
        remove(attachment.id)
    }

    @objc private func tapped() {
        guard attachment.isFailed else { return }
        retry(attachment.id)
    }
}

// MARK: - DEBUG hooks

#if DEBUG
extension Notification.Name {
    static let multiplexDebugTalkbackToggle = Notification.Name("MultiplexDebugTalkbackToggle")
    static let multiplexDebugTalkbackType = Notification.Name("MultiplexDebugTalkbackType")
    static let multiplexDebugTalkbackSend = Notification.Name("MultiplexDebugTalkbackSend")
    static let multiplexDebugTalkbackAttach = Notification.Name("MultiplexDebugTalkbackAttach")
}

/// Headless proof of the composer, no touch required:
/// `notifyutil -p app.multiplexterm.multiplex.debug.talkback` toggles the box
/// for the focused terminal (the talk key), `….debug.talkbacktype` puts a
/// two-line sample into its field, `….debug.talkbackattach` attaches a
/// sample photo + text file through the real upload queue,
/// `….debug.talkbacksend` presses ↑ — the harness's `tmux capture-pane` then
/// shows the message (paths first) landing.
@MainActor
enum TalkbackDebugHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        var toggleToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.talkback", &toggleToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugTalkbackToggle, object: nil)
        }
        var typeToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.talkbacktype", &typeToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugTalkbackType, object: nil)
        }
        var sendToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.talkbacksend", &sendToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugTalkbackSend, object: nil)
        }
        var attachToken: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.talkbackattach", &attachToken, .main
        ) { _ in
            NotificationCenter.default.post(name: .multiplexDebugTalkbackAttach, object: nil)
        }
    }
}
#endif
