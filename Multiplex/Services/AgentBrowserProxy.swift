import Foundation
import Network
import NIOCore
import NIOPosix
import NIOSSH
import os

/// The agent browser's HOST ROUTE: an HTTP proxy on the device's loopback
/// that WebKit uses for one host's agent tabs, and that opens every
/// connection from the host over SSH (`SSHConnection.openDirectTCPIP`).
/// A page then lives on the host's network — `localhost` is the host's
/// loopback, and the device's LAN is never on the path, whatever DNS says.
///
/// Guarded by a random credential: any app on the device can reach
/// loopback, and this proxy spends the user's SSH session. Parsing is
/// `AgentProxyHead` (pure); this file is only plumbing.
///
/// A real device never proxies loopback (`localhost`, `127.0.0.1`,
/// `*.localhost` go straight to the phone's own loopback — the simulator
/// proxies them), so the host's loopback ports are reached through
/// FORWARDS instead: a listener on the device's 127.0.0.1/::1 at the same
/// port, piped to the host's `localhost:<port>` (`ssh -L` style). URLs,
/// Host headers, redirects and HMR sockets all stay `localhost`. Device
/// loopback is shared by every app, so a forward admits a connection only
/// when its first request carries `forwardCookies` — set HttpOnly in the
/// agent tabs' own cookie store, so nothing else on the device has them —
/// and forwards exist only while the host has agent tabs. An OPEN port
/// (`mpx browser forward <port> --open`, the agent's explicit choice for
/// cross-port requests a page makes without credentials) skips the cookie:
/// any app on the device can use it while it is up.
final class AgentBrowserProxy: @unchecked Sendable {
    let username = "mpx"
    let password: String
    /// The forwards' admission secret (`AgentProxyHead.forwardVerdict`).
    let forwardSecret: String
    private let lock = NSLock()
    /// Read at every dial, so a host-record edit reaches the next one.
    private var host: Host
    private var connection: SSHConnection?
    private var connecting: Task<SSHConnection, Error>?
    private var server: Channel?
    private var opened = 0
    private var forwards: [Int: [Channel]] = [:]
    private var openPorts: Set<Int> = []
    /// Device-side connections admitted because their port was OPEN — any
    /// app's, possibly. They end when the port stops being open.
    private var openAdmitted: [Int: [ObjectIdentifier: Channel]] = [:]
    private var binding: [Int: Task<Void, Error>] = [:]

    static let log = Logger.agentBrowser

    init(host: Host) {
        self.host = host
        func random() -> Data {
            var bytes = [UInt8](repeating: 0, count: 24)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return Data(bytes)
        }
        password = random().base64EncodedString()
        forwardSecret = random().map { String(format: "%02x", $0) }.joined()
    }

    /// A record edit that changes how to reach the host (address,
    /// credentials, pinned keys) retires the current connection; live
    /// tunnels keep theirs until they end.
    func update(host newHost: Host) {
        let retired = lock.withLock { () -> SSHConnection? in
            defer { host = newHost }
            guard !newHost.hasSameConnectionModelConfiguration(as: host) else { return nil }
            defer { connection = nil; connecting = nil }
            return connection
        }
        if let retired { Task { await retired.close() } }
    }

    /// The device changed networks: the connection's socket is on the old
    /// path. Drop it; the next tunnel dials fresh.
    func dropConnection() {
        let dropped = lock.withLock { () -> SSHConnection? in
            defer { connection = nil; connecting = nil }
            return connection
        }
        if let dropped { Task { await dropped.close() } }
    }

    /// Host connections opened so far (each one an SSH channel) — the
    /// keep-alive health number `mpx browser probe` reports.
    var tunnelsOpened: Int { lock.withLock { opened } }

    /// The cookies WebKit must carry to a forward: host-only for each
    /// loopback spelling a page uses, HttpOnly so page scripts cannot read
    /// them, session-scoped.
    var forwardCookies: [HTTPCookie] {
        ["localhost", "127.0.0.1"].compactMap { domain in
            HTTPCookie(properties: [
                .name: AgentProxyHead.forwardCookieName,
                .value: forwardSecret,
                .domain: domain,
                .path: "/",
                HTTPCookiePropertyKey("HttpOnly"): "TRUE",
                .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax,
            ])
        }
    }

    var credential: String { "\(username):\(password)" }

    /// The proxy's device-loopback port, once bound.
    var port: Int? { lock.withLock { server?.localAddress?.port } }

    /// What the agent tabs' data store routes through: this proxy, with its
    /// credential, and never a direct fallback.
    func configuration(port: Int) -> ProxyConfiguration? {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        var configuration = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: endpointPort))
        configuration.allowFailover = false
        configuration.applyCredential(username: username, password: password)
        return configuration
    }

    /// Binds `127.0.0.1:<ephemeral>` and returns the port.
    func start() async throws -> Int {
        if let port { return port }
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] child in
                guard let self else { return child.close() }
                return child.pipeline.addHandler(HeadHandler(proxy: self))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        lock.withLock { server = channel }
        guard let port = channel.localAddress?.port else { throw SSHConnectionError.notConnected }
        Self.log.info("host route proxy on 127.0.0.1:\(port, privacy: .public)")
        return port
    }

    func stop() {
        stopForwards()
        dropConnection()
        lock.withLock { () -> Channel? in
            defer { server = nil }
            return server
        }?.close(promise: nil)
    }

    // MARK: Loopback forwards

    /// The device's port is taken (another app, or another host's forward).
    struct PortBusy: Error {}

    var forwardedPorts: [Int] { lock.withLock { forwards.keys.sorted() } }

    /// Forwarded ports that admit any device client.
    var openForwardedPorts: [Int] { lock.withLock { openPorts.intersection(forwards.keys).sorted() } }

    /// Whether `port` skips the cookie check — read per connection, so a
    /// change applies to the next one.
    func isOpen(_ port: Int) -> Bool { lock.withLock { openPorts.contains(port) } }

    func setOpen(_ port: Int, _ open: Bool) {
        let ended = lock.withLock { () -> [Channel] in
            if open {
                openPorts.insert(port)
                return []
            }
            openPorts.remove(port)
            return openAdmitted.removeValue(forKey: port).map { Array($0.values) } ?? []
        }
        // Kept-alive tunnels admitted while open would otherwise outlive it.
        ended.forEach { $0.close(promise: nil) }
        let mode = open ? "OPEN to every app on the device" : "cookie-checked"
        Self.log.info("host route: forward :\(port, privacy: .public) \(mode, privacy: .public)")
    }

    /// Makes the device's `localhost:<port>` reach the host's. Idempotent;
    /// concurrent callers for one port share the bind.
    func forward(port: Int) async throws {
        let task: Task<Void, Error>? = lock.withLock {
            if forwards[port] != nil { return nil }
            if let pending = binding[port] { return pending }
            let task = Task { try await self.bindForward(port: port) }
            binding[port] = task
            return task
        }
        guard let task else { return }
        defer { lock.withLock { binding[port] = nil } }
        try await task.value
    }

    private func bindForward(port: Int) async throws {
        var listeners: [Channel] = []
        // IPv4 is required; ::1 is best effort (WebKit may try it first for
        // `localhost`, and falls back to 127.0.0.1 when it is refused).
        for address in ["127.0.0.1", "::1"] {
            do {
                let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .childChannelInitializer { [weak self] child in
                        guard let self else { return child.close() }
                        return child.pipeline.addHandler(HeadHandler(proxy: self, target: ("localhost", port)))
                    }
                    .bind(host: address, port: port)
                    .get()
                listeners.append(listener)
            } catch where address == "127.0.0.1" {
                throw PortBusy()
            } catch {
                continue
            }
        }
        lock.withLock { forwards[port] = listeners }
        Self.log.info("host route: device localhost:\(port, privacy: .public) → host localhost:\(port, privacy: .public)")
    }

    /// Closes every forward (the host has no agent tabs left), and every
    /// connection an open port admitted.
    func stopForwards() {
        let channels = lock.withLock { () -> [Channel] in
            defer { forwards.removeAll(); openPorts.removeAll(); openAdmitted.removeAll() }
            return forwards.values.flatMap { $0 } + openAdmitted.values.flatMap { $0.values }
        }
        channels.forEach { $0.close(promise: nil) }
    }

    /// Records a connection admitted only because `port` is open; it is
    /// forgotten when it closes.
    fileprivate func admittedWhileOpen(_ channel: Channel, port: Int) {
        let key = ObjectIdentifier(channel)
        lock.withLock { openAdmitted[port, default: [:]][key] = channel }
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.lock.withLock { _ = self?.openAdmitted[port]?.removeValue(forKey: key) }
        }
    }

    // MARK: SSH

    /// One SSH connection for every tunnel, dialled on first use and again
    /// after it dies. `fresh` says it was dialled for this caller.
    private func ssh() async throws -> (connection: SSHConnection, fresh: Bool) {
        let (existing, task): (SSHConnection?, Task<SSHConnection, Error>?) = lock.withLock {
            if let connection { return (connection, nil) }
            if let connecting { return (nil, connecting) }
            let host = host
            let task = Task {
                let secrets = await HostSecrets.loadOffMain(for: host)
                let dialled = SSHConnection(host: host, secrets: secrets)
                // Citadel connects can black-hole and ignore cancellation.
                try await deadlined(seconds: HostTest.connectDeadline) { try await dialled.connect() }
                return dialled
            }
            connecting = task
            return (nil, task)
        }
        if let existing { return (existing, false) }
        guard let task else { throw SSHConnectionError.notConnected }
        do {
            let ready = try await task.value
            lock.withLock { connection = ready; connecting = nil }
            return (ready, true)
        } catch {
            lock.withLock { connecting = nil }
            throw error
        }
    }

    /// Opens `target:port` from the host. A REUSED connection that fails is
    /// presumed dead (suspension, network change): it is closed and one
    /// fresh dial tried — but not when the host answered by refusing the
    /// channel (nothing listening there), which says the link is fine.
    fileprivate func open(host target: String, port: Int) async throws -> Channel {
        lock.withLock { opened += 1 }
        let initialize: @Sendable (Channel) -> EventLoopFuture<Void> = { $0.eventLoop.makeSucceededVoidFuture() }
        let (link, fresh) = try await ssh()
        do {
            return try await link.openDirectTCPIP(host: target, port: port, initialize: initialize)
        } catch {
            let refused = (error as? NIOSSHError)?.type == .channelSetupRejected
            guard !fresh, !refused, !(error is CancellationError) else { throw error }
            lock.withLock { if connection === link { connection = nil } }
            Task { await link.close() }
            return try await ssh().connection.openDirectTCPIP(host: target, port: port, initialize: initialize)
        }
    }
}

/// Reads the request head (or, for a forward, just holds early bytes),
/// then swaps itself for a byte splice.
private final class HeadHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let proxy: AgentBrowserProxy
    /// A forward's fixed target: no head to parse, tunnel on connect.
    private let target: (host: String, port: Int)?
    private var buffered = Data()
    private var decided = false

    init(proxy: AgentBrowserProxy, target: (host: String, port: Int)? = nil) {
        self.proxy = proxy
        self.target = target
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var chunk = unwrapInboundIn(data)
        buffered.append(contentsOf: chunk.readBytes(length: chunk.readableBytes) ?? [])
        guard !decided else { return }
        let local = context.channel
        if let target {
            admitForward(local, to: target)
            return
        }
        let (outcome, headLength) = AgentProxyHead.parse(buffered, credential: proxy.credential)
        switch outcome {
        case .incomplete:
            return
        case .tooLarge, .malformed:
            refuse(local, AgentProxyHead.response("400 Bad Request"))
        case .unauthorized:
            refuse(local, AgentProxyHead.authenticationRequired)
        case .connect(let host, let port):
            decided = true
            tunnel(local, to: host, port: port, reply: AgentProxyHead.established, headLength: headLength)
        case .notTunnel:
            refuse(local, AgentProxyHead.response("501 Not Implemented"))
        }
    }

    /// Ends the connection undecided-for-good: answer (when there is an
    /// answer to give) then close.
    private func refuse(_ local: Channel, _ reply: Data?) {
        decided = true
        guard let reply else { return local.close(promise: nil) }
        local.writeAndFlush(ByteBuffer(bytes: reply)).whenComplete { _ in local.close(promise: nil) }
    }

    /// A forward's first request must carry the agent tabs' cookie; the
    /// whole request (head included) then goes to the host unchanged. An
    /// OPEN port tunnels whatever arrives. Decided at the first bytes, not
    /// at accept: WebKit pre-opens spare connections, and one accepted
    /// before `--open` must follow the mode in force when it is used.
    private func admitForward(_ local: Channel, to target: (host: String, port: Int)) {
        if proxy.isOpen(target.port) {
            decided = true
            proxy.admittedWhileOpen(local, port: target.port)
            return tunnel(local, to: target.host, port: target.port, reply: nil, headLength: 0)
        }
        switch AgentProxyHead.forwardVerdict(buffered, secret: proxy.forwardSecret) {
        case .incomplete:
            return
        case .allowed:
            decided = true
            tunnel(local, to: target.host, port: target.port, reply: nil, headLength: 0)
        case .refused:
            AgentBrowserProxy.log.info("host route: refused an uncredentialed client of forward :\(target.port, privacy: .public)")
            refuse(local, AgentProxyHead.forwardRefused)
        case .notHTTP:
            refuse(local, nil)
        }
    }

    /// Opens the host-side connection, answers, flushes what arrived after
    /// the head, then glues the two channels.
    private func tunnel(
        _ local: Channel,
        to host: String,
        port: Int,
        reply: Data?,
        headLength: Int
    ) {
        let started = ContinuousClock.now
        Task { [proxy] in
            let remote: Channel
            do {
                remote = try await proxy.open(host: host, port: port)
            } catch {
                AgentBrowserProxy.log.info("host route: \(host, privacy: .private):\(port, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                // A proxy client gets a status; a forward's client just
                // sees the connection end, as a refused port would.
                local.eventLoop.execute {
                    self.refuse(local, reply == nil ? nil : AgentProxyHead.response("502 Bad Gateway"))
                }
                return
            }
            let milliseconds = Int((ContinuousClock.now - started) / .milliseconds(1))
            AgentBrowserProxy.log.debug("host route: \(host, privacy: .private):\(port, privacy: .public) open in \(milliseconds, privacy: .public) ms")
            local.eventLoop.execute {
                // Anything sent after the head (rare for CONNECT) goes first.
                let rest = Data(self.buffered.dropFirst(headLength))
                self.buffered = Data()
                _ = local.pipeline.removeHandler(self)
                // Backpressure pauses the host side once the device socket
                // holds `high` unsent bytes; at NIO's 64 KiB default every
                // pause cost a network round trip. Only the device socket
                // takes the option: the SSH channel's writability is its
                // flow-control window, and NIOSSH's child channel TRAPS
                // (fatalError) on an option it does not support.
                let watermark = ChannelOptions.Types.WriteBufferWaterMark(low: 512 << 10, high: 2 << 20)
                _ = local.setOption(ChannelOptions.writeBufferWaterMark, value: watermark)
                let (fromDevice, fromHost) = AgentProxySplice.pair(local, remote)
                _ = local.pipeline.addHandler(fromDevice)
                _ = remote.pipeline.addHandler(fromHost)
                if !rest.isEmpty { remote.writeAndFlush(ByteBuffer(bytes: rest), promise: nil) }
                if let reply { local.writeAndFlush(ByteBuffer(bytes: reply), promise: nil) }
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// One direction of a tunnel: forwards every read to the partner channel,
/// with backpressure — while the partner cannot take more (its socket
/// buffer, or its SSH channel window, is full) this side stops reading, so
/// a fast host never piles a slow page's bytes up in memory (and a fast
/// page never outruns the SSH window). The pair resumes each other across
/// event loops: the device socket and the SSH channel live on different
/// ones. When one side ends, the other closes after its queued writes.
final class AgentProxySplice: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let partner: Channel
    /// The splice on the partner channel — told when this side can take
    /// more again.
    weak var peer: AgentProxySplice?
    private var context: ChannelHandlerContext?
    /// A read the pipeline asked for while the partner was full.
    private var pendingRead = false

    init(partner: Channel) {
        self.partner = partner
    }

    /// Two splices that resume each other.
    static func pair(_ first: Channel, _ second: Channel) -> (AgentProxySplice, AgentProxySplice) {
        let forward = AgentProxySplice(partner: second)
        let backward = AgentProxySplice(partner: first)
        forward.peer = backward
        backward.peer = forward
        return (forward, backward)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    /// Writes now, flushes once per read burst (`channelReadComplete`), so a
    /// burst leaves as one write rather than one per chunk.
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner.write(unwrapInboundIn(data), promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner.flush()
        context.fireChannelReadComplete()
    }

    /// Reads are granted only while the partner can absorb them.
    func read(context: ChannelHandlerContext) {
        if partner.isWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable, let peer {
            // The peer lives on the partner channel's loop; resume it there.
            partner.eventLoop.execute { peer.resumeReading() }
        }
        context.fireChannelWritabilityChanged()
    }

    /// On this splice's own event loop: grant the read held back while the
    /// partner was full.
    func resumeReading() {
        guard pendingRead, let context else { return }
        pendingRead = false
        context.read()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event { finish() }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
        partner.close(promise: nil)
    }

    private func finish() {
        let partner = partner
        // Writes complete in order: an empty write's completion means every
        // byte queued before it is out.
        partner.writeAndFlush(ByteBuffer()).whenComplete { _ in partner.close(promise: nil) }
    }
}
