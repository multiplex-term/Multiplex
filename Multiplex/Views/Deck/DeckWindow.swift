import SwiftUI

/// The launcher: hosts on the left, a host's tmux sessions on the right.
struct DeckWindow: View {
    @Environment(HostStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    @State private var selectedHostID: UUID?
    @State private var addingHost = false
    @State private var editingHost: Host?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let id = selectedHostID, let host = store.host(id: id) {
                HostDetailView(host: host)
                    .id(host.id)
            } else {
                FirstRunView(hasHosts: !store.hosts.isEmpty) {
                    addingHost = true
                }
            }
        }
        .sheet(isPresented: $addingHost) { AddHostSheet() }
        .sheet(item: $editingHost) { host in AddHostSheet(editing: host) }
        .onAppear {
            if selectedHostID == nil { selectedHostID = store.hosts.first?.id }
        }
        #if DEBUG
        .task { await autoAttachIfRequested() }
        #endif
    }

    #if DEBUG
    /// Headless-verification hook: `MULTIPLEX_AUTO_ATTACH=<a,b,…>` opens one
    /// terminal window per session through the same route the Attach button uses.
    private func autoAttachIfRequested() async {
        guard let list = ProcessInfo.processInfo.environment["MULTIPLEX_AUTO_ATTACH"],
              !list.isEmpty else { return }
        try? await Task.sleep(for: .seconds(5))
        guard let host = store.hosts.first else { return }
        for name in list.split(separator: ",").map(String.init) {
            openWindow(id: "terminal", value: TerminalRoute(hostID: host.id, mode: .attach(sessionName: name)))
            try? await Task.sleep(for: .seconds(1))
        }
    }
    #endif

    private var sidebar: some View {
        List(selection: $selectedHostID) {
            Section {
                ForEach(store.hosts) { host in
                    HostRow(host: host)
                        .tag(host.id)
                        .contextMenu {
                            Button("Edit…") { editingHost = host }
                            Button("Remove", role: .destructive) { remove(host) }
                        }
                }
            } header: {
                Eyebrow("Hosts")
            }
        }
        .navigationTitle("Multiplex")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addingHost = true
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
            }
        }
    }

    private func remove(_ host: Host) {
        if selectedHostID == host.id { selectedHostID = nil }
        store.remove(host)
    }
}

private struct HostRow: View {
    @Environment(ConnectionHub.self) private var hub
    let host: Host

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(hub.model(for: host).phase == .connected ? Theme.phosphor : Theme.line)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name)
                    .font(.mono(15, weight: .medium))
                Text(host.address)
                    .font(.mono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// First-run hero: the one place the amber caret gets to breathe.
struct FirstRunView: View {
    var hasHosts: Bool
    var addHost: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var caretOn = true

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 2) {
                Text("multiplex")
                    .font(.mono(34, weight: .semibold))
                Rectangle()
                    .fill(Theme.phosphor)
                    .frame(width: 16, height: 34)
                    .opacity(caretOn ? 1 : 0.15)
            }
            Text(hasHosts ? "Select a host to see its tmux sessions." : "Every tmux session, its own window in space.")
                .font(.body)
                .foregroundStyle(.secondary)
            if !hasHosts {
                Button(action: addHost) {
                    Text("Add Host")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.phosphor)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                withAnimation(.easeInOut(duration: 0.25)) { caretOn.toggle() }
            }
        }
    }
}
