#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo bash install-netbird-delayed-update.sh        # default: 3 days delay
#   sudo bash install-netbird-delayed-update.sh 5      # 5 days delay

if [[ $EUID -ne 0 ]]; then
  echo "This installer must be run as root. Use: sudo bash $0 [MIN_AGE_DAYS]" >&2
  exit 1
fi

MIN_AGE_DAYS="${1:-3}"

echo "Installing NetBird delayed auto-update with a minimum age of ${MIN_AGE_DAYS} day(s)."

#############################################
# 1) Main update script (APT + local state) #
#############################################
cat >/usr/local/sbin/netbird-delayed-update.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# How many days to wait since the version first appeared in the APT repository
MIN_AGE_DAYS="${MIN_AGE_DAYS:-3}"

PKG_NAME="netbird"
STATE_DIR="/var/lib/netbird-delayed-update"
STATE_FILE="${STATE_DIR}/state"

require_cmd() {
  # Ensure all required commands are available
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      echo "Error: required command not found: $c" >&2
      exit 1
    fi
  done
}

# This script must run as root (usually via systemd service or sudo)
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (via sudo or systemd)." >&2
  exit 1
fi

require_cmd apt-get apt-cache dpkg date mkdir systemctl

# Create directory for local state (version + first-seen timestamp)
mkdir -p "$STATE_DIR"

##########################################
# 1) Get candidate version from APT      #
##########################################
candidate=$(apt-cache policy "$PKG_NAME" 2>/dev/null | awk '/Candidate:/ {print $2}' || true)

if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
  echo "Package $PKG_NAME is not available in APT (no Candidate). Nothing to update."
  exit 0
fi

remote_ver_deb="$candidate"            # e.g. 0.59.12-1
remote_ver="${remote_ver_deb%%-*}"     # → 0.59.12 (strip debian revision)

##########################################
# 2) Get currently installed version     #
##########################################
local_ver_deb=$(dpkg-query -W -f='${Version}' "$PKG_NAME" 2>/dev/null || true)

if [[ -z "$local_ver_deb" ]]; then
  echo "NetBird (package $PKG_NAME) is not installed. Auto-install is not performed."
  exit 0
fi

local_ver="${local_ver_deb%%-*}"

# If local version is already >= candidate, nothing to do
if dpkg --compare-versions "$remote_ver" le "$local_ver"; then
  echo "Local version $local_ver is already >= repository version $remote_ver. No update needed."
  # Optional: clean up stale state file
  if [[ -f "$STATE_FILE" ]]; then
    rm -f "$STATE_FILE"
  fi
  exit 0
fi

now_ts=$(date -u +%s)

##########################################
# 3) Load previous state (if any)        #
##########################################
state_version=""
state_first_seen_ts=0

if [[ -f "$STATE_FILE" ]]; then
  # Format: "<version> <epoch_timestamp>"
  read -r state_version state_first_seen_ts < "$STATE_FILE" || true
fi

##########################################
# 4) New candidate or reset condition    #
##########################################
# If candidate version has changed (new version or rollback), record it and wait MIN_AGE_DAYS
if [[ "$state_version" != "$remote_ver" || "$state_first_seen_ts" -le 0 ]]; then
  echo "$remote_ver $now_ts" > "$STATE_FILE"
  echo "New candidate version detected: $remote_ver. First seen now, waiting ${MIN_AGE_DAYS} day(s)."
  exit 0
fi

##########################################
# 5) Check age of the candidate version  #
##########################################
age_days=$(( (now_ts - state_first_seen_ts) / 86400 ))

echo "Candidate version $remote_ver has been in the repository for approximately ${age_days} day(s)."

if (( age_days < MIN_AGE_DAYS )); then
  echo "Age is less than ${MIN_AGE_DAYS} day(s) – deferring update."
  exit 0
fi

##########################################
# 6) Perform the APT upgrade             #
##########################################
echo "Upgrading NetBird: ${local_ver} → ${remote_ver} (version has matured for ${age_days} day(s))."

apt-get update
# Try to upgrade netbird and netbird-ui together; if UI is not installed, fall back to netbird only
apt-get install --only-upgrade -y netbird netbird-ui || \
  apt-get install --only-upgrade -y netbird || true

##########################################
# 7) Restart NetBird service if present  #
##########################################
if systemctl list-unit-files | grep -q '^netbird\.service'; then
  # Restart via systemd unit if available
  systemctl restart netbird || true
else
  # Fallback to CLI restart if available
  if command -v netbird >/dev/null 2>&1; then
    netbird service restart >/dev/null 2>&1 || true
  fi
fi

echo "NetBird delayed update finished."
SCRIPT

chmod +x /usr/local/sbin/netbird-delayed-update.sh
mkdir -p /var/lib/netbird-delayed-update
chown root:root /var/lib/netbird-delayed-update

#############################################
# 2) systemd service unit                   #
#############################################
cat >/etc/systemd/system/netbird-delayed-update.service <<EOF
[Unit]
Description=NetBird auto-update with version aging (via APT)

[Service]
Type=oneshot
# Pass minimum age in days via environment variable
Environment=MIN_AGE_DAYS=${MIN_AGE_DAYS}
ExecStart=/usr/local/sbin/netbird-delayed-update.sh
EOF

#############################################
# 3) systemd timer unit                     #
#    - Runs every day at 04:00 server time  #
#    - With a randomized delay up to 1 hour #
#############################################
cat >/etc/systemd/system/netbird-delayed-update.timer <<'EOF'
[Unit]
Description=Daily NetBird delayed update check at 04:00 with random spread

[Timer]
# Run every day at 04:00 (server local time)
OnCalendar=*-*-* 04:00:00

# Add a random delay up to 1 hour to avoid updating all hosts at the same time
RandomizedDelaySec=3600

# Run missed jobs at startup if the machine was down at the scheduled time
Persistent=true

[Install]
WantedBy=timers.target
EOF

#############################################
# 4) Reload systemd and enable the timer    #
#############################################
systemctl daemon-reload
systemctl enable --now netbird-delayed-update.timer

echo "Installation complete."
echo "Check timer status:  systemctl status netbird-delayed-update.timer"
echo "View last run logs:  journalctl -u netbird-delayed-update.service -n 50"
