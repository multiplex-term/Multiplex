import Foundation
import UniformTypeIdentifiers

/// Turns a drop's item providers into `DroppedFile` values.
///
/// `loadFileRepresentation` handles Files-app drops and dragged images. Its
/// temporary URL is valid only during the completion callback, so bytes are
/// copied there before the result crosses back into the terminal controller.
enum TerminalDropLoader {
    static func load(_ providers: [NSItemProvider]) async -> [DroppedFile] {
        var files: [DroppedFile] = []
        for provider in providers {
            guard let type = provider.registeredContentTypes
                .first(where: { $0.conforms(to: .data) })
            else { continue }

            let suggestedName = provider.suggestedName
            let loaded: DroppedFile? = await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(
                    forTypeIdentifier: type.identifier
                ) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    var name = suggestedName ?? url.lastPathComponent
                    if !name.contains("."),
                       let pathExtension = type.preferredFilenameExtension {
                        name += ".\(pathExtension)"
                    }
                    continuation.resume(
                        returning: DroppedFile(name: name, data: data)
                    )
                }
            }
            if let loaded {
                files.append(loaded)
            }
        }
        return files
    }
}
