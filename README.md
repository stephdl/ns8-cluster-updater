# ns8-cluster-updater

Bash script to update a [NethServer 8](https://nethserver.org) cluster: core,
applications and OS packages, in one run or separately, with a pre-check that
skips an update call entirely when nothing is pending.

## Why

`update-core` and `update-modules` are cluster actions available through
`api-cli`. Calling `update-core` also restarts `redis.service` and
`api-server.service` on every targeted node, even when there is no new core
image to install (this is how NS8 core's own `update-core.d/` hooks work).
That restart drops the cluster-admin UI websocket and any in-flight
`api-cli` task for a few seconds. This script checks whether an update is
actually available (`list-core-modules` / `list-updates`) before calling the
action, so a no-op run doesn't restart anything. If a pre-check itself fails
(`api-cli`/`jq` error), the script dies loudly instead of silently treating
the failure as "nothing pending".

Every cluster task is also submitted with `extra.isNotificationHidden`, so it
doesn't pop a toast in every admin's cluster-admin UI. `api-cli` hardcodes
this to `false` with no CLI flag to change it, so the script talks to the
underlying `agent.tasks` Python API directly for this one thing. Failures
still surface normally, only successful no-op-looking tasks stay quiet.

## Requirements

- Run as `root`, on the cluster leader (the script checks
  `get-cluster-status .leader` and refuses otherwise).
- `runagent` (NS8's agent framework) and `jq`.
- For `--os-safe`/`--os-full`: passwordless root SSH from the leader to every
  worker node over the cluster VPN (`10.5.4.0/24` by default). NS8 leaders
  already have this by design (used for cluster management), so nothing extra
  to set up in a normal cluster.
- Works on mixed clusters (some nodes `dnf`-based, some `apt`-based).

## Usage

```
ns8-cluster-updater.sh [--core] [--modules] [--os-safe|--os-full] [--all] [-h|--help]
```

| Option        | Effect |
|---------------|--------|
| `--core`      | Update NS8 core on all cluster nodes, only if a newer version is available. |
| `--modules`   | Update all NS8 app instances, on all nodes, only if at least one has a pending update. |
| `--os-safe`   | Update OS packages, restricted to official distro repos, no package removal/addition. |
| `--os-full`   | Update OS packages, all enabled repos, full dependency resolution. Can install a new kernel. |
| `--all`       | Shortcut for `--os-safe --core --modules`, run in that order (same as NS8's own automatic updates). |
| `-h`, `--help`| Show usage and exit. |

Running the script with no option prints the usage and does nothing (safe by
default, no accidental cluster-wide update).

### `--os-safe` vs `--os-full`

|              | dnf (Rocky/AlmaLinux)                          | apt (Debian/Ubuntu) |
|--------------|-------------------------------------------------|----------------------|
| `--os-safe`  | `--disablerepo='*' --enablerepo=ns-baseos,ns-appstream` (same repos as NS8's own `update-os` node action) | `sources.list` only (`sources.list.d/` ignored), plain `apt-get upgrade` (never removes or adds a package) |
| `--os-full`  | all enabled repos (e.g. EPEL)                    | all sources, `apt-get dist-upgrade` (full dependency resolution, can add/remove packages, install a new kernel) |

`--os-safe` is the low-risk default (also used by `--all`). `--os-full` must
be requested explicitly.

On Debian/Ubuntu, both modes run with `DEBIAN_FRONTEND=noninteractive` plus
`Dpkg::Options::=--force-confdef` and `Dpkg::Options::=--force-confold`: if a
package update ships a new version of a config file you've edited locally,
dpkg keeps your local version automatically instead of prompting or silently
overwriting it. This makes the whole run non-interactive by design, no manual
step needed.

### Reboot detection

The script never reboots a node. It only reports, at the end of the run,
whether at least one node needs a reboot, and leaves the decision to the
sysadmin:

- dnf: `needs-restarting -r`.
- apt: `/var/run/reboot-required` if present, else `needrestart -b`, else a
  fallback comparing the running kernel (`uname -r`) against the newest
  installed `linux-image-*` package (ignoring the transitional `-unsigned`
  build, which is an installer artifact and never matches `uname -r`).

## Logging

Everything is appended to a single file, `/var/log/ns8-full-update.log`
(never rotated by the script itself, timestamped per line), so it is
straightforward to feed to `logrotate`. Install the provided config:

```
cp logrotate.d/ns8-cluster-updater /etc/logrotate.d/ns8-cluster-updater
```

## Example: cron

```cron
# Every night at 2am, update core+apps, and OS packages (safe mode only)
0 2 * * * root /usr/local/sbin/ns8-cluster-updater.sh --all >/dev/null 2>&1
```

## Known limitations

- `--os-full` on Debian can install a new kernel; the script detects this and
  warns, but does not reboot. Tested with a real reboot in development: the
  node rejoins the cluster VPN mesh and its NS8 containers come back up
  normally.
- NS8's own `update-os` node action (used by the native
  `set-automatic-updates` scheduler) only supports `dnf`; there is no
  upstream equivalent for `apt` yet. This script's `apt` support is this
  project's own addition, not an NS8 core feature.
- If NS8's native automatic updates
  (`api-cli run set-automatic-updates --data '{"apply_updates_is_active": true}'`)
  are already enabled, this script and the native nightly timer are
  independent and can both run; there's no coordination between them.
