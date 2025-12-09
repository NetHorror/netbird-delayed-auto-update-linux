#!/usr/bin/env bash
# Version: 0.2.0
#
# NetBird Delayed Auto-Update for Linux (APT + systemd)
#
# Delayed / staged auto-update for the NetBird client installed from APT.
#
# Features:
#   - Version aging: new candidate versions must stay in the repository
#     for N days before they are allowed to be installed.
#   - No auto-install: only upgrades an already installed NetBird package.
#   - Systemd integration: daily checks via a timer + oneshot service.
#   - Log files with retention in /var/lib/netbird-delayed-update.
#   - Script self-update via GitHub releases (this repo).
#
# Usage (examples):
#   # One-off check with no delay and no random jitter:
#   sudo ./netbird-delayed-update-linux.sh \
#     --delay-days 0 \
#     --max-random-delay-seconds 0 \
#     --log-retention-days 60
#
#   # Install systemd service + timer with defaults:
#   sudo ./netbird-delayed-update-linux.sh --install
#
#   # Install with custom settings:
#   sudo ./netbird-delayed-update-linux.sh --install \
#     --delay-days 10 \
#     --max-random-delay-seconds 3600 \
#     --log-retention-days 60 \
#     --daily-time "04:00"
#
#   # Uninstall systemd units but keep state/logs:
#   sudo ./netbird-delayed-update-linux.sh --uninstall
#
#   # Uninstall and remove state/logs + installed script:
#   sudo ./netbird-delayed-update-linux.sh --uninstall --remove-state
#

set -euo pipefail

# -------------------- Defaults / Config --------------------

STATE_DIR="/var/lib/netbird-delayed-update"
STATE_FILE="${STATE_DIR}/state.json"
LOG_PREFIX="${STATE_DIR}/netbird-delayed-update"

SYSTEMD_UNIT_DIR="/etc/systemd/system"
SERVICE_NAME="netbird-delayed-update.service"
TIMER_NAME="netbird-delayed-update.timer"

# Script installed path (used by --install, kept for backward compatibility)
INSTALLED_SCRIPT_PATH="/usr/local/sbin/netbird-delayed-update.sh"

DELAY_DAYS=10
MAX_RANDOM_DELAY_SECONDS=3600
DAILY_TIME="04:00"
LOG_RETENTION_DAYS=60

# Script self-update
SCRIPT_VERSION="0.2.0"
SELFUPDATE_REPO="NetHorror/netbird-delayed-auto-update-linux"
SELFUPDATE_PATH="netbird-delayed-update-linux.sh"

# -------------------- Runtime globals --------------------

LOG_FILE=""
LOG_CLEANED=0

MODE="run"          # run | install | uninstall
REMOVE_STATE=0

# -------------------- Helpers: logging & usage --------------------

log() {
  local ts
  ts="$(date -u +"%Y-%m-%d %H:%M:%S")"
  local line="[$ts] $*"

  # Ensure state dir and log file exist
  if [[ -z "${LOG_FILE}" ]]; then
    mkdir -p "${STATE_DIR}"
    LOG_FILE="${LOG_PREFIX}-$(date -u +"%Y%m%d-%H%M%S").log"
  fi

  # One-time log cleanup per run
  if [[ "${LOG_CLEANED}" -eq 0 ]] && [[ "${LOG_RETENTION_DAYS}" -gt 0 ]]; then
    LOG_CLEANED=1
    find "${STATE_DIR}" -maxdepth 1 -type f -name "netbird-delayed-update-*.log" \
      -mtime +"${LOG_RETENTION_DAYS}" -print0 2>/dev/null \
      | xargs -0r rm -f || true
  fi

  echo "${line}" | tee -a "${LOG_FILE}" >&2
}

usage() {
  cat <<EOF
NetBird Delayed Auto-Update for Linux (APT + systemd)
Current script version: ${SCRIPT_VERSION}

Modes:
  --install, -i        Install or update systemd service + timer.
  --uninstall, -u      Remove systemd service + timer (optionally state/logs).
  (no mode)            Run a single delayed-update check.

Common options:
  --delay-days N       Minimum age (in days) for a new candidate version.
                       Default: ${DELAY_DAYS}
  --max-random-delay-seconds N
                       Max random delay (seconds) before each run.
                       Default: ${MAX_RANDOM_DELAY_SECONDS}
  --log-retention-days N
                       Keep per-run log files for N days (0 = no cleanup).
                       Default: ${LOG_RETENTION_DAYS}
  --daily-time "HH:MM" Daily time for systemd timer (local time).
                       Used with --install; default: ${DAILY_TIME}

Install / uninstall options:
  --install, -i        Install systemd .service and .timer.
  --uninstall, -u      Disable + remove systemd units.
  --remove-state       When used with --uninstall, also remove:
                       - ${INSTALLED_SCRIPT_PATH}
                       - ${STATE_DIR}

Examples:
  sudo ./netbird-delayed-update-linux.sh --install
  sudo ./netbird-delayed-update-linux.sh --install \\
    --delay-days 10 --max-random-delay-seconds 3600 --daily-time "04:00"
  sudo ./netbird-delayed-update-linux.sh --uninstall --remove-state
  sudo ./netbird-delayed-update-linux.sh --delay-days 0 --max-random-delay-seconds 0

EOF
}

# -------------------- Helpers: version comparison --------------------

version_is_newer() {
  # Returns 0 if $1 (remote) > $2 (local), 1 otherwise.
  local remote="$1"
  local local_ver="$2"

  if [[ "${remote}" == "${local_ver}" ]]; then
    return 1
  fi

  local first
  first="$(printf '%s\n%s\n' "${remote}" "${local_ver}" | LC_ALL=C sort -V | head -n1)"

  if [[ "${first}" == "${local_ver}" ]]; then
    # local is smaller ⇒ remote is newer
    return 0
  fi

  return 1
}

# -------------------- Helpers: state (JSON) --------------------

load_state() {
  # Outputs three lines on success:
  #   CandidateVersion
  #   FirstSeenUtc
  #   LastCheckUtc
  # Returns 0 if state is available, 1 otherwise.
  if [[ ! -f "${STATE_FILE}" ]]; then
    return 1
  fi

  local out
  if ! out="$(python3 - "${STATE_FILE}" <<'PY' 2>/dev/null
import json, sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)

for key in ("CandidateVersion", "FirstSeenUtc", "LastCheckUtc"):
    print(data.get(key, ""))
PY
)"; then
    log(f"WARNING: Failed to parse state file '${STATE_FILE}', ignoring it.")
    return 1
  fi

  mapfile -t STATE_LINES <<< "${out}"
  if [[ "${#STATE_LINES[@]}" -lt 3 ]]; then
    log "WARNING: State file '${STATE_FILE}' is incomplete, ignoring it."
    return 1
  fi

  return 0
}

save_state() {
  local candidate="$1"
  local first_seen="$2"
  local last_check="$3"

  mkdir -p "${STATE_DIR}"

  python3 - "${candidate}" "${first_seen}" "${last_check}" "${STATE_FILE}" <<'PY' 2>/dev/null
import json, sys
candidate, first_seen, last_check, path = sys.argv[1:5]
obj = {
    "CandidateVersion": candidate,
    "FirstSeenUtc": first_seen,
    "LastCheckUtc": last_check,
}
try:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, sort_keys=True)
except Exception as e:
    sys.stderr.write(f"Failed to write state file '{path}': {e}\n")
    sys.exit(1)
PY

  if [[ $? -ne 0 ]]; then
    log "WARNING: Failed to write state file '${STATE_FILE}'."
  fi
}

compute_age_days() {
  local first_seen="$1"

  if [[ -z "${first_seen}" ]]; then
    echo "0"
    return
  fi

  local first_epoch
  if ! first_epoch="$(date -u -d "${first_seen}" +%s 2>/dev/null)"; then
    # Invalid timestamp in state ⇒ treat as 0 days old.
    echo "0"
    return
  fi

  local now_epoch
  now_epoch="$(date -u +%s)"

  local diff=$(( now_epoch - first_epoch ))
  if (( diff < 0 )); then
    diff=0
  fi

  echo $(( diff / 86400 ))
}

# -------------------- Helpers: self-update --------------------

self_update() {
  if [[ -z "${SELFUPDATE_REPO}" ]]; then
    return 0
  fi

  log "Self-update: checking latest release for ${SELFUPDATE_REPO} (current ${SCRIPT_VERSION})."

  local api_url="https://api.github.com/repos/${SELFUPDATE_REPO}/releases/latest"
  local json
  if ! json="$(curl -fsSL "${api_url}" 2>/dev/null)"; then
    log "Self-update: failed to query GitHub API, skipping."
    return 0
  fi

  local remote_tag
  remote_tag="$(printf '%s\n' "${json}" | awk -F'"' '/"tag_name"/ {print $4; exit}')"
  if [[ -z "${remote_tag}" ]]; then
    log "Self-update: could not parse tag_name from GitHub response."
    return 0
  fi

  remote_tag="${remote_tag#v}"

  if ! version_is_newer "${remote_tag}" "${SCRIPT_VERSION}"; then
    log "Self-update: no newer version available (latest ${remote_tag})."
    return 0
  fi

  local script_path
  if ! script_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"; then
    script_path="$0"
  fi

  if [[ ! -w "${script_path}" ]]; then
    log "Self-update: script path '${script_path}' is not writable, skipping."
    return 0
  fi

  # Try git pull if inside a git repo
  if command -v git >/dev/null 2>&1; then
    local repo_root
    if repo_root="$(cd "$(dirname "${script_path}")" && git rev-parse --show-toplevel 2>/dev/null)"; then
      log "Self-update: script is inside a git repository; trying 'git pull --ff-only'."
      if (cd "${repo_root}" && git pull --ff-only); then
        log "Self-update: git pull completed; new version will be used on the next run."
        return 0
      else
        log "Self-update: git pull failed, falling back to raw download."
      fi
    fi
  fi

  # Fallback: download from raw.githubusercontent.com
  local raw_url="https://raw.githubusercontent.com/${SELFUPDATE_REPO}/${remote_tag}/${SELFUPDATE_PATH}"
  log "Self-update: downloading script from ${raw_url}"

  local tmp
  tmp="$(mktemp "/tmp/netbird-delayed-update-linux.XXXXXX")" || {
    log "Self-update: failed to create temporary file."
    return 0
  }

  if ! curl -fsSL "${raw_url}" -o "${tmp}" 2>/dev/null; then
    log "Self-update: failed to download script from raw GitHub."
    rm -f "${tmp}" || true
    return 0
  fi

  if ! mv "${tmp}" "${script_path}"; then
    log "Self-update: failed to overwrite script at '${script_path}'."
    rm -f "${tmp}" || true
    return 0
  fi

  chmod +x "${script_path}" || true
  log "Self-update: script updated to version ${remote_tag}. New version will be used on the next run."
}

# -------------------- Helpers: systemd install/uninstall --------------------

validate_time_hhmm() {
  local t="$1"
  if [[ ! "${t}" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "Invalid time format '${t}'. Use HH:MM (24-hour), e.g. 04:00." >&2
    exit 1
  fi
}

install_systemd_units() {
  validate_time_hhmm "${DAILY_TIME}"

  local src
  if ! src="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"; then
    src="$0"
  fi

  echo "Installing NetBird delayed auto-update (systemd)..."

  # Copy script to a stable location
  install -D -m 0755 "${src}" "${INSTALLED_SCRIPT_PATH}"

  mkdir -p "${STATE_DIR}"
  chmod 755 "${STATE_DIR}"

  cat >"${SYSTEMD_UNIT_DIR}/${SERVICE_NAME}" <<EOF
[Unit]
Description=NetBird auto-update with delayed rollout (APT)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=MIN_AGE_DAYS=${DELAY_DAYS}
Environment=LOG_RETENTION_DAYS=${LOG_RETENTION_DAYS}
ExecStart=${INSTALLED_SCRIPT_PATH} --delay-days ${DELAY_DAYS} --max-random-delay-seconds ${MAX_RANDOM_DELAY_SECONDS} --log-retention-days ${LOG_RETENTION_DAYS}
Nice=10
EOF

  cat >"${SYSTEMD_UNIT_DIR}/${TIMER_NAME}" <<EOF
[Unit]
Description=Daily NetBird delayed auto-update check

[Timer]
OnCalendar=*-*-* ${DAILY_TIME}:00
RandomizedDelaySec=${MAX_RANDOM_DELAY_SECONDS}
Persistent=true
Unit=${SERVICE_NAME}

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${TIMER_NAME}"

  echo "Systemd service and timer installed:"
  echo "  Service: ${SYSTEMD_UNIT_DIR}/${SERVICE_NAME}"
  echo "  Timer:   ${SYSTEMD_UNIT_DIR}/${TIMER_NAME}"
  echo "Daily schedule: ${DAILY_TIME} with up to ${MAX_RANDOM_DELAY_SECONDS}s random delay."
}

uninstall_systemd_units() {
  echo "Uninstalling NetBird delayed auto-update (systemd)..."

  systemctl disable --now "${TIMER_NAME}" 2>/dev/null || true
  rm -f "${SYSTEMD_UNIT_DIR}/${TIMER_NAME}" || true
  rm -f "${SYSTEMD_UNIT_DIR}/${SERVICE_NAME}" || true

  systemctl daemon-reload || true

  if [[ "${REMOVE_STATE}" -eq 1 ]]; then
    rm -f "${INSTALLED_SCRIPT_PATH}" || true
    rm -rf "${STATE_DIR}" || true
    echo "Removed ${INSTALLED_SCRIPT_PATH} and ${STATE_DIR}."
  fi

  echo "Systemd units removed."
}

# -------------------- Core: delayed update logic --------------------

check_prerequisites() {
  if ! command -v apt-get >/dev/null 2>&1; then
    log "ERROR: apt-get not found. This script is intended for APT-based systems (e.g. Ubuntu)."
    exit 1
  fi

  if ! command -v dpkg-query >/dev/null 2>&1; then
    log "ERROR: dpkg-query not found; cannot inspect installed packages."
    exit 1
  fi
}

get_installed_version() {
  dpkg-query -W -f='${Version}\n' netbird 2>/dev/null || true
}

get_candidate_version() {
  apt-cache policy netbird 2>/dev/null | awk '/Candidate:/ {print $2; exit}' || true
}

restart_netbird_service() {
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^netbird\.service'; then
    if ! systemctl restart netbird 2>/dev/null; then
      log "WARNING: Failed to restart netbird.service via systemctl."
    else
      log "Restarted netbird.service via systemctl."
    fi
  elif command -v netbird >/dev/null 2>&1; then
    if ! netbird service restart 2>/dev/null; then
      log "WARNING: Failed to restart NetBird via 'netbird service restart'."
    else
      log "Restarted NetBird via 'netbird service restart'."
    fi
  else
    log "NOTE: Could not find netbird systemd service or CLI restart command."
  fi
}

perform_update() {
  local installed_ver="$1"
  local candidate_ver="$2"
  local age_days="$3"

  log "Upgrading NetBird: ${installed_ver} → ${candidate_ver} (version has matured for ${age_days} day(s))."

  export DEBIAN_FRONTEND=noninteractive

  if ! apt-get update -y 2>/dev/null; then
    log "WARNING: 'apt-get update' failed; continuing with cached metadata."
  fi

  # Try upgrading netbird + netbird-ui, then fall back to netbird only.
  if ! apt-get install --only-upgrade -y netbird netbird-ui 2>/dev/null; then
    log "WARNING: Failed to upgrade 'netbird-ui' (possibly not installed). Retrying with 'netbird' only."
    apt-get install --only-upgrade -y netbird
  fi

  restart_netbird_service
  log "NetBird delayed update finished."
}

run_delayed_update() {
  # Optional random spread inside the script itself.
  if [[ "${MAX_RANDOM_DELAY_SECONDS}" -gt 0 ]]; then
    local sleep_for=$(( RANDOM % (MAX_RANDOM_DELAY_SECONDS + 1) ))
    log "Sleeping for ${sleep_for} second(s) before running checks (random jitter)."
    sleep "${sleep_for}"
  fi

  check_prerequisites

  local installed_ver
  installed_ver="$(get_installed_version)"

  if [[ -z "${installed_ver}" ]]; then
    log "NetBird (package 'netbird') is not installed. Auto-install is not performed."
    return 0
  fi

  local candidate_ver
  candidate_ver="$(get_candidate_version)"

  if [[ -z "${candidate_ver}" || "${candidate_ver}" == "(none)" ]]; then
    log "No candidate version found in APT for package 'netbird'. Nothing to do."
    return 0
  fi

  # Compare versions; if installed >= candidate, exit.
  if dpkg --compare-versions "${installed_ver}" ge "${candidate_ver}"; then
    log "Local version ${installed_ver} is already >= repository version ${candidate_ver}. No update needed."
    return 0
  fi

  local now_utc
  now_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  local state_candidate=""
  local state_first_seen=""
  local state_last_check=""

  if load_state; then
    state_candidate="${STATE_LINES[0]}"
    state_first_seen="${STATE_LINES[1]}"
    state_last_check="${STATE_LINES[2]}"
  fi

  if [[ -z "${state_candidate}" || "${state_candidate}" != "${candidate_ver}" ]]; then
    # New candidate version detected.
    log "New candidate version detected: ${candidate_ver}. First seen now, waiting ${DELAY_DAYS} day(s)."
    save_state "${candidate_ver}" "${now_utc}" "${now_utc}"
    return 0
  fi

  # Candidate unchanged; compute age.
  local age_days
  age_days="$(compute_age_days "${state_first_seen}")"
  log "Candidate version ${candidate_ver} has been in the repository for approximately ${age_days} day(s)."

  if (( age_days < DELAY_DAYS )); then
    log "Age is less than ${DELAY_DAYS} day(s) – deferring update."
    save_state "${candidate_ver}" "${state_first_seen}" "${now_utc}"
    return 0
  fi

  # Age threshold reached; perform upgrade.
  perform_update "${installed_ver}" "${candidate_ver}" "${age_days}"
  save_state "${candidate_ver}" "${state_first_seen}" "${now_utc}"
}

# -------------------- Argument parsing --------------------

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install|-i)
        MODE="install"
        shift
        ;;
      --uninstall|-u)
        MODE="uninstall"
        shift
        ;;
      --remove-state)
        REMOVE_STATE=1
        shift
        ;;
      --delay-days)
        if [[ $# -lt 2 ]]; then
          echo "Missing value for --delay-days" >&2
          exit 1
        fi
        DELAY_DAYS="$2"
        shift 2
        ;;
      --max-random-delay-seconds)
        if [[ $# -lt 2 ]]; then
          echo "Missing value for --max-random-delay-seconds" >&2
          exit 1
        fi
        MAX_RANDOM_DELAY_SECONDS="$2"
        shift 2
        ;;
      --daily-time)
        if [[ $# -lt 2 ]]; then
          echo "Missing value for --daily-time" >&2
          exit 1
        fi
        DAILY_TIME="$2"
        shift 2
        ;;
      --log-retention-days)
        if [[ $# -lt 2 ]]; then
          echo "Missing value for --log-retention-days" >&2
          exit 1
        fi
        LOG_RETENTION_DAYS="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --version)
        echo "${SCRIPT_VERSION}"
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

# -------------------- Main --------------------

main() {
  parse_args "$@"

  case "${MODE}" in
    install)
      install_systemd_units
      ;;
    uninstall)
      uninstall_systemd_units
      ;;
    run)
      mkdir -p "${STATE_DIR}"
      LOG_FILE="${LOG_PREFIX}-$(date -u +"%Y%m%d-%H%M%S").log"
      log "Starting NetBird delayed auto-update (version ${SCRIPT_VERSION})."
      self_update
      run_delayed_update
      ;;
    *)
      echo "Internal error: unknown mode '${MODE}'" >&2
      exit 1
      ;;
  esac
}

main "$@"
