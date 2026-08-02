import XCTest
@testable import SwiftTerm
@testable import Multiplex

/// Regression tests for input a remote endpoint controls: mosh instructions
/// from the connected server, bind frames from a peer, Markdown from a host's
/// filesystem, and terminal escape sequences from anything that can print
/// into a pane. Every case here terminated the app (a checked-arithmetic
/// trap, an out-of-bounds index, or stack exhaustion) before the fix, so the
/// assertion that matters most is that these calls return at all.
final class HostileInputTests: XCTestCase {
    // MARK: mosh

    func testProtobufLengthAboveIntMaxIsRejectedNotFatal() {
        // Field 6, wire type 2, with a legal ten-byte varint length above
        // Int.max. Converting it to Int trapped.
        var wire = Data([0x32])
        wire.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                                 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])
        XCTAssertNil(MoshInstruction(parsing: wire))
    }

    func testManyUnknownFixedWidthFieldsDoNotExhaustTheStack() {
        // Fixed32 (wire type 5) and fixed64 (wire type 1) fields are skipped.
        // Skipping used to recurse once per field.
        var wire = Data()
        for _ in 0..<200_000 {
            wire.append(0x0D)                       // field 1, fixed32
            wire.append(contentsOf: [0, 0, 0, 0])
        }
        MoshProto.appendField(3, varint: 7, to: &wire)
        XCTAssertEqual(MoshInstruction(parsing: wire)?.newNum, 7)
    }

    // MARK: bind

    func testDeeplyNestedCBORIsRejected() {
        // 0x9F = indefinite array… not supported; use definite one-element
        // arrays (0x81) instead: compact, and each one nests a level deeper.
        var wire = Data(repeating: 0x81, count: 4096)
        wire.append(0x00)  // uint 0 at the bottom
        XCTAssertThrowsError(try BindCBOR.decode(wire))
    }

    func testShallowCBORStillDecodes() {
        let value = BindCBOR.Value.map([
            ("v", .uint(1)),
            ("items", .array([.text("a"), .bytes(Data([1, 2]))])),
        ])
        XCTAssertEqual(try? BindCBOR.decode(BindCBOR.encode(value)), value)
    }

    // MARK: file viewer

    func testDeeplyNestedBlockQuoteDoesNotExhaustTheStack() {
        let line = String(repeating: "> ", count: 20_000) + "boom"
        let blocks = MarkdownDocument.parse(line)
        XCTAssertFalse(blocks.isEmpty)
    }

    func testTableCardinalityIsBounded() {
        var text = "| a | b |\n| --- | --- |\n"
        text += String(repeating: "| 1 | 2 |\n", count: 5_000)
        let blocks = MarkdownDocument.parse(text)
        guard case .table(_, let rows)? = blocks.first(where: {
            if case .table = $0 { return true } else { return false }
        }) else {
            return XCTFail("expected a table block")
        }
        XCTAssertEqual(rows.count, MarkdownDocument.maxTableRows)
    }

    // MARK: terminal escape sequences

    /// Feeds bytes through a real `Terminal` the way a session's transport
    /// does. Each of these sequences crashed the app.
    private func feed(_ text: String, cols: Int = 80, rows: Int = 24) {
        let terminal = Terminal(delegate: SilentTerminalDelegate(),
                                options: TerminalOptions(cols: cols, rows: rows))
        terminal.feed(text: text)
    }

    func testOverlongCSIParameterDoesNotTrap() {
        feed("\u{1B}[" + String(repeating: "9", count: 40) + "m")
    }

    func testOverlongOSCCommandNumberDoesNotTrap() {
        feed("\u{1B}]" + String(repeating: "9", count: 40) + ";x\u{07}")
    }

    func testNegativeOSC104PaletteIndexDoesNotTrap() {
        feed("\u{1B}]104;-1\u{07}")
    }

    func testEraseAboveAtTheBottomRightCellDoesNotTrap() {
        // Alternate screen (no scrollback above), cursor at the last cell,
        // then erase-above: the wrap-state update ran off the buffer.
        feed("\u{1B}[?1049h\u{1B}[24;80H\u{1B}[1J")
    }

    func testUnterminatedOSCPayloadStaysBounded() {
        // 32 MB of OSC body with no terminator: the parser's buffer used to
        // retain every byte between feeds.
        feed("\u{1B}]0;" + String(repeating: "A", count: 32 << 20))
    }

    func testManyEmptyCSIParametersStayBounded() {
        feed("\u{1B}[" + String(repeating: ";", count: 100_000) + "m")
    }

    func testTitleStackPushesStayBounded() {
        let terminal = Terminal(delegate: SilentTerminalDelegate(),
                                options: TerminalOptions(cols: 80, rows: 24))
        terminal.feed(text: "\u{1B}]0;a title\u{07}")
        for _ in 0..<10_000 {
            terminal.feed(text: "\u{1B}[22;0t")
        }
        XCTAssertLessThanOrEqual(
            terminal.terminalTitleStack.count, Terminal.maxTitleStackDepth)
        XCTAssertLessThanOrEqual(
            terminal.terminalIconStack.count, Terminal.maxTitleStackDepth)
    }

    func testSixelWithoutALineTerminatorDoesNotTrap() {
        // The sizing pass never widened maxX, so the plotting pass wrote
        // past the (empty) bitmap.
        feed("\u{1B}Pq#0~~~\u{1B}\\")
    }

    func testSixelOverlongRepeatCountDoesNotTrap() {
        feed("\u{1B}Pq#0!" + String(repeating: "9", count: 40) + "~\u{1B}\\")
    }

    func testKittyDeleteRangeAboveUInt32DoesNotTrap() {
        // `a=d,d=r` reads x/y as an image-id range and converted to UInt32.
        feed("\u{1B}_Ga=d,d=r,x=99999999999,y=99999999999\u{1B}\\")
    }

    func testKittyOversizedPlacementDoesNotTrap() {
        feed("\u{1B}_Ga=p,i=1,c=99999999,r=99999999,H=99999999,V=99999999\u{1B}\\")
    }
}

/// The terminal only needs somewhere to send its responses; every other
/// delegate method has a default implementation.
private final class SilentTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
