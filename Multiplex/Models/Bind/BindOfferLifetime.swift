import Foundation

/// How long a heard bind offer can still be worth showing.
///
/// The normal ways `mpx bind` stops waiting — Ctrl-C, expiry, a decline, a
/// lockout, a successful enrollment — all unregister the Bonjour service, so
/// the browser withdraws it and the row goes on its own. That is the real
/// mechanism and this is not a substitute for it.
///
/// What it covers is the case no signal handler can: a machine killed
/// outright, crashed, or put to sleep never sends a goodbye, and its record
/// then sits in every browsing device's cache — measured here still being
/// advertised half an hour later, with no process behind it. Such a row is a
/// lie the browser cannot detect.
///
/// A network probe seemed like the answer and was tried first. It was
/// abandoned: a Bonjour name resolves to every address the machine ever
/// answered on (including vmnet aliases and, observed here, a `.0` network
/// address), so a connect to a perfectly live offer intermittently timed out
/// and removed it — twice in four runs. Deleting a live machine is far worse
/// than showing a dead one, because a removed row does not come back.
///
/// So the rule is arithmetic instead of network: **the CLI clamps
/// `--expires` to 600 s, so no offer can outlive that.** A row first heard
/// longer ago than the cap plus a margin cannot possibly still be bindable,
/// whatever the cache says — and this can never drop a live one.
enum BindOfferLifetime {
    /// `mpx bind` computes `expires.min(600).max(10)`, in seconds, starting
    /// before it announces. Kept in step with the CLI deliberately; if that
    /// cap ever rises, the offer's own expiry has to move into the TXT
    /// record rather than being inferred here.
    static let maximumOffer: TimeInterval = 600

    /// Slack for discovery lag and clock skew — the point is to never expire
    /// something still valid, so the margin is generous.
    static let margin: TimeInterval = 60

    static func isStale(firstHeard: Date, now: Date) -> Bool {
        now.timeIntervalSince(firstHeard) > maximumOffer + margin
    }
}
