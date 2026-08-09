# mosh transport

Load-bearing decisions split from AGENTS.md.

- **mosh is a second transport; SSH stays the control plane**
  (`Services/Mosh/`, `Host.useMosh`): probing, capture-pane, SFTP, and
  the bootstrap all ride `SSHConnection.exec`; only the interactive
  stream moves to UDP. The bootstrap resolves the hostname and **pins the
  SSH to the literal IP** so `mosh-server -s` binds the address the UDP
  session dials; `route.moshRemoteCommand` drops the `exec` prefix
  (mosh-server execvps its argv, no shell). The wire stack is
  **clean-room from protocol facts (mosh is GPLv3 — never translate its
  source)**, pure + unit-tested: AES-128-OCB3 (RFC 7253 vectors, 12-byte
  nonce = `0x00000000` ‖ BE64(dir<<63|seq)), zlib-wrapped DEFLATE, a
  minimal proto2 codec, a 10-byte-header fragmenter, and a faithful
  TransportSender/receiver port (paced diffs, prospective resend,
  heartbeats, the `new_num = UInt64.max` shutdown). **Never let a sent
  state number reach `.max` on a non-shutdown path** — the shutdown
  override must win before `last.num + 1` overflows (regression-tested;
  the interop harness caught it). Receiver is head-state-only: diff from
  head applies, diff from state 0 applies after a reset, anything else
  drops (server re-bases within an RTO); a desync valve turns pathology
  into a reconnect. `MoshSession` re-creates the socket on
  failure/better-path/silence (mosh's port hop + roaming); `.active`
  nudges a heartbeat. **The two tmux split rows use the SSH control plane on
  every transport** — the tab's live control connection on SSH, a short-lived
  one on mosh — resolving tmux's active pane id before `split-window`: iPad can
  intermittently lose Ctrl-B from the stock-prefix burst and type the shifted
  `%` into the pane on either transport. A direct command MUST outrank the
  split's documented `bindingInput`; `-c '#{pane_current_path}'` keeps the
  binding's working-directory semantics. Other non-destructive shortcut rows
  still ride the ordered terminal pump. mosh tabs have no exec surface:
  FILE is hidden and pane drops are refused with a message, never silently
  dropped.
