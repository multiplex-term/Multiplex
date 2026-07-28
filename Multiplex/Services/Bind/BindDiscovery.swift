import Foundation
import Network
import Observation
import os

/// Browses `_multiplex-bind._tcp` while a bind surface is on screen and
/// publishes the machines currently offering to pair. Never starts on its
/// own: `BindController` gates it behind the user's first explicit bind
/// action, so the local-network prompt cannot fire before the user touches
/// the feature. TXT parsing is pure (`BindAnnouncement`); this class only
/// owns the NWBrowser and the endpoint each announcement resolves to.
@MainActor
@Observable
final class BindDiscovery {
    private(set) var announcements: [BindAnnouncement] = []

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var endpoints: [String: NWEndpoint] = [:]
    @ObservationIgnored private let log = Logger(
        subsystem: "app.multiplexterm.multiplex", category: "bind"
    )

    var isBrowsing: Bool { browser != nil }

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: BindWire.bonjourType, domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let parsed: [(BindAnnouncement, NWEndpoint)] = results.compactMap { result in
                guard case .bonjour(let record) = result.metadata,
                      let announcement = BindAnnouncement(txt: record.dictionary)
                else { return nil }
                return (announcement, result.endpoint)
            }
            Task { @MainActor [weak self] in
                self?.apply(parsed)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.log.debug("bind browser failed: \(String(describing: error))")
                    // One quiet rebuild; a second failure stays down until
                    // the surface toggles again.
                    let wasBrowsing = self.browser != nil
                    self.stop()
                    if wasBrowsing { self.start() }
                }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
        log.debug("bind browse started")
    }

    func stop() {
        browser?.cancel()
        browser = nil
        announcements = []
        endpoints = [:]
    }

    func endpoint(for announcement: BindAnnouncement) -> NWEndpoint? {
        endpoints[announcement.id]
    }

    private func apply(_ results: [(BindAnnouncement, NWEndpoint)]) {
        // Dedupe by session key — one machine, several interfaces, one row.
        var seen: Set<String> = []
        var list: [BindAnnouncement] = []
        var map: [String: NWEndpoint] = [:]
        for (announcement, endpoint) in results where !seen.contains(announcement.id) {
            seen.insert(announcement.id)
            list.append(announcement)
            map[announcement.id] = endpoint
        }
        list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if list != announcements { announcements = list }
        endpoints = map
    }
}
