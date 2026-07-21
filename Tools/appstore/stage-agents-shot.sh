#!/bin/bash
# Stage + capture the `agents` App Store shot: the dev-sshd harness's fake
# Claude Code pane parks on a permission dialog, the wall tile flips
# NEEDS YOU, and the local-notification banner posts — no real agent CLI.
#
#   ./stage-agents-shot.sh visionos|ipad|iphone [udid]
#
# Run AFTER the fleet is staged and the app is frontmost on its deck:
#   Tools/dev-sshd/harness.sh start && Tools/dev-sshd/harness.sh demo
#   Tools/appstore/stage-sessions.sh
#   SIMCTL_CHILD_MULTIPLEX_SEED_HOST=$PWD/Tools/dev-sshd/state/store-seed.json \
#     xcrun simctl launch <udid> app.multiplexterm.multiplex
#
# Alerts need Pro (the DEBUG default — don't combine with
# MULTIPLEX_PRO_LOCKED) and SETTINGS → Alerts on. The FIRST alert on a
# fresh install pops the notification permission dialog instead of a clean
# banner (there is no headless grant) — approve it, then re-run.
#
# Why a script: AttentionTracker fires on EDGES, so a pane already parked
# on a dialog never re-banners — each run re-arms by going idle for one
# probe cycle first. And the banner is transient, so the script
# burst-captures frames into raw/_agents-burst-<device>/; pick the one
# with the banner fully drawn and save it as raw/<device>-agents.png.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

DEVICE="${1:-}"
case "$DEVICE" in
    visionos) MATCH="Apple Vision Pro" ;;
    ipad)     MATCH="iPad" ;;
    iphone)   MATCH="iPhone" ;;
    *) echo "usage: $0 visionos|ipad|iphone [udid]" >&2; exit 1 ;;
esac

UDID="${2:-$(xcrun simctl list devices booted | grep "$MATCH" | grep -oE '[0-9A-F-]{36}' | head -1)}"
[ -n "$UDID" ] || { echo "no booted $MATCH simulator" >&2; exit 1; }

# Banners are gated twice beyond detection (the NEEDS YOU badge shows
# either way, so both gates fail silently): SETTINGS → Alerts, and Pro
# (DEBUG defaults to Pro unless the debug override persisted it off).
pref() { xcrun simctl spawn "$UDID" defaults read app.multiplexterm.multiplex "$1" 2>/dev/null || true; }
if [ "$(pref attention.alertsEnabled)" = "0" ]; then
    echo "SETTINGS → Alerts is OFF in the app — no banner will post. Fix:" >&2
    echo "  xcrun simctl terminate $UDID app.multiplexterm.multiplex" >&2
    echo "  xcrun simctl spawn $UDID defaults write app.multiplexterm.multiplex attention.alertsEnabled -bool true" >&2
    echo "  xcrun simctl launch $UDID app.multiplexterm.multiplex" >&2
    exit 1
fi
if [ "$(pref MultiplexProUnlocked)" = "0" ]; then
    echo "Debug free-tier override active (MultiplexProUnlocked=0) — alerts are Pro. Fix:" >&2
    echo "  xcrun simctl terminate $UDID app.multiplexterm.multiplex" >&2
    echo "  xcrun simctl spawn $UDID defaults delete app.multiplexterm.multiplex MultiplexProUnlocked" >&2
    echo "  xcrun simctl launch $UDID app.multiplexterm.multiplex" >&2
    exit 1
fi

tmux has-session -t agent 2>/dev/null || {
    echo "no fake agent session — stage the fleet first:" >&2
    echo "  Tools/dev-sshd/harness.sh start && Tools/dev-sshd/harness.sh demo" >&2
    echo "  Tools/appstore/stage-sessions.sh" >&2
    exit 1
}

BURST="$HERE/raw/_agents-burst-$DEVICE"
rm -rf "$BURST"
mkdir -p "$BURST"

# 1. Re-arm: AttentionTracker fires on edges, so respawn the cc pane idle
#    (✳ title, fresh grid) and wait out one probe cycle (~5 s cadence
#    while the deck is frontmost) so the tracker records the idle state.
#    `stty -echo` keeps the dialog single-rendered for the tile miniature —
#    the demo pane's tty echo + cat otherwise paints every line twice.
#    `exec -a claude` keeps the ps-tree detection signal intact.
echo "re-arming agent:cc (idle ✳, waiting out a probe cycle)…"
tmux respawn-pane -k -t agent:0.0 \
    'stty -echo; printf "\033]2;✳ Claude Code\033\\"; exec -a claude cat'
tmux select-pane -t agent:0.0 -T '✳ Scripted harness task'
# Two full probe cycles: one cycle can be eaten by the 4 s settled-probe
# coalescing, and a missed idle sample means dialog→dialog reads as no
# edge — the tracker then never posts.
sleep 13

# 2. Park on an AskUserQuestion-shaped dialog — the next probe flips the
#    tile to NEEDS YOU and posts "Claude Code has a question" (session
#    must be unfocused: stay on the deck, don't focus an attached agent
#    terminal). The ☐ header + question rows feed
#    AgentAttention.dialogSummary, so the banner leads with the dialog's
#    own copy instead of the pane-title fallback; the copy mirrors the
#    accepted iphone-agents shot so the store set reads as one moment.
#    (harness.sh ask stays the quick verification fake — its bare
#    permission dialog has no ⏺/`$ cmd` line, so its banner falls back to
#    the pane title.)
tmux select-pane -t agent:0.0 -T '⠂ Panel design bake-off'
while IFS= read -r line; do
    [ -n "$line" ] && tmux send-keys -t agent:0.0 -l "$line"
    tmux send-keys -t agent:0.0 Enter
done <<'EOF'
☐ Design format

  How should I deliver the 3 panel design versions
  for you to choose from?

❯ 1. Separate branch per design
  2. One branch, three commits
  3. Inline screenshots first

 Enter to select · ↑/↓ to navigate · Esc to cancel
EOF
echo "agent:cc parked on a question dialog (NEEDS YOU)"

# 3. Burst-capture while the banner is up.
echo "burst-capturing to ${BURST#"$HERE/"} for ~20 s…"
SECONDS=0
i=0
while [ "$SECONDS" -lt 20 ]; do
    xcrun simctl io "$UDID" screenshot \
        "$BURST/$(printf 'frame-%02d' "$i").png" >/dev/null 2>&1 || true
    i=$((i + 1))
    sleep 0.4
done

echo
echo "captured $i frames. Pick the one with the banner fully drawn and the"
echo "NEEDS YOU tile lit, then:"
echo "  cp $BURST/frame-NN.png $HERE/raw/$DEVICE-agents.png"
echo "(safe to re-run — every run re-arms before asking)"
open "$BURST" 2>/dev/null || true
