import XCTest
@testable import Multiplex

final class RemoteShellEnvelopeTests: XCTestCase {
    func testFormatEscapesOnlyTheRequiredScalars() {
        for (input, expected) in [("'", "\\047"), ("\\", "\\134"), ("!", "\\041"), ("\n", "\\012"), ("%", "%%")] {
            XCTAssertEqual(RemoteShellEnvelope.format(input), expected)
        }
        XCTAssertEqual(RemoteShellEnvelope.format("工作階段🚀 $HOME \"x\"\t"), "工作階段🚀 $HOME \"x\"\t")
        XCTAssertEqual(RemoteShellEnvelope.format(""), "")
        XCTAssertEqual(RemoteShellEnvelope.exec(""), "printf '{\\012:\\012} </dev/null\\012' | sh")
        XCTAssertEqual(RemoteShellEnvelope.octal("🚀"), "\\360\\237\\232\\200")
    }

    func testLiteralHandoffEligibilityIsNotPrintfFormatEligibility() {
        XCTAssertTrue(RemoteShellEnvelope.isUniversallyQuotable("exec tmux attach -t main"))
        for character in ["'", "\\", "!", "\n", "!\u{20DD}"] {
            XCTAssertFalse(RemoteShellEnvelope.isUniversallyQuotable(character))
        }
        XCTAssertEqual(RemoteShellEnvelope.handoff("exec tmux"), "exec sh -c 'exec tmux'")
    }

    func testUniversalArgumentsRetainBoundariesAndHomeExpansion() {
        XCTAssertEqual("two words".universalArgument, "'two words'")
        XCTAssertEqual("工作階段🚀".universalArgument, "'工作階段🚀'")
        for value in ["it's", "back\\slash", "hey!", "line\nbreak", "it's * two words"] {
            XCTAssertEqual(value.universalArgument, "\"$(printf '" + RemoteShellEnvelope.octal(value) + "')\"")
        }
        // Substitution would strip these bytes. The handoff carrier protects
        // the retained POSIX quoting, including a literal final newline.
        XCTAssertEqual("line\n".universalArgument, "'line\n'")
        XCTAssertEqual("~/proj".universalArgumentDirectory, "\"$HOME\"/'proj'")
        XCTAssertEqual("~".universalArgumentDirectory, "\"$HOME\"")
        XCTAssertEqual("~/it's here".universalArgumentDirectory, "\"$HOME\"/" + "it's here".universalArgument)
    }

    func testRealExecBuildersHaveOnePortableFormatAndDecodeByteForByte() throws {
        for payload in Self.execPayloads.values {
            let command = RemoteShellEnvelope.exec(payload)
            XCTAssertTrue(command.hasPrefix("printf '{\\012"))
            XCTAssertTrue(command.hasSuffix("\\012} </dev/null\\012' | sh"))
            let region = try quotedRegion(command)
            try assertPortableFormat(region)
            XCTAssertEqual(try decodeFormat(region), "{\n" + payload + "\n} </dev/null\n")
        }
    }

    func testHandoffBuildersAreCarriedWithoutChangingThePayloadOrPlainShell() throws {
        for name in Self.names {
            for mode in [
                TerminalRoute.Mode.attach(sessionName: name),
                .create(sessionName: name, directory: "~/it's here"),
                .herdrAttach(sessionName: name),
            ] {
                let route = TerminalRoute(hostID: UUID(), mode: mode)
                let payload = try XCTUnwrap(route.remoteCommand)
                // Even a plain route contains POSIX single quotes; the
                // literal-only invariant in the brief cannot hold for it.
                XCTAssertFalse(RemoteShellEnvelope.isUniversallyQuotable(payload))
                let command = RemoteShellEnvelope.handoff(payload)
                XCTAssertTrue(command.hasPrefix("exec sh -c 'eval \"$(printf \""))
                let region = try quotedRegion(command)
                try assertPortableFormat(region)
                let prefix = "eval \"$(printf \""
                let suffix = "\")\""
                let encoded = String(region.dropFirst(prefix.count).dropLast(suffix.count))
                XCTAssertEqual(try decodeFormat(encoded), payload)
                XCTAssertEqual(ShellHandoff.payload(for: command), ":\n" + command + "\n")
            }
        }
        let plain = TerminalRoute(hostID: UUID(), mode: .shell)
        XCTAssertNil(plain.remoteCommand.map { RemoteShellEnvelope.handoff($0) })
    }

    /// Process is unavailable in simulator XCTest. Export the actual Swift
    /// builders and carriers for the throwaway macOS shell-proof driver.
    func testExportLocalShellProofFixtures() throws {
        var fixtures: [String: String] = [:]
        for (name, payload) in Self.execPayloads {
            fixtures[name] = RemoteShellEnvelope.exec(payload)
        }
        fixtures["empty"] = RemoteShellEnvelope.exec("")
        fixtures["stdin"] = RemoteShellEnvelope.exec("cat; printf 'after-child\\n'")
        fixtures["exit"] = RemoteShellEnvelope.exec("exit 7")
        fixtures["tail"] = RemoteShellEnvelope.exec("false || true")
        fixtures["tty"] = RemoteShellEnvelope.handoff("test -t 0 && printf 'TTY_OK\\n'")
        for (index, name) in Self.names.enumerated() {
            let payload = "printf '%s' " + name.universalArgument
            fixtures["argument-\(index)"] = RemoteShellEnvelope.handoff(payload)
            fixtures["expected-\(index)"] = name
        }
        let create = TmuxSessionLaunch.createAndAttachCommand(sessionName: "mpx-fish-proof", directory: "~/proj")
        let createEcho = create.replacingOccurrences(of: "exec tmux", with: "echo tmux")
        fixtures["create-echo"] = RemoteShellEnvelope.handoff(createEcho)
        fixtures["exec-create-echo"] = RemoteShellEnvelope.exec(createEcho)
        fixtures["handoff-echo"] = RemoteShellEnvelope.handoff(create)
            .replacingOccurrences(of: "exec sh", with: "echo sh")
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fish-support-fixtures.json")
        try JSONEncoder().encode(fixtures).write(to: url)
        print("FISH_SUPPORT_FIXTURES=\(url.path)")
    }

    private static let names = [
        "main", "two words", "it's", "back\\slash", "hey!", "line\nbreak", "line\n", "工作階段🚀",
        "it's * two words", "$(touch /tmp/MPX_MUST_NOT_EXIST); `id` ! \\",
    ]

    private static var execPayloads: [String: String] {
        var tmux = Host(name: "dev", hostname: "localhost", username: "dev")
        var herdr = tmux
        herdr.sessionBackend = .herdr
        tmux.useMosh = true
        let hostile = "printf '%s\\n' \"it's \\ here! 100%\"\nprintf '工作階段🚀\\n'"
        return [
            "probe": TmuxProbe.probeCommand(),
            "check-tmux": HostTest.checkCommand(for: Host(name: "dev", hostname: "localhost", username: "dev")),
            "check-herdr": HostTest.checkCommand(for: herdr),
            "check-mosh": HostTest.checkCommand(for: tmux),
            "diff": GitCommands.diffFile(root: "/tmp/mpx-fish-no-repo", path: "it's\\!%\n工作階段🚀"),
            "new-session": TmuxProbe.newSessionCommand(
                name: "mpx-fish-proof", sourceSessionName: nil, script: hostile, launch: nil
            ),
            "create-attach": TmuxSessionLaunch.createAndAttachCommand(sessionName: "mpx-fish-proof", directory: nil),
            "hostile": hostile,
            "spawn": HerdrProbe.spawnSessionCommand(sessionName: "it's\\!%\n工作階段🚀"),
            "jump": AgentSessionHistory.jumpPrologueCommand(sessionName: "it's\\!%\n工作階段🚀"),
            "mosh": MoshBootstrap.command(
                serverPath: nil, ports: "60000:61000", locale: "C.UTF-8",
                remoteCommand: "tmux attach-session -t 'main'"
            ),
        ]
    }

    private func quotedRegion(_ command: String) throws -> String {
        let pieces = command.components(separatedBy: "'")
        XCTAssertEqual(pieces.count, 3, command)
        return try XCTUnwrap(pieces.count == 3 ? pieces[1] : nil)
    }

    private func assertPortableFormat(_ region: String) throws {
        XCTAssertFalse(region.contains("!"))
        XCTAssertFalse(region.contains("\n"))
        XCTAssertFalse(region.contains("'"))
        XCTAssertFalse(region.contains("\\\\"))
        let bytes = Array(region.utf8)
        for index in bytes.indices where bytes[index] == 92 {
            XCTAssertGreaterThanOrEqual(bytes.count - index, 4)
            XCTAssertTrue(bytes.dropFirst(index + 1).prefix(3).allSatisfy { (48...55).contains($0) })
        }
    }

    private func decodeFormat(_ format: String) throws -> String {
        let input = Array(format.utf8)
        var bytes: [UInt8] = []
        var index = 0
        while index < input.count {
            if input[index] == 92 {
                let digits = String(decoding: input.dropFirst(index + 1).prefix(3), as: UTF8.self)
                bytes.append(try XCTUnwrap(UInt8(digits, radix: 8)))
                index += 4
            } else if input[index] == 37 {
                XCTAssertEqual(input[index + 1], 37)
                bytes.append(37)
                index += 2
            } else {
                bytes.append(input[index])
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
