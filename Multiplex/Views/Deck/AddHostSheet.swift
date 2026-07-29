import SwiftUI
import UIKit

/// Add or edit a host. Secrets go straight to the Keychain on save.
///
/// Adding is two roads to the same place, so they share one modal behind a
/// choice bar: BIND (run one command on the machine and confirm it) and
/// MANUAL (type the destination). Editing an existing host has only the form
/// — there is nothing to bind — so the bar is absent there entirely.
struct AddHostSheet: View {
    @Environment(HostStore.self) private var store
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(BindController.self) private var bind
    @Environment(\.dismiss) private var dismiss

    var editing: Host?

    /// Which road this modal is showing. Add opens on BIND: the deck no
    /// longer carries a BIND chip, so this bar is where the flow lives.
    enum Mode: Hashable {
        case bind
        case manual
    }

    @State private var mode: Mode = .bind
    @State private var name = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod: Host.AuthMethod = .password
    @State private var password = ""
    @State private var privateKey = ""
    /// Editing an existing host opens with the stored key hidden; a tap on
    /// the field swaps in the editor. Add mode always shows the editor.
    @State private var privateKeyConcealed = false
    @State private var passphrase = ""
    /// New hosts are added on the air; Host Settings mirrors the deck switch.
    @State private var isEnabled = true
    @State private var useMosh = false
    @State private var moshServerPath = ""
    @State private var moshPorts = ""
    @State private var workingDirs: [WorkingDir] = []
    @State private var newWorkingDir = ""
    /// Add mode starts on the default so it is visible and editable before
    /// the first save, not invisible policy.
    @State private var newSessionTmuxConf = Host.defaultNewSessionTmuxConf
    @State private var scripts: [ScriptRow] = []
    /// Launch-model lists as one-id-per-line text, one field per agent —
    /// the tmux-conf field's compact grammar, not editable rows (model ids
    /// are short single tokens; row chrome tripled the height).
    @State private var modelText: [AgentKind: String] = [:]
    @State private var testState: TestState = .idle
    @State private var showingPaywall = false

    /// Editable row model — a stable identity (not `id: \.self` on the
    /// string) so editing a path in place doesn't tear down the row's text
    /// field. Bindings below resolve through this ID so a late text-system
    /// write cannot target a stale array index after a move or deletion.
    private struct WorkingDir: Identifiable, Equatable {
        let id = UUID()
        var path: String
    }

    /// Same row discipline for setup scripts, except the identity is the
    /// script's own persisted id: the remembered-selection memory points at
    /// it, so editing a script must never remint it.
    private struct ScriptRow: Identifiable, Equatable {
        let id: UUID
        var name: String
        var body: String

        init(_ script: SessionScript) {
            id = script.id
            name = script.name
            body = script.body
        }

        init() {
            id = UUID()
            name = ""
            body = ""
        }

        var script: SessionScript {
            SessionScript(id: id, name: name, body: body)
        }
    }

    private enum TestState: Equatable {
        case idle
        case running
        case passed(headline: String, warnings: [String])
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 18) {
                    if showsModeBar {
                        VStack(alignment: .leading, spacing: 8) {
                            TallyChoiceBar(
                                [("Bind", Mode.bind), ("Manual", Mode.manual)],
                                selection: $mode
                            )
                            // Neither word says what it costs you. BIND needs
                            // something installed on the machine, which is
                            // the one thing that can make it the wrong road —
                            // so each caption names that and points at the
                            // other.
                            Text(modeDetail)
                                .font(.ui(10))
                                .foregroundStyle(Theme.signal2)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 2)
                        }
                    }
                    switch resolvedMode {
                    case .bind:
                        BindPane()
                    case .manual:
                        manualForm
                    }
                }
                .frame(maxWidth: 680)
                .padding(18)
                .frame(maxWidth: .infinity)
            }
            .task { await scrollForVerificationIfRequested(proxy) }
            .task { openBindPaneForVerificationIfRequested() }
            .chassisSheetGround()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ChassisSheetTitle(title)
                ToolbarItem(placement: .cancellationAction) {
                    // Nothing on the Bind pane is this modal's to save — the
                    // machine and the controller finish that between them —
                    // so the bar offers a way out, not a discard.
                    ChassisBarButton(resolvedMode == .bind ? "Done" : "Cancel") {
                        clearSecretsAndDismiss()
                    }
                }
                if resolvedMode == .manual {
                    ToolbarItem(placement: .confirmationAction) {
                        ChassisBarButton("Save", action: save)
                            .disabled(!isValid)
                    }
                }
            }
            }
        }
        // The manual form is long and easy to drag while scrolling. Require
        // the explicit Cancel or Save action there so a swipe cannot discard
        // edits; both paths also clear secret bindings before the sheet tears
        // down. The Bind pane holds no unsaved edits, so a swipe is allowed —
        // except mid-enrollment, where it would look like a cancel and isn't.
        .interactiveDismissDisabled(
            resolvedMode == .manual || bind.pending.contains(where: \.isBusy)
        )
        .onAppear(perform: populate)
        .sheet(isPresented: $showingPaywall) { ProPaywallView() }
        // A scan or paste that isn't a bind code at all. It belongs to this
        // modal now: the deck has no bind surface to present it from, and an
        // alert raised behind an open sheet would never be seen.
        .alert(
            "Bind Code Not Recognized",
            isPresented: Binding(
                get: { bind.alert != nil },
                set: { if !$0 { bind.alert = nil } }
            ),
            presenting: bind.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        // Binding creates a host, so it meets the same free-tier limit the
        // manual form does — refused before anything is enrolled on the
        // machine, never after.
        .onChange(of: bind.needsProForHostLimit) { _, needsPro in
            guard needsPro else { return }
            bind.needsProForHostLimit = false
            showingPaywall = true
        }
        // Any edit that could change the outcome retires the shown result —
        // a stale PASSED next to a new address would vouch for the wrong host.
        .onChange(of: testFingerprint) { testState = .idle }
    }

    private var title: String { editing == nil ? "Add Host" : "Host Settings" }

    private var modeDetail: String {
        switch resolvedMode {
        case .bind:
            "Run the mpx CLI on the machine you're adding and it offers "
                + "itself — no address, user, or key to type here. Can't "
                + "install it? Switch to MANUAL."
        case .manual:
            "Type the SSH destination yourself. Nothing to install on the "
                + "machine."
        }
    }

    /// Editing an existing host is form-only; there is no machine to bind.
    private var showsModeBar: Bool { editing == nil }

    private var resolvedMode: Mode { showsModeBar ? mode : .manual }

    private var manualForm: some View {
        VStack(spacing: 18) {
            hostSection
            monitoringSection
            credentialsSection
            testSection
            workingDirsSection
            tmuxConfSection
            scriptsSection
            agentModelsSection
                .id("agent-models")
            transportSection
        }
        // A tap on the chassis outside any field drops keyboard focus.
        // SwiftUI fields, chips, and switches claim their own taps, so this
        // only fires on inert ground.
        //
        // Scoped to this form on purpose — it used to sit on the whole scroll
        // view, which put a `UITapGestureRecognizer` above the Bind pane's
        // `PasteButton`. That is UIKit's `UIPasteControl`, a plain `UIControl`
        // whose touch tracking an ancestor recognizer cancels, so the button
        // rendered enabled and did nothing when pressed (user-reported).
        // SwiftUI's own controls are unaffected because SwiftUI arbitrates
        // its gestures internally; a hosted UIKit control is the odd one out.
        // The Bind pane wants no such gesture anyway: its only input is the
        // PIN field.
        .contentShape(Rectangle())
        .onTapGesture(perform: unfocusInputs)
    }

    // MARK: Form sections

    private var hostSection: some View {
        TallyFormSection(
            "Host identity",
            detail: "The name labels this host on the deck. Address, port, and user form the SSH destination."
        ) {
            TallyFormField("Name") {
                TextField("devbox", text: $name)
            }
            TallyFormField("Address") {
                TextField("host.example.com", text: $hostname)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            TallyFormField("Port") {
                TextField("22", text: $port)
                    .keyboardType(.numberPad)
            }
            TallyFormField("User") {
                TextField("root", text: $username)
                    .keyboardType(.asciiCapable)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    // The empty content type neutralizes the username half of
                    // AutoFill's login-form pairing — without it, User plus
                    // any secret field below reads as a savable credential.
                    .textContentType(.init(rawValue: ""))
            }
        }
    }

    /// Sits directly under the identity fields because it answers the first
    /// question someone opens this sheet with when a host shows nothing:
    /// whether anything is dialling it at all. The deck's host menu is the
    /// quick way to flip it; this is the same switch, saved with the form.
    private var monitoringSection: some View {
        TallyFormSection("Monitoring", detail: monitoringDetail) {
            TallyFormBoolField(
                "Connect on the deck",
                isOn: $isEnabled,
                accessibilityHint: "Off keeps the host in the fleet without connecting to it"
            )
        }
    }

    private var monitoringDetail: String {
        if isEnabled {
            "The deck probes this host about every five seconds while it's in front, and its sessions appear as live tiles."
        } else {
            "Off parks the host on the deck without dialling it: no probing, no tiles, and widgets or Shortcuts report it as disabled. Terminal windows already open keep running, and Signal check below still connects on demand."
        }
    }

    private var credentialsSection: some View {
        TallyFormSection("Credentials", detail: credentialsDetail) {
            TallyFormRow {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sign in with")
                        .font(.ui(10, weight: .semibold))
                        .foregroundStyle(Theme.signal2)
                    TallyChoiceBar(
                        Host.AuthMethod.allCases.map { ($0.label, $0) },
                        selection: $authMethod
                    )
                }
            }

            switch authMethod {
            case .password:
                TallyFormField("Password") {
                    // Neutral placeholder on purpose: AutoFill's login-form
                    // heuristics read field placeholders, and the caption row
                    // above already names the field for humans.
                    RevealableSecureField("Password", prompt: "Required", text: $password)
                }
            case .privateKey:
                TallyFormField("Private key") {
                    if privateKeyConcealed {
                        // The stored key must not paint on screen just for
                        // opening Host Settings. Fixed-count bullets so the
                        // mask leaks nothing, not even the key's size; the
                        // binding still holds the key, so Save and Test work
                        // without ever revealing it.
                        Button {
                            privateKeyConcealed = false
                        } label: {
                            HStack(spacing: 12) {
                                Text(String(repeating: "\u{2022}", count: 8))
                                Spacer(minLength: 12)
                                ChassisLabel("EDIT", size: 8, color: Theme.signal2)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .chassisHover(2)
                        .accessibilityLabel("Edit private key")
                        .accessibilityHint("Shows the saved key")
                    } else {
                        TextField(
                            "BEGIN OPENSSH PRIVATE KEY",
                            text: $privateKey,
                            axis: .vertical
                        )
                        .lineLimit(4...8)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .textContentType(.init(rawValue: ""))
                    }
                }
                TallyFormField("Passphrase") {
                    RevealableSecureField("Passphrase", prompt: "Optional", text: $passphrase)
                }
            }
        }
    }

    private var credentialsDetail: String {
        switch authMethod {
        case .password:
            "Stored in iCloud Keychain, never in the host record."
        case .privateKey:
            "The OpenSSH key is stored in iCloud Keychain. Leave its passphrase blank to enter it when connecting, or save the passphrase there too."
        }
    }

    private var transportSection: some View {
        TallyFormSection("Transport", detail: transportDetail) {
            TallyFormBoolField(
                "Connect with mosh",
                isOn: moshToggle,
                status: moshRequiresPro ? "PRO" : nil,
                statusIsProminent: true,
                accessibilityHint: moshRequiresPro
                    ? "Requires Multiplex Pro"
                    : nil
            )

            if useMosh {
                TallyFormField("mosh-server") {
                    TextField("mosh-server", text: $moshServerPath)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                TallyFormField("UDP port or range") {
                    TextField("60000:61000", text: $moshPorts)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                if !moshPortsValid {
                    TallyFormRow {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            TallyLamp(caption: "INVALID", color: Theme.caution)
                            Text("Use one port or a range from 1 to 65535.")
                                .font(.ui(10))
                                .foregroundStyle(Theme.signal2)
                        }
                    }
                }
            }
        }
    }

    private var transportDetail: String {
        if useMosh {
            "Terminals attach over UDP and survive roaming or sleep. SSH still signs in, starts mosh-server, and probes the deck."
        } else {
            "SSH carries both the control connection and attached terminals."
        }
    }

    // MARK: Test connection

    private var testSection: some View {
        TallyFormSection("Signal check", detail: testDetail) {
            TallyFormRow {
                HStack(spacing: 12) {
                    ChassisChip("TEST CONNECTION", action: runTest)
                        .disabled(!isValid || testState == .running)
                        .opacity(!isValid || testState == .running ? 0.45 : 1)
                    Spacer()
                    if testState == .running {
                        TallyLamp(caption: "TESTING", color: Theme.caution)
                    }
                }
            }

            switch testState {
            case .idle, .running:
                EmptyView()
            case .passed(let headline, let warnings):
                TallyFormRow {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            TallyLamp(caption: "CONNECTED", color: Theme.ok)
                            Text(headline)
                                .font(.ui(11, weight: .medium))
                                .foregroundStyle(Theme.signal)
                        }
                        ForEach(warnings, id: \.self) { warning in
                            HStack(alignment: .top, spacing: 10) {
                                TallyLamp(caption: "CHECK", color: Theme.caution)
                                Text(warning)
                                    .font(.ui(10))
                                    .foregroundStyle(Theme.signal2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            case .failed(let message):
                TallyFormRow {
                    HStack(alignment: .top, spacing: 10) {
                        TallyLamp(caption: "NO SIGNAL", color: Theme.caution)
                        Text(message)
                            .font(.ui(11))
                            .foregroundStyle(Theme.signal)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var testDetail: String {
        useMosh
            ? "Signs in over SSH with the settings above, then looks for tmux and mosh-server on the host."
            : "Signs in over SSH with the settings above, then looks for tmux on the host."
    }

    /// Everything a test's outcome depends on. Edits reset the shown result,
    /// and a test that finishes after further edits discards itself.
    private var testFingerprint: [String] {
        [hostname, port, username, authMethod.rawValue,
         password, privateKey, passphrase,
         useMosh ? "mosh" : "ssh", moshServerPath]
    }

    private func runTest() {
        testState = .running
        let host = formHost()
        let secrets = HostSecrets(
            password: authMethod == .password ? password : nil,
            privateKey: authMethod == .privateKey ? privateKey : nil,
            passphrase: authMethod == .privateKey && !passphrase.isEmpty ? passphrase : nil
        )
        let fingerprint = testFingerprint
        Task {
            let outcome = await HostTest.run(host: host, secrets: secrets)
            guard fingerprint == testFingerprint else { return }
            switch outcome {
            case .connected(let report):
                var warnings: [String] = []
                if !report.tmuxFound {
                    warnings.append("tmux wasn't found on the host — the deck can't list sessions there. Plain shells still work.")
                }
                if report.moshServerFound == false {
                    warnings.append("mosh-server wasn't found — mosh attaches will fail. Install it on the host or set its path below.")
                }
                testState = .passed(
                    headline: "Connected to \(host.hostname) as \(host.username).",
                    warnings: warnings
                )
            case .failed(let message):
                testState = .failed(message)
            }
        }
    }

    // MARK: Working directories

    private var workingDirsSection: some View {
        TallyFormSection("New session defaults", detail: workingDirsDetail) {
            ForEach(workingDirs) { dir in
                TallyFormRow {
                    HStack(spacing: 8) {
                        ChassisLabel(
                            dir.id == workingDirs.first?.id ? "DEFAULT" : "PATH",
                            size: 8,
                            color: dir.id == workingDirs.first?.id
                                ? Theme.signal2
                                : Theme.signal3
                        )
                        .frame(width: 54, alignment: .leading)

                        TextField("Directory", text: workingDirBinding(for: dir))
                            .font(.mono(11))
                            .foregroundStyle(Theme.signal)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .background(Theme.screen)
                            .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        let index = workingDirs.firstIndex(where: { $0.id == dir.id }) ?? 0
                        workingDirButton(
                            "arrow.up",
                            label: "Move directory up",
                            disabled: index == 0
                        ) { moveWorkingDir(id: dir.id, offset: -1) }
                        workingDirButton(
                            "arrow.down",
                            label: "Move directory down",
                            disabled: index >= workingDirs.count - 1
                        ) { moveWorkingDir(id: dir.id, offset: 1) }
                        workingDirButton("trash", label: "Delete directory") {
                            removeWorkingDir(id: dir.id)
                        }
                    }
                }
            }

            TallyFormRow {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Add directory")
                        .font(.ui(10, weight: .semibold))
                        .foregroundStyle(Theme.signal2)
                    HStack(spacing: 8) {
                        TextField("~/projects/app", text: $newWorkingDir)
                            .font(.mono(11))
                            .foregroundStyle(Theme.signal)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .background(Theme.screen)
                            .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit(addWorkingDir)
                        ChassisChip("ADD", systemImage: "plus", action: addWorkingDir)
                            .disabled(newWorkingDir.trimmingCharacters(in: .whitespaces).isEmpty)
                            .opacity(newWorkingDir.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
                    }
                }
            }
        }
    }

    private var workingDirsDetail: String {
        workingDirs.isEmpty
            ? "New sessions start in the host's home directory. Add paths to make them available in New Session."
            : "The first path is the default. New Session can choose another path or the host's home directory."
    }

    private func workingDirBinding(for snapshot: WorkingDir) -> Binding<String> {
        Binding(
            get: {
                workingDirs.first(where: { $0.id == snapshot.id })?.path
                    ?? snapshot.path
            },
            set: { value in
                guard let index = workingDirs.firstIndex(where: { $0.id == snapshot.id }) else {
                    return
                }
                workingDirs[index].path = value
            }
        )
    }

    private func moveWorkingDir(id: UUID, offset: Int) {
        guard let source = workingDirs.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard workingDirs.indices.contains(destination) else { return }
        workingDirs.swapAt(source, destination)
    }

    private func removeWorkingDir(id: UUID) {
        workingDirs.removeAll { $0.id == id }
    }

    private func workingDirButton(
        _ systemImage: String,
        label: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.ui(9, weight: .semibold))
                .foregroundStyle(disabled ? Theme.signal3 : Theme.signal2)
                .frame(width: 25, height: 25)
                .background(Theme.chassis)
                .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .chassisHover(2)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private func addWorkingDir() {
        let dir = newWorkingDir.trimmingCharacters(in: .whitespaces)
        guard !dir.isEmpty, !workingDirs.contains(where: { $0.path == dir }) else { return }
        workingDirs.append(WorkingDir(path: dir))
        newWorkingDir = ""
    }

    // MARK: New session tmux conf

    private var tmuxConfSection: some View {
        TallyFormSection(
            "New session tmux conf",
            detail: "One option per line, like a .tmux.conf (mouse on, "
                + "history-limit 50000). Each line is applied when Multiplex "
                + "creates a session with tmux set-option -t that session. "
                + "Attaching never applies anything, and session-scoped "
                + "options do not change sessions made on the host. Hosts "
                + "start with mouse on and focus-events on; clear the field "
                + "to apply nothing. "
                + "Focus events and other server-scoped options still reach "
                + "the whole tmux server."
        ) {
            TallyFormField("Options") {
                TextField("cleared — nothing applied", text: $newSessionTmuxConf, axis: .vertical)
                    .lineLimit(2...6)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
    }

    // MARK: Session setup scripts

    private var scriptsSection: some View {
        TallyFormSection("Session setup scripts", detail: scriptsDetail) {
            ForEach(scripts) { row in
                TallyFormRow {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            TextField("Name", text: scriptBinding(for: row, \.name))
                                .font(.ui(11, weight: .medium))
                                .foregroundStyle(Theme.signal)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 8)
                                .background(Theme.screen)
                                .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)

                            let index = scripts.firstIndex(where: { $0.id == row.id }) ?? 0
                            workingDirButton(
                                "arrow.up",
                                label: "Move script up",
                                disabled: index == 0
                            ) { moveScript(id: row.id, offset: -1) }
                            workingDirButton(
                                "arrow.down",
                                label: "Move script down",
                                disabled: index >= scripts.count - 1
                            ) { moveScript(id: row.id, offset: 1) }
                            workingDirButton("trash", label: "Delete script") {
                                scripts.removeAll { $0.id == row.id }
                            }
                        }

                        TextField(
                            "source ~/.venv/bin/activate",
                            text: scriptBinding(for: row, \.body),
                            axis: .vertical
                        )
                        .lineLimit(2...6)
                        .font(.mono(11))
                        .foregroundStyle(Theme.signal)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .background(Theme.screen)
                        .overlay(Rectangle().strokeBorder(Theme.bezelHi, lineWidth: 1))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("Script commands")
                    }
                }
            }

            TallyFormRow {
                ChassisChip("ADD SCRIPT", systemImage: "plus") {
                    scripts.append(ScriptRow())
                }
            }
        }
    }

    private var scriptsDetail: String {
        scripts.isEmpty
            ? "New Session can type a chosen script into the fresh shell before anything launches. Add one to make it available."
            : "New Session offers these by name; the chosen one is typed into the fresh shell before the launch command."
    }

    // MARK: Agent launch models

    /// One compact field per agent, one model id per line — the tmux-conf
    /// field's grammar. Model ids are short single tokens, so editable rows
    /// with move/delete chrome only added height; line order IS the picker
    /// order, and deleting a line deletes the model.
    private var agentModelsSection: some View {
        TallyFormSection("Agent launch models", detail: modelsDetail) {
            ForEach(AgentKind.allCases, id: \.self) { agent in
                TallyFormField(agent.displayName) {
                    TextField(
                        modelPlaceholder(for: agent),
                        text: modelTextBinding(for: agent),
                        axis: .vertical
                    )
                    .lineLimit(1...5)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("\(agent.displayName) models, one per line")
                }
            }
        }
    }

    private var modelsDetail: String {
        "One model id per line, in picker order. New Session, the Open "
            + "Agent shortcut, and the host widget offer them as choices, "
            + "passed as --model; nothing is applied unless chosen at launch."
    }

    /// A hint only where the alias grammar is stable; Codex and Pi ids are
    /// exactly what this feature saves the user from retyping, so those
    /// fields never suggest one that would go stale.
    private func modelPlaceholder(for agent: AgentKind) -> String {
        switch agent {
        case .claudeCode: "opus, sonnet, or a full model id"
        case .codex: "model id per line"
        case .pi: "provider/model-id per line"
        }
    }

    private func modelTextBinding(for agent: AgentKind) -> Binding<String> {
        Binding(
            get: { modelText[agent] ?? "" },
            set: { modelText[agent] = $0 }
        )
    }

    /// Fields split back into lists, in editor order; the token gate and
    /// dedupe happen in `Host.normalizedLaunchModels` at save.
    private var resolvedLaunchModels: [String: [String]] {
        var models: [String: [String]] = [:]
        for agent in AgentKind.allCases {
            models[agent.rawValue] = (modelText[agent] ?? "")
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return models
    }

    /// Same late-write discipline as the working-dir rows: resolve through
    /// the row id, never a captured array index.
    private func scriptBinding(
        for snapshot: ScriptRow, _ keyPath: WritableKeyPath<ScriptRow, String>
    ) -> Binding<String> {
        Binding(
            get: {
                (scripts.first(where: { $0.id == snapshot.id }) ?? snapshot)[keyPath: keyPath]
            },
            set: { value in
                guard let index = scripts.firstIndex(where: { $0.id == snapshot.id }) else {
                    return
                }
                scripts[index][keyPath: keyPath] = value
            }
        )
    }

    private func moveScript(id: UUID, offset: Int) {
        guard let source = scripts.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard scripts.indices.contains(destination) else { return }
        scripts.swapAt(source, destination)
    }

    /// What gets saved: rows trimmed, emptied rows dropped, duplicates
    /// (possible now that rows are editable) collapsed to the first, and a
    /// directory typed but not yet added folded in — losing text sitting
    /// visibly in the field would read as a bug.
    private var resolvedWorkingDirs: [String] {
        var seen = Set<String>()
        var dirs: [String] = []
        let pending = newWorkingDir.trimmingCharacters(in: .whitespaces)
        for path in workingDirs.map(\.path) + [pending] {
            let dir = path.trimmingCharacters(in: .whitespaces)
            if !dir.isEmpty, seen.insert(dir).inserted { dirs.append(dir) }
        }
        return dirs
    }

    // MARK: Validation / persistence

    /// Mosh is gated only when a free user tries to turn it on. A host that
    /// already uses mosh (for example, one synced from a Pro device) remains
    /// editable and keeps connecting; free users can always turn it off.
    /// The saved record's value participates so that reverting your own
    /// toggle-off within one edit session restores what the record already
    /// has — that is not new Pro intent. The row's PRO badge mirrors this
    /// same predicate so it appears exactly when enabling would paywall.
    private var moshRequiresPro: Bool {
        !entitlements.canEnableMosh(
            currentlyEnabled: useMosh || editing?.useMosh == true
        )
    }

    private var moshToggle: Binding<Bool> {
        Binding(
            get: { useMosh },
            set: { enabled in
                if enabled, moshRequiresPro {
                    showingPaywall = true
                    return
                }
                useMosh = enabled
            }
        )
    }

    private var isValid: Bool {
        !hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(port) != nil
            && moshPortsValid
    }

    /// Empty, one port, or a low:high range — mirrors what mosh-server -p
    /// accepts. The string lands in a remote shell line, so reject anything
    /// beyond digits and a colon outright.
    private var moshPortsValid: Bool {
        guard useMosh else { return true }
        let trimmed = moshPorts.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part) else { return false }
            return (1...65535).contains(value)
        }
    }

    /// `MULTIPLEX_AUTO_HOST_SETTINGS=models` scrolls to the Agent launch
    /// models section once the sheet settles — the form is taller than one
    /// headless frame and the simulator cannot scroll (DEBUG capture only).
    private func scrollForVerificationIfRequested(_ proxy: ScrollViewProxy) async {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let target: String
        if environment["MULTIPLEX_AUTO_HOST_SETTINGS"] == "models" {
            target = "agent-models"
        } else if environment["MULTIPLEX_AUTO_ADD_HOST"] == "bind-elsewhere" {
            target = BindPane.elsewhereID
        } else {
            return
        }
        try? await Task.sleep(for: .milliseconds(700))
        withAnimation(nil) { proxy.scrollTo(target, anchor: .top) }
        #endif
    }

    /// `MULTIPLEX_AUTO_ADD_HOST=bind|manual` picks which road this modal
    /// opens on, so both panes can be captured headlessly (the simulator
    /// cannot tap the choice bar). Adding always defaults to Bind.
    private func openBindPaneForVerificationIfRequested() {
        #if DEBUG
        guard showsModeBar,
              let request = ProcessInfo.processInfo.environment[
                "MULTIPLEX_AUTO_ADD_HOST"
              ]
        else { return }
        mode = request == "manual" ? .manual : .bind
        #endif
    }

    /// Resigns whichever field currently holds the keyboard. Routed through
    /// the responder chain so it covers the SwiftUI fields and the
    /// UIKit-backed secret fields alike, without threading FocusState
    /// through every row.
    private func unfocusInputs() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    private func populate() {
        guard let host = editing else { return }
        name = host.name
        hostname = host.hostname
        port = String(host.port)
        username = host.username
        authMethod = host.authMethod
        isEnabled = host.isEnabled
        useMosh = host.useMosh
        moshServerPath = host.moshServerPath ?? ""
        moshPorts = host.moshPorts ?? ""
        workingDirs = host.workingDirs.map { WorkingDir(path: $0) }
        newSessionTmuxConf = host.newSessionTmuxConf
        scripts = host.sessionScripts.map(ScriptRow.init)
        modelText = [:]
        for agent in AgentKind.allCases {
            let models = host.launchModels(for: agent)
            if !models.isEmpty {
                modelText[agent] = models.joined(separator: "\n")
            }
        }
        password = KeychainStore.get(for: host.id, kind: .password) ?? ""
        privateKey = KeychainStore.get(for: host.id, kind: .privateKey) ?? ""
        passphrase = KeychainStore.get(for: host.id, kind: .keyPassphrase) ?? ""
        privateKeyConcealed = !privateKey.isEmpty
    }

    /// The form's current values as a Host record — what Save persists and
    /// what Test Connection dials, so the two can never disagree.
    private func formHost() -> Host {
        // Start from the live record, not the snapshot that opened the sheet:
        // another scene or iCloud may have updated its synced command setup
        // while this form was open, and saving connection fields must retain it.
        var host = editing.flatMap { store.host(id: $0.id) }
            ?? editing
            ?? Host(name: "", hostname: "", username: "")
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        host.name = trimmedName.isEmpty ? hostname : trimmedName
        host.hostname = hostname.trimmingCharacters(in: .whitespaces)
        host.port = Int(port) ?? 22
        host.username = username.trimmingCharacters(in: .whitespaces)
        host.authMethod = authMethod
        host.isEnabled = isEnabled
        host.useMosh = useMosh
        let serverPath = moshServerPath.trimmingCharacters(in: .whitespaces)
        host.moshServerPath = serverPath.isEmpty ? nil : serverPath
        let ports = moshPorts.trimmingCharacters(in: .whitespaces)
        host.moshPorts = ports.isEmpty ? nil : ports
        host.workingDirs = resolvedWorkingDirs
        // Same scrub the command builder applies as its last-line defense —
        // what's stored is what the parser will see. A cleared field
        // persists as empty: "apply nothing" is a choice that must survive
        // saves and sync, never bounce back to the default.
        host.newSessionTmuxConf = TmuxProbe.normalizedTmuxConf(newSessionTmuxConf) ?? ""
        // Rows with nothing to type drop out; ids survive edits so the
        // remembered-selection memory keeps pointing at the same script.
        host.sessionScripts = SessionScript.normalized(scripts.map(\.script))
        // Known agents' lists come from the editor; a newer schema's agent
        // keys pass through from the live record so this save can't drop
        // them. The normalizer applies the launch grammar's token gate.
        var launchModels = host.agentLaunchModels.filter {
            AgentKind(rawValue: $0.key) == nil
        }
        for (agentRaw, values) in resolvedLaunchModels {
            launchModels[agentRaw] = values
        }
        host.agentLaunchModels = Host.normalizedLaunchModels(launchModels)
        return host
    }

    private func save() {
        let host = formHost()

        switch authMethod {
        case .password:
            KeychainStore.set(password, for: host.id, kind: .password)
        case .privateKey:
            KeychainStore.set(privateKey, for: host.id, kind: .privateKey)
            if !passphrase.isEmpty {
                SSHKeyPassphraseSession.accept(
                    passphrase,
                    for: host.id,
                    saveToICloud: true
                )
            } else {
                SSHKeyPassphraseSession.clear(for: host.id)
            }
        }

        if editing == nil {
            store.add(host)
        } else {
            store.update(host)
        }
        clearSecretsAndDismiss()
    }

    /// AutoFill offers "Save to Passwords" from whatever text still sits in
    /// a secure field when the hosting view controller closes — so the sheet
    /// must close with every secret field empty (the Keychain already holds
    /// the secrets). Dismissal waits one runloop turn: it must not start
    /// until SwiftUI has pushed the emptied strings into the UIKit fields,
    /// or teardown snapshots the old text and the prompt fires anyway.
    private func clearSecretsAndDismiss() {
        password = ""
        privateKey = ""
        passphrase = ""
        DispatchQueue.main.async { dismiss() }
    }
}

/// A secret field with an eye toggle: bullets normally, the plain string
/// while revealed. One binding backs both, so toggling never loses what was
/// typed. The masking is drawn app-side (`MaskedSecretField`) instead of
/// `isSecureTextEntry`: modern iOS hard-wires the Passwords QuickType bar
/// and the save-to-Passwords prompt to secure entry — every content-type
/// opt-out is ignored — and one secure field marks the whole sheet as a
/// login form, dragging User and Private key into the same treatment.
/// Internal (not file-private) because BindPane's KEY PASSPHRASE field is
/// the same control under the same rules.
struct RevealableSecureField: View {
    let title: String
    let prompt: String
    @Binding var text: String

    @State private var revealed = false

    init(_ title: String, prompt: String? = nil, text: Binding<String>) {
        self.title = title
        self.prompt = prompt ?? title
        _text = text
    }

    var body: some View {
        HStack(spacing: 10) {
            MaskedSecretField(
                title: title,
                prompt: prompt,
                text: $text,
                revealed: revealed
            )
            .frame(maxWidth: .infinity)
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.ui(10, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.signal2)
            .chassisHover(2)
            .accessibilityLabel(revealed ? "Hide \(title)" : "Show \(title)")
        }
    }
}

/// UIKit-backed secret entry that never sets `isSecureTextEntry`. The field's
/// UIKit text is only ever bullets (or the revealed plain string); the real
/// secret lives in the SwiftUI binding, edited by mapping the change range
/// onto it — one bullet per Character keeps UIKit's UTF-16 ranges aligned
/// with Character indices. Copy/cut/select are refused while masked, so the
/// bullets can't be round-tripped out through the edit menu.
private struct MaskedSecretField: UIViewRepresentable {
    let title: String
    let prompt: String
    @Binding var text: String
    var revealed: Bool

    func makeUIView(context: Context) -> SecretTextField {
        let field = SecretTextField()
        field.font = .monospacedSystemFont(
            ofSize: 12 * Theme.typeScale,
            weight: .regular
        )
        field.textColor = UIColor(Theme.signal)
        field.attributedPlaceholder = NSAttributedString(
            string: prompt,
            attributes: [.foregroundColor: UIColor(Theme.signal3)]
        )
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.autocapitalizationType = .none
        field.keyboardType = .asciiCapable
        field.textContentType = UITextContentType(rawValue: "")
        field.accessibilityLabel = title
        field.delegate = context.coordinator
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged),
            for: .editingChanged
        )
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: SecretTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.revealed = revealed
        field.masksEditActions = !revealed
        let desired = revealed ? text : Self.bullets(text.count)
        // No-op while the coordinator itself just wrote this value, so the
        // caret survives ordinary typing; external writes (populate, clears,
        // the reveal toggle) repaint and drop the caret to the end.
        if field.text != desired {
            field.text = desired
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, revealed: revealed)
    }

    static func bullets(_ count: Int) -> String {
        String(repeating: "\u{2022}", count: count)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var revealed: Bool

        init(text: Binding<String>, revealed: Bool) {
            self.text = text
            self.revealed = revealed
        }

        func textField(
            _ field: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            guard !revealed else { return true }
            var chars = Array(text.wrappedValue)
            let lower = min(range.location, chars.count)
            let upper = min(range.location + range.length, chars.count)
            chars.replaceSubrange(lower..<upper, with: Array(string))
            text.wrappedValue = String(chars)
            field.text = MaskedSecretField.bullets(chars.count)
            let caret = lower + string.count
            if let position = field.position(
                from: field.beginningOfDocument,
                offset: caret
            ) {
                field.selectedTextRange = field.textRange(
                    from: position,
                    to: position
                )
            }
            return false
        }

        @objc func editingChanged(_ field: UITextField) {
            guard revealed else { return }
            text.wrappedValue = field.text ?? ""
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            return true
        }
    }
}

/// The masked half of `MaskedSecretField`: refuses selection and clipboard
/// actions while bullets are shown, since the underlying UIKit text is not
/// the secret but leaking even its shape through the edit menu is wrong.
final class SecretTextField: UITextField {
    var masksEditActions = true

    override func canPerformAction(
        _ action: Selector,
        withSender sender: Any?
    ) -> Bool {
        if masksEditActions {
            switch action {
            case #selector(copy(_:)),
                 #selector(cut(_:)),
                 #selector(select(_:)),
                 #selector(selectAll(_:)):
                return false
            default:
                break
            }
        }
        return super.canPerformAction(action, withSender: sender)
    }
}

#if DEBUG
#Preview("Revealable secure field") {
    TallyFormField("Password") {
        RevealableSecureField(
            "Password",
            text: .constant("correct horse battery staple")
        )
    }
    .padding()
    .frame(width: 420)
    .background(Theme.chassis)
}
#endif
