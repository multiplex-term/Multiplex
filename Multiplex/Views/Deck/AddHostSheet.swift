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
    /// string) so editing a path in place doesn't tear down the row's
    /// text field, and reorders/deletes track rows, not values.
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
            Form {
                Section("Host") {
                    TextField("Name", text: $name, prompt: Text("devbox"))
                    TextField("Address", text: $hostname, prompt: Text("10.0.1.12 or host.example.com"))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("User", text: $username, prompt: Text("root"))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Sign in") {
                    Picker("Method", selection: $authMethod) {
                        ForEach(Host.AuthMethod.allCases) { method in
                            Text(method.label).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch authMethod {
                    case .password:
                        RevealableSecureField("Password", text: $password)
                    case .privateKey:
                        TextField("Private key", text: $privateKey, axis: .vertical)
                            .font(.mono(12))
                            .lineLimit(4...8)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        RevealableSecureField("Passphrase (optional)", text: $passphrase)
                    }
                }

                if authMethod == .privateKey {
                    Section {
                        Text("Paste an OpenSSH private key (BEGIN OPENSSH PRIVATE KEY). It is stored in the Keychain, never in a file.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                testSection

                workingDirsSection

                Section("Transport") {
                    Toggle(isOn: moshToggle) {
                        HStack {
                            Text("Connect with mosh")
                            if moshRequiresPro {
                                Spacer()
                                ChassisBadge("PRO", prominent: true)
                            }
                        }
                    }
                    if useMosh {
                        TextField("mosh-server path", text: $moshServerPath, prompt: Text("mosh-server"))
                            .font(.mono(12))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("UDP port or range", text: $moshPorts, prompt: Text("60000:61000"))
                            .font(.mono(12))
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }

                if useMosh {
                    Section {
                        Text("Terminals attach over UDP through mosh-server — sessions ride out roaming and sleep. Sign-in above authenticates the SSH bootstrap; the deck's session probe stays on SSH.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(editing == nil ? "Add Host" : "Edit Host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!isValid)
                }
            }
        }
        .onAppear(perform: populate)
        .sheet(isPresented: $showingPaywall) { ProPaywallView() }
        // Any edit that could change the outcome retires the shown result —
        // a stale PASSED next to a new address would vouch for the wrong host.
        .onChange(of: testFingerprint) { testState = .idle }
    }

    // MARK: Test connection

    private var testSection: some View {
        Section {
            Button(action: runTest) {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if testState == .running {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(!isValid || testState == .running)

            switch testState {
            case .idle, .running:
                EmptyView()
            case .passed(let headline, let warnings):
                Label {
                    Text(headline)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.ok)
                }
                .font(.callout)
                ForEach(warnings, id: \.self) { warning in
                    Label {
                        Text(warning)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.caution)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.caution)
                }
                .font(.callout)
            }
        } footer: {
            Text(useMosh
                ? "Signs in over SSH with the settings above (mosh uses SSH to start mosh-server), then looks for tmux and mosh-server on the host."
                : "Signs in over SSH with the settings above, then looks for tmux on the host.")
        }
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
        Section {
            ForEach($workingDirs) { $dir in
                TextField("Directory", text: $dir.path)
                    .font(.mono(12))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .onMove { workingDirs.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { workingDirs.remove(atOffsets: $0) }
            HStack {
                TextField("Add directory", text: $newWorkingDir, prompt: Text("~/projects/app"))
                    .font(.mono(12))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(addWorkingDir)
                Button(action: addWorkingDir) {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(newWorkingDir.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Add working directory")
            }
        } header: {
            HStack {
                Text("Working directories")
                Spacer()
                if workingDirs.count > 1 {
                    EditButton().font(.footnote)
                }
            }
        } footer: {
            Text("New sessions start in the first directory (or your home directory when the list is empty); the rest are choices in the New Session prompt. Edit to reorder.")
        }
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
        var host = editing ?? Host(name: "", hostname: "", username: "")
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
    @Binding var text: String

    @State private var revealed = false

    init(_ title: String, text: Binding<String>) {
        self.title = title
        _text = text
    }

    var body: some View {
        HStack {
            if revealed {
                TextField(title, text: $text)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
            } else {
                SecureField(title, text: $text)
            }
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(revealed ? "Hide \(title)" : "Show \(title)")
        }
    }
}
