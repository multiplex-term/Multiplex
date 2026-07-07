import SwiftUI

/// Add or edit a host. Secrets go straight to the Keychain on save.
struct AddHostSheet: View {
    @Environment(HostStore.self) private var store
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
                        SecureField("Password", text: $password)
                    case .privateKey:
                        TextField("Private key", text: $privateKey, axis: .vertical)
                            .font(.mono(12))
                            .lineLimit(4...8)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Passphrase (optional)", text: $passphrase)
                    }
                }

                if authMethod == .privateKey {
                    Section {
                        Text("Paste an OpenSSH private key (BEGIN OPENSSH PRIVATE KEY). It is stored in the Keychain, never in a file.")
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
    }

    private var isValid: Bool {
        !hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(port) != nil
    }

    private func populate() {
        guard let host = editing else { return }
        name = host.name
        hostname = host.hostname
        port = String(host.port)
        username = host.username
        authMethod = host.authMethod
        password = KeychainStore.get(for: host.id, kind: .password) ?? ""
        privateKey = KeychainStore.get(for: host.id, kind: .privateKey) ?? ""
        passphrase = KeychainStore.get(for: host.id, kind: .keyPassphrase) ?? ""
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var host = editing ?? Host(name: "", hostname: "", username: "")
        host.name = trimmedName.isEmpty ? hostname : trimmedName
        host.hostname = hostname.trimmingCharacters(in: .whitespaces)
        host.port = Int(port) ?? 22
        host.username = username.trimmingCharacters(in: .whitespaces)
        host.authMethod = authMethod

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
