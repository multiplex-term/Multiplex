#!/bin/bash
# Pre-submission check of the reviewer demo host — run the day before every
# App Store / TestFlight-external submission. Interactive: you type the demo
# password, which also proves the exact auth path reviewers will use.
#
#   ./verify.sh [host]        # default: demo.multiplexterm.dev
set -u
HOST="${1:-demo.multiplexterm.dev}"

echo "— DNS"
dig +short A "$HOST" | sed 's/^/  /'

echo "— port 22"
nc -vz -G 5 "$HOST" 22 || { echo "  UNREACHABLE"; exit 1; }

echo "— login as review (type the demo password)"
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no "review@$HOST" '
  echo "  sessions:"; tmux ls 2>/dev/null | sed "s/^/    /" || echo "    NONE — reseed broken"
  printf "  mosh-server: "; command -v mosh-server || echo "MISSING"
  printf "  locale:      "; locale | grep ^LANG
  printf "  sudo:        "; sudo -n true 2>/dev/null && echo "!!! HAS SUDO — fix this" || echo "none (correct)"
'
echo "OK"
