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
