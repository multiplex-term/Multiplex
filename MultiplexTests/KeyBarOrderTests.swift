import Foundation
import XCTest
@testable import Multiplex

/// The key rail's order model: always a full permutation, tier-filtered
/// rendering, and the drag rule that moves only the dragged key.
final class KeyBarOrderTests: XCTestCase {
    private let phoneTier: [KeyBarSlot] = [
        .escape, .control, .tab, .left, .up, .down, .right, .talkback, .keyboard, .shortcuts,
    ]

    func testStandardOrderIsTheDeclaredSlotSequence() {
        XCTAssertEqual(KeyBarOrder.standard.slots, KeyBarSlot.allCases)
        XCTAssertTrue(KeyBarOrder.standard.isStandard)
        XCTAssertEqual(KeyBarOrder.standard.tokens.count, KeyBarSlot.allCases.count)
        XCTAssertEqual(KeyBarSlot.returnKey.rawValue, "return", "Persisted tokens never change")
    }

    func testStoredTokensNormalizeToAFullPermutation() {
        let order = KeyBarOrder(tokens: ["tab", "bogus", "escape", "tab", "return"])
        XCTAssertEqual(Array(order.slots.prefix(3)), [.tab, .escape, .returnKey])
        XCTAssertEqual(order.slots.count, KeyBarSlot.allCases.count)
        XCTAssertEqual(Set(order.slots), Set(KeyBarSlot.allCases))
        XCTAssertEqual(
            Array(order.slots.dropFirst(3)),
            KeyBarSlot.allCases.filter { ![.tab, .escape, .returnKey].contains($0) },
            "Missing slots append in shipped order"
        )
        XCTAssertFalse(order.isStandard)
        XCTAssertEqual(KeyBarOrder(tokens: order.tokens), order, "Tokens round-trip")
        XCTAssertEqual(KeyBarOrder(tokens: []), .standard)
    }

    func testArrangeKeepsOnlyTheTierKeysInOrder() {
        let order = KeyBarOrder(slots: [.shortcuts, .keyboard, .escape])
        XCTAssertEqual(
            order.arrange(phoneTier),
            [.shortcuts, .keyboard, .escape, .control, .tab, .left, .up, .down, .right, .talkback]
        )
        XCTAssertEqual(KeyBarOrder.standard.arrange(phoneTier), phoneTier)
        XCTAssertEqual(order.arrange([]), [])
    }

    func testRightwardMoveLandsJustAfterTheNeighbourItPassed() {
        // A phone tier hides the symbols and page keys between TAB and the
        // arrows. Dragging TAB past → must not drag those along.
        let moved = KeyBarOrder.standard.moving(.tab, toVisibleIndex: 6, among: phoneTier)
        XCTAssertEqual(
            moved.slots,
            [
                .escape, .control, .tilde, .pipe, .slash, .hyphen, .pageUp, .pageDown,
                .left, .up, .down, .right, .tab, .returnKey, .talkback, .keyboard, .shortcuts,
            ]
        )
        XCTAssertEqual(
            moved.arrange(phoneTier),
            [.escape, .control, .left, .up, .down, .right, .tab, .talkback, .keyboard, .shortcuts],
            "The phone sees exactly the drop it made"
        )
    }

    func testLeftwardMoveLandsJustBeforeTheNeighbourItPassed() {
        let moved = KeyBarOrder.standard.moving(.left, toVisibleIndex: 0, among: phoneTier)
        XCTAssertEqual(Array(moved.slots.prefix(4)), [.left, .escape, .control, .tab])
        XCTAssertEqual(
            Array(moved.slots.dropFirst(4)),
            [.tilde, .pipe, .slash, .hyphen, .pageUp, .pageDown, .up, .down, .right,
             .returnKey, .talkback, .keyboard, .shortcuts]
        )
        // Rightward up to a hidden run: ESC dropped after TAB (before ← on
        // the phone) lands right after TAB, ahead of the symbols and page
        // keys the phone never showed.
        let escape = KeyBarOrder.standard.moving(.escape, toVisibleIndex: 2, among: phoneTier)
        XCTAssertEqual(
            escape.slots,
            [
                .control, .tab, .escape, .tilde, .pipe, .slash, .hyphen, .pageUp, .pageDown,
                .left, .up, .down, .right, .returnKey, .talkback, .keyboard, .shortcuts,
            ]
        )
        // Leftward past the same run: ← dropped before TAB lands right
        // before TAB, the hidden run still after it.
        let arrow = KeyBarOrder.standard.moving(.left, toVisibleIndex: 2, among: phoneTier)
        XCTAssertEqual(
            Array(arrow.slots.prefix(5)),
            [.escape, .control, .left, .tab, .tilde]
        )
    }

    func testMoveClampsIgnoresAbsentKeysAndKeepsAPermutation() {
        XCTAssertEqual(
            KeyBarOrder.standard.moving(.tab, toVisibleIndex: 2, among: phoneTier),
            .standard,
            "Dropping a key where it already sits changes nothing"
        )
        XCTAssertEqual(
            KeyBarOrder.standard.moving(.tilde, toVisibleIndex: 0, among: phoneTier),
            .standard,
            "A key the tier does not show cannot move"
        )
        let clamped = KeyBarOrder.standard.moving(.escape, toVisibleIndex: 99, among: phoneTier)
        XCTAssertEqual(clamped.slots.last, .escape)
        XCTAssertEqual(clamped.slots.count, KeyBarSlot.allCases.count)
        XCTAssertEqual(Set(clamped.slots), Set(KeyBarSlot.allCases))
        XCTAssertEqual(
            KeyBarOrder.standard.moving(.escape, toVisibleIndex: 1, among: [.escape]),
            .standard,
            "One visible key has nowhere to go"
        )
    }

    /// Whatever the move, the tier that made it sees the plain reorder — the
    /// invariant the rail relies on to skip a rebuild after its own drop.
    func testEveryVisibleMoveIsSeenBackAsThatMove() {
        for from in phoneTier.indices {
            for to in phoneTier.indices {
                let slot = phoneTier[from]
                var expected = phoneTier
                expected.remove(at: from)
                expected.insert(slot, at: to)
                let moved = KeyBarOrder.standard.moving(slot, toVisibleIndex: to, among: phoneTier)
                XCTAssertEqual(moved.arrange(phoneTier), expected, "\(slot) \(from) → \(to)")
                XCTAssertEqual(moved.slots.count, KeyBarSlot.allCases.count)
            }
        }
    }
}

@MainActor
final class KeyBarOrderStoreTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "KeyBarOrderStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testFreshStoreIsStandardAndACustomOrderPersistsAsTokens() {
        let store = KeyBarOrderStore(defaults: defaults)
        XCTAssertEqual(store.order, .standard)
        XCTAssertNil(defaults.object(forKey: KeyBarOrderStore.key))

        let custom = KeyBarOrder(slots: [.shortcuts, .escape])
        store.setOrder(custom)
        XCTAssertEqual(store.order, custom)
        XCTAssertEqual(
            defaults.stringArray(forKey: KeyBarOrderStore.key)?.prefix(2).map { $0 },
            ["shortcuts", "escape"]
        )
        XCTAssertEqual(KeyBarOrderStore(defaults: defaults).order, custom, "Comes back on relaunch")

        store.reset()
        XCTAssertEqual(store.order, .standard)
        XCTAssertNil(
            defaults.object(forKey: KeyBarOrderStore.key),
            "The shipped order is the absence of a record"
        )
    }

    func testGarbageOnDiskFallsBackToTheShippedOrder() {
        defaults.set("not an array", forKey: KeyBarOrderStore.key)
        XCTAssertEqual(KeyBarOrderStore(defaults: defaults).order, .standard)
        defaults.set(["bogus", "escape", "escape"], forKey: KeyBarOrderStore.key)
        let store = KeyBarOrderStore(defaults: defaults)
        XCTAssertEqual(store.order.slots.first, .escape)
        XCTAssertEqual(store.order.slots.count, KeyBarSlot.allCases.count)
    }
}
