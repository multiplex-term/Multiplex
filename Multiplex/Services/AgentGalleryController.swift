import Foundation

/// One per ✳ Agent Gallery tab — the herdr chat surface's state owner:
/// which agent is selected, that agent's visible screen, and the composer's
/// delivery verdicts. Dials its OWN SSHConnection lazily (the file viewer's
/// lifecycle exactly): never the probe's — a disabled host must not be
/// revived by a tab — and never a terminal's transport, because merge/split
/// move this tab away. Request/response only, so a dead reused socket is
/// redialed once per operation and suspension needs no resume policy.
///
/// The rail's rows come from the host's existing probe (via the pure
/// `AgentGallery.agents` derivation over the connection model's records) —
/// this controller never runs its own topology probe.
@MainActor
@Observable
final class AgentGalleryController: AuxiliaryPaneController {
    let tabID: UUID
    let host: Host

    private(set) var selectedPaneID: String?
    /// The selected agent's visible screen, right-trimmed with the trailing
    /// blank run dropped — the same shape the wall's miniatures show.
    private(set) var screenLines: [String] = []
    /// Why the screen is empty, when it is for a reason worth saying.
    private(set) var screenNote: String?
    private(set) var isSending = false
    /// The composer's last delivery verdict worth showing (stalled or
    /// failed); cleared by the next successful send.
    private(set) var deliveryNote: String?

    var tabLabel: String { "✳ agents" }

    @ObservationIgnored private var connection: SSHConnection?
    /// Drops screen reads that finish after the person switched agents.
    @ObservationIgnored private var screenGeneration = 0

    init(tabID: UUID, host: Host) {
        self.tabID = tabID
        self.host = host
    }

    func select(_ paneID: String?) {
        guard selectedPaneID != paneID else { return }
        selectedPaneID = paneID
        screenLines = []
        screenNote = nil
        screenGeneration &+= 1
        guard paneID != nil else { return }
        Task { await refreshScreen() }
    }

    /// One visible-screen read for the selected agent. QUIET swap — the
    /// pane re-renders only when the lines changed, and a read that lands
    /// after the person moved on is dropped by the generation counter.
    func refreshScreen() async {
        guard let paneID = selectedPaneID else { return }
        let generation = screenGeneration
        do {
            let output = try await withConnection { connection in
                try await connection.exec(
                    HerdrProbe.screenReadCommand(paneID: paneID))
            }
            guard generation == screenGeneration else { return }
            let lines = Self.visibleLines(output)
            if screenLines != lines { screenLines = lines }
            if screenNote != nil { screenNote = nil }
        } catch {
            guard generation == screenGeneration else { return }
            screenNote = "NO ROUTE — \(shortDescription(of: error))"
        }
    }

    /// Send one prompt through `herdr agent prompt`. Control characters are
    /// stripped and interior newlines kept — herdr's bracketed paste makes
    /// multiline safe, and the CLI itself performs the submit.
    func send(prompt: String) async {
        guard let paneID = selectedPaneID, !isSending else { return }
        let text = Self.sanitizedPrompt(prompt)
        guard !text.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            let output = try await withConnection { connection in
                try await connection.exec(
                    HerdrProbe.promptCommand(paneID: paneID, text: text))
            }
            switch HerdrProbe.promptVerdict(output) {
            case .delivered:
                deliveryNote = nil
            case .stalled:
                deliveryNote = "SENT — AGENT DIDN'T PICK IT UP YET"
            case .failed(let message):
                deliveryNote = "NOT DELIVERED — \(message)"
            }
        } catch {
            deliveryNote = "NOT DELIVERED — \(shortDescription(of: error))"
        }
        Task { await refreshScreen() }
    }

    /// The composer's persistence rule: no control bytes (a CR would run
    /// whatever sits in a remote composer), interior newlines kept for
    /// herdr's bracketed paste, outside whitespace trimmed.
    nonisolated static func sanitizedPrompt(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let safe = normalized.unicodeScalars.reduce(into: "") { result, scalar in
            let allowed = scalar.value == 0x0A
                || !CharacterSet.controlCharacters.contains(scalar)
            if allowed { result.append(Character(scalar)) }
        }
        return safe.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func visibleLines(_ output: String) -> [String] {
        var lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var slice = line[...]
                while let last = slice.last, last == " " || last == "\t" {
                    slice = slice.dropLast()
                }
                return String(slice)
            }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines
    }

    // MARK: Connection (file-viewer lifecycle)

    private func liveConnection() async throws -> (SSHConnection, fresh: Bool) {
        if let connection { return (connection, false) }
        let secrets = await HostSecrets.loadOffMain(for: host)
        let dialed = SSHConnection(host: host, secrets: secrets)
        try await dialed.connect()
        connection = dialed
        return (dialed, true)
    }

    private func withConnection<T: Sendable>(
        _ body: @Sendable (SSHConnection) async throws -> T
    ) async throws -> T {
        let (link, fresh) = try await liveConnection()
        do {
            return try await body(link)
        } catch {
            guard !fresh, !(error is CancellationError) else { throw error }
            connection = nil
            Task { await link.close() }
            let (redialed, _) = try await liveConnection()
            return try await body(redialed)
        }
    }

    private func shortDescription(of error: Error) -> String {
        if let connectionError = error as? SSHConnectionError {
            return connectionError.localizedDescription
        }
        return String(describing: type(of: error))
    }

    func shutdown() {
        let dying = connection
        connection = nil
        Task { await dying?.close() }
    }
}
