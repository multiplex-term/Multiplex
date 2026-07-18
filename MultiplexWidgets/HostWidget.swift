import SwiftUI
import WidgetKit

/// The per-host widget, in the locked hybrid design: small is a pure
/// Monitor tile (held miniature + UMD row, one tap); medium keeps the
/// screen + spine on the left and trades the telemetry column for the
/// SHELL / AGENT key pair. All content is the last-known App Group
/// snapshot; taps deep-link into the app, which runs the status-guarded
/// flows.
struct HostWidget: Widget {
    static let kind = "MultiplexHostWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: HostWidgetConfigurationIntent.self,
            provider: HostWidgetProvider()
        ) { entry in
            HostWidgetView(entry: entry)
                .modifier(TallyThemed())
                .containerBackground(WidgetTheme.chassis, for: .widget)
        }
        .configurationDisplayName("Host Monitor")
        .description("Last-known sessions for one host. Tap to open a shell or launch an agent.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct HostWidgetEntry: TimelineEntry {
    var date: Date
    var configuration: HostWidgetConfigurationIntent
    var host: WidgetHostState?
}

struct HostWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> HostWidgetEntry {
        HostWidgetEntry(
            date: Date(),
            configuration: HostWidgetConfigurationIntent(),
            host: .sample
        )
    }

    func snapshot(
        for configuration: HostWidgetConfigurationIntent, in context: Context
    ) async -> HostWidgetEntry {
        entry(for: configuration)
    }

    func timeline(
        for configuration: HostWidgetConfigurationIntent, in context: Context
    ) async -> Timeline<HostWidgetEntry> {
        // One entry, no schedule: the app pushes reloads when content
        // changes, and the SEEN stamp is a relative date that ages by
        // itself. The widget never does periodic work.
        Timeline(entries: [entry(for: configuration)], policy: .never)
    }

    private func entry(for configuration: HostWidgetConfigurationIntent) -> HostWidgetEntry {
        let fleet = SharedStateStore.load()?.hosts ?? []
        let host: WidgetHostState?
        if let id = configuration.host?.id {
            host = fleet.first { $0.id == id }
        } else {
            host = fleet.first
        }
        return HostWidgetEntry(date: Date(), configuration: configuration, host: host)
    }
}

struct HostWidgetView: View {
    let entry: HostWidgetEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.tallyPalette) private var palette

    var body: some View {
        Group {
            if let host = entry.host {
                switch family {
                case .systemMedium: mediumView(host)
                default: smallView(host)
                }
            } else {
                AwaitingDataView().padding(13)
            }
        }
    }

    // MARK: Small — pure Monitor tile

    private func smallView(_ host: WidgetHostState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heldFrame(for: host.mostRecentSession)
            WidgetLabel(smallTitle(for: host), size: 9.5)
                .padding(.top, 9)
            HStack {
                SeenStamp(date: host.probedAt)
                Spacer(minLength: 4)
                Text("\(host.sessions.count) SESS")
                    .font(.widgetMono(7.5))
                    .foregroundStyle(palette.signal3)
            }
            .padding(.top, 4)
        }
        .padding(13)
        .widgetURL(smallTapURL(for: host))
    }

    private func smallTitle(for host: WidgetHostState) -> String {
        if let session = host.mostRecentSession {
            return "\(host.name) · \(session.name)"
        }
        return host.name
    }

    private func smallTapURL(for host: WidgetHostState) -> URL {
        switch entry.configuration.action {
        case .shell:
            WidgetLink.shellURL(
                hostID: host.id,
                sessionName: host.mostRecentSession?.name
            )
        case .agent:
            WidgetLink.agentURL(
                hostID: host.id,
                agentRaw: entry.configuration.agent.rawValue,
                askForPrompt: entry.configuration.askForPrompt
            )
        }
    }

    // MARK: Medium — hybrid (Monitor left, Switchboard keys right)

    private func mediumView(_ host: WidgetHostState) -> some View {
        let session = host.mostRecentSession
        return HStack(spacing: 12) {
            VStack(spacing: 5) {
                Link(destination: WidgetLink.shellURL(
                    hostID: host.id, sessionName: session?.name
                )) {
                    heldFrame(for: session)
                }
                if let session, !session.windowNames.isEmpty {
                    SpineRow(
                        names: session.windowNames,
                        activeIndex: session.activeWindowIndex
                    )
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    WidgetLabel(host.name, size: 13)
                    Spacer(minLength: 4)
                    if let session {
                        Text(session.name.uppercased())
                            .font(.widgetMono(7))
                            .foregroundStyle(palette.signal3)
                            .lineLimit(1)
                    }
                }
                Text(host.address)
                    .font(.widgetMono(8))
                    .foregroundStyle(palette.signal2)
                    .lineLimit(1)
                    .padding(.top, 2)

                HStack(spacing: 7) {
                    Link(destination: WidgetLink.shellURL(
                        hostID: host.id, sessionName: session?.name
                    )) {
                        ActionKey(glyph: "❯_", caption: "shell")
                    }
                    Link(destination: WidgetLink.agentURL(
                        hostID: host.id,
                        agentRaw: entry.configuration.agent.rawValue,
                        askForPrompt: entry.configuration.askForPrompt
                    )) {
                        ActionKey(
                            glyph: "✳",
                            caption: "agent",
                            sub: agentKeySub
                        )
                    }
                }
                .frame(maxHeight: .infinity)
                .padding(.top, 8)

                HStack(spacing: 4) {
                    SeenStamp(date: host.probedAt)
                    Text("· \(host.sessions.count) SESS")
                        .font(.widgetMono(7.5))
                        .foregroundStyle(palette.signal3)
                }
                .padding(.top, 7)
            }
            .frame(width: 132)
        }
        .padding(13)
    }

    private var agentKeySub: String {
        let label = SharedStateStore.agentTelemetryLabel(
            forRaw: entry.configuration.agent.rawValue) ?? "AGENT"
        return entry.configuration.askForPrompt ? "\(label) · ASK" : label
    }

    @ViewBuilder
    private func heldFrame(for session: WidgetSessionState?) -> some View {
        if let session, !session.miniatureLines.isEmpty {
            MiniatureScreen(lines: session.miniatureLines)
        } else if session != nil {
            HatchScreen(caption: "No recent frame")
        } else {
            HatchScreen(caption: "No sessions")
        }
    }
}

extension WidgetHostState {
    /// Placeholder content for the widget gallery.
    static let sample = WidgetHostState(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "devbox",
        address: "jhen@10.0.1.7",
        sessions: [WidgetSessionState(
            name: "main",
            agentRaw: "claudeCode",
            windowNames: ["editor", "server", "logs"],
            activeWindowIndex: 1,
            miniatureLines: [
                "$ pnpm build",
                "✓ 214 modules · 3.2s",
                "$ git push origin main",
                "→ deploy queued",
            ],
            createdAt: Date(timeIntervalSinceNow: -7200)
        )],
        probedAt: Date(timeIntervalSinceNow: -120)
    )
}
