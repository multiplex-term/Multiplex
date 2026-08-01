import XCTest
@testable import Multiplex

final class TerminalDropLoaderTests: XCTestCase {
    func testLoadsFileProviderBeforeTemporaryRepresentationExpires() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalDropLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("release-notes.md")
        let bytes = Data("ship the UIKit migration".utf8)
        try bytes.write(to: source)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: source))
        // `NSItemProvider(contentsOf:)` synthesizes a type display name on
        // visionOS (for example, "Markdown") instead of the dragged file's
        // name. Files-app drag providers supply this metadata explicitly.
        provider.suggestedName = source.lastPathComponent

        let files = await TerminalDropLoader.load([provider])

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].name, "release-notes.md")
        XCTAssertEqual(files[0].data, bytes)
    }

    func testLoadsEverySupportedProviderInOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalDropLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURL = directory.appendingPathComponent("first.txt")
        let secondURL = directory.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let first = try XCTUnwrap(NSItemProvider(contentsOf: firstURL))
        let second = try XCTUnwrap(NSItemProvider(contentsOf: secondURL))
        first.suggestedName = firstURL.lastPathComponent
        second.suggestedName = secondURL.lastPathComponent

        let files = await TerminalDropLoader.load([first, second])

        XCTAssertEqual(files.map(\.name), ["first.txt", "second.txt"])
        XCTAssertEqual(files.map(\.data), [Data("first".utf8), Data("second".utf8)])
    }
}
