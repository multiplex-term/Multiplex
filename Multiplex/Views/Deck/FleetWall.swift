import SwiftUI

/// Breakpoint sizing for the wall's session-tile grid. Tiles expand toward the
/// preferred width, but a new column enters as soon as every tile can retain
/// the compact minimum. This keeps an iPad mini's two-tile portrait row and
/// three-tile landscape row intact instead of orphaning the last tile.
///
/// Only the column count may cross into SwiftUI state. The continuously
/// changing window width is reduced to that count by `onGeometryChange`, so
/// ordinary resize frames do not rebuild the FleetWall view hierarchy.
enum FleetTileGridSizing {
    static let minimumTileWidth: CGFloat = 290
    static let preferredTileWidth: CGFloat = 360
    static let gutter: CGFloat = 14

    static func initialColumnCount(availableWidth rawWidth: CGFloat) -> Int {
        let width = Self.normalized(rawWidth)
        return Self.maximumColumnCount(
            tileWidth: Self.minimumTileWidth,
            availableWidth: width
        )
    }

    static func columnCount(current: Int?, availableWidth rawWidth: CGFloat) -> Int {
        let width = Self.normalized(rawWidth)
        var count = max(1, current ?? initialColumnCount(availableWidth: width))

        // Growing: use the same compact threshold as shrinking. This also
        // lets the real viewport recover after SwiftUI reports a transient
        // narrow width during presentation.
        while Self.requiredWidth(
            columnCount: count + 1,
            tileWidth: Self.minimumTileWidth
        ) <= width {
            count += 1
        }

        // Shrinking: keep the row intact while every tile remains at least
        // 290 points, then wrap one or more columns as necessary.
        while count > 1,
              Self.requiredWidth(
                columnCount: count,
                tileWidth: Self.minimumTileWidth
              ) > width {
            count -= 1
        }

        return count
    }

    static func requiredWidth(columnCount: Int, tileWidth: CGFloat) -> CGFloat {
        guard columnCount > 0 else { return 0 }
        return CGFloat(columnCount) * tileWidth + CGFloat(columnCount - 1) * gutter
    }

    private static func maximumColumnCount(
        tileWidth: CGFloat,
        availableWidth: CGFloat
    ) -> Int {
        max(1, Int((availableWidth + gutter) / (tileWidth + gutter)))
    }

    private static func normalized(_ width: CGFloat) -> CGFloat {
        width.isFinite ? max(0, width) : 0
    }
}

/// The deck: the whole fleet as one broadcast monitor wall. Every host
/// probes concurrently under a thin rail; every session is a live tile
/// showing its actual last lines (capture-pane over the host's control
/// connection, ~5 s cadence while the deck is frontmost). Unreachable
/// hosts render in the composition as NO SIGNAL tiles instead of hiding
/// behind a selection — there is no sidebar on purpose.
struct FleetWall: View {
    enum Presentation: Equatable {
        case standard
        case shellCompact
        case shellRail
    }

    @Environment(HostStore.self) private var store
    @Environment(ConnectionHub.self) private var hub
    @Environment(TerminalWorkspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var terminalOpener: TerminalRouteOpener
    var presentation: Presentation = .standard
    var selectedTerminal: TerminalRoute?
    /// Safe-area insets the shell spends on the wall instead of reserving
    /// them: chassis, rules, and the scroll viewport reach the window's
    /// physical edges, and the wall restores these as content padding — so
    /// tiles pass beneath the home indicator while staying clear of the
    /// Dynamic Island. Classic deck scenes leave this zero and retain their
    /// existing layout.
    var shellSafeArea = EdgeInsets()
    var addHost: () -> Void
    var editHost: (Host) -> Void
    var openSettings: () -> Void

    @State private var namingHost: Host?
    @State private var deleteTarget: DeleteTarget?
    @State private var removingHost: Host?
    @State private var unreachableNotice: UnreachableNotice?
    @State private var legacyDropTarget: SessionDropTarget?
    @State private var tileGridColumnCount: Int?

    /// Pending delete confirmation — which session on which host.
    private struct DeleteTarget {
        let host: Host
        let session: TmuxSession
    }

    /// Failure detail captured when the rail's UNREACHABLE status is
    /// pressed. Capture the text so a background retry cannot replace it
    /// while the explanation is onscreen.
    private struct UnreachableNotice: Identifiable {
        let host: Host
        let reason: String

        var id: UUID { host.id }
    }

    private var wallPadding: CGFloat {
        presentation == .shellRail ? 12 : 26
    }
    /// Wall cadence: one concurrent probe round-trip per host per tick.
    private static let feedInterval: Duration = .seconds(5)

    /// Feed-loop identity: restarts on fleet changes AND on scene
    /// activation, so a deck coming to the foreground ticks immediately
    /// instead of finishing whatever sleep it was suspended in.
    private struct FeedID: Hashable {
        let hosts: [UUID]
        let active: Bool
    }

    var body: some View {
        platformWall
        .background(Theme.chassis.ignoresSafeArea())
        .task(
            id: FeedID(hosts: store.hosts.map(\.id), active: scenePhase == .active)
        ) { await runFeed() }
        .sheet(item: $namingHost) { host in
            NewSessionSheet(
                host: host,
                existingNames: hub.model(for: host).tmux.sessions.map(\.name),
                create: { name, agent, directory in
                    createSession(on: host, named: name, launching: agent, startingIn: directory)
                }
            )
        }
        .alert(
            "Delete Session",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { target in
            Button("Delete", role: .destructive) { kill(target) }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text("Kills “\(target.session.name)” on \(target.host.name) and everything running in it.")
        }
        .alert(
            "Remove Host",
            isPresented: Binding(
                get: { removingHost != nil },
                set: { if !$0 { removingHost = nil } }
            ),
            presenting: removingHost
        ) { host in
            Button("Remove", role: .destructive) { remove(host) }
            Button("Cancel", role: .cancel) {}
        } message: { host in
            Text("Removes “\(host.name)” and its saved secret from this device and your synced devices. tmux sessions on the host keep running.")
        }
        .alert(item: $unreachableNotice) { notice in
            Alert(
                title: Text("\(notice.host.name) Unreachable"),
                message: Text(notice.reason),
                dismissButton: .cancel(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private var platformWall: some View {
        if presentation != .standard {
            shellWall
        } else {
            #if os(visionOS)
            wall(showHeader: true)
            #else
            if #available(iOS 26.0, *) {
                // iPadOS window controls occupy the leading edge of the title
                // bar, but don't contribute a safe-area inset to arbitrary
                // content. Put the classic deck rail in the system toolbar
                // so MULTIPLEX is laid out around those controls instead of
                // underneath them. The in-scene shell has no window controls
                // and keeps its TALLY header full-bleed in the wall itself.
                NavigationStack {
                    wall(showHeader: false)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(Theme.chassis, for: .navigationBar)
                        .toolbar { deckToolbar }
                }
            } else {
                wall(showHeader: true)
            }
            #endif
        }
    }

    /// Shell decks use a fixed TALLY header. Only the host sections scroll,
    /// and their viewport extends beneath the bottom safe area while content
    /// receives the equivalent inset as trailing breathing room.
    private var shellWall: some View {
        VStack(spacing: 0) {
            header
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, wallPadding + shellSafeArea.leading)
                .padding(.trailing, wallPadding + shellSafeArea.trailing)
                .padding(.top, min(wallPadding, 16))
                .background(Theme.chassis)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.bezelHi).frame(height: 1)
                }

            wall(showHeader: false)
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    private func wall(showHeader: Bool) -> some View {
        let columns = gridColumns(
            count: tileGridColumnCount ?? (presentation == .standard ? 2 : 1)
        )

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if showHeader { header }
                if store.hosts.isEmpty {
                    awaitingSignal
                } else {
                    ForEach(store.hosts) { host in
                        hostSection(host, columns: columns)
                    }
                }
            }
            .frame(
                maxWidth: .infinity,
                alignment: presentation == .shellCompact ? .center : .leading
            )
            .padding(.leading, wallPadding + shellSafeArea.leading)
            .padding(.trailing, wallPadding + shellSafeArea.trailing)
            .padding(.top, presentation == .standard ? wallPadding : 0)
            .padding(.bottom, wallPadding + shellSafeArea.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            // Measure a viewport-sized, content-independent surface. If the
            // grid is between breakpoint updates, its temporary ideal width
            // must never feed back into the width used to choose columns.
            Color.clear
                .allowsHitTesting(false)
                .onGeometryChange(for: Int.self) { geometry in
                    FleetTileGridSizing.columnCount(
                        current: tileGridColumnCount,
                        availableWidth: max(
                            0,
                            geometry.size.width - wallPadding * 2
                                - shellSafeArea.leading - shellSafeArea.trailing
                        )
                    )
                } action: { count in
                    guard tileGridColumnCount != count else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        tileGridColumnCount = count
                    }
                }
        }
    }

    private func gridColumns(count: Int) -> [GridItem] {
        Array(
            repeating: GridItem(
                .flexible(
                    // The breakpoint policy enforces the 290pt minimum. A
                    // zero layout minimum lets a stale count compress for the
                    // single observation pass instead of widening and
                    // recentering the entire vertical scroll view.
                    minimum: 0,
                    maximum: FleetTileGridSizing.preferredTileWidth
                ),
                spacing: FleetTileGridSizing.gutter
            ),
            count: count
        )
    }

    private var gridAlignment: HorizontalAlignment {
        presentation == .shellCompact ? .center : .leading
    }

    /// While this view exists, keep the wall alive: re-probe each host and
    /// refresh its miniatures. Skips work while the app is backgrounded;
    /// `.task(id:)` restarts the loop when the fleet changes.
    private func runFeed() async {
        while !Task.isCancelled {
            guard UIApplication.shared.applicationState == .active else {
                // Not active YET: a cold launch runs the first tick before
                // the scene activates, and burning a whole feed interval
                // here read as "~6 s to connect" on a real iPad. Poll
                // briefly instead — the task id also restarts this loop the
                // moment the scene turns active, and iOS suspends the
                // process outright in the background, so this never spins.
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            // Resolve models on the main actor first, then let every host
            // run its own probe (one exec round-trip carrying sessions,
            // agent detection, and miniature tails). One slow host must
            // not delay the rest of the fleet.
            let models = store.hosts.map { hub.model(for: $0) }
            await withTaskGroup(of: Void.self) { group in
                for model in models {
                    group.addTask {
                        await model.refreshAndWait(ifStaleFor: 4)
                    }
                }
            }
            try? await Task.sleep(for: Self.feedInterval)
        }
    }

    // MARK: Wall chrome

    #if !os(visionOS)
    @available(iOS 26.0, *)
    @ToolbarContentBuilder
    private var deckToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    ChassisLabel("Multiplex", size: 15)
                    Text(fleetSummary)
                        .font(.mono(11))
                        .foregroundStyle(Theme.signal2)
                        .lineLimit(1)
                }
                ChassisLabel("Multiplex", size: 15)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ChassisChip("HOST", systemImage: "plus", action: addHost)
                .fixedSize()
                .accessibilityLabel("Add host")
            ChassisChip("SETTINGS", systemImage: "gearshape", action: openSettings)
                .fixedSize()
                // The system's compact trailing margin looks crowded against
                // the rounded corner when the deck is an iPad window.
                .padding(.trailing, 12)
        }
        .sharedBackgroundVisibility(.hidden)
    }
    #endif

    @ViewBuilder
    private var header: some View {
        if presentation == .shellRail {
            HStack(alignment: .center, spacing: 8) {
                ChassisLabel("Multiplex", size: 13)
                Spacer(minLength: 4)
                Text(fleetSummary)
                    .font(.mono(8.5))
                    .foregroundStyle(Theme.signal2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                ChassisChip("", systemImage: "plus", action: addHost)
                    .accessibilityLabel("Add host")
                ChassisChip("", systemImage: "gearshape", action: openSettings)
                    .accessibilityLabel("Settings")
            }
            .padding(.bottom, 12)
        } else if presentation == .shellCompact {
            ViewThatFits(in: .horizontal) {
                shellCompactHeader(showsSummary: true, iconOnly: false)
                shellCompactHeader(showsSummary: false, iconOnly: false)
                shellCompactHeader(showsSummary: false, iconOnly: true)
            }
            .padding(.bottom, 16)
        } else {
            HStack(alignment: .center, spacing: 10) {
                ChassisLabel("Multiplex", size: 15)
                Spacer()
                Text(fleetSummary)
                    .font(.mono(11))
                    .foregroundStyle(Theme.signal2)
                ChassisChip("HOST", systemImage: "plus", action: addHost)
                ChassisChip("SETTINGS", systemImage: "gearshape", action: openSettings)
            }
            .padding(.bottom, 16)
        }
    }

    private func shellCompactHeader(
        showsSummary: Bool,
        iconOnly: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ChassisLabel("Multiplex", size: 15)
                .fixedSize()
            Spacer(minLength: 4)
            if showsSummary {
                Text(fleetSummary)
                    .font(.mono(11))
                    .foregroundStyle(Theme.signal2)
                    .lineLimit(1)
                    .fixedSize()
            }
            ChassisChip(iconOnly ? "" : "HOST", systemImage: "plus", action: addHost)
                .fixedSize()
                .accessibilityLabel("Add host")
            ChassisChip(
                iconOnly ? "" : "SETTINGS",
                systemImage: "gearshape",
                action: openSettings
            )
            .fixedSize()
            .accessibilityLabel("Settings")
        }
    }

    private var fleetSummary: String {
        let sessions = store.hosts.reduce(0) { count, host in
            count + hub.model(for: host).tmux.sessions.count
        }
        let hosts = store.hosts.count
        return "\(hosts) HOST\(hosts == 1 ? "" : "S") · \(sessions) SESSION\(sessions == 1 ? "" : "S")"
    }

    /// First run: one dark monitor waiting for a source.
    private var awaitingSignal: some View {
        VStack(spacing: 0) {
            ZStack {
                HatchedScreen()
                VStack(spacing: 12) {
                    ChassisLabel("Awaiting signal", size: 13, color: Theme.signal3)
                    Text("Every tmux session, its own window in space.")
                        .font(.footnote)
                        .foregroundStyle(Theme.signal2)
                }
            }
            .frame(maxWidth: 420, minHeight: 150)
            HStack {
                ChassisLabel("No hosts", size: 12, color: Theme.signal3)
                Spacer()
                ChassisChip("ADD HOST", systemImage: "plus", prominent: true, action: addHost)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 8)
        }
        .padding(5)
        .background(Theme.bezel)
        .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
        .frame(maxWidth: 430)
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }

    // MARK: Host rail + tiles

    @ViewBuilder
    private func hostSection(_ host: Host, columns: [GridItem]) -> some View {
        let model = hub.model(for: host)

        VStack(alignment: .leading, spacing: 12) {
            rail(host, model: model)
            tiles(host, model: model, columns: columns)
        }
        .padding(.bottom, 22)
    }

    private func rail(_ host: Host, model: HostConnectionModel) -> some View {
        let connected = model.phase == .connected
        return Group {
            if presentation == .shellRail {
                VStack(alignment: .leading, spacing: 8) {
                    Rectangle().fill(Theme.bezel).frame(height: 1)
                    HStack(spacing: 8) {
                        ChassisLabel(host.name, size: 11)
                        Spacer(minLength: 4)
                        railStatus(model)
                        hostMenu(host)
                    }
                    HStack(spacing: 8) {
                        Text(host.address)
                            .font(.mono(9.5))
                            .foregroundStyle(Theme.signal2)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        shellChip(host, connected: connected)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Rectangle().fill(Theme.bezel).frame(height: 1)
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        ChassisLabel(host.name, size: 12)
                        Text(host.address)
                            .font(.mono(11))
                            .foregroundStyle(Theme.signal2)
                            .lineLimit(2)
                        Spacer()
                        railStatus(model)
                        // The SHELL chip is the row's tallest element —
                        // inserting/removing it with the phase resizes the
                        // whole rail. Keep its slot and fade it instead.
                        shellChip(host, connected: connected)
                        hostMenu(host)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            hostMenuActions(host)
        }
    }

    private func shellChip(_ host: Host, connected: Bool) -> some View {
        ChassisChip("SHELL") {
            open(TerminalRoute(hostID: host.id, mode: .shell))
        }
        .opacity(connected ? 1 : 0)
        .allowsHitTesting(connected)
        .disabled(!connected)
        .accessibilityHidden(!connected)
    }

    /// Visible host controls. Edit is most needed when a host is
    /// UNREACHABLE (fixing a bad address), so unlike SHELL this menu shows
    /// in every connection phase; the rail's long-press menu mirrors it.
    private func hostMenu(_ host: Host) -> some View {
        Menu {
            hostMenuActions(host)
        } label: {
            ChassisBadge("", systemImage: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .chassisHover(2)
        .accessibilityLabel("Host options for \(host.name)")
    }

    @ViewBuilder
    private func hostMenuActions(_ host: Host) -> some View {
        Button {
            store.moveUp(host)
        } label: {
            Label("Move Up", systemImage: "arrow.up")
        }
        .disabled(!store.canMoveUp(host))

        Button {
            store.moveDown(host)
        } label: {
            Label("Move Down", systemImage: "arrow.down")
        }
        .disabled(!store.canMoveDown(host))

        Divider()
        Button("Edit Host…") { editHost(host) }
        Button("Remove Host…", role: .destructive) { removingHost = host }
    }

    @ViewBuilder
    private func railStatus(_ model: HostConnectionModel) -> some View {
        Group {
            switch model.phase {
            case .connected:
                railLabel("CONNECTED", dot: Theme.ok)
            case .connecting:
                // Same dot anatomy as every other phase — a ProgressView is
                // intrinsically taller and its spinner draws outside the
                // slot. The pulse carries the "in flight" signal instead.
                railLabel("LINKING", dot: Theme.signal2, pulsing: true)
            case .failed(let reason):
                Button {
                    unreachableNotice = UnreachableNotice(host: model.host, reason: reason)
                } label: {
                    railLabel("UNREACHABLE", dot: Theme.signal3, text: Theme.signal3)
                }
                .buttonStyle(.plain)
                .chassisHover(2)
                .accessibilityLabel("\(model.host.name) unreachable")
                .accessibilityHint("Shows why the host could not be reached")
            case .idle:
                Text("STANDBY").font(.mono(9)).kerning(1).foregroundStyle(Theme.signal3)
            }
        }
        // Every phase shares one fixed-height slot so no phase change can
        // move the rail.
        .frame(height: 12)
    }

    private func railLabel(
        _ text: String, dot: Color, text textColor: Color = Theme.signal2, pulsing: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 6, height: 6)
                .modifier(DotPulse(active: pulsing))
            Text(text).font(.mono(9)).kerning(1).foregroundStyle(textColor)
        }
    }

    @ViewBuilder
    private func tiles(
        _ host: Host,
        model: HostConnectionModel,
        columns: [GridItem]
    ) -> some View {
        switch model.tmux {
        case .sessions(let sessions):
            if #available(iOS 27.0, visionOS 27.0, *) {
                animatedGrid(
                    reorderableSessionGrid(
                        host,
                        model: model,
                        sessions: sessions,
                        columns: columns
                    ),
                    state: model.tmux
                )
            } else {
                animatedGrid(
                    legacySessionGrid(
                        host,
                        model: model,
                        sessions: sessions,
                        columns: columns
                    ),
                    state: model.tmux
                )
            }
        case .noServer:
            animatedGrid(
                LazyVGrid(
                    columns: columns,
                    alignment: gridAlignment,
                    spacing: FleetTileGridSizing.gutter
                ) {
                    newSessionTile(host)
                },
                state: model.tmux
            )
        case .tmuxMissing:
            animatedGrid(
                LazyVGrid(
                    columns: columns,
                    alignment: gridAlignment,
                    spacing: FleetTileGridSizing.gutter
                ) {
                    noteTile("No tmux on host", detail: "You can still open a plain shell.")
                },
                state: model.tmux
            )
        case .failed:
            animatedGrid(
                LazyVGrid(
                    columns: columns,
                    alignment: gridAlignment,
                    spacing: FleetTileGridSizing.gutter
                ) {
                    noSignalTile(host, model: model)
                },
                state: model.tmux
            )
        case .unknown, .probing:
            animatedGrid(
                LazyVGrid(
                    columns: columns,
                    alignment: gridAlignment,
                    spacing: FleetTileGridSizing.gutter
                ) {
                    acquiringTile
                },
                state: model.tmux
            )
        }
    }

    /// OS 27's reorder container is purpose-built for this interaction: a
    /// long press lifts one tile, leaves a placeholder, and makes the other
    /// tiles move out of the way as the drag crosses the responsive grid.
    @available(iOS 27.0, visionOS 27.0, *)
    private func reorderableSessionGrid(
        _ host: Host,
        model: HostConnectionModel,
        sessions: [TmuxSession],
        columns: [GridItem]
    ) -> some View {
        LazyVGrid(
            columns: columns,
            alignment: gridAlignment,
            spacing: FleetTileGridSizing.gutter
        ) {
            newSessionTile(host)
            ForEach(store.orderedSessions(sessions, for: host.id)) { session in
                sessionTile(host, model: model, session: session)
            }
            .reorderable()
        }
        .reorderContainer(for: TmuxSession.self) { difference in
            let destination: String?
            switch difference.destination.position {
            case .before(let sessionName): destination = sessionName
            case .end: destination = nil
            }
            store.moveSessions(
                difference.sources,
                before: destination,
                for: host.id,
                available: sessions
            )
        }
    }

    /// iOS/visionOS 16–26 fallback using the original Transferable drag/drop
    /// API. Dropping on a session moves the dragged tile into that tile's
    /// slot; the neutral outline makes the pending destination explicit.
    private func legacySessionGrid(
        _ host: Host,
        model: HostConnectionModel,
        sessions: [TmuxSession],
        columns: [GridItem]
    ) -> some View {
        LazyVGrid(
            columns: columns,
            alignment: gridAlignment,
            spacing: FleetTileGridSizing.gutter
        ) {
            newSessionTile(host)
            ForEach(store.orderedSessions(sessions, for: host.id)) { session in
                let target = SessionDropTarget(hostID: host.id, sessionName: session.name)
                sessionTile(host, model: model, session: session)
                    .draggable(sessionDragPayload(hostID: host.id, sessionName: session.name))
                    .overlay {
                        Rectangle()
                            .strokeBorder(Theme.signal2, lineWidth: 2)
                            .opacity(legacyDropTarget == target ? 1 : 0)
                            .allowsHitTesting(false)
                    }
                    .dropDestination(for: String.self) { payloads, _ in
                        defer { legacyDropTarget = nil }
                        guard let payload = payloads.first,
                              let source = SessionDropTarget(payload: payload),
                              source.hostID == host.id
                        else { return false }

                        let move = {
                            store.moveSession(
                                source.sessionName,
                                to: session.name,
                                for: host.id,
                                available: sessions
                            )
                        }
                        if reduceMotion {
                            move()
                        } else {
                            withAnimation(.spring(response: 0.32, dampingFraction: 1), move)
                        }
                        return true
                    } isTargeted: { targeted in
                        if targeted {
                            legacyDropTarget = target
                        } else if legacyDropTarget == target {
                            legacyDropTarget = nil
                        }
                    }
            }
        }
    }

    private func sessionTile(
        _ host: Host, model: HostConnectionModel, session: TmuxSession
    ) -> SessionTile {
        SessionTile(
            session: session,
            lines: model.miniatures[session.name] ?? [],
            attention: model.attention[session.name],
            hasLiveAgentState: model.lastRefreshed != nil,
            hasOpenTab: workspace.hasTab(hostID: host.id, sessionName: session.name),
            compact: presentation == .shellRail,
            selected: selectedTerminal?.hostID == host.id
                && selectedTerminal?.sessionName == session.name,
            duplicateAttachTitle: terminalOpener.duplicateAttachTitle,
            openTabAccessibilityText: terminalOpener.openTabAccessibilityText,
            attach: {
                focusOrAttach(host, session: session)
            },
            attachNewWindow: {
                open(TerminalRoute(hostID: host.id, mode: .attach(sessionName: session.name)))
            },
            delete: {
                deleteTarget = DeleteTarget(host: host, session: session)
            }
        )
    }

    private func sessionDragPayload(hostID: UUID, sessionName: String) -> String {
        "multiplex-session\n\(hostID.uuidString)\n\(sessionName)"
    }

    @ViewBuilder
    private func animatedGrid<Content: View>(_ grid: Content, state: TmuxState) -> some View {
        if reduceMotion {
            grid
        } else {
            grid.animation(.easeOut(duration: 0.3), value: state)
        }
    }

    // MARK: Special tiles

    private func newSessionTile(_ host: Host) -> some View {
        Button {
            namingHost = host
        } label: {
            VStack {
                ChassisLabel("+ New Session", size: 11, color: Theme.signal2)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: presentation == .shellRail ? 92 : 138
            )
            .overlay(
                Rectangle().strokeBorder(
                    Theme.bezelHi,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chassisHover(4)
        .accessibilityLabel("New session on \(host.name)")
    }

    private func noSignalTile(_ host: Host, model: HostConnectionModel) -> some View {
        Button {
            model.refresh()
        } label: {
            VStack(spacing: 0) {
                ZStack {
                    HatchedScreen()
                    ChassisLabel("No Signal", size: 13, color: Theme.signal3)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: presentation == .shellRail ? 64 : 96
                )
                HStack {
                    ChassisLabel(host.name, size: 12, color: Theme.signal3)
                    Spacer()
                    ChassisBadge("RECONNECT")
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 8)
            }
            .padding(5)
            .background(Theme.bezel)
            .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chassisHover(4)
        .accessibilityLabel("\(host.name) unreachable. Reconnect")
    }

    private var acquiringTile: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            ChassisLabel("Acquiring signal", size: 10, color: Theme.signal3)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: presentation == .shellRail ? 92 : 138
        )
        .background(Theme.screen)
        .padding(5)
        .background(Theme.bezel)
        .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
    }

    private func noteTile(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            ChassisLabel(title, size: 11, color: Theme.signal3)
            Text(detail).font(.footnote).foregroundStyle(Theme.signal2)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: presentation == .shellRail ? 92 : 138
        )
        .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
    }

    // MARK: Actions

    private func remove(_ host: Host) {
        hub.dropModel(for: host.id)
        store.remove(host)
    }

    private func kill(_ target: DeleteTarget) {
        let model = hub.model(for: target.host)
        Task { await model.killSession(target.session) }
    }

    /// The prompt's Create & Attach. Mint the detached session over the
    /// control connection first, then attach the terminal window. Besides
    /// keeping agent `send-keys` ahead of the attach, creation can place a
    /// first Linux tmux server outside the SSH login scope so closing the
    /// terminal does not reap it. Creation failures surface on the rail —
    /// `createSession` marks the host failed when the control connection is
    /// the problem.
    private func createSession(
        on host: Host, named rawName: String, launching agent: AgentKind?,
        startingIn directory: String?
    ) {
        let name = TmuxProbe.sanitizedSessionName(rawName)
        let model = hub.model(for: host)
        Task {
            guard let created = await model.createSession(
                base: name,
                inDirectoryOf: nil,
                startingIn: directory,
                typing: agent?.launchCommand
            ) else { return }
            open(TerminalRoute(hostID: host.id, mode: .attach(sessionName: created)))
        }
    }

    /// A tile press: if some open terminal window already shows this
    /// session, bring that window (and its tab) forward instead of
    /// attaching a duplicate client; only otherwise attach in a new window.
    /// The tile's long-press menu keeps an explicit new-window attach.
    private func focusOrAttach(_ host: Host, session: TmuxSession) {
        if workspace.focusTab(hostID: host.id, sessionName: session.name) { return }
        open(TerminalRoute(hostID: host.id, mode: .attach(sessionName: session.name)))
    }

    private func open(_ route: TerminalRoute) {
        terminalOpener(TerminalWindowRoute(tab: route))
    }
}

/// String-backed identity for the pre-27 Transferable fallback. Session names
/// occupy the final component verbatim, so spaces and Unicode survive.
private struct SessionDropTarget: Equatable {
    let hostID: UUID
    let sessionName: String

    init(hostID: UUID, sessionName: String) {
        self.hostID = hostID
        self.sessionName = sessionName
    }

    init?(payload: String) {
        let parts = payload.split(
            separator: "\n",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard parts.count == 3,
              parts[0] == "multiplex-session",
              let hostID = UUID(uuidString: String(parts[1]))
        else { return nil }

        self.hostID = hostID
        sessionName = String(parts[2])
    }
}

/// The wall's New Session prompt: a name plus what launches in the fresh
/// shell — the agent quick options that used to hide behind the tile's
/// long press are explicit choices now. The name prefills the first free
/// conventional name for the selection (main / claude / codex / pi, then
/// -2, -3…) so Create is one tap; picking an agent re-prefills it unless
/// the user already typed their own. An opt-in remembers the submitted
/// launch choice for the next prompt. Hosts with working directories also
/// get a "Starts in" picker, defaulting to the first (the host's own default).
private struct NewSessionSheet: View {
    let host: Host
    let existingNames: [String]
    let create: (String, AgentKind?, String?) -> Void

    private let preferences: NewSessionPreferences

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var agent: AgentKind?
    @State private var directory: String?
    @State private var remembersLastLaunch: Bool

    init(
        host: Host,
        existingNames: [String],
        create: @escaping (String, AgentKind?, String?) -> Void,
        preferences: NewSessionPreferences = NewSessionPreferences()
    ) {
        self.host = host
        self.existingNames = existingNames
        self.create = create
        self.preferences = preferences

        let remembersLastLaunch = preferences.remembersLastLaunch
        let agent = preferences.rememberedAgent
        _agent = State(initialValue: agent)
        _directory = State(initialValue: host.workingDirs.first)
        _remembersLastLaunch = State(initialValue: remembersLastLaunch)
        _name = State(initialValue: TmuxProbe.uniqueSessionName(
            base: agent?.launchCommand ?? "main", existing: existingNames))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    TallyFormSection("Target host") {
                        TallyFormRow {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ChassisLabel(host.name, size: 12)
                                    Text(host.address)
                                        .font(.mono(10))
                                        .foregroundStyle(Theme.signal2)
                                        .lineLimit(1)
                                }
                                Spacer()
                                ChassisBadge(host.useMosh ? "MOSH" : "SSH")
                            }
                        }
                    }

                    TallyFormSection(
                        "Session identity",
                        detail: "Shown on the deck and in the terminal window's source label."
                    ) {
                        TallyFormField("Name") {
                            TextField("main", text: $name)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    }

                    TallyFormSection("Launch", detail: launchDetail) {
                        TallyFormRow {
                            TallyChoiceBar(launchChoices, selection: $agent)
                                .accessibilityLabel("What to launch")
                        }
                        TallyFormRow {
                            HStack(spacing: 12) {
                                ChassisSwitch(
                                    "REMEMBER",
                                    isOn: $remembersLastLaunch,
                                    accessibilityLabel: "Remember launch choice"
                                )
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    ChassisLabel("Command", size: 7, color: Theme.signal3)
                                    Text(agent?.launchCommand ?? "login shell")
                                        .font(.mono(9, weight: .medium))
                                        .foregroundStyle(Theme.signal2)
                                }
                            }
                        }
                    }

                    TallyFormSection("Directory", detail: directoryDetail) {
                        if host.workingDirs.isEmpty {
                            TallyFormRow {
                                HStack(spacing: 12) {
                                    Text("Starts in")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Theme.signal2)
                                    Spacer()
                                    Text("HOME")
                                        .font(.mono(10, weight: .medium))
                                        .foregroundStyle(Theme.signal)
                                }
                            }
                        } else {
                            TallyFormField("Starts in") {
                                Menu {
                                    ForEach(host.workingDirs, id: \.self) { dir in
                                        Button(dir) { directory = dir }
                                    }
                                    Divider()
                                    Button("Home") { directory = nil }
                                } label: {
                                    HStack(spacing: 10) {
                                        Text(directory ?? "Home")
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(Theme.signal2)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .chassisHover(2)
                                .accessibilityLabel("Starting directory")
                            }
                        }
                    }
                }
                .frame(maxWidth: 600)
                .padding(18)
                .frame(maxWidth: .infinity)
            }
            .background(sheetGround.ignoresSafeArea())
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create & Attach") {
                        preferences.save(
                            remembersLastLaunch: remembersLastLaunch,
                            agent: agent
                        )
                        create(name, agent, directory)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            #if !os(visionOS)
            .toolbarBackground(Theme.chassis, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
        }
        .onChange(of: agent) { previous, selected in
            let untouched = name == prefill(for: previous)
            if untouched { name = prefill(for: selected) }
        }
    }

    @ViewBuilder
    private var sheetGround: some View {
        #if os(visionOS)
        Color.clear
        #else
        Theme.chassis
        #endif
    }

    private var launchChoices: [(String, AgentKind?)] {
        [("Shell", nil)] + AgentKind.allCases.map {
            ($0.displayName, Optional($0))
        }
    }

    private func prefill(for agent: AgentKind?) -> String {
        TmuxProbe.uniqueSessionName(
            base: agent?.launchCommand ?? "main", existing: existingNames)
    }

    private var launchDetail: String {
        guard let agent else {
            return "Creates the tmux session, then attaches to its login shell."
        }
        return "Creates the tmux session, types “\(agent.launchCommand)” into its fresh shell, then attaches."
    }

    private var directoryDetail: String {
        guard !host.workingDirs.isEmpty else {
            return "Uses the host's login-shell home directory."
        }
        if let directory {
            return "Starts in \(directory). Choose Home to use the login shell's default."
        }
        return "Uses the host's login-shell home directory."
    }
}

/// The broadcast no-signal texture: diagonal hatching on screen ground.
struct HatchedScreen: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 14
            }
            context.stroke(path, with: .color(Color(hex: 0x101114)), lineWidth: 5)
        }
        .background(Theme.screen)
    }
}

/// One monitor on the wall: live miniature, UMD row (name, lamp or attach
/// badge, telemetry), and the session's windows as its segmented lower
/// bezel — the spine. The whole tile is one button: press focuses the
/// window already attached to this session, or attaches in a new one;
/// long press offers an explicit new-window attach (a second synced
/// tmux client) alongside delete.
/// Slow opacity pulse for a status dot — activity without geometry, so the
/// rail can signal "in flight" from inside a fixed-height slot. Static under
/// Reduce Motion.
private struct DotPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var active: Bool

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content.phaseAnimator([1.0, 0.25]) { dot, opacity in
                dot.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.7)
            }
        } else {
            content
        }
    }
}

private struct SessionTile: View {
    let session: TmuxSession
    let lines: [String]
    /// Agent state from the latest probe/capture pass for the active pane.
    /// Background pane title state is folded into the visible tile below.
    let attention: PaneAgentState?
    /// Pane titles survive in cold-launch snapshots so agent telemetry paints
    /// immediately, but activity/attention must be re-earned by a live probe.
    let hasLiveAgentState: Bool
    /// Whether some open terminal window already has this session as a tab
    /// — pressing then focuses that window instead of attaching again.
    let hasOpenTab: Bool
    /// Expanded shell rails use the approved mini-tile anatomy while keeping
    /// the same live capture, state, actions, and reorder behavior.
    let compact: Bool
    let selected: Bool
    let duplicateAttachTitle: String
    let openTabAccessibilityText: String
    let attach: () -> Void
    let attachNewWindow: () -> Void
    let delete: () -> Void

    var body: some View {
        Button(action: attach) {
            VStack(spacing: 0) {
                screen
                umd
                if !compact { segmentStrip }
            }
            .padding(compact ? 4 : 5)
            .background(Theme.bezel)
            .overlay(Rectangle().strokeBorder(
                selected ? Theme.signal2 : Theme.bezelHi,
                lineWidth: selected ? 1.5 : 1
            ))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chassisHover(4)
        // Keep the lifted reorder preview on the tile's full rectangular
        // chassis bounds; the default inferred shape can inset/round it and
        // make the card read as if it shrank under the finger.
        .contentShape(.dragPreview, Rectangle())
        .contextMenu {
            Button(duplicateAttachTitle, action: attachNewWindow)
            Button("Delete Session…", role: .destructive, action: delete)
        }
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("Long press and drag to reorder within this host")
    }

    private var screen: some View {
        VStack(alignment: .leading, spacing: 2) {
            if lines.isEmpty {
                Text("—")
                    .font(.mono(11))
                    .foregroundStyle(Theme.signal3)
            } else {
                ForEach(
                    Array(lines.prefix(compact ? 3 : lines.count).enumerated()),
                    id: \.offset
                ) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.mono(11))
                        .foregroundStyle(Theme.miniText.opacity(0.78))
                        .lineLimit(1)
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: compact ? 56 : 76,
            alignment: .topLeading
        )
        .padding(compact ? 8 : 10)
        .background(Theme.screen)
    }

    private var umd: some View {
        HStack(spacing: 9) {
            ChassisLabel(session.name, size: compact ? 10 : 12)
            // The badge is taller than the lamp, so swapping them resizes
            // the tile on every attach/detach. The badge keeps its slot in
            // both states (hidden under the lamp) to pin the row's height.
            ZStack(alignment: .leading) {
                ChassisBadge("ATTACH")
                    .opacity(session.isAttached ? 0 : 1)
                    .accessibilityHidden(session.isAttached)
                if session.isAttached {
                    TallyLamp()
                }
            }
            // An agent blocked on the user outranks everything else the
            // tile could say — caution, captioned, never tally red.
            if agentNeedsYou {
                TallyLamp(caption: "NEEDS YOU", color: Theme.caution)
            }
            Spacer(minLength: 6)
            if !compact {
                Text(telemetry)
                    .font(.mono(9.5))
                    .foregroundStyle(Theme.signal2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, compact ? 6 : 7)
        .padding(.top, compact ? 6 : 8)
        .padding(.bottom, 5)
    }

    private var telemetry: String {
        let hasSplitPanes = session.paneCount > session.windowCount
        var parts = [hasSplitPanes ? "\(session.windowCount)W" : "\(session.windowCount) WIN"]
        if hasSplitPanes {
            parts.append("\(session.paneCount)P")
        }
        if session.clientCount > 0 {
            parts.append(hasSplitPanes
                ? "\(session.clientCount)C"
                : "\(session.clientCount) CLIENT\(session.clientCount == 1 ? "" : "S")")
        }
        // Free-tier telemetry sees every split. Keep the active kind first,
        // then stable pane order; repeated kinds get a compact count.
        for agent in orderedAgentKinds {
            let count = session.detectedAgents.count { $0 == agent }
            parts.append(count > 1
                ? "\(count)×\(agent.telemetryLabel)"
                : agent.telemetryLabel)
        }
        if agentRunning {
            parts.append("RUNNING")
        }
        parts.append(sessionAge)
        return parts.joined(separator: " · ")
    }

    private var orderedAgentKinds: [AgentKind] {
        var result: [AgentKind] = []
        if let active = session.activeAgent { result.append(active) }
        for agent in session.detectedAgents where !result.contains(agent) {
            result.append(agent)
        }
        return result
    }

    private var agentRunning: Bool {
        if attention == .busy { return true }
        guard hasLiveAgentState else { return false }
        return session.agentPanes.contains {
            AgentAttention.classifyVerified(
                title: $0.title,
                tail: [],
                agent: $0.agent
            ) == .busy
        }
    }

    private var agentNeedsYou: Bool {
        if case .needsYou = attention { return true }
        guard hasLiveAgentState else { return false }
        return session.agentPanes.contains {
            if case .some(.needsYou) = AgentAttention.classifyVerified(
                title: $0.title,
                tail: [],
                agent: $0.agent
            ) {
                return true
            }
            return false
        }
    }

    private var sessionAge: String {
        let seconds = max(0, Date().timeIntervalSince(session.created))
        if seconds >= 86_400 { return "\(Int(seconds / 86_400))d" }
        if seconds >= 3_600 { return "\(Int(seconds / 3_600))h" }
        return "\(max(1, Int(seconds / 60)))m"
    }

    private var segmentStrip: some View {
        HStack(spacing: 3) {
            ForEach(session.windows) { window in
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(window.isActive ? Theme.signal : Theme.bezelHi)
                        .frame(height: 2)
                    Text(
                        "\(window.index) \(window.name)"
                            + (window.paneCount > 1 ? " · \(window.paneCount)P" : "")
                    )
                        .font(.mono(8))
                        .kerning(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(window.isActive ? Theme.signal : Theme.signal2)
                        .lineLimit(1)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) {
                    if window.hasBell || window.hasActivity {
                        Rectangle()
                            .fill(Theme.caution)
                            .frame(width: 5, height: 5)
                            .offset(y: -2)
                    }
                }
            }
        }
        .padding(.horizontal, 3)
        .padding(.bottom, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spineSummary)
    }

    private var spineSummary: String {
        let active = session.windows.first(where: \.isActive).map { "\($0.name) active" } ?? ""
        return "\(session.windowCount) windows, \(session.paneCount) panes. \(active)"
    }

    private var accessibilitySummary: String {
        var parts = [session.name, session.isAttached ? "live" : "not attached"]
        if agentNeedsYou { parts.append("agent needs your input") }
        if agentRunning { parts.append("agent running") }
        parts.append("\(session.windowCount) windows and \(session.paneCount) panes")
        return parts.joined(separator: ", ")
            + (hasOpenTab ? ". \(openTabAccessibilityText)" : ". Attach")
    }
}

#if DEBUG
private enum FleetWallPreviewData {
    static let host = Host(
        name: "devbox",
        hostname: "127.0.0.1",
        port: 2222,
        username: "jhen",
        workingDirs: ["~/workspace/Multiplex", "~/workspace"]
    )

    static let session = TmuxSession(
        name: "agent",
        windows: [
            TmuxWindow(
                index: 0,
                name: "codex",
                isActive: true,
                hasBell: false,
                hasActivity: true,
                agent: .codex,
                paneTitle: "Action Required | ~/workspace/Multiplex",
                panes: [
                    TmuxPane(
                        index: 0,
                        isActive: true,
                        tmuxID: "%1",
                        pid: 101,
                        tty: "ttys001",
                        command: "codex",
                        title: "Action Required | ~/workspace/Multiplex",
                        agent: .codex
                    ),
                ]
            ),
            TmuxWindow(
                index: 1,
                name: "logs",
                isActive: false,
                hasBell: true,
                hasActivity: false,
                agent: nil
            ),
        ],
        clientCount: 1,
        created: Date().addingTimeInterval(-7_200),
        tmuxID: "$1"
    )
}

#Preview("Session tile") {
    SessionTile(
        session: FleetWallPreviewData.session,
        lines: [
            "$ codex",
            "Review the preview coverage",
            "Waiting for approval…",
        ],
        attention: .needsYou(.permission),
        hasLiveAgentState: true,
        hasOpenTab: true,
        compact: false,
        selected: true,
        duplicateAttachTitle: "Attach in New Window",
        openTabAccessibilityText: "Shows its open window",
        attach: {},
        attachNewWindow: {},
        delete: {}
    )
    .frame(width: 360)
    .padding()
    .background(Theme.chassis)
}

#Preview("New session sheet") {
    NewSessionSheet(
        host: FleetWallPreviewData.host,
        existingNames: ["main", "scratch"],
        create: { _, _, _ in },
        preferences: NewSessionPreferences(
            defaults: UserDefaults(
                suiteName: "app.multiplexterm.multiplex.preview.new-session"
            )!
        )
    )
}

#Preview("Hatched screen") {
    HatchedScreen()
        .frame(width: 360, height: 180)
        .padding()
        .background(Theme.chassis)
}
#endif
