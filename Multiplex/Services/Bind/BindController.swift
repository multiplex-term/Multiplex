import CryptoKit
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

    /// One machine offering to bind — a row in the Bind pane. Only the
    /// source, the typed PIN, and the enrollment stage are stored; identity
    /// and display facts derive from the source, so no construction site can
    /// let them drift.
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
            case bound
            case failed(String)
        }

        var source: Source
        var pin: String = ""
        var stage: Stage = .awaitingPIN

        var id: String {
            switch source {
            case .discovered(let announcement):
                announcement.id
            case .payload(let payload):
                payload.isOffline
                    ? "offline:\(payload.name):\(payload.offline?.sshUser ?? "")"
                    : payload.spub.base64EncodedString()
            }
        }

        var name: String {
            switch source {
            case .discovered(let announcement): announcement.name
            case .payload(let payload): payload.name
            }
        }

        // The compact handshake payload knows the machine's address but not
        // its SSH user or fingerprint — the OFFER brings those a moment
        // later — so a payload row shows only what it actually knows.

        var user: String {
            switch source {
            case .discovered(let announcement): announcement.user
            case .payload(let payload): payload.offline?.sshUser ?? ""
            }
        }

        var addressSummary: String {
            switch source {
            case .discovered(let announcement): "ssh :\(announcement.sshPort)"
            case .payload(let payload): BindNaming.addressSummary(for: payload)
            }
        }

        var fingerprint: String? {
            switch source {
            case .discovered(let announcement): announcement.fingerprint
            case .payload(let payload): payload.offline?.pinnedHostKey
            }
        }

        /// Only a network-discovered machine proves itself with the PIN its
        /// terminal printed; scan/paste payloads carry their own token.
        var needsPIN: Bool {
            if case .discovered = source { return true }
            return false
        }

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
    }

    private(set) var pending: [Pending] = []
    /// True while any row is mid-enrollment. Stored rather than computed on
    /// purpose: the deck's browse task keys on this fact, and a computed
    /// read of `pending` would re-evaluate the deck's whole body on every
    /// PIN keystroke (Observation tracks the array, not the derived Bool).
    private(set) var enrollmentInFlight = false
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
    var bindSurfaceOpen = false {
        didSet {
            // A closed pane forgets its passphrase: the field is bind-flow
            // state, not something to find pre-filled next week. In-flight
            // binds already snapshotted their copy at confirm time. The
            // backend choice resets with it for the same reason — a pane
            // opened next week must state what it is about to do, never
            // carry a silent choice from a session nobody remembers.
            if !bindSurfaceOpen {
                keyPassphrase = ""
                backends = Host.BackendSelection()
            }
        }
    }
    /// The pane's optional KEY PASSPHRASE — ssh-keygen's passphrase ask,
    /// relocated to where this flow generates its key. Every bind executed
    /// while it is set stores its private key sealed with it in OpenSSH's
    /// own encrypted format; empty means today's plaintext store. Not tied
    /// to any transport mode — handshake and offline-seed binds seal alike,
    /// and a payload the CLI already sealed keeps its own passphrase (that
    /// one Multiplex never saw, so its first connect asks through the
    /// key-unlock prompt). Typing it here counts as the person's one
    /// Multiplex typing: it is saved into the host's settings exactly like
    /// the Host Settings Passphrase field (synced Keychain, visible and
    /// clearable there), so connecting keeps working without a re-ask.
    var keyPassphrase = ""
    /// Which multiplexer the machines bound from this pane run their sessions
    /// on. Bind proves who the machine is; it says nothing about what runs on
    /// it, and `mpx bind` doesn't report a backend — so this is the person's
    /// choice, made where the host record is minted rather than found wrong on
    /// the deck afterwards. Never auto-switched (`Host.sessionBackend`'s rule),
    /// and changeable later in Host Settings → Backend. A machine may be
    /// enrolled showing both (the same check selection Host Settings uses),
    /// in which case the default is what new sessions run on.
    var backends = Host.BackendSelection()

    private let discovery = BindDiscovery()

    /// When each announcement id was first heard, kept across pane opens so
    /// the staleness clock is the offer's age, not this pane session's.
    @ObservationIgnored private var firstHeard: [String: Date] = [:]
    /// Retires announcement rows whose machine died without withdrawing —
    /// only their age can (`BindOfferLifetime`); runs while browsing does.
    @ObservationIgnored private var staleSweep: Task<Void, Never>?

    @ObservationIgnored private weak var store: HostStore?
    @ObservationIgnored private weak var entitlements: EntitlementStore?
    @ObservationIgnored private let rotations = BindRotationStore()
    @ObservationIgnored private let log = Logger(
        subsystem: "app.multiplexterm.multiplex", category: "bind"
    )
    @ObservationIgnored private var debugHooksInstalled = false

    var hasContext: Bool { store != nil }

    init() {
        // The controller owns the announcements→rows fold: views consume
        // `pending` and never have to pump between two objects it holds.
        discovery.onAnnouncementsChanged = { [weak self] in
            self?.syncDiscovered()
        }
    }

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
    /// the background. This class holds the browser and runs the fold.
    func beginDiscovery() {
        discovery.start()
        guard staleSweep == nil else { return }
        // A machine killed outright never withdrew its announcement, so no
        // browse change will ever retire that row — only its age can. Slow
        // on purpose: this is arithmetic, not a network call.
        staleSweep = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.syncDiscovered()
            }
        }
    }

    func endDiscovery() {
        staleSweep?.cancel()
        staleSweep = nil
        // stop() empties the announcement list and the fold retires the
        // rows for machines we can no longer hear — except ones mid-flight
        // or already bound (their receipt stays put).
        discovery.stop()
    }

    /// Folds the browser's current list into the candidate rows, preserving
    /// any PIN the user has already typed and any in-flight stage, and drops
    /// offers too old to still be live (`BindOfferLifetime`). Also called on
    /// the slow sweep above, because a stale record produces no browse
    /// change to react to — that is exactly its problem.
    private func syncDiscovered(now: Date = Date()) {
        for announcement in discovery.announcements where firstHeard[announcement.id] == nil {
            firstHeard[announcement.id] = now
        }
        let heard = discovery.announcements.filter { announcement in
            guard let since = firstHeard[announcement.id] else { return true }
            return !BindOfferLifetime.isStale(firstHeard: since, now: now)
        }
        var updated = pending
        for announcement in heard where !updated.contains(where: { $0.id == announcement.id }) {
            updated.append(Pending(source: .discovered(announcement)))
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

    /// Scan and paste live inside the Bind pane, so the act that delivered
    /// this payload — pointing the camera at the machine's own QR, pressing
    /// Paste — IS the user's confirmation, and the bind runs at once. Both
    /// surfaces parse before they submit; unparseable text never leaves the
    /// pane (its inline caption is the one failure surface).
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
        let candidate = Pending(source: .payload(payload))
        if let index = index(of: candidate.id) {
            guard !pending[index].isBusy else { return nil }
            pending[index] = candidate
        } else {
            pending.append(candidate)
        }
        return candidate.id
    }

    func setPIN(_ pin: String, for id: String) {
        guard let index = index(of: id) else { return }
        let digits = String(pin.filter(\.isNumber).prefix(6))
        guard pending[index].pin != digits else { return }
        pending[index].pin = digits
    }

    func dismiss(id: String) {
        pending.removeAll { $0.id == id }
        refreshEnrollmentInFlight()
    }

    private func index(of id: String) -> Int? {
        pending.firstIndex { $0.id == id }
    }

    // MARK: Enrollment

    func confirm(id: String) {
        guard let index = index(of: id) else {
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
        refreshEnrollmentInFlight()
        log.debug("bind starting for \(candidate.name, privacy: .public)")
        Task { await performBind(candidate) }
    }

    private func performBind(_ candidate: Pending) async {
        // Snapshot the pane's passphrase and backend now: the pane may close
        // (and reset both) while this bind is still talking to the machine.
        let passphrase = keyPassphrase
        let backends = self.backends
        if case .payload(let payload) = candidate.source, payload.isOffline {
            await importOffline(
                payload, id: candidate.id, keyPassphrase: passphrase, backends: backends
            )
        } else {
            await handshake(for: candidate, keyPassphrase: passphrase, backends: backends)
        }
    }

    private func handshake(
        for candidate: Pending,
        keyPassphrase: String,
        backends: Host.BackendSelection
    ) async {
        let id = candidate.id
        let raw = Curve25519.Signing.PrivateKey()
        let key = BindSSHKey.make(from: raw)
        // Seal BEFORE enrolling: a sealing failure after the machine already
        // added the public half would orphan an authorized_keys line whose
        // private key the app then refuses to store.
        let storedPrivateKey: String
        if keyPassphrase.isEmpty {
            storedPrivateKey = key.privateOpenSSH
        } else if let sealed = await Self.sealedOffMain(key: raw, passphrase: keyPassphrase) {
            storedPrivateKey = sealed
        } else {
            fail(id: id, "Couldn’t seal the key with that passphrase — nothing was enrolled.")
            return
        }
        let device = Self.deviceName
        do {
            let completion: BindClient.Completion
            var payload: BindPayload?
            switch candidate.source {
            case .payload(let scanned):
                payload = scanned
                completion = try await BindClient.run(
                    payload: scanned,
                    publicKeyLine: key.publicLine,
                    device: device
                )
            case .discovered(let announcement):
                guard let endpoint = discovery.endpoint(for: announcement) else {
                    fail(id: id, "That machine stopped announcing — run mpx bind again.")
                    return
                }
                completion = try await BindClient.run(
                    endpoint: endpoint,
                    spub: announcement.spub,
                    credential: .pin(candidate.pin),
                    publicKeyLine: key.publicLine,
                    device: device
                )
            }
            log.debug("bind enrolled \(completion.comment, privacy: .public)")
            setStage(id: id, .enrolling)
            let hostname = BindNaming.hostname(
                for: completion.offer,
                connectedTo: completion.connectedHost,
                payload: payload
            )
            log.debug("bind host address: \(hostname, privacy: .public)")
            await save(
                id: id,
                name: completion.offer.name,
                hostname: hostname,
                port: completion.offer.sshPort,
                username: completion.offer.sshUser,
                privateKey: storedPrivateKey,
                pins: completion.offer.hostkeys,
                rotation: nil,
                savedPassphrase: keyPassphrase.isEmpty ? nil : keyPassphrase,
                backends: backends
            )
        } catch {
            fail(id: id, (error as? LocalizedError)?.errorDescription
                ?? "The bind didn’t complete. Run mpx bind again.")
        }
    }

    /// bcrypt-pbkdf at 16 rounds is ~150 ms of deliberate KDF work.
    /// `Task.detached`, not merely nonisolated, so it stays off the main
    /// actor under every language-mode default — the row's spinner (and the
    /// wall behind the sheet) keep animating while the key seals.
    private static func sealedOffMain(
        key: Curve25519.Signing.PrivateKey, passphrase: String
    ) async -> String? {
        await Task.detached {
            BindSSHKey.sealedPrivateOpenSSH(key: key, passphrase: passphrase)
        }.value
    }

    /// `mpx bind --offline`: the key came with the payload as a raw seed, so
    /// there is no handshake — rebuild it, import, then rotate it out. With
    /// a pane passphrase set, the stored key is sealed instead and NEVER
    /// rotated: swapping it for a device-generated plaintext key would
    /// trade the person's own protection away.
    private func importOffline(
        _ payload: BindPayload,
        id: String,
        keyPassphrase: String,
        backends: Host.BackendSelection
    ) async {
        guard let offline = payload.offline,
              let raw = try? Curve25519.Signing.PrivateKey(rawRepresentation: offline.seed)
        else {
            fail(id: id, "That bind code is missing its key.")
            return
        }
        let key = BindSSHKey.make(from: raw)
        let privateKey: String
        let rotation: BindRotationStore.Request?
        var savedPassphrase: String?
        if keyPassphrase.isEmpty {
            privateKey = key.privateOpenSSH
            rotation = BindRotationStore.Request(
                transportedPublicB64: key.publicB64,
                authorizedKeysPath: offline.authorizedKeysPath
            )
        } else {
            guard let sealed = await Self.sealedOffMain(key: raw, passphrase: keyPassphrase)
            else {
                fail(id: id, "Couldn’t seal the key with that passphrase — nothing was saved.")
                return
            }
            privateKey = sealed
            rotation = nil
            savedPassphrase = keyPassphrase
        }
        setStage(id: id, .enrolling)
        await save(
            id: id,
            name: payload.name,
            hostname: payload.addrs.first ?? payload.name,
            port: offline.sshPort,
            username: offline.sshUser,
            privateKey: privateKey,
            pins: offline.pinnedHostKey.map { [$0] } ?? [],
            rotation: rotation,
            savedPassphrase: savedPassphrase,
            backends: backends
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
        rotation: BindRotationStore.Request?,
        savedPassphrase: String?,
        backends: Host.BackendSelection
    ) async {
        guard let store else { return }
        var host = Host(
            name: BindNaming.uniqueName(name, taken: store.hosts.map(\.name)),
            hostname: hostname,
            username: username
        )
        host.port = Int(port)
        host.authMethod = .privateKey
        host.pinnedHostKeys = pins
        // Set before the test connect below: `HostTest` looks for the host's
        // own multiplexer on the exec PATH — the default one, which is the
        // one that mints.
        host.backendSelection = backends
        KeychainStore.set(privateKey, for: host.id, kind: .privateKey)
        store.add(host)
        if let savedPassphrase {
            // Typed into the pane — the person's one Multiplex typing. It
            // lands in the host's settings exactly as the Host Settings
            // Passphrase field would put it (synced Keychain; visible and
            // clearable there), so connecting never re-asks unless the
            // person clears it. CLI-sealed imports pass nil: Multiplex
            // never saw that passphrase, and the key-unlock prompt is
            // where it gets typed.
            SSHKeyPassphraseSession.accept(
                savedPassphrase, for: host.id, saveToICloud: true
            )
        }
        if let rotation {
            rotations.record(rotation, for: host.id)
        }

        // A sealed key with no passphrase on file cannot pass any probe —
        // auth construction refuses before dialing — so don't run a test
        // that exists only to fail with copy about a field this pane
        // doesn't have. The wall's NEEDS PASSPHRASE tile takes over the
        // moment the deck probes this host, and its UNLOCK flow is the
        // prompt.
        if OpenSSHPrivateKeyEnvelope.encryption(in: privateKey) == .encrypted,
           HostSecrets.load(for: host).passphrase == nil {
            log.debug("bind import: key is passphrase-sealed — skipping the doomed probe; no rotation")
            markBound(id: id)
            return
        }

        setStage(id: id, .checking)
        let outcome = await HostTest.run(host: host, secrets: HostSecrets.load(for: host))
        switch outcome {
        case .connected:
            if rotation != nil {
                await rotateIfNeeded(host: host)
            }
            markBound(id: id)
        case .failed(let message):
            // The record and its key are saved either way — the host is on
            // the wall and can be fixed in Host Settings. Say what happened.
            log.debug("bind test connect failed: \(message, privacy: .public)")
            setStage(id: id, .failed("Bound, but the first connection failed: \(message)"))
        }
    }

    private func markBound(id: String) {
        setStage(id: id, .bound)
        // The receipt is the row saying BOUND; drop it shortly after so the
        // list settles back to whatever is still asking.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.dismiss(id: id)
        }
    }

    private func setStage(id: String, _ stage: Pending.Stage) {
        guard let index = index(of: id) else { return }
        pending[index].stage = stage
        refreshEnrollmentInFlight()
    }

    private func refreshEnrollmentInFlight() {
        let busy = pending.contains(where: \.isBusy)
        if enrollmentInFlight != busy { enrollmentInFlight = busy }
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

    #if DEBUG
    /// Headless hooks — the simulator can neither scan a QR nor tap a row:
    ///   MULTIPLEX_AUTO_BIND=<multiplex://b/…>     submit a payload once
    ///   MULTIPLEX_BIND_AUTOPIN=<6 digits>         answer the first heard
    ///                                             machine with that PIN
    ///   MULTIPLEX_BIND_PASSPHRASE=<text>          preset the pane's KEY
    ///                                             PASSPHRASE for that bind
    ///   MULTIPLEX_BIND_BACKEND=tmux|herdr         preset the pane's backend
    ///                                             choice for that bind
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
                // Stand in for the Bind pane being on screen: the mounted
                // deck's lifecycle task reads this flag and runs the browser
                // through the same policy the real pane gets.
                self?.bindSurfaceOpen = true
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
        if let passphrase = environment["MULTIPLEX_BIND_PASSPHRASE"], !passphrase.isEmpty {
            keyPassphrase = passphrase
            log.debug("bind automation: pane passphrase preset")
        }
        // Comma-separated so a headless run can mint a MIXED host; the
        // first entry is the default (`tmux,herdr` = both shown, tmux mints).
        if let raw = environment["MULTIPLEX_BIND_BACKEND"] {
            let parsed = raw.split(separator: ",")
                .compactMap { Host.SessionBackend(token: String($0)) }
            if let preferred = parsed.first {
                backends = Host.BackendSelection(
                    preferred: preferred, also: Set(parsed.dropFirst()))
                log.debug("bind automation: backend preset to \(raw, privacy: .public)")
            }
        }
        // Let the store finish its first load (and any seeded host land).
        try? await Task.sleep(for: .seconds(2))
        if let payload {
            if let parsed = BindPayload(string: payload) {
                submit(payload: parsed)
            } else {
                log.debug("MULTIPLEX_AUTO_BIND payload didn't parse (\(payload.count) chars)")
            }
            return
        }
        guard let autoPIN else { return }
        // Same stand-in as the notification hook: the deck's lifecycle task
        // sees the flag and starts the browser, and the announcement fold
        // fills `pending` on its own — this walk only polls for the row.
        bindSurfaceOpen = true
        for _ in 0..<60 {
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
