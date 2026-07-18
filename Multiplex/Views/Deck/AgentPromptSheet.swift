import SwiftUI

/// The widget's ASK mode: an agent-open arrived asking for its first prompt,
/// so collect it here — plus the starting directory, mirroring the New
/// Session sheet's picker — and resubmit the same action with `askForPrompt`
/// off. Launching with an empty field opens the agent bare — the prompt is
/// always optional, matching the New Session sheet.
struct AgentPromptSheet: View {
    let request: AgentPromptRequest

    @Environment(ExternalActionRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    /// Same encoding the action carries: a working-dir path, or "~" for the
    /// explicit Home choice. Seeded with the originating action's directory,
    /// else the host's default (first working dir).
    @State private var directory: String?
    @FocusState private var promptFocused: Bool

    init(request: AgentPromptRequest) {
        self.request = request
        _directory = State(
            initialValue: request.directory ?? request.host.workingDirs.first)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    TallyFormSection(
                        "First prompt",
                        detail: "Sent as \(request.agent.displayName)'s launch argument — it starts working on it immediately. Leave empty to open \(request.agent.displayName) without a prompt."
                    ) {
                        TallyFormField("Prompt") {
                            TextField(
                                "What should \(request.agent.displayName) do?",
                                text: $prompt,
                                axis: .vertical
                            )
                            .lineLimit(3...8)
                            .focused($promptFocused)
                        }
                    }

                    TallyFormSection("Directory", detail: directoryDetail) {
                        if request.host.workingDirs.isEmpty {
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
                                    ForEach(request.host.workingDirs, id: \.self) { dir in
                                        Button(dir) { directory = dir }
                                    }
                                    Divider()
                                    Button("Home") { directory = "~" }
                                } label: {
                                    HStack(spacing: 10) {
                                        Text(directoryLabel)
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
                .frame(maxWidth: 680)
                .padding(18)
                .frame(maxWidth: .infinity)
            }
            .background(sheetGround.ignoresSafeArea())
            .navigationTitle("\(request.agent.displayName) on \(request.host.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Launch", action: launch)
                }
            }
            #if !os(visionOS)
            .toolbarBackground(Theme.chassis, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
        }
        .task { promptFocused = true }
    }

    @ViewBuilder
    private var sheetGround: some View {
        #if os(visionOS)
        Color.clear
        #else
        Theme.chassis
        #endif
    }

    private var directoryLabel: String {
        guard let directory, directory != "~" else { return "Home" }
        return directory
    }

    private var directoryDetail: String {
        guard !request.host.workingDirs.isEmpty else {
            return "Uses the host's login-shell home directory."
        }
        if let directory, directory != "~" {
            return "Starts in \(directory). Choose Home to use the login shell's default."
        }
        return "Uses the host's login-shell home directory."
    }

    private func launch() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        router.submit(.openAgent(
            host: .id(request.host.id),
            agent: request.agent,
            prompt: text.isEmpty ? nil : text,
            askForPrompt: false,
            directory: directory
        ))
        dismiss()
    }
}
