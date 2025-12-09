# NetBird Delayed Auto-Update

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) ![Platform: Linux](https://img.shields.io/badge/platform-Linux-informational) ![Init: systemd](https://img.shields.io/badge/init-systemd-blue) ![Shell: bash](https://img.shields.io/badge/shell-bash-green)

Helper script that implements **delayed / staged** updates for the NetBird client
installed from an APT repository.

Instead of upgrading to the newest package as soon as it appears, each new
version must "age" for a configurable number of days before it is allowed to
be installed. Short-lived or broken releases that are quickly replaced in the
repository will never reach your machines.

This project mirrors the behaviour of the Windows and macOS delayed update
scripts, but is tailored to Linux with APT and systemd.

Current script version: **0.2.0**

---

## Idea

- Do **not** upgrade NetBird immediately when a new version hits the APT repo.
- Treat the latest available version as a **candidate**.
- Let the candidate "age" for `N` days.
- Only after it stayed unchanged for `N` days, upgrade to that version.
- If a candidate is replaced quickly (hotfix or broken release), it never gets installed.

---

## Features

### Delayed rollout (version aging)

- The APT candidate version for `netbird` becomes a *candidate*.
- A candidate must stay unchanged for `--delay-days` days before upgrade is allowed.
- State is stored as a small JSON file at:

  ~~~text
  /var/lib/netbird-delayed-update/state.json
  ~~~

### No auto-install

- The script only upgrades an already installed `netbird` package.
- If NetBird is not present locally, it logs a message and exits without installing anything.

### APT-only update

- Uses APT metadata (`apt-cache policy netbird`) to detect the candidate version.
- Upgrade is performed via:

  ~~~bash
  apt-get install --only-upgrade -y netbird [netbird-ui]
  ~~~

- If `netbird-ui` is not available, the script falls back to upgrading `netbird` only.

### Log files with retention

- Each run writes a log file under:

  ~~~text
  /var/lib/netbird-delayed-update/netbird-delayed-update-YYYYMMDD-HHMMSS.log
  ~~~

- `--log-retention-days` (default: `60`) controls how long these logs are kept.
- `--log-retention-days 0` disables log cleanup.

### Script self-update (optional)

- On each run, the script can check the latest GitHub release of this repository.
- If a newer version exists, it:
  - tries `git pull --ff-only` when the script lives inside a git checkout, or
  - downloads `netbird-delayed-update-linux.sh` from the tagged version on
    `raw.githubusercontent.com` and overwrites the local script.
- The new version is used on the **next** run.

### Systemd integration

- `--install` / `-i` creates or updates:
  - `netbird-delayed-update.service`
  - `netbird-delayed-update.timer`
- Daily schedule at a configurable time (`--daily-time "HH:MM"`, default `04:00`).
- `RandomizedDelaySec` is set to `--max-random-delay-seconds` (default `3600`)
  to spread the actual run time across machines.
- The timer is configured with `Persistent=true`, so missed runs are executed
  shortly after boot.

---

## Requirements

- Linux system with:
  - `systemd` (for the service and timer),
  - `bash`,
  - `curl`,
  - `python3`,
  - APT (`apt-get`, `apt-cache`, `dpkg-query`).
- NetBird installed from an APT repository, so that:

  ~~~bash
  apt-cache policy netbird
  ~~~

  shows a valid `Candidate` version.
- Root access (`sudo`) to:
  - install / remove systemd units,
  - run the delayed-update script in production.

---

## Repository structure

~~~text
netbird-delayed-auto-update-linux/
├── LICENSE
├── README.md
├── CHANGELOG.md
└── netbird-delayed-update-linux.sh
~~~

---

## Quick start

### 1. Clone the repository

~~~bash
git clone https://github.com/NetHorror/netbird-delayed-auto-update-linux.git
cd netbird-delayed-auto-update-linux
~~~

### 2. Make the main script executable

~~~bash
chmod +x ./netbird-delayed-update-linux.sh
~~~

### 3. (Optional) Test a one-off run

Run a single check with **no** delay and **no** random jitter:

~~~bash
sudo ./netbird-delayed-update-linux.sh \
  --delay-days 0 \
  --max-random-delay-seconds 0 \
  --log-retention-days 60
~~~

You should see log output mentioning:

- the local NetBird version,
- the candidate version from APT,
- whether the upgrade is allowed or still "aging".

The full log file is stored under:

~~~text
/var/lib/netbird-delayed-update/netbird-delayed-update-YYYYMMDD-HHMMSS.log
~~~

---

## Installing the systemd timer (recommended)

To install with default settings:

- delay: 3 days
- random jitter: up to 3600 seconds
- time: 04:00 (server local time)
- log retention: 60 days

run:

~~~bash
sudo ./netbird-delayed-update-linux.sh --install
~~~

To customise the schedule and settings:

~~~bash
sudo ./netbird-delayed-update-linux.sh --install \
  --delay-days 3 \
  --max-random-delay-seconds 3600 \
  --log-retention-days 60 \
  --daily-time "04:00"
~~~

This will:

- copy the script to `/usr/local/sbin/netbird-delayed-update.sh`;
- create `/etc/systemd/system/netbird-delayed-update.service`;
- create `/etc/systemd/system/netbird-delayed-update.timer`;
- reload systemd and enable the timer;
- schedule the script to run daily at the specified time, with a random delay.

---

## How it works (behaviour details)

On each run (manual or via systemd), the script:

1. Verifies that the system is APT-based and that `netbird` is installed locally.
2. Reads the local version from `dpkg`:

   ~~~bash
   dpkg-query -W -f='${Version}\n' netbird
   ~~~

3. Reads the candidate version from APT:

   ~~~bash
   apt-cache policy netbird
   ~~~

4. Loads `state.json`. If the candidate version changed compared to the last run:
   - updates `CandidateVersion`,
   - sets `FirstSeenUtc` and `LastCheckUtc` to now,
   - logs that the version is new and starts the aging period (no upgrade yet).

5. Computes the age (in days) between `FirstSeenUtc` and the current time:
   - negative values (clock skew) are clamped to `0`.

6. If `age < delayDays`:
   - logs that the version is still aging and **does not** upgrade.

7. If the candidate has aged enough:
   - compares local vs candidate version with `dpkg --compare-versions`;
   - if the local version is older:
     - runs `apt-get update` (best-effort),
     - attempts to upgrade `netbird` and optionally `netbird-ui`,
     - restarts the NetBird service via `systemctl restart netbird` or
       `netbird service restart`.

---

## Logs and state

All runtime files live under:

~~~text
/var/lib/netbird-delayed-update/
~~~

- `state.json` – delayed rollout state:
  - `CandidateVersion`
  - `FirstSeenUtc`
  - `LastCheckUtc`
- `netbird-delayed-update-*.log` – per-run logs.
- Additional files may appear in the future if needed.

---

## Manual one-off runs

You can also run the script manually without installing the timer, for example:

~~~bash
sudo ./netbird-delayed-update-linux.sh \
  --delay-days 7 \
  --max-random-delay-seconds 0 \
  --log-retention-days 30
~~~

This is useful for:

- testing in staging,
- forcing a check immediately after changing the delay or other parameters.

---

## Uninstall

To remove only the systemd units (keep script, state and logs):

~~~bash
sudo ./netbird-delayed-update-linux.sh --uninstall
~~~

To also remove the installed script and all runtime files:

~~~bash
sudo ./netbird-delayed-update-linux.sh --uninstall --remove-state
~~~

This will:

- disable and stop `netbird-delayed-update.timer`,
- remove the `.service` and `.timer` from `/etc/systemd/system`,
- reload systemd,
- delete `/usr/local/sbin/netbird-delayed-update.sh` and
  `/var/lib/netbird-delayed-update` when `--remove-state` is used.

---

## Versioning

This project uses semantic versioning:

- **0.2.0** – main script `netbird-delayed-update-linux.sh`, logs with retention, JSON state,
  script self-update and CLI-based systemd installation.
- **0.1.0** – initial delayed auto-update implementation with a simple installer script
  and basic systemd units.

See `CHANGELOG.md` for detailed history.
