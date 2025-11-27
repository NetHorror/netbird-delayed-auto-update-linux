# NetBird Delayed Auto-Update (APT + systemd)

This repository provides a small, opinionated automation that **delays NetBird updates for a configurable number of days** after a new version appears in the APT repository.

The main idea:

> Don’t upgrade clients immediately when a new NetBird version hits the repo.  
> Instead, wait _N_ days. If that version gets replaced quickly (a “bad” or “hotfix” release), clients will **never** upgrade to it.

The solution is built around:

- a single installer script: `install-netbird-delayed-update.sh`
- a systemd oneshot service: `netbird-delayed-update.service`
- a systemd timer: `netbird-delayed-update.timer`
- an update logic script: `/usr/local/sbin/netbird-delayed-update.sh`

---

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
git clone https://github.com/NetHorror/netbird-delayed-auto-update.git
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
