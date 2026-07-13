import SwiftUI

/// The deck: the whole fleet as one broadcast monitor wall. Every host
/// probes concurrently under a thin rail; every session is a live tile
/// showing its actual last lines (capture-pane over the host's control
/// connection, ~5 s cadence while the deck is frontmost). Unreachable
/// hosts render in the composition as NO SIGNAL tiles instead of hiding
/// behind a selection — there is no sidebar on purpose.
struct FleetWall: View {
    @Environment(HostStore.self) private var store
    @Environment(ConnectionHub.self) private var hub
    @Environment(TerminalWorkspace.self) private var workspace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var addHost: () -> Void
    var editHost: (Host) -> Void
    var openSettings: () -> Void

    @State private var namingHost: Host?
    @State private var deleteTarget: DeleteTarget?
    @State private var removingHost: Host?
    @State private var unreachableNotice: UnreachableNotice?
    @State private var legacyDropTarget: SessionDropTarget?

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

    private let columns = [GridItem(.adaptive(minimum: 290, maximum: 360), spacing: 14)]
    /// Wall cadence: one probe + capture round-trip per host per tick.
    private static let feedInterval: Duration = .seconds(5)

    var body: some View {
        platformWall
        .background(Theme.chassis.ignoresSafeArea())
        .task(id: store.hosts.map(\.id)) { await runFeed() }
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
        #if os(visionOS)
        wall(showHeader: true)
        #else
        if #available(iOS 26.0, *) {
            // iPadOS window controls occupy the leading edge of the title
            // bar, but don't contribute a safe-area inset to arbitrary
            // content. Put the deck rail in the system toolbar so MULTIPLEX
            // is laid out around those controls instead of underneath them.
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

    private func wall(showHeader: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if showHeader { header }
                if store.hosts.isEmpty {
                    awaitingSignal
                } else {
                    ForEach(store.hosts) { host in
                        hostSection(host)
                    }
                }
            }
            .padding(26)
        }
    }

    /// While this view exists, keep the wall alive: re-probe each host and
    /// refresh its miniatures. Skips work while the app is backgrounded;
    /// `.task(id:)` restarts the loop when the fleet changes.
    private func runFeed() async {
        while !Task.isCancelled {
            if UIApplication.shared.applicationState == .active {
                for host in store.hosts {
                    let model = hub.model(for: host)
                    model.refresh()
                    await model.captureTails()
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

    private var header: some View {
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
    private func hostSection(_ host: Host) -> some View {
        let model = hub.model(for: host)

        VStack(alignment: .leading, spacing: 12) {
            rail(host, model: model)
            tiles(host, model: model)
        }
        .padding(.bottom, 22)
    }

    private func rail(_ host: Host, model: HostConnectionModel) -> some View {
        let connected = model.phase == .connected
        return VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Theme.bezel).frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                ChassisLabel(host.name, size: 12)
                Text(host.address)
                    .font(.mono(11))
                    .foregroundStyle(Theme.signal2)
                Spacer()
                railStatus(model)
                // The SHELL chip is the row's tallest element — inserting/
                // removing it with the phase resizes the whole rail. Keep
                // its slot in every phase and fade it instead.
                ChassisChip("SHELL") {
                    open(TerminalRoute(hostID: host.id, mode: .shell))
                }
                .opacity(connected ? 1 : 0)
                .allowsHitTesting(connected)
                .disabled(!connected)
                .accessibilityHidden(!connected)
                hostMenu(host)
            }
            .contentShape(Rectangle())
            .contextMenu {
                hostMenuActions(host)
            }
        }
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
    private func tiles(_ host: Host, model: HostConnectionModel) -> some View {
        switch model.tmux {
        case .sessions(let sessions):
            if #available(iOS 27.0, visionOS 27.0, *) {
                animatedGrid(
                    reorderableSessionGrid(host, model: model, sessions: sessions),
                    state: model.tmux
                )
            } else {
                animatedGrid(
                    legacySessionGrid(host, model: model, sessions: sessions),
                    state: model.tmux
                )
            }
        case .noServer:
            animatedGrid(
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    newSessionTile(host)
                },
                state: model.tmux
            )
        case .tmuxMissing:
            animatedGrid(
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    noteTile("No tmux on host", detail: "You can still open a plain shell.")
                },
                state: model.tmux
            )
        case .failed:
            animatedGrid(
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    noSignalTile(host, model: model)
                },
                state: model.tmux
            )
        case .unknown, .probing:
            animatedGrid(
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    acquiringTile
                },
                state: model.tmux
            )
        }
    }

    /// OS 27's reorder container is purpose-built for this interaction: a
    /// long press lifts one tile, leaves a placeholder, and makes the other
    /// tiles move out of the way as the drag crosses the adaptive grid.
    @available(iOS 27.0, visionOS 27.0, *)
    private func reorderableSessionGrid(
        _ host: Host, model: HostConnectionModel, sessions: [TmuxSession]
    ) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
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
        _ host: Host, model: HostConnectionModel, sessions: [TmuxSession]
    ) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
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
            hasOpenTab: workspace.hasTab(hostID: host.id, sessionName: session.name),
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
            .frame(maxWidth: .infinity, minHeight: 138)
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
                .frame(maxWidth: .infinity, minHeight: 96)
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
        .frame(maxWidth: .infinity, minHeight: 138)
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
        .frame(maxWidth: .infinity, minHeight: 138)
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
        openWindow(id: "terminal", value: TerminalWindowRoute(tab: route))
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
/// long press are the dropdown now. The name prefills the first free
/// conventional name for the selection (main / claude / codex, then -2,
/// -3…) so Create is one tap; picking an agent re-prefills it unless the
/// user already typed their own. An opt-in remembers the submitted launch
/// choice for the next prompt. Hosts with working directories also get a
/// "Starts in" picker, defaulting to the first (the host's own default).
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
            Form {
                Section {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Picker("Launches", selection: $agent) {
                        Text("Shell only").tag(AgentKind?.none)
                        Text(AgentKind.claudeCode.displayName).tag(AgentKind?.some(.claudeCode))
                        Text(AgentKind.codex.displayName).tag(AgentKind?.some(.codex))
                    }
                    .pickerStyle(.menu)
                    if !host.workingDirs.isEmpty {
                        Picker("Starts in", selection: $directory) {
                            ForEach(host.workingDirs, id: \.self) { dir in
                                Text(dir).tag(String?.some(dir))
                            }
                            Text("Home").tag(String?.none)
                        }
                        .pickerStyle(.menu)
                    }
                    Toggle("Remember launch choice", isOn: $remembersLastLaunch)
                } footer: {
                    Text(detail)
                }
            }
            .navigationTitle("New Session")
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
        }
        .onChange(of: agent) { previous, selected in
            let untouched = name == prefill(for: previous)
            if untouched { name = prefill(for: selected) }
        }
    }

    private func prefill(for agent: AgentKind?) -> String {
        TmuxProbe.uniqueSessionName(
            base: agent?.launchCommand ?? "main", existing: existingNames)
    }

    private var detail: String {
        var text = "Creates a tmux session on \(host.name) and attaches to it."
        if let directory {
            text += " Starts in \(directory)."
        }
        if let agent {
            text += " Types “\(agent.launchCommand)” into the fresh shell to start \(agent.displayName)."
        }
        return text
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
    /// Agent state from the latest probe/capture pass; nil when the active
    /// pane runs no detected agent.
    let attention: PaneAgentState?
    /// Whether some open terminal window already has this session as a tab
    /// — pressing then focuses that window instead of attaching again.
    let hasOpenTab: Bool
    let attach: () -> Void
    let attachNewWindow: () -> Void
    let delete: () -> Void

    var body: some View {
        Button(action: attach) {
            VStack(spacing: 0) {
                screen
                umd
                segmentStrip
            }
            .padding(5)
            .background(Theme.bezel)
            .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chassisHover(4)
        // Keep the lifted reorder preview on the tile's full rectangular
        // chassis bounds; the default inferred shape can inset/round it and
        // make the card read as if it shrank under the finger.
        .contentShape(.dragPreview, Rectangle())
        .contextMenu {
            Button("Attach in New Window", action: attachNewWindow)
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
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.mono(11))
                        .foregroundStyle(Theme.miniText.opacity(0.78))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .padding(10)
        .background(Theme.screen)
    }

    private var umd: some View {
        HStack(spacing: 9) {
            ChassisLabel(session.name, size: 12)
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
            if case .needsYou = attention {
                TallyLamp(caption: "NEEDS YOU", color: Theme.caution)
            }
            Spacer(minLength: 6)
            Text(telemetry)
                .font(.mono(9.5))
                .foregroundStyle(Theme.signal2)
        }
        .padding(.horizontal, 7)
        .padding(.top, 8)
        .padding(.bottom, 5)
    }

    private var telemetry: String {
        var parts = ["\(session.windowCount) WIN"]
        if session.clientCount > 0 {
            parts.append("\(session.clientCount) CLIENT\(session.clientCount == 1 ? "" : "S")")
        }
        // Free-tier teaser: the wall names a detected agent in telemetry —
        // and whether it's mid-turn right now.
        if let agent = session.activeAgent {
            parts.append(agent.telemetryLabel)
            if attention == .busy { parts.append("RUNNING") }
        }
        parts.append(sessionAge)
        return parts.joined(separator: " · ")
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
                    Text("\(window.index) \(window.name)")
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
        return "\(session.windowCount) windows. \(active)"
    }

    private var accessibilitySummary: String {
        var parts = [session.name, session.isAttached ? "live" : "not attached"]
        if case .needsYou = attention { parts.append("agent needs your input") }
        parts.append("\(session.windowCount) windows")
        return parts.joined(separator: ", ")
            + (hasOpenTab ? ". Shows its open window" : ". Attach")
    }
}
