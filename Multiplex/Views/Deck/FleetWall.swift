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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var addHost: () -> Void
    var editHost: (Host) -> Void
    var openSettings: () -> Void

    @State private var namingHost: Host?
    @State private var newSessionName = ""
    @State private var deleteTarget: DeleteTarget?
    @State private var removingHost: Host?

    /// Pending delete confirmation — which session on which host.
    private struct DeleteTarget {
        let host: Host
        let session: TmuxSession
    }

    private let columns = [GridItem(.adaptive(minimum: 290, maximum: 360), spacing: 14)]
    /// Wall cadence: one probe + capture round-trip per host per tick.
    private static let feedInterval: Duration = .seconds(5)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
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
        .background(Theme.chassis.ignoresSafeArea())
        .task(id: store.hosts.map(\.id)) { await runFeed() }
        .alert(
            "New Session",
            isPresented: Binding(
                get: { namingHost != nil },
                set: { if !$0 { namingHost = nil } }
            )
        ) {
            TextField("Name", text: $newSessionName)
            Button("Create & Attach") { createSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a tmux session on \(namingHost?.name ?? "the host") and attaches to it.")
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
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Theme.bezel).frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                ChassisLabel(host.name, size: 12)
                Text(host.address)
                    .font(.mono(11))
                    .foregroundStyle(Theme.signal2)
                Spacer()
                railStatus(model)
                if model.phase == .connected {
                    ChassisChip("SHELL") {
                        open(TerminalRoute(hostID: host.id, mode: .shell))
                    }
                }
                hostMenu(host)
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button("Edit Host…") { editHost(host) }
                Button("Remove Host…", role: .destructive) { removingHost = host }
            }
        }
    }

    /// Visible host controls. Edit is most needed when a host is
    /// UNREACHABLE (fixing a bad address), so unlike SHELL this menu shows
    /// in every connection phase; the rail's long-press menu mirrors it.
    private func hostMenu(_ host: Host) -> some View {
        Menu {
            Button("Edit Host…") { editHost(host) }
            Button("Remove Host…", role: .destructive) { removingHost = host }
        } label: {
            ChassisBadge("", systemImage: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .chassisHover(2)
        .accessibilityLabel("Host options for \(host.name)")
    }

    @ViewBuilder
    private func railStatus(_ model: HostConnectionModel) -> some View {
        switch model.phase {
        case .connected:
            railLabel("CONNECTED", dot: Theme.ok)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("LINKING").font(.mono(9)).kerning(1).foregroundStyle(Theme.signal2)
            }
        case .failed:
            railLabel("UNREACHABLE", dot: Theme.signal3, text: Theme.signal3)
        case .idle:
            Text("STANDBY").font(.mono(9)).kerning(1).foregroundStyle(Theme.signal3)
        }
    }

    private func railLabel(_ text: String, dot: Color, text textColor: Color = Theme.signal2) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text).font(.mono(9)).kerning(1).foregroundStyle(textColor)
        }
    }

    @ViewBuilder
    private func tiles(_ host: Host, model: HostConnectionModel) -> some View {
        let grid = LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            switch model.tmux {
            case .sessions(let sessions):
                ForEach(sessions) { session in
                    SessionTile(
                        session: session,
                        lines: model.miniatures[session.name] ?? [],
                        attach: {
                            open(TerminalRoute(hostID: host.id, mode: .attach(sessionName: session.name)))
                        },
                        delete: {
                            deleteTarget = DeleteTarget(host: host, session: session)
                        }
                    )
                }
                newSessionTile(host)
            case .noServer:
                newSessionTile(host)
            case .tmuxMissing:
                noteTile("No tmux on host", detail: "You can still open a plain shell.")
            case .failed:
                noSignalTile(host, model: model)
            case .unknown, .probing:
                acquiringTile
            }
        }
        if reduceMotion {
            grid
        } else {
            grid.animation(.easeOut(duration: 0.3), value: model.tmux)
        }
    }

    // MARK: Special tiles

    private func newSessionTile(_ host: Host) -> some View {
        Button {
            newSessionName = ""
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

    private func createSession() {
        guard let host = namingHost else { return }
        var name = newSessionName
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        if name.isEmpty { name = "main" }
        open(TerminalRoute(hostID: host.id, mode: .create(sessionName: name)))
    }

    private func open(_ route: TerminalRoute) {
        openWindow(id: "terminal", value: TerminalWindowRoute(tab: route))
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
/// bezel — the spine. The whole tile is the Attach button.
private struct SessionTile: View {
    let session: TmuxSession
    let lines: [String]
    let attach: () -> Void
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
        .contextMenu {
            Button("Delete Session…", role: .destructive, action: delete)
        }
        .accessibilityLabel(accessibilitySummary)
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
            if session.isAttached {
                TallyLamp()
            } else {
                ChassisBadge("ATTACH")
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
        // Free-tier teaser: the wall names a detected agent in telemetry.
        if let agent = session.activeAgent {
            parts.append(agent.telemetryLabel)
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
        "\(session.name), \(session.isAttached ? "live" : "not attached"), \(session.windowCount) windows. Attach"
    }
}
