import Foundation

/// A JSON value that can cross actors: requests decoded off the SSH channel
/// and results built on the main actor travel as this, never as `Any`.
enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    /// A protocol integer: finite, whole, and within 0...2^53 (the range a
    /// JSON number carries exactly). Anything else is not a number this wire
    /// sends — and converting it unchecked would trap.
    var wireInteger: UInt64? {
        guard case .number(let value) = self,
              value.isFinite, value >= 0, value <= 9_007_199_254_740_992,
              value.rounded(.towardZero) == value
        else { return nil }
        return UInt64(value)
    }

    /// Decodes JSON text; nil for anything unparseable.
    static func parse(_ text: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}

/// The agent browser's failure vocabulary — the `code` an agent (and the
/// skill that teaches it) can branch on, plus a sentence for a person.
struct AgentBrowserError: Error, Equatable, Sendable {
    var code: String
    var message: String

    static func badRequest(_ message: String) -> Self { .init(code: "bad_request", message: message) }
    static func unknownMethod(_ method: String) -> Self {
        .init(code: "unknown_method", message: "Unknown method '\(method)'. Is mpx newer than Multiplex?")
    }
    static func noTab() -> Self {
        .init(code: "no_tab", message: "No agent tab here yet — `mpx browser open <url>` starts one.")
    }
    static func unknownTab(_ tab: String) -> Self {
        .init(code: "no_tab", message: "No agent tab '\(tab)' — `mpx browser tabs` lists yours.")
    }
    static func blocked(_ message: String) -> Self { .init(code: "blocked", message: message) }
    static func noWindow(hostName: String) -> Self {
        .init(
            code: "no_window",
            message: "Multiplex has no terminal open for \(hostName). Open one in the app, then retry."
        )
    }
    static func hidden() -> Self {
        .init(
            code: "hidden",
            message: "The tab is not on screen, so it cannot be captured. Use `snapshot`, "
                + "or `show` to bring it forward (that takes the user's focus)."
        )
    }
    static func script(_ message: String) -> Self { .init(code: "script_error", message: message) }
    static func timeout(_ message: String) -> Self { .init(code: "timeout", message: message) }
}

/// The app's half of the `mpx bridge` wire (the CLI's `bridge.rs` is the
/// other): newline-delimited JSON over the bridge's stdin/stdout. Pure.
enum AgentBrowserWire {
    /// The protocol this build speaks; a bridge announcing another is
    /// refused rather than half-understood.
    static let protocolVersion = 1

    struct Request: Equatable, Sendable {
        var id: UInt64
        var method: String
        var params: JSONValue
        /// When the bridge sent it, on the bridge's monotonic clock (ms).
        var sentAt: Double?
        /// How long the agent waits for it (ms).
        var ttl: Double?
    }

    /// Maps the bridge's monotonic clock onto the app's, learned from pongs.
    /// Both clocks keep counting while the app is suspended, so a request
    /// read on resume can be aged — the cure for an app waking up to a queue
    /// of clicks their agent already gave up on. Only a pong answering the
    /// ping in flight, back within `maxRoundTripMs`, teaches the offset: a
    /// pong that sat in the pipe through a suspension would otherwise make
    /// the bridge look far behind and every stale request look fresh. One
    /// clock per bridge process — reset on reconnect.
    struct BridgeClock: Equatable, Sendable {
        static let maxRoundTripMs: Double = 2_000

        /// bridge ms − local ms, from the last trusted pong.
        private(set) var offset: Double?

        /// Returns whether the sample was trusted.
        @discardableResult
        mutating func learn(bridgeMs: Double, sentLocalMs: Double, receivedLocalMs: Double) -> Bool {
            let roundTrip = receivedLocalMs - sentLocalMs
            guard roundTrip >= 0, roundTrip <= Self.maxRoundTripMs else { return false }
            offset = bridgeMs - (sentLocalMs + receivedLocalMs) / 2
            return true
        }

        mutating func reset() {
            offset = nil
        }

        /// True when the request outlived its agent's wait. Unknown clocks
        /// or stamps never call a request stale.
        func isStale(_ request: Request, localMs: Double) -> Bool {
            guard let offset, let sentAt = request.sentAt, let ttl = request.ttl else { return false }
            return localMs + offset - sentAt > ttl
        }
    }

    enum Incoming: Equatable, Sendable {
        /// The bridge is up and serving `socket`.
        case hello(version: Int, socket: String?)
        /// The launch script found no `mpx` on the host.
        case missing
        case request(Request)
        case pong(UInt64, bridgeMs: Double?)
        /// Request N timed out at the bridge: do not run it late (an app
        /// back from suspension reads its queue all at once).
        case cancel(UInt64)
        /// Login-shell chatter before the hello, or noise.
        case ignored
    }

    static func decode(_ line: String) -> Incoming {
        guard let value = JSONValue.parse(line), case .object = value else { return .ignored }
        if let tag = value["mpx"]?.stringValue {
            switch tag {
            case "browser-bridge":
                // An unreadable version reads as 0: older than any bridge,
                // which the link reports as an mpx to update.
                let version = value["v"]?.wireInteger.flatMap { Int(exactly: $0) } ?? 0
                return .hello(version: version, socket: value["socket"]?.stringValue)
            case "missing":
                return .missing
            default:
                return .ignored
            }
        }
        if let pong = value["pong"]?.wireInteger {
            return .pong(pong, bridgeMs: value["t"]?.wireInteger.map { Double($0) })
        }
        if let cancel = value["cancel"]?.wireInteger {
            return .cancel(cancel)
        }
        if let id = value["id"]?.wireInteger,
           let method = value["method"]?.stringValue {
            return .request(Request(
                id: id,
                method: method,
                params: value["params"] ?? .object([:]),
                sentAt: value["t"]?.wireInteger.map { Double($0) },
                ttl: value["ttl"]?.wireInteger.map { Double($0) }
            ))
        }
        return .ignored
    }

    static func result(id: UInt64, _ result: JSONValue) -> Data {
        line(.object(["id": .number(Double(id)), "result": result]))
    }

    static func error(id: UInt64, _ error: AgentBrowserError) -> Data {
        line(.object([
            "id": .number(Double(id)),
            "error": .object(["code": .string(error.code), "message": .string(error.message)]),
        ]))
    }

    static func ping(_ token: UInt64) -> Data {
        line(.object(["ping": .number(Double(token))]))
    }

    private static func line(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    /// Splits a byte stream into lines. A line longer than `maxLineBytes` is
    /// dropped whole (the bridge never sends one; a runaway rc file might).
    struct LineBuffer {
        static let maxLineBytes = 4 << 20

        private var pending = Data()
        private var discarding = false

        mutating func append(_ bytes: Data) -> [String] {
            var lines: [String] = []
            var rest = bytes[...]
            while !rest.isEmpty {
                let newline = rest.firstIndex(of: 0x0A)
                let chunk = rest[..<(newline ?? rest.endIndex)]
                if !discarding {
                    if pending.count + chunk.count > Self.maxLineBytes {
                        pending.removeAll()
                        discarding = true
                    } else {
                        pending.append(chunk)
                    }
                }
                guard let newline else { break }
                if !discarding { lines.append(String(decoding: pending, as: UTF8.self)) }
                pending.removeAll(keepingCapacity: true)
                discarding = false
                rest = rest[rest.index(after: newline)...]
            }
            return lines
        }
    }
}

/// How the app starts `mpx bridge` on a host: typed as the first line of a
/// PTY-less login shell, so the host's own PATH (Homebrew, cargo) applies.
enum AgentBrowserLaunch {
    /// Where `mpx` usually lands when a login shell's PATH misses it.
    static let fallbackPaths = [
        "$HOME/.cargo/bin/mpx",
        "$HOME/.local/bin/mpx",
        "/opt/homebrew/bin/mpx",
        "/usr/local/bin/mpx",
        "/home/linuxbrew/.linuxbrew/bin/mpx",
    ]

    /// The POSIX script: exec the first `mpx` found as the bridge, or say
    /// `{"mpx":"missing"}` so the app can tell "not installed" from "failed".
    /// `installID` separates same-named devices (iOS reports a generic
    /// "iPad"); `preferred` (a DEBUG hook: a dev build of mpx) is tried
    /// first.
    static func script(deviceName: String, installID: String, preferred: String? = nil) -> String {
        let first = preferred.map { [quoted($0)] } ?? []
        let candidates = (first + ["mpx", "multiplex"] + fallbackPaths.map { "\"\($0)\"" })
            .joined(separator: " ")
        return """
            for c in \(candidates); do \
            if command -v "$c" >/dev/null 2>&1; then exec "$c" bridge --device \(quoted(deviceName)) --id \(quoted(installID)); fi; \
            done; printf '%s\\n' '{"mpx":"missing"}'
            """
    }

    /// The stdin bytes for the shell channel.
    static func payload(deviceName: String, installID: String, preferred: String? = nil) -> String {
        ShellHandoff.payload(for: RemoteShellEnvelope.handoff(
            script(deviceName: deviceName, installID: installID, preferred: preferred)
        ))
    }

    /// This install's id for the bridge: 8 hex digits, device-local, made
    /// once. Never synced — it names THIS device to the host.
    static func installID(in defaults: UserDefaults = .standard) -> String {
        let key = "agentBrowser.installID"
        if let existing = defaults.string(forKey: key), existing.count == 8,
           existing.allSatisfy(\.isHexDigit) {
            return existing
        }
        let fresh = BindMarker.randomID8()
        defaults.set(fresh, forKey: key)
        return fresh
    }

    /// POSIX single-quoting. Control characters are dropped: a device name
    /// has no business carrying a newline into a shell line.
    static func quoted(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }).shellQuoted
    }

    /// An older `mpx` (before `bridge` existed) fails in clap with this on
    /// stderr — the cue to ask for an upgrade instead of reporting a fault.
    static func isOutdatedCLI(stderr: String) -> Bool {
        stderr.contains("unrecognized subcommand") || stderr.contains("unexpected argument")
    }
}
