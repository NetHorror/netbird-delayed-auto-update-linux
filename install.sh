#!/usr/bin/env bash
# One-line installer for netbird-delayed-update-linux.
#   curl -fsSL https://github.com/NetHorror/netbird-delayed-auto-update-linux/releases/download/0.3.0/install.sh | sudo bash
# Downloads the script and SHA256SUMS of the same release, verifies the hash,
# then runs the script with --install --install-client.
set -euo pipefail

VER="${NB_DELAYED_VERSION:-0.3.0}"
BASE="${NB_DELAYED_BASE:-https://github.com/NetHorror/netbird-delayed-auto-update-linux/releases/download/${VER}}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This installer must run as root: curl -fsSL <url>/install.sh | sudo bash" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

echo "Downloading netbird-delayed-update-linux ${VER}..."
curl -fsSLO "${BASE}/netbird-delayed-update-linux.sh"
curl -fsSLO "${BASE}/SHA256SUMS"

echo "Verifying SHA-256..."
sha256sum -c SHA256SUMS --ignore-missing

echo "Installing (systemd timer + NetBird client if missing)..."
bash ./netbird-delayed-update-linux.sh --install --install-client
