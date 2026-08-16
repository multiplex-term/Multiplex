import Foundation
import XCTest
@testable import Multiplex

/// The app-wide store: the shipped set until edited, `keycommands.json`
/// persistence, and the Keychain mirror's last-writer-wins merge.
@MainActor
final class KeyCommandStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keycommands-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testFreshStoreShipsTheDefaultsAndPersistsNormalizedReplacements() {
        let store = KeyCommandStore(directory: directory)
        XCTAssertEqual(store.commands, KeyCommandSet.shipped)
        XCTAssertEqual(store.updatedAt, .distantPast)

        var wild = KeyCommand(kind: .chord(KeyChord(modifiers: [.option], key: .enter)))
        wild.repeatCount = 99
        wild.repeatGapMilliseconds = 1
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        store.replace(
            KeyCommandSet.shipped + [wild, KeyCommand(kind: .text(KeyTextSnippet(text: "  ")))],
            now: stamp
        )
        XCTAssertEqual(store.commands.count, 4, "The blank text row is dropped")
        XCTAssertEqual(store.commands[3].repeatCount, KeyCommandRepeatGuard.maximumCount)
        XCTAssertEqual(store.commands[3].repeatGapMilliseconds, KeyCommandRepeatGuard.gapRange.lowerBound)
        XCTAssertEqual(store.updatedAt, stamp)

        let reloaded = KeyCommandStore(directory: directory)
        XCTAssertEqual(reloaded.commands, store.commands, "The set comes back from keycommands.json")
        XCTAssertEqual(reloaded.updatedAt, stamp)
    }

    func testCloudMergeIsLastWriterWins() throws {
        let store = KeyCommandStore(directory: directory)
        let local = KeyCommand(kind: .chord(KeyChord(key: .space)))
        store.replace([local], now: Date(timeIntervalSince1970: 2_000))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let older = KeyCommandSet(
            commands: [KeyCommand(kind: .chord(KeyChord(key: .escape)))],
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        store.adopt(cloudRecord: try encoder.encode(older))
        XCTAssertEqual(store.commands, [local], "An older mirror never overwrites a newer local set")

        let newer = KeyCommandSet(
            commands: [KeyCommand(kind: .chord(KeyChord(key: .escape)))],
            updatedAt: Date(timeIntervalSince1970: 3_000)
        )
        store.adopt(cloudRecord: try encoder.encode(newer))
        XCTAssertEqual(store.commands.map(\.name), ["ESC"], "A newer peer set replaces the local one whole")
        XCTAssertEqual(store.updatedAt, Date(timeIntervalSince1970: 3_000))

        store.adopt(cloudRecord: Data("not json".utf8))
        XCTAssertEqual(store.commands.map(\.name), ["ESC"], "Garbage in the mirror is ignored")

        let reloaded = KeyCommandStore(directory: directory)
        XCTAssertEqual(reloaded.commands.map(\.name), ["ESC"], "An adopted set is persisted locally")
    }
}
