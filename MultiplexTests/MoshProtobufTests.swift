import XCTest
@testable import Multiplex

/// Goldens hand-computed from the proto2 wire format and mosh's schemas
/// (transportinstruction/userinput/hostinput.proto).
final class MoshProtobufTests: XCTestCase {
    func testInstructionGoldenEncoding() {
        var instruction = MoshInstruction()
        instruction.newNum = 1
        instruction.diff = Data("AB".utf8)
        XCTAssertEqual(
            instruction.encoded(),
            Data(hex: "08021000180120002800320241423a00")
        )
    }

    func testInstructionRoundTripIncludingShutdownSentinel() {
        var instruction = MoshInstruction()
        instruction.oldNum = 7
        instruction.newNum = .max // the shutdown marker — 10-byte varint
        instruction.ackNum = 3
        instruction.throwawayNum = 2
        instruction.diff = Data([0x00, 0xFF, 0x10])
        instruction.chaff = Data([1, 2, 3, 4])

        let decoded = MoshInstruction(parsing: instruction.encoded())
        XCTAssertEqual(decoded, instruction)
    }

    func testInstructionIgnoresUnknownFieldsAndRejectsGarbage() {
        var instruction = MoshInstruction()
        instruction.newNum = 5
        var wire = instruction.encoded()
        MoshProto.appendField(15, varint: 99, to: &wire)
        MoshProto.appendField(16, bytes: Data("future".utf8), to: &wire)
        XCTAssertEqual(MoshInstruction(parsing: wire), instruction)

        XCTAssertNil(MoshInstruction(parsing: Data([0x08]))) // truncated varint
        XCTAssertNil(MoshInstruction(parsing: Data([0x32, 0x7F, 0x00]))) // bytes overrun
    }

    func testUserMessageGoldens() {
        XCTAssertEqual(
            MoshUserMessage.encode([.keys(Data("ls\r".utf8))][...]),
            Data(hex: "0a0712052203" + "6c730d")
        )
        XCTAssertEqual(
            MoshUserMessage.encode([.resize(cols: 120, rows: 40)][...]),
            Data(hex: "0a061a0428783028")
        )
    }

    func testUserMessageCoalescesAdjacentKeystrokes() {
        let events: [MoshUserEvent] = [
            .keys(Data("a".utf8)),
            .keys(Data("b".utf8)),
            .resize(cols: 120, rows: 40),
            .keys(Data("c".utf8)),
        ]
        let wire = MoshUserMessage.encode(events[...])
        XCTAssertEqual(
            wire,
            Data(hex: "0a06120422026162" + "0a061a0428783028" + "0a0512032201" + "63")
        )
        XCTAssertEqual(
            MoshUserMessage.decode(wire),
            [.keys(Data("ab".utf8)), .resize(cols: 120, rows: 40), .keys(Data("c".utf8))]
        )
    }

    func testHostMessageDecodeGoldens() {
        XCTAssertEqual(
            MoshHostMessage.decode(Data(hex: "0a0612042202" + "6869")),
            [.hostBytes(Data("hi".utf8))]
        )
        XCTAssertEqual(
            MoshHostMessage.decode(Data(hex: "0a043a024005")),
            [.echoAck(5)]
        )
        XCTAssertEqual(
            MoshHostMessage.decode(Data(hex: "0a061a042864301e")),
            [.resize(cols: 100, rows: 30)]
        )
    }

    func testHostMessageRoundTripAndUnknownExtensions() {
        let items: [MoshHostInstruction] = [
            .echoAck(41),
            .resize(cols: 215, rows: 52),
            .hostBytes(Data("\u{1B}[2J\u{1B}[Hhello".utf8)),
        ]
        XCTAssertEqual(MoshHostMessage.decode(MoshHostMessage.encode(items)), items)

        // An instruction carrying only an unknown extension contributes
        // nothing but must not break the message.
        var unknownExtension = Data()
        MoshProto.appendField(9, bytes: Data("??".utf8), to: &unknownExtension)
        var wire = Data()
        MoshProto.appendField(1, bytes: unknownExtension, to: &wire)
        wire.append(MoshHostMessage.encode([.echoAck(1)]))
        XCTAssertEqual(MoshHostMessage.decode(wire), [.echoAck(1)])
    }
}
