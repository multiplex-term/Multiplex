#!/bin/bash
# (Re)provision the GCP reviewer demo host — the deployed variant of option B
# (bare VM, no Docker) for the box behind demo-for-review.multiplexterm.dev.
# Idempotent: run before every submission and monthly (same cadence as the
# Docker rebuild in README.md) — it pulls Ubuntu security updates, reinstalls
# the canonical demo scripts, re-asserts sshd/ufw/fail2ban/locale state, and
# reseeds the demo sessions. Host keys live on the VM disk, so the SSH
# identity survives redeploys (only VM re-CREATION changes it).
#
#   ./gcp-deploy.sh                    # redeploy with the current password
#   ./gcp-deploy.sh --rotate-password  # mint a new password into fastlane/.env
#                                      #   (then update ASC's demo-account field!)
#   ./gcp-deploy.sh --start            # start the VM first if it is stopped
#
# Requirements: gcloud (authed for the project), openssl, dig. Optional for
# the built-in verification: sshpass (login battery), expect + mosh-client
# (real mosh session proof). verify.sh remains the interactive deep check.
#
# GCP specifics baked in (learned the hard way, 2026-07-18):
#   - The VM's ONE sshd serves both gcloud admin (keys) and review (password):
#     only a Match User drop-in is written; global auth is never touched, so a
#     bad run cannot lock out the admin path (sshd -t gates the reload).
#   - locales-all: a mosh client forwards its own locale via `mosh-server -l
#     LC_ALL=…` (AcceptEnv does not apply); a missing locale kills the
#     detached mosh-server AFTER "MOSH CONNECT" and every mosh session fails.
#   - The ephemeral external IP changes on stop→start: this script warns when
#     DNS disagrees and verifies against the IP, but updating the Vercel A
#     record (TTL 60) is a manual step — there is no vercel CLI auth here.
#   - fail2ban bans an IP for 10 min after repeated auth failures; if you
#     fat-finger the password while testing, that "connection refused" is it.
set -euo pipefail

INSTANCE="${MPX_DEMO_INSTANCE:-multiplex-demo-host}"
ZONE="${MPX_DEMO_ZONE:-us-west1-b}"
DOMAIN="${MPX_DEMO_DOMAIN:-demo-for-review.multiplexterm.dev}"

cd "$(dirname "$0")"
ENV_FILE="../../fastlane/.env"

GCLOUD="$(command -v gcloud || true)"
[ -z "$GCLOUD" ] && [ -x "$HOME/google-cloud-sdk/bin/gcloud" ] && GCLOUD="$HOME/google-cloud-sdk/bin/gcloud"
[ -n "$GCLOUD" ] || { echo "ERROR: gcloud not found (looked in PATH and ~/google-cloud-sdk/bin)"; exit 1; }

ROTATE=0 START=0
for a in "$@"; do
  case "$a" in
    --rotate-password) ROTATE=1 ;;
    --start)           START=1 ;;
    -h|--help)         sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a (see --help)"; exit 1 ;;
  esac
done

# ---- password: read from fastlane/.env, optionally rotate -------------------
[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE missing"; exit 1; }
PW="$(grep -m1 '^DEMO_SSH_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)"

if [ "$ROTATE" = 1 ]; then
  NEW="$(openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | head -c 28)"
  [ "${#NEW}" -ge 24 ] || { echo "ERROR: password generation failed"; exit 1; }
  # .env is the source of truth (same value as ASC's demo-account field), so
  # it is updated BEFORE provisioning: if the deploy dies midway, rerunning
  # converges the host onto the recorded value.
  awk -v pw="$NEW" '
    /^DEMO_SSH_PASSWORD=/ { print "DEMO_SSH_PASSWORD=" pw; done=1; next }
    { print } END { exit done ? 0 : 1 }' "$ENV_FILE" > "$ENV_FILE.tmp" \
    || { rm -f "$ENV_FILE.tmp"; echo "ERROR: no DEMO_SSH_PASSWORD= line in $ENV_FILE"; exit 1; }
  mv "$ENV_FILE.tmp" "$ENV_FILE"
  PW="$NEW"
  echo "password: ROTATED in fastlane/.env"
else
  echo "password: keeping current fastlane/.env value"
fi
[ -n "$PW" ] || { echo "ERROR: DEMO_SSH_PASSWORD is empty — set it or pass --rotate-password"; exit 1; }
HASH="$(openssl passwd -6 "$PW")"   # only the hash travels to the VM

# ---- VM state ---------------------------------------------------------------
STATUS="$("$GCLOUD" compute instances describe "$INSTANCE" --zone="$ZONE" --format='value(status)')"
if [ "$STATUS" != "RUNNING" ]; then
  if [ "$START" = 1 ]; then
    echo "instance is $STATUS — starting…"
    "$GCLOUD" compute instances start "$INSTANCE" --zone="$ZONE" --quiet >/dev/null
    for _ in $(seq 1 40); do
      "$GCLOUD" compute ssh "$INSTANCE" --zone="$ZONE" --quiet --command='true' >/dev/null 2>&1 && break
      sleep 5
    done
  else
    echo "ERROR: instance is $STATUS — rerun with --start (note: starting changes the ephemeral IP)"; exit 1
  fi
fi
IP="$("$GCLOUD" compute instances describe "$INSTANCE" --zone="$ZONE" \
      --format='value(networkInterfaces[0].accessConfigs[0].natIP)')"
echo "instance: $INSTANCE ($ZONE) — RUNNING at $IP"

# ---- DNS sanity -------------------------------------------------------------
DNS_IP="$(dig +short A "$DOMAIN" 2>/dev/null | head -1 || true)"
DNS_OK=0
if [ "$DNS_IP" = "$IP" ]; then
  DNS_OK=1; echo "dns:      $DOMAIN → $IP (ok)"
else
  echo "dns:      ⚠ $DOMAIN → ${DNS_IP:-<unresolved>} but the VM is at $IP"
  echo "          update the Vercel A record (Domains → multiplexterm.dev → ${DOMAIN%%.multiplexterm.dev}),"
  echo "          TTL 60 — verification below will use the raw IP meanwhile."
fi

# ---- provision --------------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/provision.sh" <<'PROV'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
HASH='__HASH__'

apt-get -o DPkg::Lock::Timeout=180 -q update
apt-get -o DPkg::Lock::Timeout=180 -yq upgrade
apt-get -o DPkg::Lock::Timeout=180 -yq install --no-install-recommends \
    tmux mosh vim htop fail2ban ufw locales-all python3

# mosh-server needs a UTF-8 locale; stop honoring client LANG/LC_* over ssh
# (mosh's own -l forwarding is covered by locales-all above).
grep -q '^LANG=' /etc/environment 2>/dev/null || echo 'LANG=C.UTF-8' >> /etc/environment
printf 'LANG=C.UTF-8\n' > /etc/default/locale
sed -i 's/^AcceptEnv/#AcceptEnv/' /etc/ssh/sshd_config
for f in /etc/ssh/sshd_config.d/*.conf; do
  [ -f "$f" ] && sed -i 's/^AcceptEnv/#AcceptEnv/' "$f"
done

# review: the only password login, no sudo, no groups
id review >/dev/null 2>&1 || useradd -m -s /bin/bash review
usermod -p "$HASH" review

# Match-only drop-in — the same sshd carries gcloud admin key logins, so the
# global auth settings are deliberately never touched here.
cat > /etc/ssh/sshd_config.d/60-review.conf <<'DROPIN'
# Password auth exists ONLY for the App Review account, with every
# forwarding surface closed so leaked credentials can't turn the box
# into a proxy.
Match User review
    PasswordAuthentication yes
    AllowTcpForwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTunnel no
DROPIN
sshd -t
systemctl reload ssh

# Pin mosh-server to the UDP range GCP + ufw publish (60000-60010)
[ -e /usr/bin/mosh-server.distrib ] || dpkg-divert --rename --add /usr/bin/mosh-server
install -m 755 /tmp/rh/scripts/mosh-server-wrapper /usr/bin/mosh-server
install -m 755 /tmp/rh/scripts/demo-server-log /tmp/rh/scripts/demo-worker-log \
    /tmp/rh/scripts/demo-build-loop /tmp/rh/scripts/demo-agent-cc \
    /tmp/rh/scripts/demo-agent-cx /tmp/rh/scripts/demo-agent-pi \
    /tmp/rh/scripts/seed-review-sessions /tmp/rh/scripts/seed-review-herdr \
    /tmp/rh/scripts/install-herdr /usr/local/bin/

# The second session backend the app can drive (pinned + checksummed). A
# download failure must not fail the deploy: tmux is what the review notes
# lead with, and the herdr seed skips itself without the binary.
/usr/local/bin/install-herdr || echo "herdr install failed — tmux demo unaffected"

cat > /etc/cron.d/review-reseed <<'CRON'
# Reseed demo sessions on boot and nightly at 08:00 UTC (midnight
# Pacific — App Review works US Pacific hours).
@reboot root /usr/local/bin/seed-review-sessions
0 8 * * * root /usr/local/bin/seed-review-sessions
CRON

# Egress lockdown (cloud-init runcmd equivalent; ufw allows are idempotent).
# mosh replies ride conntrack.
ufw default deny incoming
ufw default deny outgoing
ufw allow in 22/tcp
ufw allow in 60000:60010/udp
ufw allow out 53
ufw allow out 123/udp
ufw allow out 67:68/udp
# The review account is a real shell, so the metadata server must not be
# reachable from it: 169.254.169.254:80 would hand out this VM's
# service-account token to anyone holding the review password. Rules are
# ordered, so this deny sits ABOVE the web allowances and below the DNS one
# (GCP's resolver IS the metadata address — port 53 has to keep working).
ufw deny out proto tcp to 169.254.169.254
ufw allow out 80/tcp
ufw allow out 443/tcp
ufw --force enable
systemctl enable --now fail2ban 2>/dev/null || systemctl restart fail2ban

/usr/local/bin/seed-review-sessions
sleep 1
su - review -c 'tmux ls'
su - review -c 'herdr session list' 2>/dev/null || true
echo PROVISION_OK
PROV
# render.sh precedent: | is the one char openssl's hash could clash with
sed -i.bak "s|__HASH__|${HASH//|/\\|}|" "$TMP/provision.sh" && rm -f "$TMP/provision.sh.bak"

echo "provisioning…"
"$GCLOUD" compute ssh "$INSTANCE" --zone="$ZONE" --quiet --command='sudo rm -rf /tmp/rh && mkdir -p /tmp/rh' >/dev/null
"$GCLOUD" compute scp --recurse scripts "$TMP/provision.sh" "$INSTANCE:/tmp/rh/" --zone="$ZONE" --quiet >/dev/null
"$GCLOUD" compute ssh "$INSTANCE" --zone="$ZONE" --quiet \
  --command='sudo bash /tmp/rh/provision.sh; rc=$?; sudo rm -rf /tmp/rh; exit $rc' \
  2>&1 | grep -vE "^Warning: Permanently added|setlocale" | tail -8

# ---- verification (best-effort, non-interactive) ----------------------------
TARGET="$DOMAIN"; [ "$DNS_OK" = 1 ] || TARGET="$IP"
echo "— port 22 ($TARGET)"
nc -z -G 5 "$TARGET" 22 >/dev/null 2>&1 && echo "  reachable" || { echo "  UNREACHABLE"; exit 1; }

if command -v sshpass >/dev/null; then
  PWFILE="$TMP/pw"; umask 077; printf '%s' "$PW" > "$PWFILE"
  SSH_OPTS=(-o PreferredAuthentications=password -o PubkeyAuthentication=no
            -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
  echo "— reviewer login battery"
  if ! sshpass -f "$PWFILE" ssh "${SSH_OPTS[@]}" "review@$TARGET" '
      printf "  sessions:    "; tmux ls 2>/dev/null | wc -l | tr -d " "
      printf "  herdr:       "; herdr --version 2>/dev/null || echo "not installed"
      printf "  herdr live:  "; herdr session list 2>/dev/null | grep -c running || true
      printf "  mosh-server: "; command -v mosh-server || echo MISSING
      printf "  locale:      "; locale | grep ^LANG=
      printf "  sudo:        "; sudo -n true 2>/dev/null && echo "!!! HAS SUDO" || echo "none (correct)"
    ' 2>/dev/null; then
    echo "  LOGIN FAILED — wrong password, fail2ban ban (wait 10 min), or, if"
    echo "  the VM was recreated: ssh-keygen -R $DOMAIN and rerun."
    exit 1
  fi
  if command -v expect >/dev/null && command -v mosh-client >/dev/null; then
    echo "— mosh session proof (bootstrap → UDP → shell prompt)"
    # kill stale demo mosh-servers first; distri[b] so pgrep -f cannot match
    # this ssh command line itself
    CONNECT="$(sshpass -f "$PWFILE" ssh "${SSH_OPTS[@]}" "review@$TARGET" \
      'kill $(pgrep -u review -f "distri[b]") 2>/dev/null; sleep 1; mosh-server new -c 256' 2>/dev/null \
      | grep 'MOSH CONNECT' | awk '{print $3" "$4}')"
    if [ -n "$CONNECT" ]; then
      cat > "$TMP/mosh.exp" <<'EXP'
set timeout 15
spawn sh -c "MOSH_KEY=$env(MKEY) mosh-client $env(MIP) $env(MPORT)"
expect { -re {\$ $} { send "exit\r"; catch {expect eof}; exit 0 } timeout { exit 1 } }
EXP
      if MIP="$IP" MPORT="${CONNECT%% *}" MKEY="${CONNECT#* }" expect "$TMP/mosh.exp" >/dev/null 2>&1; then
        echo "  interactive mosh session over UDP ${CONNECT%% *}: OK"
      else
        echo "  MOSH FAILED (udp ${CONNECT%% *}) — check GCP firewall udp:60000-60010 and ufw"
        exit 1
      fi
    else
      echo "  MOSH BOOTSTRAP FAILED — no MOSH CONNECT line"
      exit 1
    fi
  else
    echo "— mosh proof skipped (need expect + mosh-client; brew install mosh)"
  fi
else
  echo "— login/mosh checks skipped (no sshpass; brew install sshpass) — run ./verify.sh"
fi

echo "DEPLOY OK — $INSTANCE at $IP"
[ "$DNS_OK" = 1 ] || echo "⚠ REMEMBER: point $DOMAIN at $IP in Vercel DNS"
if [ "$ROTATE" = 1 ]; then
  echo "⚠ PASSWORD ROTATED: update App Store Connect's demo-account field with"
  echo "  the new fastlane/.env DEMO_SSH_PASSWORD before the next submission."
fi
