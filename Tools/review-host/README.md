# Reviewer demo host

The App Review demo server as code: one cloud-init file, rendered with the
demo password, pasted into any VPS provider. Policy/why in
`docs/appstore/release-playbook.md`; reviewer-facing walkthrough in
`fastlane/metadata/review_information/notes.txt`.

## Platform

Any plain KVM VPS works — this needs a real VM (persistent tmux, systemd,
**UDP 60000–61000 for mosh**), which rules out containers/PaaS. Pick a
**US-West region**: App Review works US Pacific hours, and a nearby host
makes the demo feel snappy instead of laggy.

| Provider | Plan | Region | ~Cost | Notes |
| --- | --- | --- | --- | --- |
| **Hetzner Cloud** (recommended) | CPX11 | Hillsboro, OR | ~€4.6/mo | cheapest solid option; clean UI + user-data field |
| DigitalOcean | Basic 1 GB | SFO3 | $6/mo | most familiar; good docs |
| Vultr | Cloud Compute 1 GB | LAX/SJC | ~$6/mo | fine alternative |
| Oracle Cloud | Always Free VM | San Jose | $0 | free, but signup friction and reclamation risk — don't hang a review on it |

~$60/yr to leave running permanently, which is the point: every app
**update** is reviewed against it too.

## Workflow

1. Password into `fastlane/.env` → `DEMO_SSH_PASSWORD` (long random; it's
   also what you'll paste into App Store Connect's demo-account field).
2. `./render.sh | pbcopy`
3. Create the VM: Ubuntu 24.04 LTS, smallest plan, US-West, add your SSH key
   (root access for you), paste the rendered YAML into the **user-data /
   cloud-init** field. Boot; cloud-init needs ~2–3 min after first login
   prompt.
4. DNS: `A demo.multiplexterm.dev → <VM IP>` (TTL 300). The hostname is baked
   into the review notes — if you use a different name, update
   `fastlane/metadata/review_information/notes.txt`.
5. `./verify.sh` — DNS, port, password login, session inventory,
   mosh-server, no-sudo check.
6. App Store Connect: demo account `review` + the password, in both the app
   version's review details and (via `fastlane beta external:true`) Beta App
   Review.

## Lifecycle

- **Rebuild, don't repair**: nothing on the box is precious. Delete the VM,
  re-create with the same user-data (rotate the password in `.env` first if
  it may have leaked).
- Sessions reseed on boot and nightly at 08:00 UTC; `verify.sh` the day
  before every submission.
- The `agent` session runs the same detection stubs as the dev harness
  (`✳ Claude Code` pane title / `exec -a` argv) so the Pro strip is
  demonstrable and deterministic — the review notes say so explicitly.
- Hardening in the cloud-init: password auth for `review` only with all SSH
  forwarding off, no sudo, egress firewall (DNS/NTP/DHCP/apt only — the box
  can't relay spam or proxy traffic), fail2ban, nightly home wipe.
