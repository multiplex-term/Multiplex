import SwiftUI

/// Add or edit a host. Secrets go straight to the Keychain on save.
struct AddHostSheet: View {
    @Environment(HostStore.self) private var store
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.dismiss) private var dismiss

    var editing: Host?

    @State private var name = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var authMethod: Host.AuthMethod = .password
    @State private var password = ""
    @State private var privateKey = ""
    @State private var passphrase = ""
    @State private var useMosh = false
    @State private var moshServerPath = ""
    @State private var moshPorts = ""
    @State private var workingDirs: [WorkingDir] = []
    @State private var newWorkingDir = ""
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

    private enum TestState: Equatable {
        case idle
        case running
        case passed(headline: String, warnings: [String])
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    hostSection
                    credentialsSection
                    testSection
                    workingDirsSection
                    transportSection
                }
                .frame(maxWidth: 680)
                .padding(18)
                .frame(maxWidth: .infinity)
            }
            .background(sheetGround.ignoresSafeArea())
            .navigationTitle(editing == nil ? "Add Host" : "Host Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!isValid)
                }
            }
            #if !os(visionOS)
            .toolbarBackground(Theme.chassis, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
        }
        .onAppear(perform: populate)
        .sheet(isPresented: $showingPaywall) { ProPaywallView() }
        // Any edit that could change the outcome retires the shown result —
        // a stale PASSED next to a new address would vouch for the wrong host.
        .onChange(of: testFingerprint) { testState = .idle }
    }

    @ViewBuilder
    private var sheetGround: some View {
        #if os(visionOS)
        Color.clear
        #else
        Theme.chassis
        #endif
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
            }
        }
    }

    private var credentialsSection: some View {
        TallyFormSection("Credentials", detail: credentialsDetail) {
            TallyFormRow {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sign in with")
                        .font(.system(size: 10, weight: .semibold))
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
                    RevealableSecureField("Password", text: $password)
                }
            case .privateKey:
                TallyFormField("Private key") {
                    TextField(
                        "BEGIN OPENSSH PRIVATE KEY",
                        text: $privateKey,
                        axis: .vertical
                    )
                    .lineLimit(4...8)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
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
            "Paste an OpenSSH private key. The key and optional passphrase are stored in iCloud Keychain, never in files."
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
                                .font(.system(size: 10))
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
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.signal)
                        }
                        ForEach(warnings, id: \.self) { warning in
                            HStack(alignment: .top, spacing: 10) {
                                TallyLamp(caption: "CHECK", color: Theme.caution)
                                Text(warning)
                                    .font(.system(size: 10))
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
                            .font(.system(size: 11))
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
                        .font(.system(size: 10, weight: .semibold))
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
                .font(.system(size: 9, weight: .semibold))
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

    private func populate() {
        guard let host = editing else { return }
        name = host.name
        hostname = host.hostname
        port = String(host.port)
        username = host.username
        authMethod = host.authMethod
        useMosh = host.useMosh
        moshServerPath = host.moshServerPath ?? ""
        moshPorts = host.moshPorts ?? ""
        workingDirs = host.workingDirs.map { WorkingDir(path: $0) }
        password = KeychainStore.get(for: host.id, kind: .password) ?? ""
        privateKey = KeychainStore.get(for: host.id, kind: .privateKey) ?? ""
        passphrase = KeychainStore.get(for: host.id, kind: .keyPassphrase) ?? ""
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
        host.useMosh = useMosh
        let serverPath = moshServerPath.trimmingCharacters(in: .whitespaces)
        host.moshServerPath = serverPath.isEmpty ? nil : serverPath
        let ports = moshPorts.trimmingCharacters(in: .whitespaces)
        host.moshPorts = ports.isEmpty ? nil : ports
        host.workingDirs = resolvedWorkingDirs
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
                KeychainStore.set(passphrase, for: host.id, kind: .keyPassphrase)
            }
        }

        if editing == nil {
            store.add(host)
        } else {
            store.update(host)
        }
        dismiss()
    }
}

/// A secret field with an eye toggle: SecureField normally, a plain
/// TextField while revealed. One binding backs both, so toggling never
/// loses what was typed.
private struct RevealableSecureField: View {
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
            if revealed {
                TextField(prompt, text: $text)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
            } else {
                SecureField(prompt, text: $text)
            }
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.signal2)
            .chassisHover(2)
            .accessibilityLabel(revealed ? "Hide \(title)" : "Show \(title)")
        }
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
