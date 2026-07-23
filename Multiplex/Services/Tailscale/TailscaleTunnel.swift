#if canImport(CTailscaleRS)
import CTailscaleRS
import Darwin
import Foundation
import Security
import UIKit
import os

struct TailscaleTunnelFailure: Error, LocalizedError, CustomStringConvertible, Sendable {
    let message: String
    var errorDescription: String? { message }
    var description: String { message }
}

/// One userspace tailnet node for this app install, over tailscale-rs
/// (`CTailscaleRS`). Unlike the Go libtailscale path, this backend takes the
/// node identity as an *input* and never writes a state directory: the app
/// generates the three 32-byte private keys itself and persists them in the
/// Keychain, so the "secrets never touch disk in plaintext" house rule holds
/// without exception. Backed by an experimental upstream — the FFI is
/// gated behind `TS_RS_EXPERIMENT` and all peer traffic relays through
/// public DERP servers today.
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
    /// Namespace UUID the app-wide auth key and node key-state live under in
    /// the Keychain (not a real host).
    static let identityNamespace = UUID(
        uuidString: "7BD81B2F-B868-4C52-A968-70A03B65CB23"
    )!

    private static let controlURLDefaultsKey = "TailscaleControlURL"
    private static let startupTimeout: TimeInterval = 30
    private static let keyStateByteCount = 96

    /// Blocking FFI calls run here — the ts_ffi runtime serializes
    /// internally, so this is a concurrent queue used only to keep the
    /// blocking `block_on` off the Swift cooperative pool. A rejected-key
    /// `ts_init` can occupy one of its threads indefinitely without wedging
    /// unrelated calls.
    private let ffiQueue = DispatchQueue(
        label: "app.multiplexterm.multiplex.tailscale",
        attributes: .concurrent
    )
    private let deadlineQueue = DispatchQueue(
        label: "app.multiplexterm.multiplex.tailscale.deadline"
    )

    private(set) var state: State = .stopped
    private var stateObservers: [UUID: AsyncStream<State>.Continuation] = [:]
    private var device: OpaquePointer?
    private var startTask: Task<StartedNode, Error>?
    private static let envConfigured: Void = {
        setenv("TS_RS_EXPERIMENT", "this_is_unstable_software", 1)
        #if !DEBUG
        // Keep the release console quiet; DEBUG keeps INFO for field
        // diagnosis. tailscale-rs logs to stderr via RUST_LOG only — there
        // is no logfd/callback surface.
        setenv("RUST_LOG", "error", 1)
        #endif
    }()

    func stateUpdates() -> AsyncStream<State> {
        let id = UUID()
        let pair = AsyncStream<State>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stateObservers[id] = pair.continuation
        pair.continuation.yield(state)
        pair.continuation.onTermination = { @Sendable _ in
            Task { await self.removeStateObserver(id) }
        }
        return pair.stream
    }

    /// Returns the far side of the SSH splice — a tailnet TCP connection
    /// wrapped as a `TailscaleRelayRemote`. The relay owns it thereafter.
    func dial(hostname: String, port: Int) async throws -> TailscaleRelayRemote {
        #if DEBUG
        // Headless seam proof without a tailnet: the relay + Citadel path is
        // identical whether the remote is a tailnet handle or a plain TCP
        // socket to the harness sshd.
        if ProcessInfo.processInfo.environment["MULTIPLEX_TAILSCALE_FAKE_DIAL"] == "1" {
            let fd = try await Self.performBlocking(on: ffiQueue) {
                try Self.debugPlainSocket(hostname: hostname, port: port)
            }
            return TailscaleFDRemote(fd: fd)
        }
        #endif
        try await ensureRunning()
        guard let device else {
            throw TailscaleTunnelFailure(
                message: "The embedded Tailscale node stopped before dialing."
            )
        }

        return try await Self.performBlocking(on: ffiQueue) {
            let stream = try Self.connect(device: device, hostname: hostname, port: port)
            return TailscaleHandleRemote(stream: stream)
        }
    }

    static func loadConfiguration() async -> Configuration {
        await Task.detached(priority: .userInitiated) {
            #if DEBUG
            if let override = ProcessInfo.processInfo
                .environment["MULTIPLEX_TAILSCALE_AUTHKEY"], !override.isEmpty {
                return Configuration(
                    authKey: override,
                    controlURL: UserDefaults.standard.string(forKey: controlURLDefaultsKey) ?? ""
                )
            }
            #endif
            return Configuration(
                authKey: KeychainStore.get(for: identityNamespace, kind: .tailscaleAuthKey) ?? "",
                controlURL: UserDefaults.standard.string(forKey: controlURLDefaultsKey) ?? ""
            )
        }.value
    }

    static func saveConfiguration(_ configuration: Configuration) async {
        await Task.detached(priority: .userInitiated) {
            let authKey = configuration.authKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if authKey.isEmpty {
                KeychainStore.delete(for: identityNamespace, kind: .tailscaleAuthKey)
            } else {
                KeychainStore.set(authKey, for: identityNamespace, kind: .tailscaleAuthKey)
            }

            let controlURL = configuration.controlURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if controlURL.isEmpty {
                UserDefaults.standard.removeObject(forKey: controlURLDefaultsKey)
            } else {
                UserDefaults.standard.set(controlURL, forKey: controlURLDefaultsKey)
            }
        }.value
    }

    private func ensureRunning() async throws {
        if device != nil, case .running = state { return }
        if let startTask {
            try await finishStart(startTask)
            return
        }

        transition(to: .starting)
        let ffiQueue = ffiQueue
        let deadlineQueue = deadlineQueue
        let task = Task {
            let configuration = await Self.loadConfiguration()
            let authKey = configuration.authKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !authKey.isEmpty else {
                throw TailscaleTunnelFailure(message: "Add a Tailscale auth key in Settings.")
            }
            let deviceName = await MainActor.run { UIDevice.current.name }
            let keyState = await Self.loadOrCreateKeyState()
            return try await Self.startNode(
                configuration: Configuration(authKey: authKey, controlURL: configuration.controlURL),
                deviceName: deviceName,
                keyState: keyState,
                ffiQueue: ffiQueue,
                deadlineQueue: deadlineQueue
            )
        }
        startTask = task
        try await finishStart(task)
    }

    private func finishStart(_ task: Task<StartedNode, Error>) async throws {
        do {
            let started = try await task.value
            if device == nil {
                device = started.device
                transition(to: .running(ips: started.ips))
            }
            startTask = nil
        } catch {
            device = nil
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
            if case .terminated = continuation.yield(newState) { terminated.append(id) }
        }
        for id in terminated { stateObservers[id] = nil }
    }

    private func removeStateObserver(_ id: UUID) {
        stateObservers[id] = nil
    }

    private struct StartedNode: Sendable {
        var device: OpaquePointer
        var ips: [String]
    }

    // MARK: - Key state (app-owned, Keychain-persisted)

    /// The three 32-byte node keys, generated once and reused so the node
    /// keeps its tailnet identity across launches. tailscale-rs has no
    /// export API, so the app is the only owner.
    private static func loadOrCreateKeyState() async -> Data {
        await Task.detached(priority: .userInitiated) {
            if let existing = KeychainStore.getData(for: identityNamespace, kind: .tailscaleKeyState),
               existing.count == keyStateByteCount {
                return existing
            }
            var bytes = Data(count: keyStateByteCount)
            let ok = bytes.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, keyStateByteCount, $0.baseAddress!)
            }
            precondition(ok == errSecSuccess, "SecRandomCopyBytes failed for tailnet keys")
            KeychainStore.setData(bytes, for: identityNamespace, kind: .tailscaleKeyState)
            return bytes
        }.value
    }

    // MARK: - Node startup

    private static func startNode(
        configuration: Configuration,
        deviceName: String,
        keyState: Data,
        ffiQueue: DispatchQueue,
        deadlineQueue: DispatchQueue
    ) async throws -> StartedNode {
        _ = envConfigured
        let hostname = TailscaleNodeHostname.format(deviceName: deviceName)
        let controlURL = configuration.controlURL.trimmingCharacters(in: .whitespacesAndNewlines)

        let device = try await withDeadline(on: deadlineQueue) {
            try await performBlocking(on: ffiQueue) {
                try initDevice(
                    authKey: configuration.authKey,
                    hostname: hostname,
                    controlURL: controlURL.isEmpty ? nil : controlURL,
                    keyState: keyState
                )
            }
        }

        do {
            let ips = try await performBlocking(on: ffiQueue) { readIPs(device: device) }
            return StartedNode(device: device, ips: ips)
        } catch {
            await performBlockingIgnoringError(on: ffiQueue) { ts_deinit(device) }
            throw error
        }
    }

    private static func initDevice(
        authKey: String,
        hostname: String,
        controlURL: String?,
        keyState: Data
    ) throws -> OpaquePointer {
        var keyBytes = [UInt8](keyState)
        return try keyBytes.withUnsafeMutableBufferPointer { keyBuffer -> OpaquePointer in
            var keyStruct = ts_persisted_key_state()
            let base = keyBuffer.baseAddress!
            withUnsafeMutableBytes(of: &keyStruct.node_private_key) {
                $0.copyBytes(from: UnsafeRawBufferPointer(start: base, count: 32))
            }
            withUnsafeMutableBytes(of: &keyStruct.machine_private_key) {
                $0.copyBytes(from: UnsafeRawBufferPointer(start: base + 32, count: 32))
            }
            withUnsafeMutableBytes(of: &keyStruct.network_lock_private_key) {
                $0.copyBytes(from: UnsafeRawBufferPointer(start: base + 64, count: 32))
            }

            return try withUnsafeMutablePointer(to: &keyStruct) { keyStatePointer in
                try hostname.withCString { hostnamePointer in
                    try "Multiplex".withCString { clientNamePointer in
                        func build(_ controlPointer: UnsafePointer<CChar>?) throws -> OpaquePointer {
                            var config = ts_config()
                            config.control_server_url = controlPointer
                            config.hostname = hostnamePointer
                            config.tags = nil
                            config.client_name = clientNamePointer
                            config.key_state = keyStatePointer
                            return try authKey.withCString { authPointer in
                                guard let device = ts_init(&config, authPointer) else {
                                    throw TailscaleTunnelFailure(
                                        message: "The embedded Tailscale node failed to start."
                                    )
                                }
                                return device
                            }
                        }
                        if let controlURL {
                            return try controlURL.withCString { try build($0) }
                        }
                        return try build(nil)
                    }
                }
            }
        }
    }

    private static func connect(
        device: OpaquePointer,
        hostname: String,
        port: Int
    ) throws -> OpaquePointer {
        var addr = ts_sockaddr()
        switch TailscaleRSDialAddress.classify(hostname: hostname) {
        case .literalIP(let ip):
            let parsed = ip.withCString { ts_parse_ip($0, &addr) }
            guard parsed == 0 else {
                throw TailscaleTunnelFailure(message: "Couldn't parse tailnet address \(ip).")
            }
        case .peerName(let name):
            var v4 = ts_in_addr_t(0, 0, 0, 0)
            let result = name.withCString { ts_peer_ipv4_addr(device, $0, &v4) }
            guard result > 0 else {
                throw TailscaleTunnelFailure(
                    message: result == 0
                        ? "No tailnet peer named \(name)."
                        : "Couldn't resolve tailnet peer \(name)."
                )
            }
            let dotted = "\(v4.0).\(v4.1).\(v4.2).\(v4.3)"
            let parsed = dotted.withCString { ts_parse_ip($0, &addr) }
            guard parsed == 0 else {
                throw TailscaleTunnelFailure(message: "Couldn't form tailnet address for \(name).")
            }
        }
        // ts_parse_ip fills the address with port 0, and the ffi's
        // ts_sockaddr_set_port is a no-op (it mutates a by-value copy of the
        // union field, upstream bug at net_types.rs:361/365). Write the port
        // directly, host byte order (the ffi and its examples use host order:
        // tcp_echo.c sets .sin_port = 1234 and prints it with %u).
        try setPort(UInt16(port), on: &addr)
        guard let stream = ts_tcp_connect(device, &addr) else {
            throw TailscaleTunnelFailure(message: "Tailscale couldn't reach \(hostname):\(port).")
        }
        return stream
    }

    /// TS_AF_INET / TS_AF_INET6 (tailscale.h) — the ffi's own family values,
    /// not the platform's AF_INET (which differs).
    private static let tsAFInet: UInt16 = 2
    private static let tsAFInet6: UInt16 = 23

    private static func setPort(_ port: UInt16, on addr: inout ts_sockaddr) throws {
        switch addr.sa_family {
        case tsAFInet:
            addr.sa_data.sockaddr_in.sin_port = port
        case tsAFInet6:
            addr.sa_data.sockaddr_in6.sin6_port = port
        default:
            throw TailscaleTunnelFailure(
                message: "Unsupported tailnet address family \(addr.sa_family)."
            )
        }
    }

    private static func readIPs(device: OpaquePointer) -> [String] {
        var ips: [String] = []
        var v4 = ts_in_addr_t(0, 0, 0, 0)
        if ts_ipv4_addr(device, &v4) == 0 {
            ips.append("\(v4.0).\(v4.1).\(v4.2).\(v4.3)")
        }
        return ips
    }

    // MARK: - Blocking-call plumbing

    private static func performBlocking<T: Sendable>(
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

    private static func performBlockingIgnoringError(
        on queue: DispatchQueue,
        _ operation: @escaping @Sendable () -> Void
    ) async {
        await withCheckedContinuation { continuation in
            queue.async {
                operation()
                continuation.resume()
            }
        }
    }

    /// Races a startup that can hang on a rejected auth key (measured >60 s
    /// in a supervision retry loop) against a deadline. On timeout the caller
    /// is freed with an error; a late success is cleaned up with `ts_deinit`.
    /// The underlying blocking thread may stay parked until the process ends
    /// — one leaked concurrent-queue thread, never the whole tunnel.
    private static func withDeadline(
        on deadlineQueue: DispatchQueue,
        _ operation: @escaping @Sendable () async throws -> OpaquePointer
    ) async throws -> OpaquePointer {
        let gate = TailscaleStartupGate()
        Task {
            do {
                let device = try await operation()
                if !gate.resolveSuccess(device) {
                    ts_deinit(device)
                }
            } catch {
                gate.resolveFailure(error)
            }
        }
        deadlineQueue.asyncAfter(deadline: .now() + startupTimeout) {
            gate.resolveTimeout(TailscaleTunnelFailure(
                message: "Tailscale startup timed out after 30 seconds. Check the auth key."
            ))
        }
        return try await gate.value()
    }

    // MARK: - DEBUG fake dial

    #if DEBUG
    private static func debugPlainSocket(hostname: String, port: Int) throws -> CInt {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
            ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, String(port), &hints, &results) == 0, let first = results else {
            throw TailscaleTunnelFailure(message: "Fake dial couldn't resolve \(hostname).")
        }
        defer { freeaddrinfo(results) }
        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else {
            throw TailscaleTunnelFailure(message: "Fake dial socket failed (errno \(errno)).")
        }
        guard Darwin.connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else {
            Darwin.close(fd)
            throw TailscaleTunnelFailure(message: "Fake dial to \(hostname):\(port) failed (errno \(errno)).")
        }
        return fd
    }
    #endif
}

/// Handle-backed remote wrapping a `ts_tcp_stream`. Send and recv are
/// independent runtime commands, so the relay's two pump threads are safe;
/// close must not race them, which the relay's finished-pump accounting
/// guarantees.
struct TailscaleHandleRemote: TailscaleRelayRemote {
    let stream: OpaquePointer

    func recv(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        guard let base = buffer.baseAddress else { return 0 }
        return Int(ts_tcp_recv(stream, base.assumingMemoryBound(to: UInt8.self), UInt(buffer.count)))
    }

    func send(_ buffer: UnsafeRawBufferPointer) -> Int {
        guard let base = buffer.baseAddress else { return 0 }
        return Int(ts_tcp_send(stream, base.assumingMemoryBound(to: UInt8.self), UInt(buffer.count)))
    }

    func shutdownWrite() {
        // ts_tcp has no half-close, and calling ts_tcp_close here would race
        // the concurrent ts_tcp_recv on this handle (documented-unsafe). The
        // SSH client closing tears the whole session down via
        // SSHConnection.close() → relay.close(), which is the handle's
        // teardown owner.
    }

    func close() {
        ts_tcp_close(stream)
    }
}

/// Resolves the startup continuation exactly once across the success,
/// failure, and deadline racers. Buffers a result that arrives before the
/// awaiter has registered its continuation (the racing Task can win before
/// `value()` runs).
private final class TailscaleStartupGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var pending: Result<OpaquePointer, Error>?
    private var continuation: CheckedContinuation<OpaquePointer, Error>?

    func value() async throws -> OpaquePointer {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<OpaquePointer, Error>? = lock.withLock {
                if let pending {
                    return pending
                }
                self.continuation = continuation
                return nil
            }
            if let ready {
                continuation.resume(with: ready)
            }
        }
    }

    /// Returns false if the race was already decided (caller must deinit a
    /// late device).
    func resolveSuccess(_ device: OpaquePointer) -> Bool {
        resolve(.success(device))
    }

    func resolveFailure(_ error: Error) {
        _ = resolve(.failure(error))
    }

    func resolveTimeout(_ error: Error) {
        _ = resolve(.failure(error))
    }

    private func resolve(_ result: Result<OpaquePointer, Error>) -> Bool {
        enum Outcome { case lost, buffered, resume(CheckedContinuation<OpaquePointer, Error>) }
        let outcome: Outcome = lock.withLock {
            guard !finished else { return .lost }
            finished = true
            if let continuation {
                self.continuation = nil
                return .resume(continuation)
            }
            pending = result
            return .buffered
        }
        switch outcome {
        case .lost:
            return false
        case .buffered:
            return true
        case .resume(let continuation):
            continuation.resume(with: result)
            return true
        }
    }
}
#endif
