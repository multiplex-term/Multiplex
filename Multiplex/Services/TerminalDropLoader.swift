import Foundation
import UniformTypeIdentifiers

/// Turns a drop's item providers into `DroppedFile` values.
///
/// `loadFileRepresentation` handles Files-app drops and dragged images. Its
/// temporary URL is valid only during the completion callback, so bytes are
/// copied there before the result crosses back into the terminal controller.
enum TerminalDropLoader {
    static func load(_ providers: [NSItemProvider]) async -> [DroppedFile] {
        // Each provider's read is independent, so they load concurrently;
        // indexing keeps the delivered order the order of the drop.
        await withTaskGroup(of: (Int, DroppedFile?).self) { group in
            for (index, provider) in providers.enumerated() {
                guard let type = provider.registeredContentTypes
                    .first(where: { $0.conforms(to: .data) })
                else { continue }
                group.addTask {
                    (index, await load(provider, as: type))
                }
            }
            var loaded: [(Int, DroppedFile)] = []
            for await (index, file) in group {
                if let file { loaded.append((index, file)) }
            }
            return loaded.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func load(
        _ provider: NSItemProvider,
        as type: UTType
    ) async -> DroppedFile? {
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
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
    }
}
