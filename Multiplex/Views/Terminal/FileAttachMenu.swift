import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if !os(visionOS)
import UIKit
#endif

/// Camera / Photos / Files entry point shared by terminal chrome on
/// SSH-backed tmux tabs. All selections become `DroppedFile`s and rejoin
/// the same SFTP + typed-path pipeline as a drag onto the terminal pane.
struct FileAttachMenu: View {
    enum LabelStyle {
        case badge
        case submenu
    }

    var controller: TerminalSessionController?
    var labelStyle: LabelStyle = .badge

    #if !os(visionOS)
    private static let cameraAvailable = UIImagePickerController
        .isSourceTypeAvailable(.camera)
    #endif

    @State private var showingFileImporter = false
    @State private var showingPhotoLibrary = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var fileTarget: TerminalSessionController?
    @State private var photoTarget: TerminalSessionController?
    #if !os(visionOS)
    @State private var showingCamera = false
    @State private var cameraTarget: TerminalSessionController?
    #endif

    var body: some View {
        if canOfferFileAttach {
            Menu {
                #if !os(visionOS)
                Button {
                    cameraTarget = controller
                    showingCamera = true
                } label: {
                    Label("Camera…", systemImage: "camera")
                }
                .disabled(!Self.cameraAvailable)
                #endif

                Button {
                    photoTarget = controller
                    showingPhotoLibrary = true
                } label: {
                    Label("Photo Library…", systemImage: "photo.on.rectangle")
                }

                Button {
                    fileTarget = controller
                    showingFileImporter = true
                } label: {
                    Label("Files…", systemImage: "folder")
                }
            } label: {
                switch labelStyle {
                case .badge:
                    ChassisBadge("FILE", systemImage: "paperclip")
                case .submenu:
                    Label("Send File…", systemImage: "paperclip")
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .chassisHover(2)
            .disabled(controller?.status != .live)
            .accessibilityLabel("Send a file to this session")
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true,
                onCompletion: receiveFiles
            )
            .photosPicker(
                isPresented: $showingPhotoLibrary,
                selection: $selectedPhotos,
                matching: .images
            )
            .onChange(of: selectedPhotos) { _, items in
                guard !items.isEmpty else { return }
                selectedPhotos = []
                let target = photoTarget
                photoTarget = nil
                Task { @MainActor in
                    target?.deliverDrop(await loadPhotos(items))
                }
            }
            #if !os(visionOS)
            .fullScreenCover(isPresented: $showingCamera) {
                CameraCaptureView(
                    captured: { data in
                        let target = cameraTarget
                        cameraTarget = nil
                        showingCamera = false
                        target?.deliverDrop([
                            DroppedFile(name: DropText.photoName(), data: data)
                        ])
                    },
                    cancelled: {
                        cameraTarget = nil
                        showingCamera = false
                    }
                )
                .ignoresSafeArea()
            }
            #endif
        }
    }

    private var canOfferFileAttach: Bool {
        guard let controller else { return false }
        return !controller.host.useMosh && controller.route.sessionName != nil
    }

    private func receiveFiles(_ result: Result<[URL], Error>) {
        let target = fileTarget
        fileTarget = nil
        guard case .success(let urls) = result else { return }
        Task { @MainActor in
            target?.deliverDrop(await Self.readSecurityScopedFiles(urls))
        }
    }

    /// File-importer URLs are security scoped and may point at an iCloud
    /// provider. Keep the grant open for the whole read and do that blocking
    /// work away from the UI actor.
    private static func readSecurityScopedFiles(_ urls: [URL]) async -> [DroppedFile] {
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

    private func loadPhotos(_ items: [PhotosPickerItem]) async -> [DroppedFile] {
        var files: [DroppedFile] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                continue
            }
            let filenameExtension = item.supportedContentTypes.lazy
                .compactMap(\.preferredFilenameExtension)
                .first ?? "jpg"
            files.append(DroppedFile(
                name: DropText.photoName(filenameExtension: filenameExtension),
                data: data
            ))
        }
        return files
    }
}

#if !os(visionOS)
/// UIKit's camera picker remains the system camera capture surface on iPadOS
/// and iOS. It is intentionally absent from the visionOS build.
private struct CameraCaptureView: UIViewControllerRepresentable {
    var captured: (Data) -> Void
    var cancelled: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(captured: captured, cancelled: cancelled)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ picker: UIImagePickerController,
        context: Context
    ) {
        context.coordinator.captured = captured
        context.coordinator.cancelled = cancelled
    }

    @MainActor
    final class Coordinator: NSObject, UINavigationControllerDelegate,
        UIImagePickerControllerDelegate {
        var captured: (Data) -> Void
        var cancelled: () -> Void

        init(captured: @escaping (Data) -> Void, cancelled: @escaping () -> Void) {
            self.captured = captured
            self.cancelled = cancelled
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            cancelled()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.9)
            else {
                cancelled()
                return
            }
            captured(data)
        }
    }
}
#endif
