# NetBird Delayed Auto-Update (APT + systemd)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE) ![Platform: Linux](https://img.shields.io/badge/platform-Linux-informational) ![Init: systemd](https://img.shields.io/badge/init-systemd-blue) ![Shell: bash](https://img.shields.io/badge/shell-bash-green)

This repository provides a small, opinionated automation that **delays NetBird updates for a configurable number of days** after a new version appears in the APT repository.

The main idea:

> Don’t upgrade clients immediately when a new NetBird version hits the repo.  
> Instead, wait _N_ days. If that version gets replaced quickly (a “bad” or “hotfix” release), clients will **never** upgrade to it.

The solution is built around:

- a single installer script: `install-netbird-delayed-update.sh`
- a systemd oneshot service: `netbird-delayed-update.service`
- a systemd timer: `netbird-delayed-update.timer`
- an update logic script: `/usr/local/sbin/netbird-delayed-update.sh`

## Quick start

```bash
# Clone the repository and enter it
git clone https://github.com/NetHorror/netbird-delayed-auto-update.git
cd netbird-delayed-auto-update

# Make the installer executable
chmod +x install-netbird-delayed-update.sh

# Install with a 3-day grace period (or pick your own number of days)
sudo ./install-netbird-delayed-update.sh 3

# Verify that the timer is active
systemctl status netbird-delayed-update.timer

# Check the last runs
journalctl -u netbird-delayed-update.service -n 20 --no-pager
```

## Features

- 🕒 **Version aging**  
  Only upgrades to a new NetBird version after it has been present in the APT repository for at least _N_ days (default: `3`).

- ⏰ **Daily check at 04:00 (server time)**  
  The systemd timer is scheduled for `04:00` based on the server’s local timezone.

- 🎲 **Random spread of updates**  
  Uses `RandomizedDelaySec=3600`, so the effective run happens at a random time between `04:00` and `05:00`. This helps avoid thundering herds hitting the package repository simultaneously.

- 📦 **APT-based only**  
  Uses the APT **candidate** version for the `netbird` package; no external APIs (no GitHub, no HTTP calls).

- 🧠 **Local state tracking**  
  Keeps a simple state file with:
  - the last seen candidate version
  - the timestamp when it was first observed  
  (stored in `/var/lib/netbird-delayed-update/state`)

- 🔒 **Safe behavior**  
  - Does **not** auto-install NetBird if it’s missing.  
  - Only performs `--only-upgrade` on the `netbird` (and optionally `netbird-ui`) package.

---

## Requirements

- Linux with **systemd** (e.g. Ubuntu 24.04).
- `netbird` installed from an APT repository (so that `apt-cache policy netbird` shows a valid `Candidate` version).
- Root access (`sudo`) to install and manage systemd units.

---

## Installation

Clone or download this repository, then run the installer script as root.

```bash
git clone https://github.com/NetHorror/netbird-delayed-auto-update-linux.git
cd netbird-delayed-auto-update

# Make the installer executable
chmod +x install-netbird-delayed-update.sh

# Default: wait 3 days after a new version appears in APT
sudo ./install-netbird-delayed-update.sh

# Or specify a custom delay (e.g. 5 days):
sudo ./install-netbird-delayed-update.sh 5
```
  
## The installer will:

- Place the main update script at /usr/local/sbin/netbird-delayed-update.sh
- Create /var/lib/netbird-delayed-update for storing the state file
- Install netbird-delayed-update.service
- Install netbird-delayed-update.timer
- Reload systemd and enable + start the timer
- After installation, the check will run automatically every day between 04:00–05:00 server time

---

## How it works

1. The timer (`netbird-delayed-update.timer`) runs the service once per day, at 04:00 (with a randomized delay up to 1 hour).
2. The service calls `/usr/local/sbin/netbird-delayed-update.sh`.
3. The update script:
   - Reads the current **candidate version** for `netbird` from APT using `apt-cache policy`.
   - Reads the **currently installed** version from `dpkg`.
   - If the installed version is already `>=` candidate → exits (no update needed, state can be cleaned up).
   - If the candidate version differs from what is stored in its local state file (`/var/lib/netbird-delayed-update/state`), it:
     - Records the new version and the current timestamp.
     - Exits **without updating**. This starts the “aging” period.
   - On subsequent runs, if the candidate version has been the same for at least **N days** (based on the stored timestamp), it:
     - Runs `apt-get update`.
     - Attempts `apt-get install --only-upgrade -y netbird netbird-ui`, and falls back to just `netbird` if the UI package is not present.
     - Restarts the NetBird service via systemd (`systemctl restart netbird`) if available, or falls back to `netbird service restart` if not.

If a “bad” NetBird version appears and then gets replaced in APT _before_ it’s old enough, the script will never upgrade to it. The “aging” counter resets when a new candidate version is detected.

---

## Example timeline

Below is a simplified example of how the delayed update logic behaves over time.

**Assumptions:**

- `MIN_AGE_DAYS = 3`
- The update check runs once per day at ~04:00 server time.

### Day 0 – New version appears

- A new NetBird version `1.2.0` appears in the APT repository.
- The next time the timer runs (~04:00):
  - The script sees that the **candidate version** (`1.2.0`) is **new** compared to what is stored in its local state (or there is no state yet).
  - It records:
    - version: `1.2.0`
    - first-seen timestamp: `now`
  - **No update is performed yet**. The aging period starts.

### Day 1 – Version still “young”

- Timer runs again (~04:00).
- Candidate version in APT is still `1.2.0`.
- The script:
  - Loads the stored state (`1.2.0`, first-seen = yesterday).
  - Calculates the age: ~1 day.
  - Since `1 day < MIN_AGE_DAYS (3)` → the update is **deferred**.
  - No change is made; it just waits.

### Day 2 – Hotfix appears (bad version replaced)

- During the day, the NetBird repository replaces `1.2.0` with `1.2.1` (e.g. a hotfix).
- Next morning (~04:00):
  - The candidate version is now `1.2.1`.
  - The local state still contains `1.2.0` as the last seen version.
  - The script detects that the candidate version has changed:
    - It **overwrites the state** with:
      - version: `1.2.1`
      - first-seen timestamp: `now`
    - It **does not upgrade** yet.
  - Result: clients **never upgraded to 1.2.0**, which turned out to be a short-lived version.

### Day 3 – New version still aging

- Timer runs (~04:00).
- Candidate in APT is still `1.2.1`.
- The script:
  - Reads state for `1.2.1` (first-seen = yesterday).
  - Age ≈ 1 day.
  - Since `1 day < MIN_AGE_DAYS (3)` → still **too fresh**, no update.

### Day 4 – Version is old enough

- Timer runs (~04:00).
- Candidate is still `1.2.1`.
- Age since first seen reaches or exceeds `3` days (depending on exact timing).
- Once `age_days >= MIN_AGE_DAYS`:
  - The script:
    - Verifies that the installed version `<` candidate.
    - Runs `apt-get update` and then `apt-get install --only-upgrade -y netbird [netbird-ui]`.
    - Restarts the NetBird service.
  - All clients now upgrade directly to `1.2.1`, **skipping the short-lived 1.2.0 entirely**.

### Day X – Candidate equals installed

- After the successful upgrade, on subsequent days:
  - The script sees that the **installed version is already >= candidate version**.
  - It exits immediately with “no update needed” and optionally clears the old state file.
  - When a new version appears in the repository, the cycle starts over again.

---

## Expected output (logs)

The main place to observe the behavior is `journalctl` for the service unit:

```bash
journalctl -u netbird-delayed-update.service -n 50
```

Below are a few typical snippets.

### 1. First time a new candidate version is seen

```text
New candidate version detected: 1.2.3. First seen now, waiting 3 day(s).
```

The script records the new version and starts the aging period. No upgrade is performed yet.

### 2. Version still too “young” (aging in progress)

```text
Candidate version 1.2.3 has been in the repository for approximately 1 day(s).
Age is less than 3 day(s) – deferring update.
```

You’ll see this every day until the age threshold is reached, as long as the candidate version stays the same.

### 3. Version is mature enough and gets upgraded

```text
Candidate version 1.2.3 has been in the repository for approximately 3 day(s).
Upgrading NetBird: 1.2.2 → 1.2.3 (version has matured for 3 day(s)).
NetBird delayed update finished.
```

Depending on your systemd logging setup, you may also see `apt-get` progress lines and a subsequent service restart, e.g.:

```text
systemd[1]: Starting NetBird auto-update with version aging (via APT)...
netbird-delayed-update.sh[XXXX]: Upgrading NetBird: 1.2.2 → 1.2.3 (version has matured for 3 day(s)).
systemd[1]: netbird-delayed-update.service: Succeeded.
systemd[1]: Finished NetBird auto-update with version aging (via APT).
```

### 4. Already up to date

```text
Local version 1.2.3 is already >= repository version 1.2.3. No update needed.
```

Typical output once your system is already on the latest candidate version.

### 5. NetBird not installed (safety check)

```text
NetBird (package netbird) is not installed. Auto-install is not performed.
```

The automation only upgrades existing installations and does not silently install NetBird.

---

## Configuration

### Minimum age (days)

The minimum age is passed as an environment variable `MIN_AGE_DAYS` from the systemd service:

```ini
# /etc/systemd/system/netbird-delayed-update.service
[Service]
Type=oneshot
Environment=MIN_AGE_DAYS=3
ExecStart=/usr/local/sbin/netbird-delayed-update.sh
```

To adjust it later:

```bash
sudo nano /etc/systemd/system/netbird-delayed-update.service
# change MIN_AGE_DAYS value
sudo systemctl daemon-reload
sudo systemctl restart netbird-delayed-update.timer
```

### Timer schedule

The timer is defined as:

```ini
# /etc/systemd/system/netbird-delayed-update.timer
[Timer]
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=3600
Persistent=true
```

You can adjust the time or the random spread as needed.

---

## Uninstall

To remove the automation:

```bash
sudo systemctl disable --now netbird-delayed-update.timer
sudo rm -f /etc/systemd/system/netbird-delayed-update.timer
sudo rm -f /etc/systemd/system/netbird-delayed-update.service
sudo rm -f /usr/local/sbin/netbird-delayed-update.sh
sudo rm -rf /var/lib/netbird-delayed-update
sudo systemctl daemon-reload
```

NetBird itself is **not** removed by this; only the delayed update mechanism.

---
