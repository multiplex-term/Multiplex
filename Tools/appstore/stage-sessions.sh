#!/bin/bash
# Reshape the dev-sshd harness sessions into the App Store screenshot fleet
# (main / build / logs / agent — docs/appstore/screenshots-plan.md) and write
# store-seed.json variants so the imported host rail reads `atlas.internal`
# instead of `demo@127.0.0.1`.
#
# Run AFTER:  Tools/dev-sshd/harness.sh start && Tools/dev-sshd/harness.sh demo
set -euo pipefail
cd "$(dirname "$0")/../.."

grep -q 'atlas\.internal' /etc/hosts || {
  echo "Missing /etc/hosts alias. Run once:"
  echo "  echo '127.0.0.1 atlas.internal' | sudo tee -a /etc/hosts"
  exit 1
}
[ -f Tools/dev-sshd/state/seed.json ] || {
  echo "No seed.json — run Tools/dev-sshd/harness.sh start first."; exit 1
}

# Store fleet = main (editor/server/logs), build, logs, agent (from demo).
tmux kill-session -t scratch 2>/dev/null || true
tmux kill-session -t deploy  2>/dev/null || true
tmux kill-session -t build   2>/dev/null || true
tmux kill-session -t logs    2>/dev/null || true

BUILD='while true; do for m in core probe wall terminal input themes sync; do printf "  compiling %-10s" "$m"; sleep 1; printf " ✓\n"; done; printf "\nbuild ok · 7 modules\n\n"; sleep 8; done'
WORKER='while true; do printf "%s  worker  job=%d  done\n" "$(date +%T)" $((RANDOM % 900 + 100)); sleep 3; done'
tmux new-session -d -s build "bash -c '$BUILD'"
tmux new-session -d -s logs  "bash -c '$WORKER'"

# Real content in the editor window (fresh from `demo`, so the pane is a prompt).
tmux send-keys -t main:0 "cd $PWD && vim DESIGN.md" Enter

python3 - <<'PY'
import json, pathlib
p = pathlib.Path("Tools/dev-sshd/state/seed.json")
s = json.loads(p.read_text())
s["name"], s["hostname"] = "atlas", "atlas.internal"
# The `launch` shot's New Session sheet only shows its STARTS IN and
# RUNS FIRST pickers when the host carries dirs/scripts — seed both.
s["workingDirs"] = ["~/code/atlas", "~/code/api"]
s["sessionScripts"] = [
    {"name": "dev env", "body": "source .envrc"},
    {"name": "venv", "body": ". .venv/bin/activate"},
]
p.with_name("store-seed.json").write_text(json.dumps(s, indent=2))
p.with_name("store-seed-mosh.json").write_text(json.dumps(dict(s, useMosh=True), indent=2))
print("wrote state/store-seed.json (+ store-seed-mosh.json)")
PY

echo
tmux ls
cat <<'EOF'

Launch the app against the store fleet (UDID=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)):

  SIMCTL_CHILD_MULTIPLEX_SEED_HOST=$PWD/Tools/dev-sshd/state/store-seed.json \
    xcrun simctl launch $UDID app.multiplexterm.multiplex

Per-shot staging: local-plan/appstore-screenshots.md
EOF
