# Changelog

All notable changes to this project will be documented in this file.

The format is inspired by https://keepachangelog.com/en/1.0.0/,
and this project uses semantic versioning.

---

## [0.2.0] – 2025-12-10

### Added

- New main script `netbird-delayed-update-linux.sh` with:
  - delayed / staged rollout based on the APT candidate version of `netbird`;
  - JSON state file at `/var/lib/netbird-delayed-update/state.json` with:
    - `CandidateVersion`
    - `FirstSeenUtc`
    - `LastCheckUtc`;
  - per-run log files under:
    ~~~text
    /var/lib/netbird-delayed-update/netbird-delayed-update-YYYYMMDD-HHMMSS.log
    ~~~
  - log retention via `--log-retention-days` (0 disables cleanup);
  - optional script self-update from GitHub releases of this repository.

- Command-line interface for installation and configuration:
  - `--install` / `-i` to create or update systemd service and timer;
  - `--uninstall` / `-u` to remove systemd units;
  - `--remove-state` to delete the installed script and the state/log directory on uninstall;
  - `--delay-days`, `--max-random-delay-seconds`, `--daily-time`, `--log-retention-days`
    for fine-grained behaviour control.

- Systemd integration:
  - installs `netbird-delayed-update.service` and `netbird-delayed-update.timer`
    under `/etc/systemd/system`;
  - daily schedule at configurable `--daily-time` (default: `04:00`);
  - `RandomizedDelaySec` is set from `--max-random-delay-seconds` to spread
    the actual run time across machines;
  - timer uses `Persistent=true` so missed runs are executed after boot.

### Changed

- The documentation now focuses on `netbird-delayed-update-linux.sh` as the main entry point,
  with direct `--install` / `--uninstall` usage instead of the legacy installer script.
- Age calculation between `FirstSeenUtc` and the current time is clamped to a minimum
  of `0` days to avoid negative values if the system clock moves backwards.
- Version comparison is performed via `dpkg --compare-versions`, ensuring correct
  ordering for Debian/Ubuntu-style versions.

### Fixed

- More robust behaviour when:
  - the `netbird` package is not installed locally (no auto-install; the script logs
    a message and exits successfully);
  - APT reports `Candidate: (none)` or no candidate at all;
  - the optional `netbird-ui` package is missing (the script falls back to upgrading
    only the `netbird` package).
- Log file handling now:
  - always creates a fresh, timestamped log file per run;
  - cleans up old log files based on `--log-retention-days`, when configured.

---

## [0.1.0] – 2025-11-27

### Added

- Initial public release of an APT-based delayed auto-update for the `netbird` package:
  - configurable grace period (minimum age in days) for a new candidate version;
  - systemd oneshot service and timer;
  - simple local state file in:
    ~~~text
    /var/lib/netbird-delayed-update/state
    ~~~
- Basic README with installation steps and a high-level explanation of the delayed
  rollout behaviour.


# GitHub Release v0.2.0 (body)

## ✨ What’s new in 0.2.0

This release turns the Linux helper into a proper sibling of the Windows and macOS
delayed update scripts:

- dedicated main script `netbird-delayed-update-linux.sh`;
- JSON state file with candidate version and timestamps;
- per-run log files with retention;
- optional script self-update from GitHub releases;
- CLI-based systemd installation and uninstall.

---

### 🚀 Added

- **Main script** `netbird-delayed-update-linux.sh`:
  - implements delayed / staged rollout using the APT candidate version of `netbird`;
  - stores state in `/var/lib/netbird-delayed-update/state.json` with:
    - `CandidateVersion`
    - `FirstSeenUtc`
    - `LastCheckUtc`;
  - writes per-run logs under:
    ~~~text
    /var/lib/netbird-delayed-update/netbird-delayed-update-YYYYMMDD-HHMMSS.log
    ~~~
  - supports `--log-retention-days` (default: `60`, `0` disables cleanup).

- **Script self-update (optional)**:
  - queries the latest GitHub release of this repository;
  - compares the release tag (`X.Y.Z`) to `SCRIPT_VERSION` (currently `0.2.0`);
  - if newer:
    - tries `git pull --ff-only` when the script lives inside a git checkout;
    - otherwise downloads `netbird-delayed-update-linux.sh` from the tagged version
      on `raw.githubusercontent.com` and overwrites the local script;
  - the updated script is used on the **next** run.

- **Systemd integration via CLI**:
  - `--install` / `-i` creates or updates:
    - `/etc/systemd/system/netbird-delayed-update.service`
    - `/etc/systemd/system/netbird-delayed-update.timer`;
  - `--uninstall` / `-u` removes these units;
  - `--remove-state` additionally removes:
    - `/usr/local/sbin/netbird-delayed-update.sh`
    - `/var/lib/netbird-delayed-update`;
  - configuration options:
    - `--delay-days`
    - `--max-random-delay-seconds`
    - `--daily-time "HH:MM"`
    - `--log-retention-days`.

---

### 🔧 Changed

- Age calculation between `FirstSeenUtc` and the current time is clamped to **≥ 0 days**
  to avoid negative values when the system clock moves backwards.
- Version comparison is now based on `dpkg --compare-versions`, which correctly handles
  Debian/Ubuntu-style version strings.
- The README and examples now use `netbird-delayed-update-linux.sh` directly as the main
  entry point for:
  - one-off runs,
  - installing the systemd service and timer,
  - uninstalling them later.

---

### 🐛 Fixed

- More robust behaviour when:
  - the `netbird` package is not installed locally (no silent auto-install);
  - APT reports `Candidate: (none)` or no candidate at all;
  - the optional `netbird-ui` package is missing from the repository
    (upgrade falls back to `netbird` only).
- Log creation and cleanup are now consistent across runs:
  - each run creates a new timestamped log file;
  - old log files are removed based on `--log-retention-days` when configured.

---

### 🧪 Upgrade / install notes

For **new installations**, follow the updated README:

~~~bash
git clone https://github.com/NetHorror/netbird-delayed-auto-update-linux.git
cd netbird-delayed-auto-update-linux
chmod +x ./netbird-delayed-update-linux.sh
sudo ./netbird-delayed-update-linux.sh --install
~~~

This will:

- copy the script to `/usr/local/sbin/netbird-delayed-update.sh`;
- install `netbird-delayed-update.service` and `netbird-delayed-update.timer`;
- reload systemd and enable the timer;
- schedule a daily delayed-update check with version aging and log retention.

Existing setups based on the previous installer script can be migrated by:

- dropping the old systemd units, and
- reinstalling them via `netbird-delayed-update-linux.sh --install` with the desired
  parameters.

See `CHANGELOG.md` for the full list of changes.
