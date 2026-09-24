import SwiftUI
import WidgetKit

/// The fleet overview, per the locked hybrid design: medium is rail rows
/// with compact key chips; large is a Monitor session-tile grid (the wall in
/// miniature), each tile a Link to its exact session. Not configurable —
/// it shows the fleet in the deck's own host order.
struct FleetWidget: Widget {
    static let kind = "MultiplexFleetWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: Self.kind,
            provider: FleetWidgetProvider()
        ) { entry in
            FleetWidgetView(entry: entry)
                .modifier(TallyThemed())
                .containerBackground(WidgetTheme.chassis, for: .widget)
        }
        .configurationDisplayName("Fleet Wall")
        .description("Every host's last-known sessions. Tap a row or tile to attach.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct FleetWidgetEntry: TimelineEntry {
    var date: Date
    var hosts: [WidgetHostState]
}

struct FleetWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> FleetWidgetEntry {
        FleetWidgetEntry(date: Date(), hosts: [.sample])
    }

    func getSnapshot(in context: Context, completion: @escaping (FleetWidgetEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FleetWidgetEntry>) -> Void) {
        // App-pushed reloads only; the stamps age as relative dates.
        completion(Timeline(entries: [entry()], policy: .never))
    }

    private func entry() -> FleetWidgetEntry {
        FleetWidgetEntry(date: Date(), hosts: SharedStateStore.load()?.hosts ?? [])
    }
}

struct FleetWidgetView: View {
    let entry: FleetWidgetEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.tallyPalette) private var palette

    var body: some View {
        Group {
            if entry.hosts.isEmpty {
                AwaitingDataView().padding(15)
            } else if family == .systemLarge {
                largeView
            } else {
                mediumView
            }
        }
    }

    private var sessionCount: Int {
        entry.hosts.reduce(0) { $0 + $1.sessions.count }
    }

    private func header(rule: Bool) -> some View {
        VStack(spacing: 8) {
            HStack {
                WidgetLabel("multiplex · fleet", size: 10)
                Spacer(minLength: 4)
                Text(verbatim: "\(entry.hosts.count) HOSTS · \(sessionCount) SESS")
                    .font(.widgetMono(7.5))
                    .foregroundStyle(palette.signal3)
            }
            if rule {
                Rectangle()
                    .fill(palette.bezelHi)
                    .frame(height: 1)
            }
        }
    }

    // MARK: Medium — rail rows + key chips

    private var mediumView: some View {
        VStack(spacing: 0) {
            header(rule: true)
            VStack(spacing: 0) {
                ForEach(entry.hosts.prefix(3)) { host in
                    Spacer(minLength: 0)
                    hostRow(host)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(13)
    }

    private func hostRow(_ host: WidgetHostState) -> some View {
        HStack(spacing: 8) {
            let session = host.featuredSession()
            Link(destination: WidgetLink.shellURL(
                hostID: host.id, sessionName: session?.name,
                // The row's own backend, present only where the host shows
                // more than one — without it a same-named session on the
                // other multiplexer could answer the tap.
                backendRaw: session?.backendRaw
            )) {
                HStack(spacing: 6) {
                    WidgetLabel(
                        host.name,
                        size: 10,
                        color: host.probedAt == nil
                            ? palette.signal2 : palette.signal
                    )
                    Text(rowTelemetry(host))
                        .font(.widgetMono(7))
                        .foregroundStyle(palette.signal3)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                // The name zone is a tap target too — span the row height.
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            HStack(spacing: 6) {
                Link(destination: WidgetLink.shellURL(hostID: host.id)) {
                    keyChip("❯_")
                }
                Link(destination: WidgetLink.agentURL(
                    hostID: host.id,
                    agentRaw: session?.agentRaw ?? "claudeCode",
                    askForPrompt: false
                )) {
                    keyChip("✳")
                }
            }
        }
    }

    private func rowTelemetry(_ host: WidgetHostState) -> String {
        var parts = ["\(host.sessions.count) SESS"]
        if host.sessions.contains(where: { $0.agentRaw != nil }) {
            parts.append("✳")
        }
        return parts.joined(separator: " · ")
    }

    /// A real tap target, not a caption: the fleet rows' whole point is
    /// launching, and the first pass's ~24×16 pt chips were too small to hit
    /// (user-reported).
    private func keyChip(_ glyph: String) -> some View {
        Text(glyph)
            .font(.widgetMono(9, weight: .medium))
            .foregroundStyle(palette.signal)
            .frame(minWidth: 44, minHeight: 28)
            .background(palette.bezel)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(palette.bezelHi, lineWidth: 1)
            )
    }

    // MARK: Large — session-tile grid (the wall in miniature)

    private struct FleetTile: Identifiable {
        let id: String
        var host: WidgetHostState
        var session: WidgetSessionState?
    }

    private var tiles: [FleetTile] {
        // Session tiles by recency across the fleet, then data-less hosts as
        // hatched tiles — failure stays part of the composition.
        let withSessions: [FleetTile] = entry.hosts
            .flatMap { host in host.sessions.map { (host, $0) } }
            .sorted { ($0.1.createdAt, $0.1.name) > ($1.1.createdAt, $1.1.name) }
            .map { FleetTile(id: "\($0.0.id)-\($0.1.name)", host: $0.0, session: $0.1) }
        let sessionless: [FleetTile] = entry.hosts
            .filter { $0.sessions.isEmpty }
            .map { FleetTile(id: $0.id.uuidString, host: $0, session: nil) }
        return Array((withSessions + sessionless).prefix(4))
    }

    private var largeView: some View {
        VStack(spacing: 10) {
            header(rule: false)
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)],
                spacing: 9
            ) {
                ForEach(tiles) { tile in
                    Link(destination: WidgetLink.shellURL(
                        hostID: tile.host.id, sessionName: tile.session?.name,
                        backendRaw: tile.session?.backendRaw
                    )) {
                        tileView(tile)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(15)
    }

    private func tileView(_ tile: FleetTile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let session = tile.session, !session.miniatureLines.isEmpty {
                    MiniatureScreen(lines: session.miniatureLines, fontSize: 7)
                } else if tile.session != nil {
                    HatchScreen(caption: String(localized: "No recent frame"))
                } else {
                    HatchScreen(caption: String(localized: "No recent data"))
                }
            }
            HStack {
                WidgetLabel(
                    tileTitle(tile),
                    size: 7.5,
                    color: tile.session == nil ? palette.signal2 : palette.signal
                )
                Spacer(minLength: 3)
                if let probed = tile.host.probedAt {
                    Text(probed, style: .relative)
                        .font(.widgetMono(6.5))
                        .foregroundStyle(palette.signal3)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tileTitle(_ tile: FleetTile) -> String {
        if let session = tile.session {
            return "\(tile.host.name) · \(session.name)"
        }
        return tile.host.name
    }
}
