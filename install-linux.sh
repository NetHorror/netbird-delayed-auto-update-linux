#!/usr/bin/env bash
# One-line installer for netbird-delayed-update-linux.
#   curl -fsSL https://github.com/NetHorror/netbird-delayed-auto-update-linux/releases/download/0.3.0/install-linux.sh | sudo bash
# Downloads the script and SHA256SUMS of release 0.3.0, verifies the SHA-256 hash,
# then runs the script with --install --install-client (extra arguments are passed on).
main() {
  set -euo pipefail
  local VER=0.3.0
  local NAME=netbird-delayed-update-linux.sh
  local BASE="https://github.com/NetHorror/netbird-delayed-auto-update-linux/releases/download/${VER}"

  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root: curl -fsSL <url>/install-linux.sh | sudo bash" >&2
    exit 1
  fi

  NBTMP="$(mktemp -d)"
  trap 'rm -rf "$NBTMP"' EXIT
  cd "$NBTMP"

  echo "Downloading ${NAME} ${VER}..."
  curl -fsSL -o "$NAME" "${BASE}/${NAME}"
  curl -fsSL -o SHA256SUMS "${BASE}/SHA256SUMS"

  echo "Verifying SHA-256..."
  local LINE
  LINE="$(grep -E "[[:space:]*]${NAME}\$" SHA256SUMS | head -n1 || true)"
  if [[ -z "$LINE" ]]; then
    echo "No checksum for ${NAME} in SHA256SUMS; nothing installed." >&2
    exit 1
  fi
  printf '%s\n' "$LINE" > check.txt
  sha256sum -c check.txt

  echo "Installing (systemd timer + NetBird client if missing)..."
  bash ./"$NAME" --install --install-client "$@" </dev/null
}
main "$@"
