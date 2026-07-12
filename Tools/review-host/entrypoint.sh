#!/bin/bash
# Container entrypoint: set the review password (runtime-only — the image
# carries none), ensure host keys (volume-persisted: once the app ships TOFU
# pinning, key stability matters), seed the demo sessions, run sshd.
set -euo pipefail

: "${DEMO_SSH_PASSWORD:?set DEMO_SSH_PASSWORD (compose reads it from your environment or .env)}"
echo "review:${DEMO_SSH_PASSWORD}" | chpasswd

mkdir -p /etc/ssh/hostkeys
[ -s /etc/ssh/hostkeys/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/hostkeys/ssh_host_ed25519_key
[ -s /etc/ssh/hostkeys/ssh_host_rsa_key ]     || ssh-keygen -q -t rsa -b 3072 -N '' -f /etc/ssh/hostkeys/ssh_host_rsa_key

/usr/local/bin/seed-review-sessions

# Nightly reseed without in-container cron; a `docker restart` reseeds too.
( while sleep 86400; do /usr/local/bin/seed-review-sessions; done ) &

exec /usr/sbin/sshd -D -e
