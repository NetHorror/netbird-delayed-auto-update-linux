#!/usr/bin/env bash
# Version: 0.3.0
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

SCRIPT_VERSION="0.3.0"

SELFUPDATE_REPO="NetHorror/netbird-delayed-auto-update-linux"
SELFUPDATE_PATH="netbird-delayed-update-linux.sh"

# Official NetBird APT repository (used only when installing the client).
NETBIRD_APT_URL="https://pkgs.netbird.io/debian"
NETBIRD_KEY_URL="https://pkgs.netbird.io/debian/public.key"
NETBIRD_KEY_FPR="EFE37DF047DF7CCDF1FC54FA83F79AD029778355"
NETBIRD_KEYRING="/usr/share/keyrings/netbird-archive-keyring.gpg"
NETBIRD_APT_LIST="/etc/apt/sources.list.d/netbird.list"

# -------------------- Runtime globals --------------------

LOG_FILE=""
LOG_CLEANED=0
MODE="run"
REMOVE_STATE=0
INSTALL_CLIENT=0
SELF_UPDATE=1

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
           [--install-client] [--no-self-update]
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
  --install-client
      If NetBird is not installed, install it from the official APT repository
      (${NETBIRD_APT_URL}) without asking. Without this flag an interactive run asks
      first, and a non-interactive run (systemd timer) only logs a warning.
      The first installation installs the current latest version; the delay
      applies only to later updates.
  --no-self-update
      Do not check GitHub releases for a newer version of this script.
      Self-update is enabled by default and only applies a release whose
      script matches the SHA256SUMS asset.

Examples:
  One-off run, no delay and no jitter:
    sudo ./netbird-delayed-update-linux.sh --delay-days 0 --max-random-delay-seconds 0

  Install systemd timer with custom settings:
    sudo ./netbird-delayed-update-linux.sh --install --delay-days 10 --max-random-delay-seconds 3600 --daily-time "04:00"

  Unattended setup on a fresh machine (install NetBird + timer):
    sudo ./netbird-delayed-update-linux.sh --install --install-client

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

extract_asset_url() {
  # Print the browser_download_url of the release asset named exactly "$2".
  # Only URLs pointing at this repository's release downloads are accepted.
  local json="$1"
  local name="$2"
  local prefix="https://github.com/${SELFUPDATE_REPO}/releases/download/"
  printf '%s' "${json}" \
    | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed 's/.*:[[:space:]]*"\([^"]*\)"$/\1/' \
    | awk -v p="${prefix}" -v n="/${name}" \
        'index($0, p) == 1 && substr($0, length($0) - length(n) + 1) == n { print; exit }'
}

self_update_cleanup() {
  rm -f "$@" 2>/dev/null || true
}

self_update() {
  if [[ "${SELF_UPDATE}" -ne 1 || -z "${SELFUPDATE_REPO}" ]]; then
    log "Self-update: disabled (--no-self-update)."
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
    log "Self-update: curl or sha256sum not available, skipping."
    return 0
  fi

  log "Self-update: checking latest release for ${SELFUPDATE_REPO} (current ${SCRIPT_VERSION})."

  local ua="netbird-delayed-update-linux/${SCRIPT_VERSION}"
  local api_url="https://api.github.com/repos/${SELFUPDATE_REPO}/releases/latest"
  local json
  if ! json="$(curl -fsSL --connect-timeout 10 --max-time 60 -H "User-Agent: ${ua}" "${api_url}" 2>/dev/null)"; then
    log "Self-update: failed to query GitHub API, skipping."
    return 0
  fi

  local remote_tag remote_ver
  remote_tag="$(extract_github_tag_name "${json}" | head -n1 || true)"
  remote_ver="${remote_tag#v}"

  if [[ ! "${remote_ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    log "Self-update: latest release tag '${remote_tag}' is not a valid version (X.Y.Z), skipping."
    return 0
  fi

  if ! version_is_newer "${remote_ver}" "${SCRIPT_VERSION}"; then
    log "Self-update: no newer version available (latest ${remote_ver})."
    return 0
  fi

  local script_url sums_url
  script_url="$(extract_asset_url "${json}" "${SELFUPDATE_PATH}" || true)"
  sums_url="$(extract_asset_url "${json}" "SHA256SUMS" || true)"
  if [[ -z "${script_url}" || -z "${sums_url}" ]]; then
    log "Self-update: release ${remote_tag} lacks '${SELFUPDATE_PATH}' and/or 'SHA256SUMS' assets; not updating."
    return 0
  fi

  local script_path
  if ! script_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"; then
    script_path="$0"
  fi

  local script_dir
  script_dir="$(dirname "${script_path}")"
  if [[ ! -w "${script_path}" || ! -w "${script_dir}" ]]; then
    log "Self-update: '${script_path}' or its directory is not writable, skipping."
    return 0
  fi

  # Temp files MUST be in the same directory as the target so the final mv is
  # an atomic rename (not a cross-filesystem copy that could leave a truncated
  # script behind if interrupted).
  local tmp tmp_sums
  if ! tmp="$(mktemp "${script_dir}/.netbird-delayed-update-linux.new.XXXXXX")"; then
    log "Self-update: failed to create temporary file in ${script_dir}."
    return 0
  fi
  if ! tmp_sums="$(mktemp "${script_dir}/.netbird-delayed-update-linux.sums.XXXXXX")"; then
    log "Self-update: failed to create temporary file in ${script_dir}."
    self_update_cleanup "${tmp}"
    return 0
  fi

  log "Self-update: downloading ${script_url}"
  if ! curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 \
      -H "User-Agent: ${ua}" "${script_url}" -o "${tmp}" 2>/dev/null \
     || ! curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 \
      -H "User-Agent: ${ua}" "${sums_url}" -o "${tmp_sums}" 2>/dev/null; then
    log "Self-update: failed to download release assets; current script left unchanged."
    self_update_cleanup "${tmp}" "${tmp_sums}"
    return 0
  fi

  # Exactly one checksum line must name the file exactly ("<hash>  <name>" or "<hash> *<name>").
  local expected actual
  expected="$(awk -v n="${SELFUPDATE_PATH}" '$2 == n || $2 == "*" n { print tolower($1) }' "${tmp_sums}")"
  if [[ ! "${expected}" =~ ^[0-9a-f]{64}$ ]]; then
    log "ERROR: Self-update: SHA256SUMS has no single valid entry for '${SELFUPDATE_PATH}'; current script left unchanged."
    self_update_cleanup "${tmp}" "${tmp_sums}"
    return 0
  fi
  actual="$(sha256sum "${tmp}" | awk '{print $1}')"
  if [[ "${actual}" != "${expected}" ]]; then
    log "ERROR: Self-update: SHA256 mismatch for downloaded script (expected ${expected}, got ${actual}); current script left unchanged."
    self_update_cleanup "${tmp}" "${tmp_sums}"
    return 0
  fi

  if ! grep -q "^SCRIPT_VERSION=\"${remote_ver}\"" "${tmp}" 2>/dev/null; then
    log "ERROR: Self-update: downloaded script does not declare SCRIPT_VERSION=\"${remote_ver}\"; current script left unchanged."
    self_update_cleanup "${tmp}" "${tmp_sums}"
    return 0
  fi

  local backup
  backup="${script_path}.bak-$(date -u +%Y%m%d-%H%M%S)"
  if ! cp -p "${script_path}" "${backup}"; then
    log "ERROR: Self-update: failed to back up current script to '${backup}'; not updating."
    self_update_cleanup "${tmp}" "${tmp_sums}"
    return 0
  fi

  chmod 755 "${tmp}" || true
  if ! mv -f "${tmp}" "${script_path}"; then
    log "ERROR: Self-update: failed to replace '${script_path}'; current script left unchanged."
    self_update_cleanup "${tmp}" "${tmp_sums}"
    return 0
  fi
  chmod 755 "${script_path}" || true
  self_update_cleanup "${tmp_sums}"

  log "Self-update: script updated ${SCRIPT_VERSION} -> ${remote_ver} (SHA256 verified, backup: ${backup}). New version will be used on the next run."
}

# -------------------- Helpers: NetBird client installation --------------------

netbird_is_installed() {
  if dpkg-query -W -f='${Status}' netbird 2>/dev/null | grep -q "install ok installed"; then
    return 0
  fi
  command -v netbird >/dev/null 2>&1
}

install_netbird_client() {
  if [[ "${EUID}" -ne 0 ]]; then
    log "ERROR: Installing NetBird requires root (run with sudo)."
    return 1
  fi

  log "Installing NetBird client from the official APT repository (${NETBIRD_APT_URL})."
  log "NOTE: The first installation installs the CURRENT latest version; the ${DELAY_DAYS}-day delay applies only to subsequent updates."

  export DEBIAN_FRONTEND=noninteractive

  if ! command -v curl >/dev/null 2>&1; then
    log "ERROR: curl is required to download the NetBird repository key."
    return 1
  fi
  if ! command -v gpg >/dev/null 2>&1; then
    log "gpg not found; installing package 'gnupg' (needed to verify the repository key)."
    if ! apt-get update -qq || ! apt-get install -y gnupg; then
      log "ERROR: failed to install gnupg (needed to verify the NetBird repository key)."
      return 1
    fi
  fi

  local tmpdir
  if ! tmpdir="$(mktemp -d)"; then
    log "ERROR: failed to create a temporary directory."
    return 1
  fi
  mkdir -m 700 "${tmpdir}/gnupg"

  local rc=0
  install_netbird_client_steps "${tmpdir}" || rc=$?
  rm -rf "${tmpdir}" || true
  return "${rc}"
}

install_netbird_client_steps() {
  local tmpdir="$1"
  local key="${tmpdir}/public.key"

  if ! curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 "${NETBIRD_KEY_URL}" -o "${key}"; then
    log "ERROR: failed to download ${NETBIRD_KEY_URL}."
    return 1
  fi

  # The file must contain exactly one primary key, and it must be NetBird's
  # (a second key would otherwise be trusted for the repository too).
  local fprs
  fprs="$(GNUPGHOME="${tmpdir}/gnupg" gpg --batch --show-keys --with-colons "${key}" 2>/dev/null \
    | awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }')" || true
  if [[ "${fprs}" != "${NETBIRD_KEY_FPR}" ]]; then
    log "ERROR: NetBird repository key fingerprint mismatch (expected ${NETBIRD_KEY_FPR}, got '${fprs//$'\n'/ }'). Nothing installed."
    return 1
  fi
  log "Repository key fingerprint verified: ${NETBIRD_KEY_FPR}."

  local key_bin="${tmpdir}/netbird-archive-keyring.gpg"
  if grep -q -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "${key}"; then
    if ! GNUPGHOME="${tmpdir}/gnupg" gpg --batch --yes --dearmor -o "${key_bin}" "${key}"; then
      log "ERROR: failed to dearmor the NetBird repository key."
      return 1
    fi
  elif ! cp "${key}" "${key_bin}"; then
    log "ERROR: failed to copy the NetBird repository key."
    return 1
  fi

  # Note: this function runs in an '|| rc=$?' context where 'set -e' is off,
  # so every step is checked explicitly.
  if ! install -D -m 0644 "${key_bin}" "${NETBIRD_KEYRING}"; then
    log "ERROR: failed to write ${NETBIRD_KEYRING}."
    return 1
  fi
  if ! printf 'deb [signed-by=%s] %s stable main\n' "${NETBIRD_KEYRING}" "${NETBIRD_APT_URL}" \
      >"${NETBIRD_APT_LIST}" || ! chmod 0644 "${NETBIRD_APT_LIST}"; then
    log "ERROR: failed to write ${NETBIRD_APT_LIST}."
    return 1
  fi
  log "Wrote ${NETBIRD_KEYRING} and ${NETBIRD_APT_LIST}."

  if ! apt-get update; then
    log "ERROR: 'apt-get update' failed after adding the NetBird repository."
    return 1
  fi
  if ! apt-get install -y netbird; then
    log "ERROR: 'apt-get install -y netbird' failed."
    return 1
  fi

  hash -r
  if ! command -v netbird >/dev/null 2>&1; then
    log "ERROR: package installed but the 'netbird' command was not found in PATH."
    return 1
  fi

  local ver
  ver="$(get_installed_version)"
  log "NetBird ${ver:-<unknown version>} installed (latest available, no delay for first install). Future updates will be delayed by ${DELAY_DAYS} day(s)."
}

ensure_netbird_client() {
  # Returns 0 if NetBird is (now) installed, 1 if it is not and we should stop.
  # Exits with an error if an installation was attempted and failed.
  if netbird_is_installed; then
    return 0
  fi

  if [[ "${INSTALL_CLIENT}" -eq 1 ]]; then
    log "NetBird not found; installing it (--install-client)."
  elif [[ -t 0 ]]; then
    local answer=""
    if ! read -r -p "NetBird не найден. Установить сейчас? [Y/n] " answer; then
      answer="n"
    fi
    case "${answer}" in
      ""|[Yy]|[Yy][Ee][Ss]) ;;
      *)
        log "NetBird is not installed; installation declined by user."
        return 1
        ;;
    esac
  else
    log "WARNING: NetBird (package 'netbird') is not installed. Not installing from a non-interactive run; use --install-client to install it."
    return 1
  fi

  if ! install_netbird_client; then
    log "ERROR: NetBird installation failed."
    exit 1
  fi
  return 0
}

# -------------------- Helpers: systemd install/uninstall --------------------

install_systemd_units() {
  validate_time_hhmm "${DAILY_TIME}"

  local src
  if ! src="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"; then
    src="$0"
  fi

  local extra_args=""
  if [[ "${SELF_UPDATE}" -ne 1 ]]; then
    extra_args=" --no-self-update"
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
ExecStart=${INSTALLED_SCRIPT_PATH} --delay-days ${DELAY_DAYS} --max-random-delay-seconds 0 --log-retention-days ${LOG_RETENTION_DAYS}${extra_args}
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

  # Install the exact version that has matured. An unpinned install would pick
  # whatever APT offers right now, which can be newer than the one we waited for.
  if ! apt-get install --only-upgrade -y "netbird=${candidate_ver}"; then
    log "ERROR: failed to install netbird=${candidate_ver}; service not restarted."
    return 1
  fi

  if dpkg-query -W -f='${Status}' netbird-ui 2>/dev/null | grep -q "install ok installed"; then
    if ! apt-get install --only-upgrade -y "netbird-ui=${candidate_ver}"; then
      log "WARNING: failed to upgrade netbird-ui to ${candidate_ver}; GUI left at its current version."
    fi
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

  check_prerequisites

  # Missing client: install it (--install-client or interactive "yes"),
  # otherwise log and stop. Done before the jitter so a prompt is not delayed.
  if ! netbird_is_installed; then
    if ensure_netbird_client; then
      log "NetBird was installed in this run; the delayed-update check starts with the next run."
    fi
    return 0
  fi

  if [[ "${MAX_RANDOM_DELAY_SECONDS}" -gt 0 ]]; then
    local sleep_for=$(( RANDOM % (MAX_RANDOM_DELAY_SECONDS + 1) ))
    log "Sleeping for ${sleep_for} second(s) before running checks (random jitter)."
    sleep "${sleep_for}"
  fi

  local installed_ver
  installed_ver="$(get_installed_version)"
  if [[ -z "${installed_ver}" ]]; then
    log "WARNING: 'netbird' command exists but the APT package 'netbird' is not installed; only APT installs are updated. Nothing to do."
    return 0
  fi

  # Refresh APT metadata first: the candidate must reflect the current repo,
  # not whatever was cached the last time apt ran.
  if ! apt-get update -qq 2>/dev/null; then
    log "WARNING: 'apt-get update' failed; using cached APT metadata."
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

  if ! perform_update "${installed_ver}" "${candidate_ver}" "${age_days}"; then
    return 1
  fi
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
      --install-client)
        INSTALL_CLIENT=1
        shift
        ;;
      --no-self-update)
        SELF_UPDATE=0
        shift
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
      if ! netbird_is_installed; then
        check_prerequisites
        ensure_netbird_client || true
      fi
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
