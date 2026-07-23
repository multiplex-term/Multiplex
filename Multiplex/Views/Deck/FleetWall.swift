import SwiftUI

/// Breakpoint sizing for the wall's session-tile grid, in two stages: how many
/// columns the width *allows*, then how many the wall has tiles to *fill*.
///
/// Width first. Tiles expand toward the preferred width, but a new column
/// enters as soon as every tile can retain the compact minimum. This keeps an
/// iPad mini's two-tile portrait row and three-tile landscape row intact
/// instead of orphaning the last tile.
///
/// Then the tiles. A wall can be wider than the fullest host has tiles for, and
/// an unfillable column is not free — every tile in the row gives up width to
/// make room for it, so a three-tile host on a four-column wall would show
/// three compressed tiles beside an empty slot, and compress further the wider
/// the wall got. The count therefore stops at the tiles that exist: surplus
/// width goes to those tiles until they reach the preferred width and then
/// simply stays empty, which is the honest answer when a viewport is larger
/// than the fleet in it.
///
/// Only the width stage may cross into SwiftUI state. The continuously changing
/// window width is reduced to that count by `onGeometryChange`, so ordinary
/// resize frames do not rebuild the FleetWall view hierarchy; the tile stage is
/// then folded in where the grid is built, since sessions arrive on the probe's
/// cadence rather than the window's.
enum FleetTileGridSizing {
    static let minimumTileWidth: CGFloat = 290
    static let preferredTileWidth: CGFloat = 360
    static let gutter: CGFloat = 14

    /// The wall's final column count: never more columns than there are tiles
    /// to put in them.
    static func columnCount(availableColumns: Int, tileCount: Int) -> Int {
        max(1, min(availableColumns, tileCount))
    }

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

/// Identity of the long-lived wall feed. It uses the same normalized host
/// configuration as `ConnectionHub`: whenever the hub replaces a stale model,
/// this changes too, cancelling the old feed and starting one for the new
/// model. Helper-command-only edits intentionally keep the existing feed.
struct FleetFeedID: Hashable {
    private let hostConfigurations: [Host]
    private let active: Bool

    init(hosts: [Host], active: Bool) {
        hostConfigurations = hosts.map(\.connectionModelConfiguration)
        self.active = active
    }
}

/// Narrow Observation boundary for one host. Capture-pane text and attention
/// changes now invalidate only that host section; the parent wall observes
/// the lightweight fleet/session summaries used for global layout.
private struct HostSectionObservation<Content: View>: View {
    let model: HostConnectionModel
    let content: (HostConnectionModel) -> Content

    init(
        model: HostConnectionModel,
        @ViewBuilder content: @escaping (HostConnectionModel) -> Content
    ) {
        self.model = model
        self.content = content
    }

    var body: some View {
        content(model)
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
    @Environment(NetworkChangeMonitor.self) private var networkChanges
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
    var openFAQ: () -> Void

    @State private var namingHost: Host?
    @State private var deleteTarget: DeleteTarget?
    @State private var removingHost: Host?
    @State private var unreachableNotice: UnreachableNotice?
    /// Background probes surface that credentials are needed but never present
    /// the prompt themselves. Only an explicit press on that host opts in.
    @State private var keyPassphraseHostID: UUID?
    @State private var legacyDropTarget: SessionDropTarget?
    @State private var tileGridColumnCount: Int?
    /// The NO TMUX tile's install-guide dialog target.
    @State private var tmuxGuideHost: Host?
    /// The rail's KEYCHAIN LOCKED tip, captured at press time.
    @State private var keychainTip: KeychainTipRequest?

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

    var body: some View {
        platformWall
        .background(Theme.chassis.ignoresSafeArea())
        .task(
            id: FleetFeedID(hosts: store.hosts, active: scenePhase == .active)
        ) { await runFeed() }
        .sheet(item: $namingHost) { host in
            NewSessionSheet(
                host: host,
                existingNames: hub.model(for: host).tmux.sessions.map(\.name),
                create: { name, agent, initialPrompt, directory, script in
                    createSession(
                        on: host,
                        named: name,
                        launching: agent,
                        initialPrompt: initialPrompt,
                        startingIn: directory,
                        running: script
                    )
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
        .sheet(item: $tmuxGuideHost) { host in
            TmuxInstallSheet(host: host)
        }
        .sheet(item: $keychainTip) { tip in
            KeychainUnlockSheet(host: tip.host, sessionNames: tip.sessionNames)
        }
        .sshKeyPassphrasePrompt(
            challenge: presentedKeyPassphraseChallenge,
            onSubmit: acceptKeyPassphrase,
            onCancel: { _ in keyPassphraseHostID = nil }
        )
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
            count: FleetTileGridSizing.columnCount(
                availableColumns: tileGridColumnCount
                    ?? (presentation == .standard ? 2 : 1),
                tileCount: tileCount
            )
        )

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if showHeader { header }
                if store.hosts.isEmpty {
                    awaitingSignal
                } else {
                    ForEach(store.hosts) { host in
                        let model = hub.model(for: host)
                        HostSectionObservation(model: model) { observed in
                            hostSection(host, model: observed, columns: columns)
                        }
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

    /// How many tiles the fullest host section has to show: its sessions plus
    /// the new-session tile, or the lone tile a probing, unreachable, or
    /// tmux-less host renders.
    ///
    /// One count for the whole wall, taken from the fullest section, so tiles
    /// stay the same size across hosts — a shorter section leaves its trailing
    /// slots empty rather than widening its own tiles out of step with the
    /// sections above and below it.
    private var tileCount: Int {
        let counts = store.hosts.map { host -> Int in
            max(1, hub.model(for: host).sessionCount + 1)
        }
        return counts.max() ?? 1
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
        let models = store.hosts.map { hub.model(for: $0) }
        await withTaskGroup(of: Void.self) { group in
            for model in models {
                group.addTask { await runFeed(for: model) }
            }
        }
    }

    /// Each host owns its cadence. A black-holed SSH link can consume its
    /// ten-second deadline without stretching healthy hosts from five to
    /// fifteen seconds between live captures.
    private func runFeed(for model: HostConnectionModel) async {
        await model.resetConnectRetryBackoff()
        while !Task.isCancelled {
            guard UIApplication.shared.applicationState == .active else {
                // Not active YET: a cold launch runs the first tick before
                // the scene activates, and burning a whole feed interval
                // here read as "~6 s to connect" on a real iPad. Poll
                // briefly instead — the task id also restarts this loop the
                // moment the scene turns active, and iOS suspends the
                // process outright in the background, so this never spins.
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
                continue
            }
            await model.refreshAndWait(ifStaleFor: 4)
            do { try await Task.sleep(for: Self.feedInterval) }
            catch { return }
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
            ChassisChip("FAQ", systemImage: "questionmark", action: openFAQ)
                .fixedSize()
                .accessibilityLabel("Frequently asked questions")
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
                ChassisChip("", systemImage: "questionmark", action: openFAQ)
                    .accessibilityLabel("Frequently asked questions")
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
                ChassisChip("FAQ", systemImage: "questionmark", action: openFAQ)
                    .accessibilityLabel("Frequently asked questions")
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
                iconOnly ? "" : "FAQ",
                systemImage: "questionmark",
                action: openFAQ
            )
            .fixedSize()
            .accessibilityLabel("Frequently asked questions")
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
            count + hub.model(for: host).sessionCount
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
    private func hostSection(
        _ host: Host,
        model: HostConnectionModel,
        columns: [GridItem]
    ) -> some View {
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
                        if host.useMosh {
                            ChassisBadge("MOSH")
                                .accessibilityLabel("Connects over mosh")
                        }
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
                        if host.useMosh {
                            ChassisBadge("MOSH")
                                .accessibilityLabel("Connects over mosh")
                        }
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
            // Device-side condition beats every per-host phase: with no
            // usable route, a lingering CONNECTED is stale (the socket just
            // hasn't timed out yet) and UNREACHABLE blames the host for the
            // device's state.
            if networkChanges.isOffline {
                railLabel("OFFLINE", dot: Theme.signal3, text: Theme.signal3)
                    .accessibilityLabel("This device has no network connection")
            } else {
                phaseRailStatus(model)
            }
        }
        // Every phase shares one fixed-height slot so no phase change can
        // move the rail.
        .frame(height: 12)
    }

    @ViewBuilder
    private func phaseRailStatus(_ model: HostConnectionModel) -> some View {
        switch model.phase {
        case .connected:
            // The keychain tip outranks the plain CONNECTED word while it
            // stands (the probe just succeeded, so connectedness is implied)
            // — same "most actionable status wins the slot" rule that lets
            // NEEDS PASSPHRASE replace UNREACHABLE detail.
            if let notice = model.keychainNotice {
                Button {
                    keychainTip = KeychainTipRequest(
                        host: model.host,
                        sessionNames: notice.sessionNames
                    )
                } label: {
                    railLabel(
                        "KEYCHAIN LOCKED",
                        dot: Theme.caution,
                        text: Theme.caution
                    )
                }
                .buttonStyle(.plain)
                .chassisHover(2)
                .accessibilityLabel(
                    "\(model.host.name): the Mac's keychain is locked, so Claude Code shows signed out"
                )
                .accessibilityHint("Shows how to unlock the keychain")
            } else {
                railLabel("CONNECTED", dot: Theme.ok)
            }
        case .connecting:
            // Same dot anatomy as every other phase — a ProgressView is
            // intrinsically taller and its spinner draws outside the
            // slot. The pulse carries the "in flight" signal instead.
            railLabel("LINKING", dot: Theme.signal2, pulsing: true)
        case .failed(let reason):
            if model.keyPassphraseChallenge != nil {
                Button {
                    _ = requestKeyPassphraseIfNeeded(model)
                } label: {
                    railLabel(
                        "NEEDS PASSPHRASE",
                        dot: Theme.caution,
                        text: Theme.caution
                    )
                }
                .buttonStyle(.plain)
                .chassisHover(2)
                .accessibilityLabel("\(model.host.name) needs its SSH key passphrase")
                .accessibilityHint("Opens the SSH key passphrase prompt")
            } else {
                Button {
                    unreachableNotice = UnreachableNotice(host: model.host, reason: reason)
                } label: {
                    railLabel("UNREACHABLE", dot: Theme.signal3, text: Theme.signal3)
                }
                .buttonStyle(.plain)
                .chassisHover(2)
                .accessibilityLabel("\(model.host.name) unreachable")
                .accessibilityHint("Shows why the host could not be reached")
            }
        case .idle:
            Text("STANDBY").font(.mono(9)).kerning(1).foregroundStyle(Theme.signal3)
        }
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
                    tmuxMissingTile(host)
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
                    .equatable()
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
                    .equatable()
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
            hasLiveAgentState: model.hasLiveProbe,
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
            grid.animation(.easeOut(duration: 0.3), value: gridIdentity(for: state))
        }
    }

    private enum GridIdentity: Hashable {
        case unknown
        case probing
        case sessions([String])
        case noServer
        case tmuxMissing
        case failed
    }

    private func gridIdentity(for state: TmuxState) -> GridIdentity {
        switch state {
        case .unknown: .unknown
        case .probing: .probing
        case .sessions(let sessions): .sessions(sessions.map(\.name))
        case .noServer: .noServer
        case .tmuxMissing: .tmuxMissing
        case .failed: .failed
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
        let needsPassphrase = model.keyPassphraseChallenge != nil

        return Button {
            if !requestKeyPassphraseIfNeeded(model) {
                model.refresh()
            }
        } label: {
            VStack(spacing: 0) {
                ZStack {
                    HatchedScreen()
                    ChassisLabel(
                        needsPassphrase ? "Passphrase Required" : "No Signal",
                        size: 13,
                        color: needsPassphrase ? Theme.caution : Theme.signal3
                    )
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: presentation == .shellRail ? 64 : 96
                )
                HStack {
                    ChassisLabel(host.name, size: 12, color: Theme.signal3)
                    Spacer()
                    ChassisBadge(needsPassphrase ? "UNLOCK" : "RECONNECT")
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
        .accessibilityLabel(
            needsPassphrase
                ? "\(host.name) needs its SSH key passphrase. Unlock"
                : "\(host.name) unreachable. Reconnect"
        )
    }

    private var presentedKeyPassphraseChallenge: SSHKeyPassphraseChallenge? {
        guard let keyPassphraseHostID,
              let host = store.host(id: keyPassphraseHostID)
        else { return nil }
        return hub.model(for: host).keyPassphraseChallenge
    }

    /// True means this failure was a credential challenge and the generic
    /// reconnect/unreachable action has been handled here.
    private func requestKeyPassphraseIfNeeded(_ model: HostConnectionModel) -> Bool {
        guard model.keyPassphraseChallenge != nil else { return false }
        if model.requestKeyPassphrase() != nil {
            keyPassphraseHostID = model.host.id
        }
        return true
    }

    private func acceptKeyPassphrase(
        _ challenge: SSHKeyPassphraseChallenge,
        passphrase: String,
        saveToICloud: Bool
    ) {
        SSHKeyPassphraseSession.accept(
            passphrase,
            for: challenge.hostID,
            saveToICloud: saveToICloud
        )
        hub.resumeConnectionsWaitingForKeyPassphrase(hostID: challenge.hostID)
        workspace.resumeConnectionsWaitingForKeyPassphrase(hostID: challenge.hostID)
        keyPassphraseHostID = nil
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

    /// The host is reachable but tmux — the wall's core dependency — isn't
    /// on its PATH. Plain shells still work (the rail's SHELL chip), and
    /// the chip opens the per-OS install guide.
    private func tmuxMissingTile(_ host: Host) -> some View {
        VStack(spacing: 8) {
            ChassisLabel("No tmux on host", size: 11, color: Theme.signal3)
            Text("You can still use a plain shell — press SHELL.")
                .font(.footnote)
                .foregroundStyle(Theme.signal2)
                .multilineTextAlignment(.center)
            ChassisChip("INSTALL GUIDE") {
                tmuxGuideHost = host
            }
            .padding(.top, 2)
        }
        .padding(10)
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
        initialPrompt: String, startingIn directory: String?,
        running script: SessionScript?
    ) {
        let name = TmuxProbe.sanitizedSessionName(rawName)
        let model = hub.model(for: host)
        Task {
            guard let created = await model.createSession(
                base: name,
                inDirectoryOf: nil,
                startingIn: directory,
                running: script?.normalizedBody,
                typing: agent?.launchCommand(initialPrompt: initialPrompt)
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
/// the user already typed their own. Each agent can receive a one-shot first
/// prompt as its CLI argument. An opt-in remembers only the submitted launch
/// and setup-script choices for the next sheet. Hosts with working
/// directories also get a "Starts in" picker, defaulting to the first (the
/// host's own default); hosts with setup scripts get a "Runs first" picker,
/// defaulting to NONE unless one is remembered.
private struct NewSessionSheet: View {
    let host: Host
    let existingNames: [String]
    let create: (String, AgentKind?, String, String?, SessionScript?) -> Void

    private let preferences: NewSessionPreferences

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var agent: AgentKind?
    @State private var initialPrompt: String
    @State private var directory: String?
    @State private var script: SessionScript?
    @State private var remembersLastLaunch: Bool
    @FocusState private var focusedField: InputField?

    private enum InputField: Hashable {
        case name
        case initialPrompt
    }

    init(
        host: Host,
        existingNames: [String],
        create: @escaping (String, AgentKind?, String, String?, SessionScript?) -> Void,
        preferences: NewSessionPreferences = NewSessionPreferences()
    ) {
        self.host = host
        self.existingNames = existingNames
        self.create = create
        self.preferences = preferences

        let remembersLastLaunch = preferences.remembersLastLaunch
        let agent = preferences.rememberedAgent
        _agent = State(initialValue: agent)
        _initialPrompt = State(initialValue: "")
        _directory = State(initialValue: host.workingDirs.first)
        _script = State(initialValue: preferences.rememberedScript(for: host))
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
                                .focused($focusedField, equals: .name)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    }

                    TallyFormSection("Launch", detail: launchDetail) {
                        TallyFormRow {
                            TallyChoiceBar(launchChoices, selection: $agent)
                                .accessibilityLabel("What to launch")
                        }
                        if let agent {
                            TallyFormField("Initial prompt (optional)") {
                                TextField(
                                    "What should \(agent.displayName) do?",
                                    text: $initialPrompt,
                                    axis: .vertical
                                )
                                .lineLimit(2...5)
                                .focused($focusedField, equals: .initialPrompt)
                                .textInputAutocapitalization(.sentences)
                                .accessibilityLabel(
                                    "Optional initial prompt for \(agent.displayName)"
                                )
                            }
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

                    if !host.sessionScripts.isEmpty {
                        TallyFormSection("Setup script", detail: scriptDetail) {
                            TallyFormField("Runs first") {
                                Menu {
                                    ForEach(host.sessionScripts) { candidate in
                                        Button(candidate.displayName) { script = candidate }
                                    }
                                    Divider()
                                    Button("None") { script = nil }
                                } label: {
                                    HStack(spacing: 10) {
                                        Text(script?.displayName ?? "None")
                                            .foregroundStyle(Theme.signal)
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.down")
                                            .font(.ui(9, weight: .semibold))
                                            .foregroundStyle(Theme.signal2)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .chassisHover(2)
                                .accessibilityLabel("Setup script")
                            }
                        }
                    }

                    TallyFormSection("Directory", detail: directoryDetail) {
                        if host.workingDirs.isEmpty {
                            TallyFormRow {
                                HStack(spacing: 12) {
                                    Text("Starts in")
                                        .font(.ui(10, weight: .semibold))
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
                                            .foregroundStyle(Theme.signal)
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.down")
                                            .font(.ui(9, weight: .semibold))
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
            .contentShape(Rectangle())
            .onTapGesture { focusedField = nil }
            .chassisSheetGround()
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ChassisSheetTitle("New Session")
                ToolbarItem(placement: .cancellationAction) {
                    ChassisBarButton("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ChassisBarButton("Create & Attach") {
                        preferences.save(
                            remembersLastLaunch: remembersLastLaunch,
                            agent: agent,
                            script: script,
                            hostID: host.id
                        )
                        create(name, agent, initialPrompt, directory, script)
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
        let remembers = host.sessionScripts.isEmpty
            ? "REMEMBER saves only the launch choice."
            : "REMEMBER saves the launch and setup-script choices."
        guard let agent else {
            return "Creates the tmux session, then attaches to its login shell. \(remembers)"
        }
        return "Starts \(agent.displayName) in the fresh shell. The optional prompt becomes its first message; \(remembers)"
    }

    private var scriptDetail: String {
        guard let script else {
            return "Nothing extra runs. A setup script is typed into the fresh shell before the launch."
        }
        return "Types \(script.displayName) into the fresh shell first, so the launch inherits what it sets up."
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
            context.stroke(path, with: .color(Theme.screenHatch), lineWidth: 5)
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

private struct SessionTile: View, Equatable {
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

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Every data field read by the tile participates. `attach`,
        // `attachNewWindow`, and `delete` are the only exclusions: equal data
        // means their captured host/session inputs are equivalent, while the
        // closures themselves receive a fresh identity on every parent pass.
        lhs.session == rhs.session
            && lhs.lines == rhs.lines
            && lhs.attention == rhs.attention
            && lhs.hasLiveAgentState == rhs.hasLiveAgentState
            && lhs.hasOpenTab == rhs.hasOpenTab
            && lhs.compact == rhs.compact
            && lhs.selected == rhs.selected
            && lhs.duplicateAttachTitle == rhs.duplicateAttachTitle
            && lhs.openTabAccessibilityText == rhs.openTabAccessibilityText
    }

    var body: some View {
        let isAgentRunning = agentRunning
        let agentNeedsInput = agentNeedsYou

        Button(action: attach) {
            VStack(spacing: 0) {
                screen
                umd(
                    agentRunning: isAgentRunning,
                    agentNeedsYou: agentNeedsInput
                )
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
        .accessibilityLabel(accessibilitySummary(
            agentRunning: isAgentRunning,
            agentNeedsYou: agentNeedsInput
        ))
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

    private func umd(agentRunning: Bool, agentNeedsYou: Bool) -> some View {
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
                Text(telemetry(agentRunning: agentRunning))
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

    private func telemetry(agentRunning: Bool) -> String {
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

    private func accessibilitySummary(
        agentRunning: Bool,
        agentNeedsYou: Bool
    ) -> String {
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
        create: { _, _, _, _, _ in },
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
