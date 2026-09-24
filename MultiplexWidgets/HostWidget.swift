import SwiftUI
import WidgetKit

/// The per-host widget, in the locked hybrid design: small is a pure
/// Monitor tile (held miniature + UMD row, one tap); medium keeps the
/// screen + spine on the left and trades the telemetry column for the
/// SHELL / AGENT key pair. All content is the last-known App Group
/// snapshot; taps deep-link into the app, which runs the status-guarded
/// flows. The tile shows one session (`featuredSession`).
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

    private func featuredSession(of host: WidgetHostState) -> WidgetSessionState? {
        host.featuredSession(
            configuredName: entry.configuration.session,
            configuredBackendRaw: entry.configuration.backend
        )
    }

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
        let session = featuredSession(of: host)
        return VStack(alignment: .leading, spacing: 0) {
            heldFrame(for: session)
            WidgetLabel(session.map { "\(host.name) · \($0.name)" } ?? host.name, size: 9.5)
                .padding(.top, 9)
            HStack {
                SeenStamp(date: host.probedAt)
                Spacer(minLength: 4)
                Text(verbatim: "\(host.sessions.count) SESS")
                    .font(.widgetMono(7.5))
                    .foregroundStyle(palette.signal3)
            }
            .padding(.top, 4)
        }
        .padding(13)
        .widgetURL(smallTapURL(for: host, session: session))
    }

    private func smallTapURL(for host: WidgetHostState, session: WidgetSessionState?) -> URL {
        switch entry.configuration.action {
        case .shell:
            WidgetLink.shellURL(
                hostID: host.id,
                sessionName: session?.name,
                // The row's own backend, present only where the host shows
                // more than one — without it a same-named session on the
                // other multiplexer could answer the tap.
                backendRaw: session?.backendRaw
            )
        case .agent:
            agentURL(for: host)
        }
    }

    /// The AGENT key/tap link — one builder for both families so the
    /// configured session target can never diverge between them.
    private func agentURL(for host: WidgetHostState) -> URL {
        WidgetLink.agentURL(
            hostID: host.id,
            agentRaw: entry.configuration.agent.rawValue,
            askForPrompt: entry.configuration.askForPrompt,
            model: entry.configuration.model,
            sessionName: entry.configuration.session,
            placementRaw: entry.configuration.placement,
            directory: entry.configuration.directory,
            // Empty (the Host Default row, and every widget configured
            // before this setting existed) omits the parameter entirely.
            backendRaw: entry.configuration.backend
        )
    }

    // MARK: Medium — hybrid (Monitor left, Switchboard keys right)

    private func mediumView(_ host: WidgetHostState) -> some View {
        let session = featuredSession(of: host)
        return HStack(spacing: 12) {
            VStack(spacing: 5) {
                Link(destination: WidgetLink.shellURL(
                    hostID: host.id, sessionName: session?.name,
                    backendRaw: session?.backendRaw
                )) {
                    heldFrame(for: session)
                }
                if let session, !session.windowNames.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        SpineRow(
                            names: session.windowNames,
                            activeIndex: session.activeWindowIndex
                        )
                        // The deck's spine pairs a pane title with its window
                        // name on one line; a medium widget's chips are ~10
                        // characters wide, so only the active window's title
                        // earns a row here — the highlighted chip above says
                        // which window it belongs to. Verbatim like the deck's
                        // (uppercasing mangles `π - harness`), and already
                        // filtered app-side by `PaneTitleDisplay`.
                        if let title = session.activePaneTitle {
                            Text(title)
                                .font(.widgetMono(6.5))
                                .kerning(0.3)
                                .foregroundStyle(palette.signal3)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
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
                        hostID: host.id, sessionName: session?.name,
                        backendRaw: session?.backendRaw
                    )) {
                        ActionKey(glyph: "❯_", caption: "shell")
                    }
                    Link(destination: agentURL(for: host)) {
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
                    Text(verbatim: "· \(host.sessions.count) SESS")
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
            HatchScreen(caption: String(localized: "No recent frame"))
        } else {
            HatchScreen(caption: String(localized: "No sessions"))
        }
    }
}

extension WidgetHostState {
    /// Placeholder content for the widget gallery.
    static let sample = WidgetHostState(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "devbox",
        address: "demo@10.0.1.7",
        sessions: [WidgetSessionState(
            name: "main",
            agentRaw: "claudeCode",
            windowNames: ["editor", "server", "logs"],
            windowPaneTitles: ["✳ Claude Code", "pnpm dev", ""],
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
