import SwiftUI

/// One host: connection status, its tmux sessions as ink cards, and the
/// verbs that open terminal windows.
struct HostDetailView: View {
    @Environment(ConnectionHub.self) private var hub
    @Environment(\.openWindow) private var openWindow

    let host: Host

    @State private var askingNewSession = false
    @State private var newSessionName = ""

    private var model: HostConnectionModel { hub.model(for: host) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                sessionSection
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: host.id) { model.refresh() }
        .alert("New Session", isPresented: $askingNewSession) {
            TextField("Name", text: $newSessionName)
            Button("Create & Attach") { createSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a tmux session on \(host.name) and attaches to it.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(host.name)
                    .font(.mono(30, weight: .semibold))
                Spacer()
                phaseBadge
            }
            Text(host.address)
                .font(.mono(13))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var phaseBadge: some View {
        switch model.phase {
        case .idle:
            statusLabel("idle", color: Theme.line)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("connecting").font(.mono(12)).foregroundStyle(.secondary)
            }
        case .connected:
            statusLabel("connected", color: Theme.phosphor)
        case .failed:
            statusLabel("unreachable", color: Color(hex: 0xEA6962))
        }
    }

    private func statusLabel(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.mono(12)).foregroundStyle(.secondary)
        }
    }

    // MARK: Sessions

    @ViewBuilder
    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Eyebrow("tmux sessions")
                Spacer()
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isBusy)
                .accessibilityLabel("Refresh sessions")
            }

            switch model.tmux {
            case .unknown, .probing:
                loadingCard
            case .sessions(let sessions):
                ForEach(sessions) { session in
                    SessionCard(session: session) { attach(to: session) }
                }
                actionRow(includeNewSession: true)
            case .noServer:
                emptyCard(
                    "No tmux sessions on this host.",
                    detail: "Create one to get started, or open a plain shell."
                )
                actionRow(includeNewSession: true)
            case .tmuxMissing:
                emptyCard(
                    "tmux isn't installed on this host.",
                    detail: "You can still open a plain shell."
                )
                actionRow(includeNewSession: false)
            case .failed(let message):
                emptyCard(message, detail: "Check the address and credentials, then try again.")
                HStack {
                    Button("Try Again") { model.refresh() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.phosphor)
                        .foregroundStyle(Theme.ink)
                }
            }
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Reading tmux sessions…")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(Theme.ink.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func emptyCard(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }

    private func actionRow(includeNewSession: Bool) -> some View {
        HStack(spacing: 12) {
            if includeNewSession {
                Button {
                    newSessionName = ""
                    askingNewSession = true
                } label: {
                    Label("New Session", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.phosphor)
                .foregroundStyle(Theme.ink)
            }
            Button {
                open(.init(hostID: host.id, mode: .shell))
            } label: {
                Label("Shell", systemImage: "terminal")
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 4)
    }

    // MARK: Actions

    private func attach(to session: TmuxSession) {
        open(.init(hostID: host.id, mode: .attach(sessionName: session.name)))
    }

    private func createSession() {
        var name = newSessionName
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        if name.isEmpty { name = "main" }
        open(.init(hostID: host.id, mode: .create(sessionName: name)))
    }

    private func open(_ route: TerminalRoute) {
        openWindow(id: "terminal", value: TerminalWindowRoute(tab: route))
        // Give tmux a beat to register the client, then reflect it on the deck.
        Task {
            try? await Task.sleep(for: .seconds(2))
            model.refresh()
        }
    }
}
