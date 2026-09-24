import Foundation

/// Which bound hosts still carry the key that travelled inside an offline
/// payload. Device-local bookkeeping (the key is this device's credential,
/// so the retry belongs here, not in the synced record) plus the pure shell
/// command that swaps it out host-side.
struct BindRotationStore {
    struct Request: Equatable, Codable {
        /// The transported key's public base64 field — the exact-match
        /// handle the removal greps by, so no other line can be touched.
        var transportedPublicB64: String?
        /// A non-default authorized_keys the CLI enrolled into
        /// (`mpx bind --authorized-keys`); nil means ~/.ssh/authorized_keys.
        var authorizedKeysPath: String?
    }

    private static let key = "MultiplexBindPendingRotations"

    var pendingHostIDs: [UUID] {
        Array(load().keys).sorted { $0.uuidString < $1.uuidString }
    }

    func request(for hostID: UUID) -> Request? {
        load()[hostID]
    }

    func record(_ request: Request, for hostID: UUID) {
        var map = load()
        map[hostID] = request
        save(map)
    }

    func clear(for hostID: UUID) {
        var map = load()
        guard map.removeValue(forKey: hostID) != nil else { return }
        save(map)
    }

    private func load() -> [UUID: Request] {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let raw = try? JSONDecoder().decode([String: Request].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    private func save(_ map: [UUID: Request]) {
        guard !map.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.key)
            return
        }
        let raw = Dictionary(uniqueKeysWithValues: map.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    /// Enrolls `addingLine` and removes every line containing the
    /// transported key's base64 field, in one POSIX-sh round trip.
    ///
    /// Three details are load-bearing: the new key is appended *before* the
    /// old one is dropped (a failure mid-way must never leave the host with
    /// no Multiplex key at all); the rewrite is `cat > "$f"` rather than
    /// `mv`, so authorized_keys keeps its inode, owner, and mode; and the
    /// removal is `grep -F` on the key material, never on the comment — a
    /// user may have edited the comment, but the key bytes are the identity.
    static func rotateCommand(
        authorizedKeysPath: String?,
        removingPublicB64: String,
        addingLine: String
    ) -> String {
        let configured = authorizedKeysPath?.trimmingCharacters(in: .whitespaces) ?? ""
        // The default path has to expand $HOME, so it is double-quoted; a
        // configured path is untrusted text and is always single-quoted.
        let quotedTarget = configured.isEmpty
            ? "\"$HOME/.ssh/authorized_keys\""
            : configured.shellQuoted
        return """
        f=\(quotedTarget); d=$(dirname "$f"); \
        mkdir -p "$d" 2>/dev/null; chmod 700 "$d" 2>/dev/null; \
        touch "$f" 2>/dev/null; chmod 600 "$f" 2>/dev/null; \
        printf '%s\\n' \(addingLine.shellQuoted) >> "$f" || exit 1; \
        t="$f.mpx-rotate"; \
        grep -v -F \(removingPublicB64.shellQuoted) "$f" > "$t" 2>/dev/null; \
        if [ -s "$t" ]; then cat "$t" > "$f"; fi; \
        rm -f "$t"; \
        echo MPX_ROTATE_OK
        """
    }
}
