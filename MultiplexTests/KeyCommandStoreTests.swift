import Foundation
import XCTest
@testable import Multiplex

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

    func testFreshStoreShipsTheDefaultsAndPersistsReplacements() {
        let store = KeyCommandStore(directory: directory)
        XCTAssertEqual(store.commands, KeyCommandSet.shipped)
        XCTAssertEqual(store.updatedAt, .distantPast)

        let custom = KeyCommand(kind: .chord(KeyChord(modifiers: [.option], key: .enter)))
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        store.replace(KeyCommandSet.shipped + [custom], now: stamp)
        XCTAssertEqual(store.commands.count, 4)
        XCTAssertEqual(store.updatedAt, stamp)

        let reloaded = KeyCommandStore(directory: directory)
        XCTAssertEqual(reloaded.commands, store.commands, "The set comes back from keycommands.json")
        XCTAssertEqual(reloaded.updatedAt, stamp)
    }

    func testReplaceNormalizesBeforePersisting() {
        let store = KeyCommandStore(directory: directory)
        var wild = KeyCommand(kind: .chord(KeyChord(key: .tab)))
        wild.repeatCount = 99
        wild.repeatGapMilliseconds = 1
        store.replace([wild, KeyCommand(kind: .text(KeyTextSnippet(text: "  ")))])
        XCTAssertEqual(store.commands.count, 1)
        XCTAssertEqual(store.commands[0].repeatCount, KeyCommandRepeatGuard.maximumCount)
        XCTAssertEqual(store.commands[0].repeatGapMilliseconds, KeyCommandRepeatGuard.gapRange.lowerBound)
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

    func testMemoryOnlyStoreDoesNotTouchDisk() {
        let store = KeyCommandStore(directory: nil)
        store.replace([KeyCommand(kind: .chord(KeyChord(key: .tab)))])
        XCTAssertEqual(store.commands.count, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("keycommands.json").path)
        )
    }
}
