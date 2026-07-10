import Foundation

// MoshSession depends on three small app-level types. Reproduce only their
// required surface here so the macOS interop executable can compile the real
// session actor and wire stack without trying to build the iOS/visionOS app.

protocol TerminalTransport: Actor {
    func write(_ data: Data) async throws
    func resize(cols: Int, rows: Int) async throws
    func close() async
}

struct Host {
    var name: String
}

enum MoshBootstrap {
    struct Target: Equatable, Sendable {
        var ip: String
        var port: UInt16
        var key: MoshKey
        var isIPv6: Bool

        var datagramBudget: Int { (isIPv6 ? 1216 : 1252) - 28 }
    }

    static func parseConnect(_ output: String) -> (port: UInt16, key: MoshKey)? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4,
                  fields[0] == "MOSH",
                  fields[1] == "CONNECT",
                  let port = UInt16(fields[2]),
                  port > 0,
                  let key = MoshKey(base64: String(fields[3]))
            else { continue }
            return (port, key)
        }
        return nil
    }
}
