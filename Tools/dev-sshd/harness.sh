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
#   ./harness.sh herdr   start a real herdr server (brew install herdr) and
#                        seed demo workspaces with deterministic agent
#                        states via `pane report-agent` — the herdr-mode
#                        analog of `demo`; point the app at
#                        state/seed-herdr.json
#   ./harness.sh bind    run the real `mpx bind` against this sshd with a
#                        pinned token/PIN, so the app's bind flow can be
#                        driven headlessly (MULTIPLEX_AUTO_BIND /
#                        MULTIPLEX_BIND_AUTOPIN); prints the payload URL
#   ./harness.sh stop    stop sshd, kill demo sessions, retire herdr fakes
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
    # `mpx bind --hostkeys-dir` looks for sshd's own naming, so publish the
    # harness host key under that name too — the bind flow then pins a real
    # fingerprint belonging to this sshd.
    cp "$STATE/host_ed25519.pub" "$STATE/ssh_host_ed25519_key.pub"

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
# Same host again, herdr backend — pair with `./harness.sh herdr`.
(state / "seed-herdr.json").write_text(json.dumps(dict(seed, sessionBackend="herdr"), indent=2))
print(f"wrote {state / 'seed.json'} (+ seed-mosh.json, seed-mosh-v6.json, seed-herdr.json)")
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
    #   pi: OSC pane title "π - harness" + argv[0] "pi"
    # All run `cat`, which echoes injected bytes — so capture-pane shows
    # what a helper chip typed.
    "$TMUX_BIN" new-session -d -s agent -n cc \
        'printf "\033]2;✳ Claude Code\033\\"; exec -a claude cat'
    "$TMUX_BIN" new-window -t agent:1 -n cx 'exec -a codex cat'
    "$TMUX_BIN" new-window -t agent:2 -n pi \
        'printf "\033]2;π - harness\033\\"; exec -a pi cat'
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

# Seed the herdr-mode analog of `demo`: a real herdr server (the same one
# the app's probe reaches over SSH — the CLI resolves the default socket,
# so a scratch socket would be invisible to the app) plus demo workspaces
# whose agent states are reported through `pane report-agent`, herdr's own
# integration door — deterministic, unlike OSC-title fakes. Everything the
# harness creates is recorded in state/herdr-workspaces so `stop` retires
# exactly those and never the developer's own workspaces.
#
# Facts this leans on (herdr 0.7.5 / protocol 17, verified 2026-08-01):
# reportable states are idle|working|blocked|unknown; `done` is derived
# server-side from a working → idle report; kinds canonicalize
# (claude-code → claude).
herdr_demo() {
    command -v herdr >/dev/null 2>&1 || {
        echo "herdr not installed — brew install herdr" >&2; exit 1
    }
    mkdir -p "$STATE"

    if ! herdr status --json 2>/dev/null | grep -q '"running":true'; then
        nohup herdr server > "$STATE/herdr-server.log" 2>&1 &
        echo $! > "$STATE/herdr-server.pid"
        for _ in $(seq 1 25); do
            herdr status --json 2>/dev/null | grep -q '"running":true' && break
            sleep 0.2
        done
        herdr status --json 2>/dev/null | grep -q '"running":true' || {
            echo "herdr server failed to start — see $STATE/herdr-server.log" >&2
            exit 1
        }
        echo "herdr server started (pid $(cat "$STATE/herdr-server.pid"))"
    fi

    # Re-runs recreate the demo topology from scratch.
    if [ -f "$STATE/herdr-workspaces" ]; then
        while IFS= read -r ws; do
            herdr workspace close "$ws" >/dev/null 2>&1 || true
        done < "$STATE/herdr-workspaces"
        : > "$STATE/herdr-workspaces"
    fi

    # workspace create prints a JSON envelope; keep the ids for cleanup and
    # the root pane ids for the agent reports.
    python3 - "$STATE" <<'PY'
import json, pathlib, subprocess, sys
state = pathlib.Path(sys.argv[1])

def create(label, cwd):
    out = subprocess.run(
        ["herdr", "workspace", "create", "--cwd", cwd, "--label", label],
        capture_output=True, text=True, check=True).stdout
    result = json.loads(out)["result"]
    return result["workspace"]["workspace_id"], result["root_pane"]["pane_id"]

def report(pane, agent, status, extra=None):
    subprocess.run(
        ["herdr", "pane", "report-agent", pane,
         "--source", "multiplex-harness", "--agent", agent, "--state", status]
        + (extra or []),
        check=True)

ids = []
web_ws, web_pane = create("web", "/tmp")
ids.append(web_ws)
report(web_pane, "claude", "working")

api_ws, api_pane = create("api", "/tmp")
ids.append(api_ws)
report(api_pane, "codex", "blocked",
       ["--message", "Allow command: npm run deploy?"])

scratch_ws, _ = create("scratch", "/tmp")
ids.append(scratch_ws)  # no agent — a plain shell workspace

# pi rides working -> idle so the server derives `done` (turn ended).
pi_ws, pi_pane = create("pi-done", "/tmp")
ids.append(pi_ws)
report(pi_pane, "pi", "working")
report(pi_pane, "pi", "idle")

(state / "herdr-workspaces").write_text("\n".join(ids) + "\n")
print("herdr demo workspaces:", ", ".join(ids))
PY
    herdr workspace list
    echo "point the app at state/seed-herdr.json (run '$0 start' if absent)"
}

stop() {
    # Retire only the workspaces this harness created; stop the server only
    # if this harness started it. A developer's own herdr stays untouched.
    if [ -f "$STATE/herdr-workspaces" ]; then
        while IFS= read -r ws; do
            herdr workspace close "$ws" >/dev/null 2>&1 || true
        done < "$STATE/herdr-workspaces"
        rm -f "$STATE/herdr-workspaces"
    fi
    if [ -f "$STATE/herdr-server.pid" ]; then
        herdr server stop >/dev/null 2>&1 || true
        kill "$(cat "$STATE/herdr-server.pid")" 2>/dev/null || true
        rm -f "$STATE/herdr-server.pid"
    fi
    if [ -f "$STATE/bind.pid" ]; then
        kill "$(cat "$STATE/bind.pid")" 2>/dev/null || true
        rm -f "$STATE/bind.pid"
    fi
    if [ -f "$STATE/sshd.pid" ]; then
        kill "$(cat "$STATE/sshd.pid")" 2>/dev/null || true
        rm -f "$STATE/sshd.pid"
    fi
    # The master only listens; established connections are served by
    # per-connection sshd-session daemons that outlive it — leaving them
    # running keeps every already-connected client (the app's control
    # link!) healthy, so "stop" wouldn't look like the host going away.
    # Kill them too, matched by the harness port so no other sshd on
    # this Mac is ever touched.
    sessions=$(lsof -nP -t -iTCP:$PORT -a -c sshd 2>/dev/null || true)
    if [ -n "$sessions" ]; then
        kill $sessions 2>/dev/null || true
    fi
    echo "sshd stopped"
    for s in main scratch deploy agent; do
        tmux kill-session -t "$s" 2>/dev/null || true
    done
}

# Run the real companion CLI against this harness sshd. It enrolls into the
# harness's own authorized_keys (never ~/.ssh), announces on the LAN, and
# takes a fixed token/PIN so a headless app launch can complete the bind:
#
#   MULTIPLEX_AUTO_BIND="$(./harness.sh bind --print-only)"   # QR/paste path
#   MULTIPLEX_BIND_AUTOPIN=482163                             # discovery path
#
# The app ends up with a SECOND host (its own freshly enrolled key) beside
# the seeded devbox — that separate record, and its key line in
# state/authorized_keys, is the proof.
bind() {
    local CLI="${MPX_BIN:-$HOME/workspace2/multiplex-cli/target/debug/mpx}"
    if [ ! -x "$CLI" ]; then
        echo "no mpx binary at $CLI — build it: (cd ~/workspace2/multiplex-cli && cargo build)" >&2
        exit 1
    fi
    [ -f "$STATE/authorized_keys" ] || { echo "run '$0 start' first" >&2; exit 1; }

    # Fixed session material: the app side can then be launched with a known
    # PIN, and the payload is reproducible across runs.
    export MPX_BIND_TEST_TOKEN=33333333333333333333333333333333
    export MPX_BIND_TEST_SESSION_SEED=1111111111111111111111111111111111111111111111111111111111111111
    export MPX_BIND_TEST_PIN=${MPX_BIND_TEST_PIN:-482163}
    export MPX_BIND_TEST_YES=1

    local args=(
        bind
        --name harness-bind
        --user "$USER"
        --ssh-port "$PORT"
        --authorized-keys "$STATE/authorized_keys"
        --hostkeys-dir "$STATE"
        --expires 600
        # This sshd listens on loopback only, so advertise the address the
        # app must actually dial — the simulator shares the Mac's stack, so
        # 127.0.0.1 resolves to this machine from inside it.
        --addr 127.0.0.1
    )
    # `--print-only` detaches the CLI (so the app can complete the handshake
    # afterwards) and prints just the payload URL, ready for
    # MULTIPLEX_AUTO_BIND. Its transcript lands in state/bind.log.
    if [ "${1:-}" = "--print-only" ]; then
        nohup "$CLI" "${args[@]}" --no-qr > "$STATE/bind.log" 2>&1 &
        echo $! > "$STATE/bind.pid"
        local url=""
        for _ in $(seq 1 50); do
            url=$(grep -m1 '^multiplex://b/' "$STATE/bind.log" 2>/dev/null || true)
            [ -n "$url" ] && break
            sleep 0.2
        done
        if [ -z "$url" ]; then
            echo "mpx bind printed no payload — see $STATE/bind.log" >&2
            exit 1
        fi
        echo "$url"
        return
    fi
    echo "PIN is $MPX_BIND_TEST_PIN · enrolling into $STATE/authorized_keys"
    # No --copy: the clipboard is opt-in, and a harness run has no
    # business taking the developer's (or, via Universal Clipboard,
    # their devices') clipboard.
    "$CLI" "${args[@]}"
}

case "${1:-}" in
    start) start ;;
    demo) demo ;;
    turn) shift; turn "$@" ;;
    ask) ask ;;
    herdr) herdr_demo ;;
    bind) shift; bind "$@" ;;
    stop) stop ;;
    *) echo "usage: $0 start|demo|turn [secs]|ask|herdr|bind [--print-only]|stop" >&2; exit 1 ;;
esac
