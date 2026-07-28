import Foundation
import Observation
import UIKit
import os
#if DEBUG
import notify
#endif

/// The bind flow's one owner: it gates discovery, holds the candidates the
/// Add Host modal's Bind pane renders, runs enrollment, and saves the host.
/// Reachable as `.shared` because `onOpenURL` fires on every scene root
/// (same reason `ExternalActionRouter` is shared); the mounted deck attaches
/// the stores it needs, exactly like that router's context.
@MainActor
@Observable
final class BindController {
    static let shared = BindController()

    /// One machine offering to bind — a row in the Bind pane.
    struct Pending: Identifiable, Equatable {
        enum Source: Equatable {
            /// Heard on the local network; the PIN in its terminal proves it.
            case discovered(BindAnnouncement)
            /// Scanned or pasted; the payload's token proves it.
            case payload(BindPayload)
        }

        enum Stage: Equatable {
            case awaitingPIN
            case binding
            case enrolling
            case checking
            case bound(hostID: UUID)
            case failed(String)
        }

        var id: String
        var source: Source
        var name: String
        var user: String
        var addressSummary: String
        var fingerprint: String?
        var pin: String = ""
        var stage: Stage = .awaitingPIN
        /// Cleared on success so a bound row stops asking for anything.
        var needsPIN: Bool

        var isBusy: Bool {
            switch stage {
            case .binding, .enrolling, .checking: true
            default: false
            }
        }

        var canSubmit: Bool {
            guard !isBusy else { return false }
            return needsPIN ? pin.count == 6 : true
        }

        var statusCaption: String {
            switch stage {
            // Say what the row is waiting for, not what it is going to be:
            // this state is the machine asking, and the PIN is the answer.
            case .awaitingPIN: needsPIN ? "NEEDS PIN" : "READY"
            case .binding: "BINDING"
            case .enrolling: "ENROLLING"
            case .checking: "CHECKING"
            case .bound: "BOUND"
            case .failed: "FAILED"
            }
        }
    }

    private(set) var pending: [Pending] = []
    /// A paste/scan that couldn't even be parsed, or a limit refusal.
    var alert: String?
    /// Raised when the free host limit blocks a bind.
    var needsProForHostLimit = false
    /// Raised when a payload arrives from outside the Add Host modal (a
    /// `multiplex://b/…` URL): the mounted deck answers by presenting the
    /// modal on its Bind pane, so the candidate the URL added is on screen
    /// waiting for the user's ENROLL rather than parked invisibly.
    var wantsBindSurface = false
    /// Set by `BindPane` while it is on screen. The whole flow lives on that
    /// one surface now, so this is what discovery is for: nothing on the wall
    /// consumes announcements, and a device that never opens the pane never
    /// raises the local-network prompt. The mounted deck still owns the
    /// browser's lifecycle and reads this as one of its inputs.
    var bindSurfaceOpen = false

    let discovery = BindDiscovery()

    /// When each announcement id was first heard, kept across pane opens so
    /// the staleness clock is the offer's age, not this pane session's.
    @ObservationIgnored private var firstHeard: [String: Date] = [:]

    @ObservationIgnored private weak var store: HostStore?
    @ObservationIgnored private weak var entitlements: EntitlementStore?
    @ObservationIgnored private let rotations = BindRotationStore()
    @ObservationIgnored private let log = Logger(
        subsystem: "app.multiplexterm.multiplex", category: "bind"
    )
    @ObservationIgnored private var debugHooksInstalled = false

    var hasContext: Bool { store != nil }

    /// The mounted deck hands over the stores; discovery stays off until the
    /// user opens a bind surface.
    func attach(store: HostStore, entitlements: EntitlementStore) {
        self.store = store
        self.entitlements = entitlements
        #if DEBUG
        installDebugHooks()
        #endif
    }

    // MARK: Discovery lifecycle

    /// Started and stopped by the mounted deck, which owns the policy: while
    /// the Bind pane is on screen or an enrollment is in flight, and never in
    /// the background. This class only holds the browser.
    func beginDiscovery() {
        discovery.start()
    }

    func endDiscovery() {
        discovery.stop()
        // Rows for machines we can no longer hear go with it, except ones
        // mid-flight or already bound (their receipt stays put).
        pending.removeAll { candidate in
            guard case .discovered = candidate.source else { return false }
            if candidate.isBusy { return false }
            if case .bound = candidate.stage { return false }
            return true
        }
    }

    /// Folds the browser's current list into the candidate rows, preserving
    /// any PIN the user has already typed and any in-flight stage, and drops
    /// offers too old to still be live (`BindOfferLifetime`). Also called on
    /// a slow tick by the pane, because a stale record produces no browse
    /// change to react to — that is exactly its problem.
    func syncDiscovered(now: Date = Date()) {
        for announcement in discovery.announcements where firstHeard[announcement.id] == nil {
            firstHeard[announcement.id] = now
        }
        let heard = discovery.announcements.filter { announcement in
            guard let since = firstHeard[announcement.id] else { return true }
            return !BindOfferLifetime.isStale(firstHeard: since, now: now)
        }
        var updated = pending
        for announcement in heard where !updated.contains(where: { $0.id == announcement.id }) {
            updated.append(Pending(
                id: announcement.id,
                source: .discovered(announcement),
                name: announcement.name,
                user: announcement.user,
                addressSummary: "ssh :\(announcement.sshPort)",
                fingerprint: announcement.fingerprint,
                needsPIN: true
            ))
        }
        let heardIDs = Set(heard.map(\.id))
        updated.removeAll { candidate in
            guard case .discovered = candidate.source, !heardIDs.contains(candidate.id)
            else { return false }
            if candidate.isBusy { return false }
            if case .bound = candidate.stage { return false }
            return true
        }
        if updated != pending { pending = updated }
    }

    // MARK: Payload entry (scan, paste, URL)

    /// A scanned/pasted/opened payload always lands as a row the user
    /// confirms — never an automatic bind. Attacker-suppliable input gets
    /// the same confirmation as anything else.
    func submit(payloadText: String) {
        guard let payload = BindPayload(string: payloadText) else {
            log.debug("bind payload rejected (\(payloadText.count) chars)")
            alert = "That isn’t a Multiplex bind code. Run mpx bind on the machine and scan or paste what it prints."
            return
        }
        submit(payload: payload)
    }

    /// Scan and paste live inside the Bind pane, so the act that delivered
    /// this payload — pointing the camera at the machine's own QR, pressing
    /// Paste — IS the user's confirmation, and the bind runs at once.
    func submit(payload: BindPayload) {
        guard let id = upsert(payload) else { return }
        confirm(id: id)
    }

    /// A payload that arrived from *outside* the modal — a `multiplex://b/…`
    /// URL another app opened. That input is attacker-suppliable (a QR on a
    /// poster, a link in a message), so unlike scan/paste it never executes:
    /// it only ever adds a candidate row, and asks the deck to put the Bind
    /// pane on screen so the user's ENROLL there is the confirmation.
    func receive(payload: BindPayload) {
        _ = upsert(payload)
        wantsBindSurface = true
    }

    /// Adds or refreshes the candidate row for a payload and answers its id,
    /// or nil while that row is mid-enrollment and must not be replaced.
    private func upsert(_ payload: BindPayload) -> String? {
        // The compact payload knows the machine's address but, on the
        // handshake path, not its SSH user or fingerprint — the OFFER brings
        // those a moment later, so the row shows what it actually knows.
        let id = payload.isOffline
            ? "offline:\(payload.name):\(payload.offline?.sshUser ?? "")"
            : payload.spub.base64EncodedString()
        var candidate = Pending(
            id: id,
            source: .payload(payload),
            name: payload.name,
            user: payload.offline?.sshUser ?? "",
            addressSummary: Self.addressSummary(for: payload),
            fingerprint: payload.offline?.pinnedHostKey,
            needsPIN: false
        )
        candidate.stage = .awaitingPIN
        if let index = pending.firstIndex(where: { $0.id == id }) {
            guard !pending[index].isBusy else { return nil }
            pending[index] = candidate
        } else {
            pending.append(candidate)
        }
        return id
    }

    func setPIN(_ pin: String, for id: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let digits = String(pin.filter(\.isNumber).prefix(6))
        guard pending[index].pin != digits else { return }
        pending[index].pin = digits
    }

    func dismiss(id: String) {
        pending.removeAll { $0.id == id }
    }

    // MARK: Enrollment

    func confirm(id: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else {
            log.debug("bind confirm: no pending row for that offer")
            return
        }
        guard pending[index].canSubmit else {
            log.debug("bind confirm: row not ready (needs its PIN, or already running)")
            return
        }
        guard let store, let entitlements else {
            log.debug("bind confirm: no deck mounted yet — nothing to save into")
            return
        }
        // The gate runs before anything is enrolled on the machine: never
        // write a key into someone's authorized_keys for a host this tier
        // can't then use.
        guard entitlements.canAddHost(existingHostCount: store.hosts.count) else {
            log.debug("bind refused: free host limit reached")
            needsProForHostLimit = true
            return
        }
        let candidate = pending[index]
        pending[index].stage = .binding
        log.debug("bind starting for \(candidate.name, privacy: .public)")
        Task { await performBind(candidate) }
    }

    private func performBind(_ candidate: Pending) async {
        switch candidate.source {
        case .payload(let payload) where payload.isOffline:
            await importOffline(payload, id: candidate.id)
        case .payload(let payload):
            await handshake(
                id: candidate.id,
                spub: payload.spub,
                credential: .token(payload.token),
                endpointPayload: payload
            )
        case .discovered(let announcement):
            await handshake(
                id: candidate.id,
                spub: announcement.spub,
                credential: .pin(candidate.pin),
                announcement: announcement
            )
        }
    }

    private func handshake(
        id: String,
        spub: Data,
        credential: BindClientSession.Credential,
        endpointPayload: BindPayload? = nil,
        announcement: BindAnnouncement? = nil
    ) async {
        let key = BindSSHKey.generate()
        let device = Self.deviceName
        do {
            let completion: BindClient.Completion
            if let payload = endpointPayload {
                completion = try await BindClient.run(
                    payload: payload,
                    publicKeyLine: key.publicLine,
                    device: device
                )
            } else if let announcement, let endpoint = discovery.endpoint(for: announcement) {
                completion = try await BindClient.run(
                    endpoint: endpoint,
                    spub: spub,
                    credential: credential,
                    publicKeyLine: key.publicLine,
                    device: device
                )
            } else {
                fail(id: id, "That machine stopped announcing — run mpx bind again.")
                return
            }
            log.debug("bind enrolled \(completion.comment, privacy: .public)")
            setStage(id: id, .enrolling)
            let hostname = Self.hostname(
                for: completion.offer,
                connectedTo: completion.connectedHost,
                payload: endpointPayload
            )
            log.debug("bind host address: \(hostname, privacy: .public)")
            await save(
                id: id,
                name: completion.offer.name,
                hostname: hostname,
                port: completion.offer.sshPort,
                username: completion.offer.sshUser,
                privateKey: key.privateOpenSSH,
                pins: completion.offer.hostkeys,
                rotation: nil
            )
        } catch {
            fail(id: id, (error as? LocalizedError)?.errorDescription
                ?? "The bind didn’t complete. Run mpx bind again.")
        }
    }

    /// `mpx bind --offline`: the key came with the payload as a raw seed, so
    /// there is no handshake — rebuild it, import, then rotate it out.
    private func importOffline(_ payload: BindPayload, id: String) async {
        guard let offline = payload.offline,
              let key = BindSSHKey(seed: offline.seed)
        else {
            fail(id: id, "That bind code is missing its key.")
            return
        }
        setStage(id: id, .enrolling)
        await save(
            id: id,
            name: payload.name,
            hostname: payload.addrs.first ?? payload.name,
            port: offline.sshPort,
            username: offline.sshUser,
            privateKey: key.privateOpenSSH,
            pins: offline.pinnedHostKey.map { [$0] } ?? [],
            rotation: BindRotationStore.Request(
                transportedPublicB64: key.publicB64,
                authorizedKeysPath: offline.authorizedKeysPath
            )
        )
    }

    private func save(
        id: String,
        name: String,
        hostname: String,
        port: UInt16,
        username: String,
        privateKey: String,
        pins: [String],
        rotation: BindRotationStore.Request?
    ) async {
        guard let store else { return }
        var host = Host(
            name: Self.uniqueName(name, taken: store.hosts.map(\.name)),
            hostname: hostname,
            username: username
        )
        host.port = Int(port)
        host.authMethod = .privateKey
        host.pinnedHostKeys = pins
        KeychainStore.set(privateKey, for: host.id, kind: .privateKey)
        store.add(host)
        if let rotation {
            rotations.record(rotation, for: host.id)
        }

        setStage(id: id, .checking)
        let outcome = await HostTest.run(host: host, secrets: HostSecrets.load(for: host))
        switch outcome {
        case .connected:
            if rotation != nil {
                await rotateIfNeeded(host: host)
            }
            markBound(id: id, host: host)
        case .failed(let message):
            // The record and its key are saved either way — the host is on
            // the wall and can be fixed in Host Settings. Say what happened.
            log.debug("bind test connect failed: \(message, privacy: .public)")
            setStage(id: id, .failed("Bound, but the first connection failed: \(message)"))
        }
    }

    private func markBound(id: String, host: Host) {
        setStage(id: id, .bound(hostID: host.id))
        // The receipt is the row saying BOUND; drop it shortly after so the
        // list settles back to whatever is still asking.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.dismiss(id: id)
        }
    }

    private func setStage(id: String, _ stage: Pending.Stage) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].stage = stage
    }

    private func fail(id: String, _ message: String) {
        log.debug("bind failed: \(message, privacy: .public)")
        setStage(id: id, .failed(message))
    }

    // MARK: Rotation (offline binds)

    /// Retires the key that travelled inside an offline payload: enroll a
    /// device-held key over the host's own SSH, then delete the transported
    /// line. Runs at import and — if that connection failed — on the next
    /// foreground pass, so the transported key's life stays short.
    func rotatePendingKeysIfNeeded() async {
        guard let store else { return }
        for hostID in rotations.pendingHostIDs {
            guard let host = store.host(id: hostID), host.isEnabled else { continue }
            await rotateIfNeeded(host: host)
        }
    }

    private func rotateIfNeeded(host: Host) async {
        guard let store, let request = rotations.request(for: host.id) else { return }
        guard let transported = request.transportedPublicB64 else {
            // Nothing identifiable to remove; don't leave a retry pending
            // forever over a key we can't name.
            rotations.clear(for: host.id)
            return
        }
        let replacement = BindSSHKey.generate()
        let comment = BindMarker.comment(id8: BindMarker.randomID8(), device: Self.deviceName)
        let command = BindRotationStore.rotateCommand(
            authorizedKeysPath: request.authorizedKeysPath,
            removingPublicB64: transported,
            addingLine: "\(replacement.publicLine) \(comment)"
        )
        let connection = SSHConnection(host: host, secrets: HostSecrets.load(for: host))
        defer { Task { await connection.close() } }
        do {
            try await connection.connect()
            let output = try await connection.exec(command)
            guard output.contains("MPX_ROTATE_OK") else {
                log.debug("bind key rotation reported no success sentinel")
                return
            }
            // Only now does the new key become this host's credential.
            KeychainStore.set(replacement.privateOpenSSH, for: host.id, kind: .privateKey)
            rotations.clear(for: host.id)
            log.debug("bind key rotated for \(host.name, privacy: .public)")
            // Force the probe link to rebuild on the new credential.
            store.update(host)
        } catch {
            // Keep the transported key (it still works) and retry later.
            log.debug("bind key rotation deferred: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Helpers

    static var deviceName: String {
        #if os(visionOS)
        let fallback = "Apple Vision Pro"
        #else
        let fallback = "iPad"
        #endif
        let name = UIDevice.current.name
        return name.isEmpty ? fallback : name
    }

    /// What the row shows under the machine's name before a handshake has
    /// told us anything more.
    nonisolated static func addressSummary(for payload: BindPayload) -> String {
        let port = payload.offline?.sshPort
        let suffix = port.map { "ssh :\($0)" } ?? "ssh"
        guard let addr = payload.addrs.first else { return suffix }
        return "\(addr) · \(suffix)"
    }

    /// Which address the saved host dials. The machine's own list is
    /// authoritative — where its *SSH* lives is not necessarily where its
    /// bind listener answered (a Bonjour resolve reports the interface the
    /// service was found on, while `mpx bind --addr` exists precisely so a
    /// machine behind NAT, a tunnel, or a port forward can name the address
    /// that actually works). So prefer the address we reached only when the
    /// machine also endorses it: that one is proven reachable *and* stated.
    nonisolated static func hostname(
        for offer: BindOffer,
        connectedTo connected: String?,
        payload: BindPayload?
    ) -> String {
        let stated = offer.addrs.isEmpty ? (payload?.addrs ?? []) : offer.addrs
        if let connected, stated.contains(connected) { return connected }
        if let first = stated.first { return first }
        return connected ?? offer.name
    }

    /// Two machines can genuinely be called "devbox". Suffix rather than
    /// merge — a bind never edits a host the user already had.
    nonisolated static func uniqueName(_ name: String, taken: [String]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "host" : trimmed
        guard taken.contains(where: { $0.caseInsensitiveCompare(base) == .orderedSame })
        else { return base }
        var suffix = 2
        while taken.contains(where: {
            $0.caseInsensitiveCompare("\(base) \(suffix)") == .orderedSame
        }) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    #if DEBUG
    /// Headless hooks — the simulator can neither scan a QR nor tap a row:
    ///   MULTIPLEX_AUTO_BIND=<multiplex://b/…>     submit a payload once
    ///   MULTIPLEX_BIND_AUTOPIN=<6 digits>         answer the first heard
    ///                                             machine with that PIN
    /// plus notification `…debug.bind` to open discovery on demand.
    private static var autoBindFired = false

    private func installDebugHooks() {
        guard !debugHooksInstalled else { return }
        debugHooksInstalled = true
        var token: Int32 = 0
        notify_register_dispatch(
            "app.multiplexterm.multiplex.debug.bind", &token, .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Stand in for the Bind pane being on screen, so the deck's
                // own lifecycle task keeps the browser up instead of tearing
                // it down on its next evaluation.
                self?.bindSurfaceOpen = true
                self?.beginDiscovery()
            }
        }
    }

    func runDebugAutomationIfRequested() async {
        guard !Self.autoBindFired else { return }
        let environment = ProcessInfo.processInfo.environment
        let payload = environment["MULTIPLEX_AUTO_BIND"]
        let autoPIN = environment["MULTIPLEX_BIND_AUTOPIN"]
        guard payload != nil || autoPIN != nil else { return }
        Self.autoBindFired = true
        log.debug("bind automation requested (payload: \(payload != nil), pin: \(autoPIN != nil))")
        // Let the store finish its first load (and any seeded host land).
        try? await Task.sleep(for: .seconds(2))
        if let payload {
            submit(payloadText: payload)
            return
        }
        guard let autoPIN else { return }
        // Same stand-in as the notification hook: the pane is what discovery
        // serves now, and the deck's lifecycle task would otherwise stop the
        // browser out from under this walk.
        bindSurfaceOpen = true
        beginDiscovery()
        for _ in 0..<60 {
            syncDiscovered()
            if let candidate = pending.first(where: {
                if case .discovered = $0.source { return $0.stage == .awaitingPIN }
                return false
            }) {
                setPIN(autoPIN, for: candidate.id)
                confirm(id: candidate.id)
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        log.debug("MULTIPLEX_BIND_AUTOPIN heard no machine announcing")
    }
    #endif
}
