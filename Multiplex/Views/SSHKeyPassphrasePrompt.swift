import SwiftUI

/// System credential prompt shared by the deck and terminal scenes. The two
/// affirmative actions make persistence explicit: Connect Once is memory-only
/// for this app run; Save & Connect writes the synchronizable Keychain item.
struct SSHKeyPassphrasePromptModifier: ViewModifier {
    var challenge: SSHKeyPassphraseChallenge?
    var onSubmit: (SSHKeyPassphraseChallenge, String, Bool) -> Void
    var onCancel: (SSHKeyPassphraseChallenge) -> Void

    @State private var passphrase = ""
    @State private var isPresented = false
    @State private var lastPresentedID: UUID?

    func body(content: Content) -> some View {
        content
            .onChange(of: challenge?.id, initial: true) { _, challengeID in
                guard let challengeID else {
                    isPresented = false
                    return
                }
                guard challengeID != lastPresentedID else { return }
                lastPresentedID = challengeID
                passphrase = ""
                isPresented = true
            }
            .alert(
                "Unlock SSH Key",
                isPresented: $isPresented,
                presenting: challenge
            ) { challenge in
                // The empty content type is the opt-out from AutoFill's
                // stored-Passwords link — a credential type here invites the
                // Passwords bar and the "Save to Passwords?" sheet for an SSH
                // secret whose persistence is this prompt's own explicit
                // Save & Connect choice.
                SecureField("Key passphrase", text: $passphrase)
                    .textContentType(.init(rawValue: ""))
                // State empties before the callbacks run: the system's
                // save-to-Passwords heuristic reads whatever text remains
                // in the field as the alert tears down.
                Button("Connect Once") {
                    let entered = passphrase
                    passphrase = ""
                    onSubmit(challenge, entered, false)
                }
                .disabled(passphrase.isEmpty)
                Button("Save & Connect") {
                    let entered = passphrase
                    passphrase = ""
                    onSubmit(challenge, entered, true)
                }
                .disabled(passphrase.isEmpty)
                Button("Cancel", role: .cancel) {
                    passphrase = ""
                    onCancel(challenge)
                }
            } message: { challenge in
                switch challenge.reason {
                case .required:
                    Text("The private key for “\(challenge.hostName)” is encrypted. Connect Once keeps the passphrase until Multiplex closes. Save & Connect stores it in iCloud Keychain for your other devices.")
                case .incorrect:
                    Text("That passphrase didn't unlock the private key for “\(challenge.hostName)”. Try again. Save & Connect replaces the copy in iCloud Keychain.")
                }
            }
    }
}

extension View {
    func sshKeyPassphrasePrompt(
        challenge: SSHKeyPassphraseChallenge?,
        onSubmit: @escaping (SSHKeyPassphraseChallenge, String, Bool) -> Void,
        onCancel: @escaping (SSHKeyPassphraseChallenge) -> Void = { _ in }
    ) -> some View {
        modifier(SSHKeyPassphrasePromptModifier(
            challenge: challenge,
            onSubmit: onSubmit,
            onCancel: onCancel
        ))
    }
}
