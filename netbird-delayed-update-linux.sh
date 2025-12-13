#!/usr/bin/env bash
# Version: 0.2.1
# NetBird Delayed Auto-Update for Linux (APT + systemd)

set -euo pipefail

# -------------------- Defaults / Config --------------------

STATE_DIR="/var/lib/netbird-delayed-update"
STATE_FILE="${STATE_DIR}/state.json"
LOG_PREFIX="${STATE_DIR}/netbird-delayed-update"

SYSTEMD_UNIT_DIR="/etc/systemd/system"
SERVICE_NAME="netbird-delayed-update.service"
TIMER_NAME="netbird-delayed-update.timer"

INSTALLED_SCRIPT_PATH="/usr/local/sbin/netbird-delayed-update.sh"

DELAY_DAYS=10
MAX_RANDOM_DELAY_SECONDS=3600
DAILY_TIME="04:00"
LOG_RETENTION_DAYS=60

SCRIPT_VERSION="0.2.1"

SELFUPDATE_REPO="NetHorror/netbird-delayed-auto-update-linux"
SELFUPDATE_PATH="netbird-delayed-update-linux.sh"

# -------------------- Runtime globals --------------------

LOG_FILE=""
LOG_CLEANED=0
MODE="run"
REMOVE_STATE=0

# -------------------- Helpers: logging & usage --------------------

log() {
  local ts
  ts="$(date -u +"%Y-%m-%d %H:%M:%S")"
  local line="[$ts] $*"

  if [[ -z "${LOG_FILE}" ]]; then
    mkdir -p "${STATE_DIR}"
    LOG_FILE="${LOG_PREFIX}-$(date -u +"%Y%m%d-%H%M%S").log"
  fi

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

Usage:
  ${0##*/} [--install|-i] [--uninstall|-u] [--remove-state]
           [--delay-days N] [--max-random-delay-seconds N]
           [--daily-time "HH:MM"] [--log-retention-days N]
           [--version] [--help|-h]

Modes:
  --install, -i
      Install/update systemd service and timer (runs daily).
  --uninstall, -u
      Remove systemd service and timer.
  --remove-state
      When used with --uninstall, also removes:
        - ${INSTALLED_SCRIPT_PATH}
        - ${STATE_DIR}

Behaviour:
  --delay-days N
      Minimum age (days) a new APT candidate version must remain unchanged
      before it is allowed to be upgraded. Default: ${DELAY_DAYS}
  --max-random-delay-seconds N
      Random jitter (sleep) before running checks. Default: ${MAX_RANDOM_DELAY_SECONDS}
      NOTE: When installed via --install, the systemd timer already uses RandomizedDelaySec,
            so the installed service runs the script with --max-random-delay-seconds 0.
  --daily-time "HH:MM"
      Time of day for the daily systemd timer. Default: ${DAILY_TIME}
  --log-retention-days N
      Delete log files older than N days. Default: ${LOG_RETENTION_DAYS}
      Use 0 to disable log cleanup.

Examples:
  One-off run, no delay and no jitter:
    sudo ./netbird-delayed-update-linux.sh --delay-days 0 --max-random-delay-seconds 0

  Install systemd timer with custom settings:
    sudo ./netbird-delayed-update-linux.sh --install --delay-days 10 --max-random-delay-seconds 3600 --daily-time "04:00"

EOF
}

# -------------------- Helpers: validation --------------------

validate_time_hhmm() {
  local t="$1"
  if [[ ! "${t}" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "Invalid time format '${t}'. Use HH:MM (24-hour), e.g. 04:00." >&2
    exit 1
  fi
}

is_nonneg_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

validate_numeric_args() {
  if ! is_nonneg_int "${DELAY_DAYS}"; then
    echo "Invalid --delay-days '${DELAY_DAYS}'. Expected a non-negative integer." >&2
    exit 1
  fi
  if ! is_nonneg_int "${MAX_RANDOM_DELAY_SECONDS}"; then
    echo "Invalid --max-random-delay-seconds '${MAX_RANDOM_DELAY_SECONDS}'. Expected a non-negative integer." >&2
    exit 1
  fi
  if ! is_nonneg_int "${LOG_RETENTION_DAYS}"; then
    echo "Invalid --log-retention-days '${LOG_RETENTION_DAYS}'. Expected a non-negative integer." >&2
    exit 1
  fi
}

# -------------------- Helpers: version comparison --------------------

version_is_newer() {
  local a="$1"
  local b="$2"
  # returns 0 if a > b
  dpkg --compare-versions "${a}" gt "${b}" 2>/dev/null
}

# -------------------- Helpers: state (JSON) --------------------

load_state() {
  if [[ ! -f "${STATE_FILE}" ]]; then
    return 1
  fi

  local candidate first_seen last_check

  candidate="$(grep -o '"CandidateVersion"[[:space:]]*:[[:space:]]*"[^"]*"' "${STATE_FILE}" 2>/dev/null | head -n1 | sed 's/.*"CandidateVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')" || true
  first_seen="$(grep -o '"FirstSeenUtc"[[:space:]]*:[[:space:]]*"[^"]*"' "${STATE_FILE}" 2>/dev/null | head -n1 | sed 's/.*"FirstSeenUtc"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')" || true
  last_check="$(grep -o '"LastCheckUtc"[[:space:]]*:[[:space:]]*"[^"]*"' "${STATE_FILE}" 2>/dev/null | head -n1 | sed 's/.*"LastCheckUtc"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')" || true

  if [[ -z "${candidate}" && -z "${first_seen}" && -z "${last_check}" ]]; then
    log "WARNING: State file '${STATE_FILE}' appears malformed, ignoring it."
    return 1
  fi

  STATE_LINES=("${candidate}" "${first_seen}" "${last_check}")
  return 0
}

save_state() {
  local candidate="$1"
  local first_seen="$2"
  local last_check="$3"

  mkdir -p "${STATE_DIR}"
  local tmp="${STATE_FILE}.tmp"

  {
    printf '{\n'
    printf '  "CandidateVersion": "%s",\n' "${candidate}"
    printf '  "FirstSeenUtc": "%s",\n' "${first_seen}"
    printf '  "LastCheckUtc": "%s"\n' "${last_check}"
    printf '}\n'
  } >"${tmp}" && mv "${tmp}" "${STATE_FILE}" || {
    log "WARNING: Failed to write state file '${STATE_FILE}'."
  }
}

compute_age_days() {
  local first_seen="$1"

  if [[ -z "${first_seen}" ]]; then
    echo "0"
    return
  fi

  local first_epoch
  if ! first_epoch="$(date -u -d "${first_seen}" +%s 2>/dev/null)"; then
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

extract_github_tag_name() {
  # Extract "tag_name" from GitHub release JSON (works for one-line and pretty JSON).
  local json="$1"
  local one_line
  one_line="$(printf '%s' "${json}" | tr -d '\n\r')"
  printf '%s' "${one_line}" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

self_update() {
  if [[ -z "${SELFUPDATE_REPO}" ]]; then
    return 0
  fi

  log "Self-update: checking latest release for ${SELFUPDATE_REPO} (current ${SCRIPT_VERSION})."

  local api_url="https://api.github.com/repos/${SELFUPDATE_REPO}/releases/latest"
  local json
  if ! json="$(curl -fsSL -H "User-Agent: netbird-delayed-update-linux/${SCRIPT_VERSION}" "${api_url}" 2>/dev/null)"; then
    log "Self-update: failed to query GitHub API, skipping."
    return 0
  fi

  local remote_tag
  remote_tag="$(extract_github_tag_name "${json}" | head -n1 || true)"

  if [[ -z "${remote_tag}" ]]; then
    log "Self-update: could not parse tag_name from GitHub response, skipping."
    return 0
  fi

  # Defensive validation: avoid treating URLs or unexpected strings as versions.
  if [[ "${remote_tag}" == http* || "${remote_tag}" == *"/"* ]]; then
    log "Self-update: parsed tag_name looks invalid ('${remote_tag}'), skipping."
    return 0
  fi

  # Harmless if tags never have 'v' prefix.
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

  local raw_url="https://raw.githubusercontent.com/${SELFUPDATE_REPO}/${remote_tag}/${SELFUPDATE_PATH}"
  log "Self-update: downloading script from ${raw_url}"

  local tmp
  tmp="$(mktemp "/tmp/netbird-delayed-update-linux.XXXXXX")" || {
    log "Self-update: failed to create temporary file."
    return 0
  }

  if ! curl -fsSL -H "User-Agent: netbird-delayed-update-linux/${SCRIPT_VERSION}" "${raw_url}" -o "${tmp}" 2>/dev/null; then
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

install_systemd_units() {
  validate_time_hhmm "${DAILY_TIME}"

  local src
  if ! src="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"; then
    src="$0"
  fi

  echo "Installing NetBird delayed auto-update (systemd)..."

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
ExecStart=${INSTALLED_SCRIPT_PATH} --delay-days ${DELAY_DAYS} --max-random-delay-seconds 0 --log-retention-days ${LOG_RETENTION_DAYS}
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

  echo "Systemd service and timer installed."
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

  log "Upgrading NetBird: ${installed_ver} -> ${candidate_ver} (version has matured for ${age_days} day(s))."

  export DEBIAN_FRONTEND=noninteractive

  if ! apt-get update 2>/dev/null; then
    log "WARNING: 'apt-get update' failed; continuing with cached metadata."
  fi

  if ! apt-get install --only-upgrade -y netbird netbird-ui 2>/dev/null; then
    log "WARNING: Failed to upgrade 'netbird-ui' (possibly not installed). Retrying with 'netbird' only."
    apt-get install --only-upgrade -y netbird
  fi

  restart_netbird_service
  log "NetBird delayed update finished."
}

run_delayed_update() {
  # Prevent concurrent runs (APT/dpkg lock issues)
  if command -v flock >/dev/null 2>&1; then
    mkdir -p "${STATE_DIR}"
    exec 9>"${STATE_DIR}/lock"
    if ! flock -n 9; then
      log "Another instance is running; exiting."
      return 0
    fi
  fi

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

  if dpkg --compare-versions "${installed_ver}" ge "${candidate_ver}"; then
    log "Local version ${installed_ver} is already >= repository version ${candidate_ver}. No update needed."
    return 0
  fi

  local now_utc
  now_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  local state_candidate="" state_first_seen="" state_last_check=""
  if load_state; then
    state_candidate="${STATE_LINES[0]}"
    state_first_seen="${STATE_LINES[1]}"
    state_last_check="${STATE_LINES[2]}"
  fi

  if [[ -z "${state_candidate}" || "${state_candidate}" != "${candidate_ver}" ]]; then
    log "New candidate version detected: ${candidate_ver}. First seen now, waiting ${DELAY_DAYS} day(s)."
    save_state "${candidate_ver}" "${now_utc}" "${now_utc}"
    return 0
  fi

  local age_days
  age_days="$(compute_age_days "${state_first_seen}")"

  log "Candidate version ${candidate_ver} has been in the repository for approximately ${age_days} day(s)."

  if (( age_days < DELAY_DAYS )); then
    log "Age is less than ${DELAY_DAYS} day(s) - deferring update."
    save_state "${candidate_ver}" "${state_first_seen}" "${now_utc}"
    return 0
  fi

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
        [[ $# -ge 2 ]] || { echo "Missing value for --delay-days" >&2; exit 1; }
        DELAY_DAYS="$2"
        shift 2
        ;;
      --max-random-delay-seconds)
        [[ $# -ge 2 ]] || { echo "Missing value for --max-random-delay-seconds" >&2; exit 1; }
        MAX_RANDOM_DELAY_SECONDS="$2"
        shift 2
        ;;
      --daily-time)
        [[ $# -ge 2 ]] || { echo "Missing value for --daily-time" >&2; exit 1; }
        DAILY_TIME="$2"
        shift 2
        ;;
      --log-retention-days)
        [[ $# -ge 2 ]] || { echo "Missing value for --log-retention-days" >&2; exit 1; }
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
  validate_numeric_args

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
