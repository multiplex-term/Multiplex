# Reviewer demo host — demo-for-review.multiplexterm.dev

The App Review demo server as code. Policy/why in
`docs/appstore/release-playbook.md`; reviewer-facing walkthrough in
`fastlane/metadata/review_information/notes.txt`.

Two ways to run it — same behavior either way: sshd with password auth for
`review` only (every forwarding surface disabled, no sudo — the binary isn't
even installed), tmux + mosh-server, and demo sessions (`main`/`build`/
`logs`/`agent` with the disclosed agent-detection stubs) reseeded on
boot/start and nightly.

## Platform

Needs a real VM with **UDP 60000–60010 reachable** (mosh) — rules out
container PaaS. Pick **US-West**: App Review works US Pacific hours and a
nearby host keeps the demo snappy.

| Provider | Plan | Region | ~Cost |
| --- | --- | --- | --- |
| **Hetzner Cloud** (recommended) | CPX11 | Hillsboro, OR | ~€4.6/mo |
| DigitalOcean | Basic 1 GB | SFO3 | $6/mo |
| Vultr | Cloud Compute 1 GB | LAX/SJC | ~$6/mo |

~$60/yr to leave running permanently — every app **update** is reviewed
against it too.

## Option A — Docker (recommended)

The container is the whole host: `Dockerfile` + `compose.yaml` here.
Immutable by design — **rebuild, don't patch** (a rebuild pulls Ubuntu
security updates; host keys persist in a volume so the box keeps its SSH
identity, which matters once the app ships TOFU pinning).

1. **VM prep** (any Ubuntu box with Docker): move the VM's own admin sshd
   off port 22 — `Port 2222` in `/etc/ssh/sshd_config`, restart — the
   container takes 22.
2. Copy this directory to the box (`scp -r Tools/review-host box:`), put the
   demo password in `.env` (`cp .env.sample .env`; same value as
   `fastlane/.env` and ASC's demo-account field).
3. `docker compose up -d --build`
4. DNS: `A demo-for-review.multiplexterm.dev → <VM IP>` (TTL 300; the zone
   lives in Vercel DNS). Different name → update `notes.txt`.
5. **Egress lockdown** — on the *host*, not in the container (ufw's
   outgoing policy does not govern Docker's FORWARD path). The running
   container needs **zero** outbound; replies ride conntrack. Run in this
   order (each `-I` prepends, so the DROP ends up last):

   ```sh
   iptables -I DOCKER-USER -s 172.28.0.0/24 -j DROP
   iptables -I DOCKER-USER -s 172.28.0.0/24 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
   ```

   (`172.28.0.0/24` is pinned in compose.yaml; persist with
   `iptables-persistent`.)
6. `./verify.sh` from the Mac — DNS, port, the real password-auth path,
   session inventory, mosh-server, no-sudo.
7. **Cadence**: `docker compose build --no-cache && docker compose up -d`
   before every submission (and monthly); restarts reseed the sessions —
   there's also an in-container 24 h reseed loop.

## Option B — cloud-init VM (no Docker)

`cloud-init.yaml` provisions a bare Ubuntu 24.04 VM identically:
`./render.sh | pbcopy` (injects the password from `fastlane/.env` as a
SHA-512 hash), paste as user-data at VM creation, DNS, `./verify.sh`.
Includes ufw egress rules and unattended-upgrades since there's no
rebuild cycle. ⚠ The demo scripts exist twice: `scripts/` (canonical,
used by Docker) and embedded in `cloud-init.yaml` — keep them in sync.

## GCP deployment (current, 2026-07)

The live host is a GCP e2-micro (`multiplex-demo-host`, `us-west1-b` — the
free-tier region) running the option-B shape, deployed and redeployed by
`./gcp-deploy.sh` (idempotent; run before every submission and monthly, the
same cadence as the Docker rebuild):

```sh
./gcp-deploy.sh                    # security updates + re-assert everything
./gcp-deploy.sh --rotate-password  # new password into fastlane/.env → ASC too
./gcp-deploy.sh --start            # boot the stopped VM first
```

Stop→start changes the ephemeral IP — update the Vercel A record (the script
detects the mismatch and prints the target). The VM's one sshd serves both
gcloud admin (keys) and `review` (password via a Match-User drop-in), so the
script never touches global sshd auth. Redeploys keep the host keys.

## Verified (local Docker run, 2026-07-12)

Built and exercised end-to-end on a Mac: seeds 4 sessions (`agent` pane
title `✳ Claude Code`, build loop printing ✓ lines); `sshd -T` shows
password auth **no** globally / **yes** only under `Match User review` with
all forwarding off; a real `ssh review@…` password login lands in
`LANG=C.UTF-8` with no locale warnings and `sudo: command not found`;
`mosh-server` via the wrapper answers `MOSH CONNECT 60000 …` — inside the
published 60000–60010 range.
