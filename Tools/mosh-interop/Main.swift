import Darwin
import Foundation

/// macOS-only executable proof against the reference `mosh-server`. It links
/// the app's real MoshSession actor and all six wire layers directly, so this
/// remains runnable even though the application target itself supports only
/// iOS and visionOS.
@main
enum MoshInterop {
    private enum Failure: Error, CustomStringConvertible {
        case message(String)

        var description: String {
            switch self {
            case .message(let message): message
            }
        }
    }

    private actor Received {
        private var bytes = Data()

        func append(_ chunk: Data) {
            bytes.append(chunk)
        }

        var text: String {
            String(decoding: bytes, as: UTF8.self)
        }
    }

    private actor Closed {
        private(set) var observed = false
        private(set) var reason: String?

        func record(_ reason: String?) {
            observed = true
            self.reason = reason
        }
    }

    static func main() async {
        do {
            try await verifyEchoIdlePumpAndShutdown()
            try await verifyPeerInitiatedClose()
            trace("interop OK")
        } catch {
            trace("FAIL: \(error)")
            exit(1)
        }
    }

    private static func verifyEchoIdlePumpAndShutdown() async throws {
        let target = try startServer(command: ["cat"])
        let session = try MoshSession(target: target, cols: 80, rows: 24)
        let received = Received()

        do {
            try await session.open(
                onData: { chunk in
                    Task { await received.append(chunk) }
                },
                onClose: { _ in }
            )
            trace("first contact established")

            // The pump previously spun after a cancelled timer woke the next
            // continuation. Process CPU time makes that regression obvious:
            // a healthy idle session consumes milliseconds, a spin consumes
            // roughly the entire two-second wall interval.
            let cpuStart = processCPUTime()
            try await Task.sleep(for: .seconds(2))
            let idleCPU = processCPUTime() - cpuStart
            guard idleCPU < 0.3 else {
                throw Failure.message(
                    String(format: "idle session used %.3fs CPU in 2s (pump may be spinning)", idleCPU)
                )
            }
            trace(String(format: "PASS: idle pump CPU %.3fs / 2s", idleCPU))

            let marker = "hello mosh \(UUID().uuidString)"
            try await session.write(Data((marker + "\n").utf8))
            try await waitUntil(timeout: 8) {
                await received.text.contains(marker)
            }
            trace("PASS: round-trip echo received")

            let closeStart = Date()
            await session.close()
            let closeElapsed = Date().timeIntervalSince(closeStart)
            guard closeElapsed < 2.2 else {
                throw Failure.message(
                    String(format: "shutdown took %.3fs; peer acknowledgement was not observed", closeElapsed)
                )
            }
            trace(String(format: "PASS: shutdown acknowledged in %.3fs", closeElapsed))
        } catch {
            await session.close()
            throw error
        }
    }

    private static func verifyPeerInitiatedClose() async throws {
        let target = try startServer(command: ["sh", "-c", "sleep 1; exit 0"])
        let session = try MoshSession(target: target, cols: 80, rows: 24)
        let closed = Closed()

        do {
            try await session.open(
                onData: { _ in },
                onClose: { reason in
                    Task { await closed.record(reason) }
                }
            )
            try await waitUntil(timeout: 8) {
                await closed.observed
            }
            let reason = await closed.reason
            guard reason == nil else {
                throw Failure.message("peer exit reported an error: \(reason!)")
            }
            trace("PASS: peer command exit closed cleanly")
        } catch {
            await session.close()
            throw error
        }
    }

    private static func startServer(command: [String]) throws -> MoshBootstrap.Target {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try locateMoshServer())
        process.arguments = [
            "new", "-c", "256", "-i", "127.0.0.1",
            "-l", "LANG=en_US.UTF-8", "--",
        ] + command

        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"
        // Bound any orphan left by a failed harness without weakening the
        // app's own one-hour suspend window.
        environment["MOSH_SERVER_NETWORK_TMOUT"] = "15"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // `mosh-server new` forks; its parent exits and closes the pipe after
        // printing MOSH CONNECT, so reading to EOF yields the complete line.
        let output = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard let (port, key) = MoshBootstrap.parseConnect(output) else {
            let errorOutput = String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw Failure.message("mosh-server did not provide MOSH CONNECT: \(output) \(errorOutput)")
        }
        trace("mosh-server up: port \(port)")
        return MoshBootstrap.Target(
            ip: "127.0.0.1",
            port: port,
            key: key,
            isIPv6: false
        )
    }

    private static func locateMoshServer() throws -> String {
        if let override = ProcessInfo.processInfo.environment["MOSH_SERVER"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        for path in [
            "/opt/homebrew/bin/mosh-server",
            "/usr/local/bin/mosh-server",
            "/usr/bin/mosh-server",
        ] where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw Failure.message("mosh-server not found (install with: brew install mosh)")
    }

    private static func waitUntil(
        timeout: TimeInterval,
        condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.message("condition not met within \(timeout)s")
    }

    private static func processCPUTime() -> TimeInterval {
        var value = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else { return 0 }
        return TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000
    }

    private static func trace(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
