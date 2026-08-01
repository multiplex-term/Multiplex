import Foundation

/// A pressed KEYCHAIN LOCKED status, snapshotted at tap time so a background
/// probe clearing the live notice cannot yank a guide out from under the user.
/// Shared by the deck rail and terminal status chip; it carries no UI types.
struct KeychainTipRequest: Identifiable {
    let host: Host
    let sessionNames: [String]

    var id: UUID { host.id }
}
