#!/bin/bash
# Render cloud-init user-data for the review host: injects the demo password
# from fastlane/.env as a SHA-512 crypt hash (the plaintext never appears in
# the provider's stored user-data). Output goes to stdout:
#
#   ./render.sh | pbcopy     # then paste into the provider's user-data field
set -euo pipefail
cd "$(dirname "$0")"

# shellcheck disable=SC1091
[ -f ../../fastlane/.env ] && source ../../fastlane/.env
: "${DEMO_SSH_PASSWORD:?set DEMO_SSH_PASSWORD in fastlane/.env first}"

HASH=$(openssl passwd -6 "$DEMO_SSH_PASSWORD")
sed "s|__DEMO_PASSWORD_HASH__|${HASH//|/\\|}|" cloud-init.yaml
