#!/bin/bash
# Local verification harness for Multiplex.
#
# Runs a user-mode sshd on 127.0.0.1:2222 (pubkey-only, current user, own
# authorized_keys — never touches ~/.ssh) and seeds demo tmux sessions, so the
# app in the visionOS/iPad simulator can connect and attach for real.
#
#   ./harness.sh start   generate keys, start sshd, write app seed JSON
#   ./harness.sh demo    create demo tmux sessions (main, scratch, deploy)
#   ./harness.sh turn    fake agent turn in agent:cc (busy title → idle);
#                        optional seconds arg, default 8
#   ./harness.sh ask     fake permission dialog in agent:cc (needs-you state)
#   ./harness.sh stop    stop sshd and kill demo sessions
#
# Everything lives in ./state/ (gitignored).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="$HERE/state"
SSHD=/usr/sbin/sshd
PORT=2222

start() {
    mkdir -p "$STATE"
    chmod 700 "$STATE"

    [ -f "$STATE/host_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C multiplex-dev-host -f "$STATE/host_ed25519"
    [ -f "$STATE/client_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C multiplex-dev-client -f "$STATE/client_ed25519"
    cp "$STATE/client_ed25519.pub" "$STATE/authorized_keys"
    chmod 600 "$STATE/authorized_keys"

    cat > "$STATE/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
ListenAddress ::1
HostKey $STATE/host_ed25519
PidFile $STATE/sshd.pid
AuthorizedKeysFile $STATE/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
LogLevel VERBOSE
Subsystem sftp internal-sftp
EOF

    if [ -f "$STATE/sshd.pid" ] && kill -0 "$(cat "$STATE/sshd.pid")" 2>/dev/null; then
        echo "sshd already running (pid $(cat "$STATE/sshd.pid"))"
    else
        "$SSHD" -f "$STATE/sshd_config" -E "$STATE/sshd.log"
        sleep 0.5
        echo "sshd listening on 127.0.0.1 + [::1]:$PORT (pid $(cat "$STATE/sshd.pid"))"
    fi

    # Seed file the app imports in DEBUG builds via MULTIPLEX_SEED_HOST.
    python3 - "$STATE" "$USER" "$PORT" <<'PY'
import json, sys, pathlib
state, user, port = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
seed = {
    "name": "devbox",
    "hostname": "127.0.0.1",
    "port": port,
    "username": user,
    "privateKey": (state / "client_ed25519").read_text(),
    "useMosh": False,
}
(state / "seed.json").write_text(json.dumps(seed, indent=2))
# Same host (same name -> same UUID on re-import), mosh transport. Point
# MULTIPLEX_SEED_HOST here to flip devbox to mosh; seed.json flips it back.
(state / "seed-mosh.json").write_text(json.dumps(dict(seed, useMosh=True), indent=2))
(state / "seed-mosh-v6.json").write_text(json.dumps(dict(seed, hostname="::1", useMosh=True), indent=2))
print(f"wrote {state / 'seed.json'} (+ seed-mosh.json, seed-mosh-v6.json)")
PY
}

demo() {
    local TMUX_BIN
    TMUX_BIN="$(command -v tmux)"

    "$TMUX_BIN" kill-session -t main 2>/dev/null || true
    "$TMUX_BIN" kill-session -t scratch 2>/dev/null || true
    "$TMUX_BIN" kill-session -t deploy 2>/dev/null || true
    "$TMUX_BIN" kill-session -t agent 2>/dev/null || true

    "$TMUX_BIN" new-session -d -s main -n editor
    "$TMUX_BIN" new-window -t main:1 -n server \
        'i=0; while true; do i=$((i+1)); printf "%s  api  GET /v1/sessions 200  %dms\n" "$(date +%T)" $((RANDOM % 90 + 10)); sleep 2; done'
    "$TMUX_BIN" new-window -t main:2 -n logs
    "$TMUX_BIN" select-window -t main:1

    "$TMUX_BIN" new-session -d -s scratch

    "$TMUX_BIN" new-session -d -s deploy -n release
    "$TMUX_BIN" new-window -t deploy:1 -n watch
    "$TMUX_BIN" select-window -t deploy:0

    # Agent-helper fakes (macOS can't fake a comm, so each window exercises
    # a different real detection path — see local-plan/agent-harness-helpers.md):
    #   cc: OSC pane title "✳ Claude Code" (the title signal)
    #   cx: argv[0] "codex" via exec -a   (the ps-tree signal)
    # Both run `cat`, which echoes injected bytes — so capture-pane shows
    # what a helper chip typed.
    "$TMUX_BIN" new-session -d -s agent -n cc \
        'printf "\033]2;✳ Claude Code\033\\"; exec -a claude cat'
    "$TMUX_BIN" new-window -t agent:1 -n cx 'exec -a codex cat'
    "$TMUX_BIN" select-window -t agent:0

    "$TMUX_BIN" list-sessions
}

# Drive the fake cc window through one agent turn: Braille-spinner pane
# title while "working", ✳ title when done — the exact signal
# AgentAttention keys on (local-plan/agent-attention.md). Detection holds
# throughout via the ps-tree walk (argv[0] "claude" from exec -a). Watch
# the wall flip CLAUDE·RUNNING → a "finished" banner if the deck is open
# and the session unfocused.
turn() {
    local secs="${1:-8}"
    # A real TUI redraws over its dialog; cat can't — wash a parked `ask`
    # off the grid first (the escape echoes through cat into the terminal).
    tmux send-keys -t agent:0.0 -l "$(printf '\033[2J\033[H')"
    tmux send-keys -t agent:0.0 Enter
    tmux select-pane -t agent:0.0 -T '⠐ Scripted harness task'
    tmux send-keys -t agent:0.0 -l '✻ Working… (harness turn)'
    tmux send-keys -t agent:0.0 Enter
    echo "agent:cc busy for ${secs}s…"
    sleep "$secs"
    tmux send-keys -t agent:0.0 -l 'done.'
    tmux send-keys -t agent:0.0 Enter
    tmux select-pane -t agent:0.0 -T '✳ Scripted harness task'
    echo "turn ended (title ⠐ → ✳)"
}

# Park the fake cc window on a permission dialog: busy title + the
# option-list/hint shape the question detector matches. `turn` clears it.
ask() {
    tmux select-pane -t agent:0.0 -T '⠂ Scripted harness task'
    while IFS= read -r line; do
        tmux send-keys -t agent:0.0 -l "$line"
        tmux send-keys -t agent:0.0 Enter
    done <<'EOF'
 Bash command
   touch probe.txt
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow
   3. No
EOF
    echo "agent:cc parked on a permission dialog (NEEDS YOU); run '$0 turn' to clear"
}

stop() {
    if [ -f "$STATE/sshd.pid" ]; then
        kill "$(cat "$STATE/sshd.pid")" 2>/dev/null || true
        rm -f "$STATE/sshd.pid"
        echo "sshd stopped"
    fi
    for s in main scratch deploy agent; do
        tmux kill-session -t "$s" 2>/dev/null || true
    done
}

case "${1:-}" in
    start) start ;;
    demo) demo ;;
    turn) shift; turn "$@" ;;
    ask) ask ;;
    stop) stop ;;
    *) echo "usage: $0 start|demo|turn [secs]|ask|stop" >&2; exit 1 ;;
esac
