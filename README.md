# NetBird Delayed Auto-Update

[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)
![Platform: Linux](https://img.shields.io/badge/platform-Linux-informational)
![Init: systemd](https://img.shields.io/badge/init-systemd-blue)
![Shell: bash](https://img.shields.io/badge/shell-bash-green)

Helper script that implements **delayed / staged** updates for the NetBird client
installed from an APT repository.

Instead of upgrading to the newest package as soon as it appears, each new
version must "age" for a configurable number of days before it is allowed to
be installed. Short-lived or broken releases that are quickly replaced in the
repository will never reach your machines.

---

## Quick start

### 1. Install

~~~bash
VER=0.3.0
BASE=https://github.com/NetHorror/netbird-delayed-auto-update-linux/releases/download/$VER
curl -fsSLO "$BASE/netbird-delayed-update-linux.sh"
curl -fsSLO "$BASE/SHA256SUMS"
sha256sum -c SHA256SUMS --ignore-missing && sudo bash netbird-delayed-update-linux.sh --install --install-client
~~~

The install command:

1. checks the script against `SHA256SUMS` from the release (the chain stops if the check fails);
2. installs NetBird from the official APT repository if it is missing (`--install-client`);
3. installs a daily systemd timer (04:00, with up to 1 hour of random delay).

> **The first install takes the current latest NetBird version.** The delay (`--delay-days`, 10 days by default) applies only to later updates.

### 2. Check

~~~bash
systemctl list-timers netbird-delayed-update.timer
sudo bash netbird-delayed-update-linux.sh --delay-days 0 --max-random-delay-seconds 0
~~~

The second command is a one-off run without delay. It can upgrade NetBird right away if a newer version exists.
Logs are in `/var/lib/netbird-delayed-update/`.

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

### Client installation (opt-in)

- NetBird is considered installed if `dpkg-query` reports the `netbird` package
  as installed or `command -v netbird` finds the CLI.
- If NetBird is missing:
  - with `--install-client` it is installed without a prompt;
  - in an interactive run (`stdin` is a terminal) the script asks
    `NetBird not found. Install now? [Y/n]` (Enter = yes);
  - in a non-interactive run (systemd timer) it logs a `WARNING` and exits with code `0`,
    **without** installing anything.
- Installation uses the official APT repository:
  1. downloads `https://pkgs.netbird.io/debian/public.key`;
  2. verifies that the file contains exactly one primary key with fingerprint
     `EFE37DF047DF7CCDF1FC54FA83F79AD029778355` (otherwise nothing is installed);
  3. stores it as `/usr/share/keyrings/netbird-archive-keyring.gpg`;
  4. writes `/etc/apt/sources.list.d/netbird.list`:
     `deb [signed-by=/usr/share/keyrings/netbird-archive-keyring.gpg] https://pkgs.netbird.io/debian stable main`;
  5. runs `apt-get update` and `apt-get install -y netbird`, then checks that `netbird` is in `PATH`.
- `gnupg` is installed automatically if `gpg` is missing (needed for the key check).
- The first installation gets the **current latest** version; the delay applies only to subsequent updates.
- A NetBird binary that was not installed as the APT package `netbird` is left alone (it is not updated).

### APT-only update

- Uses APT metadata (`apt-cache policy netbird`) to detect the candidate version.
- Upgrade installs exactly the version that has aged (pinned), so a newer
  release that appeared in the meantime cannot bypass the delay:

~~~bash
apt-get install --only-upgrade -y netbird=<aged-version> [netbird-ui=<aged-version>]
~~~

- `netbird-ui` is upgraded only if it is installed.

### Log files with retention

- Each run writes a log file under:

~~~text
/var/lib/netbird-delayed-update/netbird-delayed-update-YYYYMMDD-HHMMSS.log
~~~

- `--log-retention-days` (default: `60`) controls how long these logs are kept.
- `--log-retention-days 0` disables log cleanup.

### Script self-update (on by default, `--no-self-update` to disable)

- On each run the script queries
  `https://api.github.com/repos/NetHorror/netbird-delayed-auto-update-linux/releases/latest`.
- The tag (without a leading `v`) must look like `X.Y.Z` and be newer than the running version.
- From the release **assets** it downloads `netbird-delayed-update-linux.sh` and `SHA256SUMS`
  (into the script's own directory, so the final `mv` is atomic). If either asset is missing, nothing changes.
- The update is applied only if:
  - the script's SHA-256 matches the `SHA256SUMS` line for exactly `netbird-delayed-update-linux.sh`, and
  - the script declares `SCRIPT_VERSION="<tag version>"`.
- The previous script is kept as `<path>.bak-<timestamp>`; the new one is moved in atomically with mode `755`.
- No `git pull` and no download from `raw.githubusercontent.com` are used anymore.
- The new version is used on the **next** run.
- `--no-self-update` disables the check (also written into the systemd service when used with `--install`).

> **Releasing:** each release must use a tag without the `v` prefix (e.g. `0.3.0`) and carry two
> assets: `netbird-delayed-update-linux.sh` and `SHA256SUMS`
> (`sha256sum netbird-delayed-update-linux.sh > SHA256SUMS`). Installations of 0.2.x
> still update themselves from the raw file of the tag, which is why the tag must match `SCRIPT_VERSION`.

### Systemd integration

- `--install` / `-i` creates or updates:
  - `netbird-delayed-update.service`
  - `netbird-delayed-update.timer`
- Daily schedule at a configurable time (`--daily-time "HH:MM"`, default `04:00`).
- `RandomizedDelaySec` is set to `--max-random-delay-seconds` (default `3600`) to spread the actual run time across machines.
- When installed via `--install`, the service runs the script with `--max-random-delay-seconds 0` to avoid double jitter (systemd timer already randomizes the start).
- The timer is configured with `Persistent=true`, so missed runs are executed shortly after boot.

### Concurrency protection
- Uses `flock` (if available) to prevent concurrent runs and avoid APT/dpkg lock conflicts.

---

## Requirements

- Linux system with:
  - `systemd` (for the service and timer),
  - `bash`,
  - `curl`, `sha256sum` (coreutils),
  - `flock` (recommended; provided by util-linux on most distros),
  - APT (`apt-get`, `apt-cache`, `dpkg-query`),
  - `gpg` (only for `--install-client`; installed automatically if missing).
- NetBird installed from an APT repository (or let the script install it with `--install-client`), so that:

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

## Options

| Option | Default | Meaning |
|---|---|---|
| `--install` | | Install the systemd service and timer; copies the script to `/usr/local/sbin/netbird-delayed-update.sh`. |
| `--uninstall` | | Remove the service and timer. Add `--remove-state` to also delete the script, state and logs. |
| `--install-client` | off | Install NetBird from APT if it is missing, without asking. The timer never installs NetBird by itself. |
| `--delay-days N` | 10 | Days a new version must stay unchanged before it is installed. |
| `--max-random-delay-seconds N` | 3600 | Random delay before each check. |
| `--daily-time "HH:MM"` | 04:00 | Time of the daily run. |
| `--log-retention-days N` | 60 | Delete logs older than N days; `0` keeps all logs. |
| `--no-self-update` | off | Do not update this script from GitHub releases. |

Values given to `--install` are written into the systemd unit. To change them, run `--install` again.

---

## How it works (behaviour details)

On each run (manual or via systemd), the script:
1. Verifies that the system is APT-based and that `netbird` is installed locally
   (if not, see *Client installation* above; a freshly installed client is not
   checked for updates in the same run).
2. Reads the local version from `dpkg`:

~~~bash
dpkg-query -W -f='${Version}\n' netbird
~~~

3. Runs `apt-get update` (best-effort) and reads the candidate version from APT:

~~~bash
apt-cache policy netbird
~~~

4. Loads `state.json`.
   If the candidate version changed compared to the last run:
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
     - installs exactly the aged version of `netbird` (and `netbird-ui`, if installed),
     - restarts the NetBird service via `systemctl restart netbird` or `netbird service restart`.

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
- delete `/usr/local/sbin/netbird-delayed-update.sh` and `/var/lib/netbird-delayed-update`
  when `--remove-state` is used.

---

## Related projects

- Windows (Chocolatey + Scheduled Task): [`NetHorror/netbird-delayed-auto-update-windows`](https://github.com/NetHorror/netbird-delayed-auto-update-windows)
- macOS (launchd): [`NetHorror/netbird-delayed-auto-update-macos`](https://github.com/NetHorror/netbird-delayed-auto-update-macos)

---

See `CHANGELOG.md` for detailed history.
