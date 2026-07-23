#if canImport(CLibTailscale)
import CLibTailscale
import Foundation
import UIKit
import os

struct TailscaleTunnelFailure: Error, LocalizedError, CustomStringConvertible, Sendable {
    let message: String
    var nodeWasClosed = false

    var errorDescription: String? { message }
    var description: String { message }
}

/// One userspace tailnet node for this app install. tsnet persists its node
/// identity in Application Support; that plaintext state directory is the
/// documented exception for this experimental spike because the C ABI does
/// not expose a Keychain-backed state store.
actor TailscaleTunnel {
    enum State: Equatable, Sendable {
        case stopped
        case starting
        case running(ips: [String])
    }

    struct Configuration: Equatable, Sendable {
        var authKey: String
        var controlURL: String
    }

    static let shared = TailscaleTunnel()
    private static let logger = Logger(
        subsystem: "app.multiplexterm.multiplex",
        category: "tailscale"
    )
    static let authKeyNamespace = UUID(
        uuidString: "7BD81B2F-B868-4C52-A968-70A03B65CB23"
    )!

    private static let controlURLDefaultsKey = "TailscaleControlURL"
    private static let startupTimeout: TimeInterval = 30

    private let cQueue = DispatchQueue(
        label: "app.multiplexterm.multiplex.tailscale"
    )
    /// `tailscale_up` occupies `cQueue`; its documented cancellation call
    /// must therefore be able to run concurrently when the deadline expires.
    private let cancellationQueue = DispatchQueue(
        label: "app.multiplexterm.multiplex.tailscale.cancel"
    )

    private(set) var state: State = .stopped
    private var stateObservers: [
        UUID: AsyncStream<State>.Continuation
    ] = [:]
    private var node: CInt?
    private var startTask: Task<StartedNode, Error>?

    func stateUpdates() -> AsyncStream<State> {
        let id = UUID()
        let pair = AsyncStream<State>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        stateObservers[id] = pair.continuation
        pair.continuation.yield(state)
        pair.continuation.onTermination = { @Sendable _ in
            Task { await self.removeStateObserver(id) }
        }
        return pair.stream
    }

    func dial(hostname: String, port: Int) async throws -> CInt {
        #if DEBUG
        // Headless seam proof without a tailnet: the relay + Citadel path
        // is identical from here on whether the fd came from tsnet or a
        // plain TCP connect to the harness sshd.
        if ProcessInfo.processInfo.environment["MULTIPLEX_TAILSCALE_FAKE_DIAL"] == "1" {
            let address = TailscaleDialAddress.format(hostname: hostname, port: port)
            return try await Self.performC(on: cQueue) {
                try Self.debugPlainSocket(hostname: hostname, port: port, address: address)
            }
        }
        #endif
        try await ensureRunning()
        guard let node else {
            throw TailscaleTunnelFailure(
                message: "The embedded Tailscale node stopped before dialing."
            )
        }

        let address = TailscaleDialAddress.format(
            hostname: hostname,
            port: port
        )
        return try await Self.performC(on: cQueue) {
            var connection: CInt = -1
            let result = address.withCString { addressPointer in
                "tcp".withCString { networkPointer in
                    tailscale_dial(
                        node,
                        networkPointer,
                        addressPointer,
                        &connection
                    )
                }
            }
            try Self.check(
                result,
                operation: "Tailscale dial to \(address)",
                node: node
            )
            guard connection >= 0 else {
                throw TailscaleTunnelFailure(
                    message: "Tailscale dial to \(address) returned no connection."
                )
            }
            return connection
        }
    }

    static func loadConfiguration() async -> Configuration {
        await Task.detached(priority: .userInitiated) {
            #if DEBUG
            if let override = ProcessInfo.processInfo
                .environment["MULTIPLEX_TAILSCALE_AUTHKEY"], !override.isEmpty {
                return Configuration(
                    authKey: override,
                    controlURL: UserDefaults.standard.string(
                        forKey: controlURLDefaultsKey
                    ) ?? ""
                )
            }
            #endif
            return Configuration(
                authKey: KeychainStore.get(
                    for: authKeyNamespace,
                    kind: .tailscaleAuthKey
                ) ?? "",
                controlURL: UserDefaults.standard.string(
                    forKey: controlURLDefaultsKey
                ) ?? ""
            )
        }.value
    }

    static func saveConfiguration(_ configuration: Configuration) async {
        await Task.detached(priority: .userInitiated) {
            let authKey = configuration.authKey.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if authKey.isEmpty {
                KeychainStore.delete(
                    for: authKeyNamespace,
                    kind: .tailscaleAuthKey
                )
            } else {
                KeychainStore.set(
                    authKey,
                    for: authKeyNamespace,
                    kind: .tailscaleAuthKey
                )
            }

            let controlURL = configuration.controlURL.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if controlURL.isEmpty {
                UserDefaults.standard.removeObject(
                    forKey: controlURLDefaultsKey
                )
            } else {
                UserDefaults.standard.set(
                    controlURL,
                    forKey: controlURLDefaultsKey
                )
            }
        }.value
    }

    private func ensureRunning() async throws {
        if node != nil, case .running = state {
            return
        }

        if let startTask {
            try await finishStart(startTask)
            return
        }

        transition(to: .starting)
        let cQueue = cQueue
        let cancellationQueue = cancellationQueue
        let task = Task {
            let configuration = await Self.loadConfiguration()
            let authKey = configuration.authKey.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !authKey.isEmpty else {
                throw TailscaleTunnelFailure(
                    message: "Add a Tailscale auth key in Settings."
                )
            }
            let deviceName = await MainActor.run { UIDevice.current.name }
            return try await Self.startNode(
                configuration: Configuration(
                    authKey: authKey,
                    controlURL: configuration.controlURL
                ),
                deviceName: deviceName,
                cQueue: cQueue,
                cancellationQueue: cancellationQueue
            )
        }
        startTask = task
        try await finishStart(task)
    }

    private func finishStart(_ task: Task<StartedNode, Error>) async throws {
        do {
            let started = try await task.value
            if node == nil {
                node = started.node
                transition(to: .running(ips: started.ips))
            }
            startTask = nil
        } catch {
            node = nil
            startTask = nil
            transition(to: .stopped)
            throw error
        }
    }

    private func transition(to newState: State) {
        guard state != newState else { return }
        state = newState
        var terminated: [UUID] = []
        for (id, continuation) in stateObservers {
            if case .terminated = continuation.yield(newState) {
                terminated.append(id)
            }
        }
        for id in terminated {
            stateObservers[id] = nil
        }
    }

    private func removeStateObserver(_ id: UUID) {
        stateObservers[id] = nil
    }

    private struct StartedNode: Sendable {
        var node: CInt
        var ips: [String]
    }

    private static func startNode(
        configuration: Configuration,
        deviceName: String,
        cQueue: DispatchQueue,
        cancellationQueue: DispatchQueue
    ) async throws -> StartedNode {
        let stateDirectory = try await prepareStateDirectory()
        let hostname = TailscaleNodeHostname.format(deviceName: deviceName)
        let node = try await createNode(
            stateDirectory: stateDirectory,
            hostname: hostname,
            configuration: configuration,
            on: cQueue
        )

        do {
            try await waitUntilReady(
                node,
                cQueue: cQueue,
                cancellationQueue: cancellationQueue
            )
            let ips = try await readIPs(node, on: cQueue)
            return StartedNode(node: node, ips: ips)
        } catch {
            if (error as? TailscaleTunnelFailure)?.nodeWasClosed != true {
                await closeNode(node, on: cQueue)
            }
            throw error
        }
    }

    private static func prepareStateDirectory() async throws -> String {
        try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let applicationSupport = try manager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = applicationSupport.appendingPathComponent(
                "tailscale-node",
                isDirectory: true
            )
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            return directory.path
        }.value
    }

    private static func createNode(
        stateDirectory: String,
        hostname: String,
        configuration: Configuration,
        on queue: DispatchQueue
    ) async throws -> CInt {
        try await performC(on: queue) {
            let node = tailscale_new()
            guard node >= 0 else {
                throw TailscaleTunnelFailure(
                    message: "Tailscale couldn't allocate its userspace node."
                )
            }

            do {
                try stateDirectory.withCString {
                    try check(
                        tailscale_set_dir(node, $0),
                        operation: "Tailscale state-directory setup",
                        node: node
                    )
                }
                try hostname.withCString {
                    try check(
                        tailscale_set_hostname(node, $0),
                        operation: "Tailscale hostname setup",
                        node: node
                    )
                }
                try configuration.authKey.withCString {
                    try check(
                        tailscale_set_authkey(node, $0),
                        operation: "Tailscale auth-key setup",
                        node: node
                    )
                }

                let controlURL = configuration.controlURL.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if !controlURL.isEmpty {
                    try controlURL.withCString {
                        try check(
                            tailscale_set_control_url(node, $0),
                            operation: "Tailscale control-URL setup",
                            node: node
                        )
                    }
                }

                try check(
                    tailscale_set_ephemeral(node, 0),
                    operation: "Tailscale persistent-node setup",
                    node: node
                )
                // tsnet's logs are the only field-debugging signal this
                // node has (the auth-key/NoState failure was diagnosed
                // from them); -1 (discard) also proved leaky on device.
                try check(
                    tailscale_set_logfd(node, makeLogSink()),
                    operation: "Tailscale logging setup",
                    node: node
                )
                try check(
                    tailscale_start(node),
                    operation: "Tailscale startup",
                    node: node
                )
                return node
            } catch {
                closeNodeSynchronously(node)
                throw error
            }
        }
    }

    private static func waitUntilReady(
        _ node: CInt,
        cQueue: DispatchQueue,
        cancellationQueue: DispatchQueue
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = TailscaleStartupGate(continuation)

            cQueue.async {
                let result = tailscale_up(node)
                if result == 0 {
                    gate.resolveFromUp(.success(()))
                } else {
                    gate.resolveFromUp(.failure(apiFailure(
                        operation: "Tailscale startup",
                        node: node
                    )))
                }
            }

            cancellationQueue.asyncAfter(
                deadline: .now() + startupTimeout
            ) {
                guard gate.claimTimeout() else { return }
                let closeResult = tailscale_close(node)
                let closeDetail: String?
                if closeResult == 0 {
                    closeDetail = nil
                } else {
                    closeDetail = errorMessage(node: node)
                }
                let suffix = closeDetail.map {
                    " Cancellation also reported: \($0)"
                } ?? ""
                gate.resolveTimeout(TailscaleTunnelFailure(
                    message: "Tailscale startup timed out after 30 seconds.\(suffix)",
                    nodeWasClosed: true
                ))
            }
        }
    }

    private static func readIPs(
        _ node: CInt,
        on queue: DispatchQueue
    ) async throws -> [String] {
        try await performC(on: queue) {
            var buffer = [CChar](repeating: 0, count: 4096)
            let result = buffer.withUnsafeMutableBufferPointer {
                tailscale_getips(node, $0.baseAddress, $0.count)
            }
            try check(
                result,
                operation: "Tailscale address lookup",
                node: node
            )
            return String(cString: buffer)
                .split(separator: ",")
                .map(String.init)
        }
    }

    private static func closeNode(
        _ node: CInt,
        on queue: DispatchQueue
    ) async {
        _ = try? await performC(on: queue) {
            closeNodeSynchronously(node)
        }
    }

    private static func closeNodeSynchronously(_ node: CInt) {
        let result = tailscale_close(node)
        if result != 0 {
            _ = errorMessage(node: node)
        }
    }

    #if DEBUG
    /// Fake-dial escape hatch: a plain blocking TCP connect standing in
    /// for `tailscale_dial`, so the relay + Citadel seam can be driven
    /// end-to-end against the local harness without a tailnet.
    private static func debugPlainSocket(
        hostname: String,
        port: Int,
        address: String
    ) throws -> CInt {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, String(port), &hints, &results) == 0,
              let first = results
        else {
            throw TailscaleTunnelFailure(
                message: "Fake dial couldn't resolve \(address)."
            )
        }
        defer { freeaddrinfo(results) }
        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else {
            throw TailscaleTunnelFailure(message: "Fake dial socket failed (errno \(errno)).")
        }
        guard connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else {
            close(fd)
            throw TailscaleTunnelFailure(
                message: "Fake dial to \(address) failed (errno \(errno))."
            )
        }
        return fd
    }
    #endif

    /// Write end of a pipe whose reader forwards each tsnet log line to
    /// the unified log (category `tailscale`, debug). The reader exits on
    /// EOF when the node closes its end; falls back to -1 (discard) if
    /// the pipe can't be made.
    private static func makeLogSink() -> CInt {
        var fds: [CInt] = [-1, -1]
        guard pipe(&fds) == 0 else { return -1 }
        let readFD = fds[0]
        DispatchQueue.global(qos: .utility).async {
            guard let stream = fdopen(readFD, "r") else {
                close(readFD)
                return
            }
            var line = [CChar](repeating: 0, count: 4096)
            while fgets(&line, Int32(line.count), stream) != nil {
                let text = String(cString: line)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    logger.debug("tsnet: \(text, privacy: .public)")
                }
            }
            fclose(stream)
        }
        return fds[1]
    }

    private static func check(
        _ result: CInt,
        operation: String,
        node: CInt
    ) throws {
        guard result == 0 else {
            throw apiFailure(operation: operation, node: node)
        }
    }

    private static func apiFailure(
        operation: String,
        node: CInt
    ) -> TailscaleTunnelFailure {
        TailscaleTunnelFailure(
            message: "\(operation) failed: \(errorMessage(node: node))"
        )
    }

    private static func errorMessage(node: CInt) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = buffer.withUnsafeMutableBufferPointer {
            tailscale_errmsg(node, $0.baseAddress, $0.count)
        }
        guard result == 0 else {
            return "the embedded node did not provide an error message"
        }
        let message = String(cString: buffer)
        return message.isEmpty ? "unknown error" : message
    }

    private static func performC<T: Sendable>(
        on queue: DispatchQueue,
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private final class TailscaleStartupGate: @unchecked Sendable {
    private enum Phase: Equatable {
        case waiting
        case cancelling
        case finished
    }

    private let lock = NSLock()
    private var phase = Phase.waiting
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resolveFromUp(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard phase == .waiting else { return nil }
            phase = .finished
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func claimTimeout() -> Bool {
        lock.withLock {
            guard phase == .waiting else { return false }
            phase = .cancelling
            return true
        }
    }

    func resolveTimeout(_ error: Error) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard phase == .cancelling else { return nil }
            phase = .finished
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(throwing: error)
    }
}
#endif
