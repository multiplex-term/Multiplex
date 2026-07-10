import SwiftUI
import UniformTypeIdentifiers

/// Turns a drop's `NSItemProvider`s into `DroppedFile`s.
/// `loadFileRepresentation` handles both Files-app drops and dragged
/// images (Photos, screenshots): it writes a temp copy — no security-scope
/// dance — valid only inside the completion, so bytes are read there.
enum TerminalDropCatcher {
    static func load(_ providers: [NSItemProvider]) async -> [DroppedFile] {
        var files: [DroppedFile] = []
        for provider in providers {
            guard let type = provider.registeredContentTypes
                .first(where: { $0.conforms(to: .data) })
            else { continue }   // folders etc. — unsupported v1
            let suggested = provider.suggestedName
            let loaded: DroppedFile? = await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    var name = suggested ?? url.lastPathComponent
                    if !name.contains("."), let ext = type.preferredFilenameExtension {
                        name += ".\(ext)"
                    }
                    continuation.resume(returning: DroppedFile(name: name, data: data))
                }
            }
            if let loaded { files.append(loaded) }
        }
        return files
    }
}

/// Upload progress / failure, floating at the pane's bottom edge.
struct DropStatusPill: View {
    let state: TerminalSessionController.DropState

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .uploading(let name, let fraction):
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(Theme.signal)
                    .frame(width: 64)
                Text("\(name) · \(Int(fraction * 100))%")
                    .font(.mono(10))
                    .foregroundStyle(Theme.signal2)
                    .lineLimit(1)
            case .failed(let message):
                Rectangle().fill(Theme.caution).frame(width: 5, height: 5)
                Text(message)
                    .font(.mono(10))
                    .foregroundStyle(Theme.signal2)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.bezel)
        .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Full-pane target highlight while a drag hovers.
struct DropTargetVeil: View {
    var body: some View {
        ZStack {
            Theme.chassis.opacity(0.35)
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.signal)
                ChassisLabel("Drop to upload", size: 11, color: Theme.signal2)
            }
        }
        .overlay(Rectangle().strokeBorder(Theme.signal2, lineWidth: 2))
        .allowsHitTesting(false)
    }
}
