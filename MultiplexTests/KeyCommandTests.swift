import Foundation
import XCTest
@testable import Multiplex

/// The pure Key Command model: the shipped defaults, derived names / faces /
/// readouts, and set normalization under the repeat guard.
final class KeyCommandTests: XCTestCase {
    func testShippedSetIsTheThreeDefaultsInOrder() {
        let shipped = KeyCommandSet.shipped
        XCTAssertEqual(shipped.map(\.name), ["SHIFT ENTER", "CTRL C", "OPTION DELETE"])
        XCTAssertEqual(shipped.map(\.repeatCount), [1, 2, 1])
        XCTAssertEqual(shipped.map(\.closesPanel), [true, true, false])
        XCTAssertTrue(shipped.allSatisfy(\.isShipped))
        XCTAssertEqual(shipped[1].repeatGapMilliseconds, 150)
        XCTAssertEqual(
            Set(shipped.map(\.id)).count,
            3,
            "The defaults keep stable, distinct IDs so peers merge to the same rows"
        )
    }

    func testDerivedNamesFacesAndReadouts() {
        let optionUp = KeyCommand(
            kind: .chord(KeyChord(modifiers: [.option, .shift], key: .up)),
            repeatCount: 3,
            repeatGapMilliseconds: 100,
            closesPanel: false
        )
        XCTAssertEqual(optionUp.name, "SHIFT OPTION UP", "Modifiers print in keycap order ⌃ ⇧ ⌥")
        XCTAssertEqual(optionUp.faces.map(\.symbolName), ["shift", "option", "arrow.up"])
        XCTAssertEqual(optionUp.readout, "×3 · 100 MS · STAYS")
        XCTAssertTrue(optionUp.isRepeating)

        let letter = KeyCommand(kind: .chord(KeyChord(modifiers: [.control], key: .character("c"))))
        XCTAssertEqual(letter.name, "CTRL C")
        XCTAssertEqual(letter.faces.map(\.text), ["⌃", "C"], "Letters render as their uppercase text face")
        XCTAssertEqual(letter.readout, "×1 · CLOSES")
        XCTAssertEqual(letter.chord?.accessibilityName, "Control C")

        let short = KeyCommand(kind: .text(KeyTextSnippet(text: "git status")))
        XCTAssertEqual(short.name, "git status")
        XCTAssertEqual(short.faces, [.text("git status")])
        XCTAssertEqual(short.readout, "SUBMITS · ×1 · CLOSES")
        let long = KeyCommand(kind: .text(KeyTextSnippet(text: "  make -j8 test\tVERBOSE=1\n", submits: false)))
        XCTAssertEqual(long.textSnippet?.normalizedText, "make -j8 test\tVERBOSE=1")
        XCTAssertEqual(long.name, "make -j8 tes...")
        XCTAssertEqual(long.readout, "×1 · CLOSES")
        XCTAssertEqual(
            KeyTextSnippet(text: "ls\u{02}\u{1B}[A").normalizedText,
            "ls[A",
            "Terminal control bytes never survive normalization"
        )
        XCTAssertFalse(KeyCommand(kind: .text(KeyTextSnippet(text: " \n "))).isSendable)

        // The composer's letter field takes one printable ASCII character.
        XCTAssertEqual(KeyChord.Key.fromFieldText("C"), .character("c"), "The base key is lowercase")
        XCTAssertEqual(KeyChord.Key.fromFieldText(" 7 "), .character("7"))
        XCTAssertNil(KeyChord.Key.fromFieldText("ab"))
        XCTAssertNil(KeyChord.Key.fromFieldText(""))
        XCTAssertNil(KeyChord.Key.fromFieldText("é"))
        XCTAssertNil(KeyChord.Key.fromFieldText("\u{1B}"))

        // The SENDS line's byte notation.
        XCTAssertEqual(KeyBytesNotation.describe([0x0A]), "LF")
        XCTAssertEqual(KeyBytesNotation.describe([0x1B, 0x5B, 0x31, 0x33, 0x3B, 0x32, 0x75]), "ESC [13;2u")
        XCTAssertEqual(KeyBytesNotation.describe([0x03]), "^C")
        XCTAssertEqual(KeyBytesNotation.describe([0x1B, 0x62]), "ESC b")
        XCTAssertEqual(KeyBytesNotation.describe([0x7F, 0x00]), "DEL NUL")
        XCTAssertEqual(KeyBytesNotation.describe(Array("héllo".utf8)), "héllo")
    }

    func testNormalizationClampsRepeatsDropsBlankTextDedupesAndCaps() {
        XCTAssertEqual(
            KeyCommandRepeatGuard.clamp(count: 9, gapMilliseconds: 10),
            .init(count: 5, gapMilliseconds: 50, wasClamped: true)
        )
        XCTAssertEqual(
            KeyCommandRepeatGuard.clamp(count: 0, gapMilliseconds: 5000),
            .init(count: 1, gapMilliseconds: 500, wasClamped: true)
        )
        // ×5 every 500 ms is a 2 s burst — exactly the limit, allowed.
        XCTAssertEqual(
            KeyCommandRepeatGuard.clamp(count: 5, gapMilliseconds: 500),
            .init(count: 5, gapMilliseconds: 500, wasClamped: false)
        )
        XCTAssertEqual(KeyCommandRepeatGuard.burstMilliseconds(count: 5, gapMilliseconds: 500), 2000)
        XCTAssertEqual(KeyCommandRepeatGuard.burstMilliseconds(count: 1, gapMilliseconds: 500), 0)

        let sharedID = UUID()
        var many: [KeyCommand] = (0..<14).map { index in
            KeyCommand(kind: .chord(KeyChord(key: .character(String(index % 10)))))
        }
        many[0].id = sharedID
        many[1].id = sharedID
        many.insert(KeyCommand(kind: .text(KeyTextSnippet(text: "   "))), at: 2)
        many[3].repeatCount = 40

        let normalized = KeyCommandSet.normalized(many)
        XCTAssertEqual(normalized.count, KeyCommandSet.maximumCount)
        XCTAssertEqual(Set(normalized.map(\.id)).count, normalized.count, "IDs are unique after normalization")
        XCTAssertFalse(normalized.contains { $0.textSnippet != nil }, "Blank text rows are dropped")
        XCTAssertEqual(normalized[2].repeatCount, KeyCommandRepeatGuard.maximumCount)
    }
}
