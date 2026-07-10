import XCTest
@testable import Multiplex

final class MoshFragmentTests: XCTestCase {
    func testHeaderGolden() {
        let fragment = MoshFragmentWire.encode(
            id: 0x0102_0304_0506_0708, number: 2, final: true, contents: Data("X".utf8)
        )
        XCTAssertEqual(fragment, Data(hex: "01020304050607088002" + "58"))

        let decoded = MoshFragmentWire.decode(fragment)
        XCTAssertEqual(decoded?.id, 0x0102_0304_0506_0708)
        XCTAssertEqual(decoded?.number, 2)
        XCTAssertEqual(decoded?.final, true)
        XCTAssertEqual(decoded?.contents, Data("X".utf8))
    }

    func testSingleFragmentRoundTrip() {
        var fragmenter = MoshFragmenter()
        var assembly = MoshFragmentAssembly()
        let payload = Data("small instruction".utf8)

        let fragments = fragmenter.fragments(of: payload, budget: 1224)
        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(assembly.add(fragments[0]), payload)
    }

    func testMultiFragmentSplitAndReassembly() {
        var fragmenter = MoshFragmenter()
        var assembly = MoshFragmentAssembly()
        let payload = Data((0 ..< 100).map(UInt8.init))

        // budget 40 → 30-byte chunks → 30/30/30/10.
        let fragments = fragmenter.fragments(of: payload, budget: 40)
        XCTAssertEqual(fragments.count, 4)
        XCTAssertTrue(fragments.allSatisfy { $0.count <= 40 })

        for fragment in fragments.dropLast() {
            XCTAssertNil(assembly.add(fragment))
        }
        XCTAssertEqual(assembly.add(fragments.last!), payload)
    }

    func testOutOfOrderReassembly() {
        var fragmenter = MoshFragmenter()
        var assembly = MoshFragmentAssembly()
        let payload = Data(repeating: 0xAB, count: 90)

        let fragments = fragmenter.fragments(of: payload, budget: 40)
        XCTAssertEqual(fragments.count, 3)
        XCTAssertNil(assembly.add(fragments[2]))
        XCTAssertNil(assembly.add(fragments[0]))
        XCTAssertEqual(assembly.add(fragments[1]), payload)
    }

    func testNewInstructionIDAbandonsPartialAssembly() {
        var fragmenter = MoshFragmenter()
        var assembly = MoshFragmentAssembly()

        let first = fragmenter.fragments(of: Data(repeating: 1, count: 90), budget: 40)
        let second = fragmenter.fragments(of: Data(repeating: 2, count: 50), budget: 40)
        XCTAssertNil(assembly.add(first[0]))
        // A fragment from the next instruction discards the partial first.
        XCTAssertNil(assembly.add(second[0]))
        XCTAssertEqual(assembly.add(second[1]), Data(repeating: 2, count: 50))
        // The abandoned instruction can no longer complete.
        XCTAssertNil(assembly.add(first[1]))
        XCTAssertNil(assembly.add(first[2]))
    }

    func testFragmentIDsAdvancePerInstruction() {
        var fragmenter = MoshFragmenter()
        let a = fragmenter.fragments(of: Data("a".utf8), budget: 100)
        let b = fragmenter.fragments(of: Data("b".utf8), budget: 100)
        XCTAssertEqual(MoshFragmentWire.decode(a[0])?.id, 0)
        XCTAssertEqual(MoshFragmentWire.decode(b[0])?.id, 1)
    }

    func testDuplicateFragmentsAreHarmless() {
        var fragmenter = MoshFragmenter()
        var assembly = MoshFragmentAssembly()
        let payload = Data(repeating: 7, count: 60)

        let fragments = fragmenter.fragments(of: payload, budget: 40)
        XCTAssertNil(assembly.add(fragments[0]))
        XCTAssertNil(assembly.add(fragments[0]))
        XCTAssertEqual(assembly.add(fragments[1]), payload)
    }

    func testTruncatedFragmentIsRejected() {
        var assembly = MoshFragmentAssembly()
        XCTAssertNil(assembly.add(Data([0, 1, 2])))
    }
}
