import Observation
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Camera / Photos / Files entry point shared by terminal chrome on
/// SSH-backed tmux and herdr tabs. Every selection becomes a `DroppedFile`
/// and rejoins the same SFTP + typed-path pipeline as a drag onto the
/// terminal pane.
enum FileAttachPicker: Equatable {
    case camera
    case photoLibrary
    case files
}

enum FileAttachAvailability {
    /// Any session-backed tab over SSH: the backend answers the pane's cwd
    /// (tmux `list-panes`, herdr snapshot) and SSH carries the SFTP upload.
    /// Mosh has no SFTP channel; a plain shell has no pane to ask.
    @MainActor
    static func canOffer(for controller: TerminalSessionController?) -> Bool {
        controller?.canUploadFiles == true
    }

    #if !os(visionOS)
    @MainActor
    static var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }
    #endif
}

/// The semantic state a native attachment menu renders. Keeping this smaller
/// than the terminal's full connection status means equivalent disabled
/// states (connecting and ended) preserve their UIKit menu identity, while
/// the transition to live is still observable by chrome that snapshots its
/// actions.
struct FileAttachMenuAvailability: Equatable {
    let canOffer: Bool
    let actionsEnabled: Bool

    init(canOffer: Bool, isLive: Bool) {
        self.canOffer = canOffer
        actionsEnabled = canOffer && isLive
    }

    @MainActor
    init(controller: TerminalSessionController?) {
        self.init(
            canOffer: FileAttachAvailability.canOffer(for: controller),
            isLive: controller?.status == .live
        )
    }
}

// MARK: - Native picker owner

/// A stable UIKit presenter for every system attachment picker. It snapshots
/// the terminal controller when the user chooses a source; a later tab switch
/// therefore cannot redirect the selected bytes to a different session.
@MainActor
class FileAttachPickerPresenterViewController: UIViewController,
    UIDocumentPickerDelegate, PHPickerViewControllerDelegate
{
    private(set) var queuedPicker: FileAttachPicker?
    private(set) weak var queuedTarget: TerminalSessionController?
    /// The tab the menu built here aims its pickers at. The FILE chip and
    /// the Talkback paperclip both point one presenter at the active tab.
    fileprivate(set) var terminalController: TerminalSessionController?
    /// Where picked files land. nil = the target's own drop path
    /// (`deliverDrop`: upload, then type the paths into the pane); the
    /// Talkback composer routes them into the target's draft instead. The
    /// target still decides eligibility either way.
    var deliver: ((TerminalSessionController, [DroppedFile]) -> Void)?

    private var activeTarget: TerminalSessionController?
    private var externalRequestIsLatched = false
    private var presentationRetryWorkItem: DispatchWorkItem?

    override func loadView() {
        let hostView = UIView()
        hostView.backgroundColor = .clear
        hostView.isUserInteractionEnabled = false
        view = hostView
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentQueuedPickerIfPossible()
    }

    /// Re-aim at another tab. The FILE chip re-renders its button on top.
    func update(controller: TerminalSessionController?) {
        terminalController = controller
    }

    /// The direct FILE chip, the compact terminal overflow and the Talkback
    /// paperclip share these exact picker actions. Capturing `target` when
    /// the menu is built preserves the selected session if a tab switch
    /// races the system picker.
    func makeSourceMenu(
        title: String = "",
        image: UIImage? = nil,
        availability: FileAttachMenuAvailability? = nil
    ) -> UIMenu? {
        guard let target = terminalController,
              FileAttachAvailability.canOffer(for: target)
        else { return nil }
        let availability = availability
            ?? FileAttachMenuAvailability(controller: target)
        guard availability.canOffer else { return nil }
        let enabled = availability.actionsEnabled
        var actions: [UIMenuElement] = []
        #if !os(visionOS)
        actions.append(UIAction(
            title: String(localized: "Camera…"),
            image: UIImage(systemName: "camera"),
            identifier: UIAction.Identifier("terminal.attach.camera"),
            attributes: enabled && FileAttachAvailability.cameraAvailable
                ? [] : .disabled
        ) { [weak self, weak target] _ in
            self?.request(.camera, target: target)
        })
        #endif
        actions.append(UIAction(
            title: String(localized: "Photo Library…"),
            image: UIImage(systemName: "photo.on.rectangle"),
            identifier: UIAction.Identifier("terminal.attach.photos"),
            attributes: enabled ? [] : .disabled
        ) { [weak self, weak target] _ in
            self?.request(.photoLibrary, target: target)
        })
        actions.append(UIAction(
            title: String(localized: "Files…"),
            image: UIImage(systemName: "folder"),
            identifier: UIAction.Identifier("terminal.attach.files"),
            attributes: enabled ? [] : .disabled
        ) { [weak self, weak target] _ in
            self?.request(.files, target: target)
        })
        return UIMenu(title: title, image: image, children: actions)
    }

    func request(
        _ picker: FileAttachPicker,
        target: TerminalSessionController?
    ) {
        guard let target, FileAttachAvailability.canOffer(for: target) else { return }
        queuedPicker = picker
        queuedTarget = target

        // Let a menu finish its selection transaction before asking the same
        // scene to present another controller.
        DispatchQueue.main.async { [weak self] in
            self?.presentQueuedPickerIfPossible()
        }
    }

    /// Consumes a state-driven external request. The latch prevents repeated
    /// updates from presenting the same non-nil request more than once.
    func consumeExternalRequest(
        _ picker: FileAttachPicker?,
        target: TerminalSessionController?
    ) {
        guard let picker else {
            externalRequestIsLatched = false
            return
        }
        guard !externalRequestIsLatched else { return }
        externalRequestIsLatched = true
        request(picker, target: target)
    }

    func makePicker(for source: FileAttachPicker) -> UIViewController? {
        switch source {
        case .files:
            let picker = UIDocumentPickerViewController(
                forOpeningContentTypes: [.item],
                asCopy: true
            )
            picker.allowsMultipleSelection = true
            picker.delegate = self
            return picker

        case .photoLibrary:
            // The system library is sufficient here; Multiplex never asks
            // PHPicker for Photos asset identifiers, only item-provider data.
            var configuration = PHPickerConfiguration()
            configuration.filter = .images
            configuration.selectionLimit = 0
            configuration.selection = .ordered
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = self
            return picker

        case .camera:
            #if !os(visionOS)
            guard FileAttachAvailability.cameraAvailable else { return nil }
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.cameraCaptureMode = .photo
            picker.delegate = self
            return picker
            #else
            return nil
            #endif
        }
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        let target = activeTarget
        activeTarget = nil
        Task { @MainActor [weak self] in
            let files = await FileAttachDataLoader.readSecurityScopedFiles(urls)
            self?.deliverPicked(files, to: target)
        }
        scheduleQueuedPresentation()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        activeTarget = nil
        scheduleQueuedPresentation()
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let target = activeTarget
        activeTarget = nil
        picker.dismiss(animated: true) { [weak self] in
            self?.presentQueuedPickerIfPossible()
        }
        guard !results.isEmpty else { return }
        Task { @MainActor [weak self] in
            let files = await FileAttachDataLoader.loadPhotos(results)
            self?.deliverPicked(files, to: target)
        }
    }

    private func presentQueuedPickerIfPossible() {
        guard isViewLoaded, view.window != nil, let source = queuedPicker else { return }
        guard let target = queuedTarget else {
            queuedPicker = nil
            return
        }
        guard presentedViewController == nil else {
            scheduleQueuedPresentation()
            return
        }

        presentationRetryWorkItem?.cancel()
        presentationRetryWorkItem = nil
        queuedPicker = nil
        queuedTarget = nil
        guard let picker = makePicker(for: source) else { return }
        activeTarget = target
        present(picker, animated: true)
    }

    /// One landing for every picker: the composer's draft when it asked, the
    /// pane's drop path otherwise.
    func deliverPicked(_ files: [DroppedFile], to target: TerminalSessionController?) {
        guard let target, !files.isEmpty else { return }
        if let deliver {
            deliver(target, files)
        } else {
            target.deliverDrop(files)
        }
    }

    private func scheduleQueuedPresentation() {
        guard queuedPicker != nil, presentationRetryWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            presentationRetryWorkItem = nil
            presentQueuedPickerIfPossible()
        }
        presentationRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }
}

#if !os(visionOS)
extension FileAttachPickerPresenterViewController: UINavigationControllerDelegate,
    UIImagePickerControllerDelegate
{
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        activeTarget = nil
        picker.dismiss(animated: true) { [weak self] in
            self?.presentQueuedPickerIfPossible()
        }
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        let target = activeTarget
        activeTarget = nil
        guard let image = info[.originalImage] as? UIImage,
              let data = image.jpegData(compressionQuality: 0.9)
        else {
            picker.dismiss(animated: true) { [weak self] in
                self?.presentQueuedPickerIfPossible()
            }
            return
        }

        picker.dismiss(animated: true) { [weak self] in
            self?.presentQueuedPickerIfPossible()
        }
        deliverPicked([DroppedFile(name: DropText.photoName(), data: data)], to: target)
    }
}
#endif

enum FileAttachDataLoader {
    /// File-importer URLs are security scoped and may point at an iCloud
    /// provider. Keep the grant open for the whole read and perform that
    /// blocking work away from the UI actor.
    static func readSecurityScopedFiles(_ urls: [URL]) async -> [DroppedFile] {
        await Task.detached(priority: .userInitiated) {
            urls.compactMap { url in
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                guard let data = try? Data(contentsOf: url) else { return nil }
                return DroppedFile(name: url.lastPathComponent, data: data)
            }
        }.value
    }

    static func loadPhotos(_ results: [PHPickerResult]) async -> [DroppedFile] {
        var files: [DroppedFile] = []
        for result in results {
            let provider = result.itemProvider
            guard let type = provider.registeredContentTypes.first(where: {
                $0.conforms(to: .image)
            }), let data = await loadData(from: provider, type: type)
            else { continue }

            files.append(DroppedFile(
                name: DropText.photoName(
                    filenameExtension: type.preferredFilenameExtension ?? "jpg"
                ),
                data: data
            ))
        }
        return files
    }

    private static func loadData(from provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

// MARK: - Native direct FILE chip

@MainActor
final class FileAttachMenuViewController: FileAttachPickerPresenterViewController {
    private(set) var attachButton = FileAttachBadgeButton()

    private var observationGeneration = 0
    private var buttonParkingConstraints: [NSLayoutConstraint] = []

    init(controller: TerminalSessionController?) {
        super.init(nibName: nil, bundle: nil)
        terminalController = controller
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func loadView() {
        let presenterHost = UIView()
        presenterHost.backgroundColor = .clear
        presenterHost.isUserInteractionEnabled = false
        presenterHost.clipsToBounds = true
        view = presenterHost
        parkAttachButton()
        attachButton.accessibilityIdentifier = "terminal.fileAttach"
        renderAndObserve()
    }

    /// The controller's root view stays inside its parent's hierarchy so it
    /// can present system pickers. Only this ordinary button view moves into
    /// a navigation bar or UMD stack; moving a child controller's root view
    /// there violates UIKit containment and crashes during state restoration.
    func takeAttachButton() -> FileAttachBadgeButton {
        loadViewIfNeeded()
        NSLayoutConstraint.deactivate(buttonParkingConstraints)
        buttonParkingConstraints.removeAll()
        if let stack = attachButton.superview as? UIStackView {
            stack.removeArrangedSubview(attachButton)
        }
        attachButton.removeFromSuperview()
        return attachButton
    }

    func parkAttachButton() {
        guard isViewLoaded else { return }
        guard attachButton.superview !== view else { return }
        _ = takeAttachButton()
        view.addSubview(attachButton)
        attachButton.translatesAutoresizingMaskIntoConstraints = false
        buttonParkingConstraints = [
            attachButton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            attachButton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            attachButton.topAnchor.constraint(equalTo: view.topAnchor),
            attachButton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ]
        NSLayoutConstraint.activate(buttonParkingConstraints)
    }

    override func update(controller: TerminalSessionController?) {
        super.update(controller: controller)
        guard isViewLoaded else { return }
        observationGeneration &+= 1
        renderAndObserve(generation: observationGeneration)
    }

    private func renderAndObserve(generation: Int? = nil) {
        let generation = generation ?? {
            observationGeneration &+= 1
            return observationGeneration
        }()
        guard generation == observationGeneration else { return }

        let availability = withObservationTracking {
            FileAttachMenuAvailability(controller: terminalController)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.renderAndObserve(generation: generation)
            }
        }
        attachButton.isHidden = !availability.canOffer
        attachButton.isEnabled = availability.actionsEnabled
        attachButton.menu = availability.canOffer
            ? makeSourceMenu(availability: availability)
            : nil
    }
}

@MainActor
final class FileAttachBadgeButton: UIButton {
    static let horizontalInset: CGFloat = 9
    static let verticalInset: CGFloat = 5
    static let contentSpacing: CGFloat = 5

    private let symbolView = UIImageView()
    private let captionLabel = UILabel()
    private let contentStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = GlassPrototype.strataChassis
        layer.borderWidth = 1
        showsMenuAsPrimaryAction = true
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 2))
        accessibilityLabel = String(localized: "Send a file to this session")

        symbolView.image = UIImage(
            systemName: "paperclip",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 9 * Theme.typeScale,
                weight: .semibold
            )
        )
        symbolView.contentMode = .scaleAspectFit
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            symbolView.widthAnchor.constraint(equalToConstant: 10 * Theme.typeScale),
            symbolView.heightAnchor.constraint(equalToConstant: 10 * Theme.typeScale),
        ])

        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = Self.contentSpacing
        contentStack.isUserInteractionEnabled = false
        contentStack.addArrangedSubview(symbolView)
        contentStack.addArrangedSubview(captionLabel)
        captionLabel.setContentHuggingPriority(.required, for: .horizontal)
        captionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Self.horizontalInset
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Self.horizontalInset
            ),
            contentStack.topAnchor.constraint(
                equalTo: topAnchor,
                constant: Self.verticalInset
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -Self.verticalInset
            ),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.4 }
    }

    override var intrinsicContentSize: CGSize {
        let content = contentStack.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize
        )
        return CGSize(
            width: ceil(content.width + Self.horizontalInset * 2),
            height: ceil(content.height + Self.verticalInset * 2)
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection)
        else { return }
        refreshColors()
    }

    private func refreshColors() {
        layer.borderColor = UIKitChassis.bezelHi
            .resolvedColor(with: traitCollection).cgColor
        symbolView.tintColor = UIKitChassis.signal2
        captionLabel.attributedText = NSAttributedString(
            string: "FILE",
            attributes: [
                .font: UIKitChassis.monoFont(9, weight: .semibold),
                .kern: 1.1,
                .foregroundColor: UIKitChassis.signal2
                    .resolvedColor(with: traitCollection),
            ]
        )
    }
}
