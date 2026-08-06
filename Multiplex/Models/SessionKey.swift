import Foundation

/// A session's identity on one host. A name alone stopped being unique the
/// moment a host could show tmux and herdr sessions together: both
/// multiplexers happily hold a `main`, and every per-session map the deck
/// keeps — miniatures, attention, tile order, capture tails — was keyed by
/// that name. One of them, `SessionOrdering.ordered`, builds a
/// `Dictionary(uniqueKeysWithValues:)` and so **traps at runtime** on the
/// collision rather than merely losing data.
///
/// Deliberately not `Identifiable`-shaped sugar over a string: the two
/// halves stay addressable because callers routinely have one and need the
/// other (a widget URL carries a name; a tile carries a backend).
struct SessionKey: Hashable, Codable, Sendable {
    var backend: Host.SessionBackend
    var name: String

    init(backend: Host.SessionBackend, name: String) {
        self.backend = backend
        self.name = name
    }

    /// The separator is a colon because no backend raw value contains one
    /// and herdr's own session-name grammar (`bakeableSessionName`) forbids
    /// it outright, so `storageKey` round-trips for every name either
    /// backend can actually produce. tmux is laxer — a name may contain a
    /// colon — which is why parsing splits on the FIRST separator only and
    /// hands everything after it to the name.
    private static let separator: Character = ":"

    /// Codable dictionary keys, the App Group projection, and the
    /// device-local order list all stay `[String: …]`, so files written
    /// before this type decode without a migration pass: a bare name is a
    /// tmux key, which is what every legacy file holds.
    var storageKey: String {
        "\(backend.rawValue)\(Self.separator)\(name)"
    }

    /// Reads a `storageKey`, and legacy bare names as tmux.
    ///
    /// A prefix is honored only when it is a backend this build knows. That
    /// matters both directions: a tmux session genuinely named `herdr:x`
    /// would mis-key (accepted — the alternative is failing to read every
    /// legacy file), while a key written by a schema with a third backend
    /// reads as a tmux session called `newthing:x` instead of vanishing.
    /// Losing a tile's saved position is recoverable; dropping the record is
    /// not.
    init(storageKey: String) {
        guard let index = storageKey.firstIndex(of: Self.separator),
              let backend = Host.SessionBackend(
                  rawValue: String(storageKey[..<index]))
        else {
            self.init(backend: .tmux, name: storageKey)
            return
        }
        self.init(
            backend: backend,
            name: String(storageKey[storageKey.index(after: index)...])
        )
    }
}

extension SessionKey: CustomStringConvertible {
    var description: String { storageKey }
}

extension Dictionary where Key == SessionKey {
    /// Persisted form of a per-session map. Only used on the way to disk or
    /// the App Group — in memory these maps stay `SessionKey`-keyed so the
    /// collision cannot come back.
    var storageKeyed: [String: Value] {
        // `storageKey` is injective over `SessionKey`, so the unique-keys
        // initializer cannot trap here.
        [String: Value](uniqueKeysWithValues: map { ($0.key.storageKey, $0.value) })
    }
}

extension Dictionary where Key == String {
    /// Reads a persisted per-session map back. Duplicate keys cannot occur:
    /// `storageKey` is injective over `SessionKey`, and legacy files hold
    /// bare names that all resolve to distinct tmux keys.
    var sessionKeyed: [SessionKey: Value] {
        [SessionKey: Value](
            map { (SessionKey(storageKey: $0.key), $0.value) },
            uniquingKeysWith: { _, later in later }
        )
    }

    /// Stamps a backend onto a name-keyed map. Probe parsers answer for ONE
    /// backend, so their maps are name-keyed; anything that merges backends
    /// is `SessionKey`-keyed — this is the seam between the two spaces, and
    /// the pre-mixed snapshot migration's too.
    ///
    /// Names are unique within one backend's answer, so the collision
    /// policy is only a formality; last-writer matches `sessionKeyed`.
    func keyed(backend: Host.SessionBackend) -> [SessionKey: Value] {
        [SessionKey: Value](
            map { (SessionKey(backend: backend, name: $0.key), $0.value) },
            uniquingKeysWith: { _, later in later }
        )
    }
}
