# ns8-cluster-updater

Bash script to update a [NethServer 8](https://nethserver.org) cluster: core,
applications and OS packages, in one run or separately, with a pre-check that
skips an update call entirely when nothing is pending.

## Why

`update-core` restarts `redis.service` and `api-server.service` on every
node, even with nothing new to install. This drops the UI websocket and any
in-flight `api-cli` task for a few seconds. The script checks first
(`list-core-modules` / `list-updates`) and skips the call when there's
nothing pending. A failed check dies loudly instead of being read as "nothing
pending".

Every task is also submitted with `extra.isNotificationHidden`, so it
doesn't toast in every admin's UI. `api-cli` hardcodes that flag to `false`
with no override, so the script calls the underlying `agent.tasks` Python
API directly for this. Failures still show up normally.

## Requirements

- `root`, on the cluster leader (checks `get-cluster-status .leader`).
- `runagent` and `jq`.
- For `--os-safe`/`--os-full`: passwordless root SSH to every worker over the
  cluster VPN — already there by default on any NS8 cluster.
- Works on mixed clusters (dnf and apt nodes together).

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

No option: prints usage, does nothing.

### `--os-safe` vs `--os-full`

|              | dnf (Rocky/AlmaLinux)                          | apt (Debian/Ubuntu) |
|--------------|-------------------------------------------------|----------------------|
| `--os-safe`  | `--disablerepo='*' --enablerepo=ns-baseos,ns-appstream` (same repos as NS8's own `update-os` node action) | `sources.list` only (`sources.list.d/` ignored), plain `apt-get upgrade` (never removes or adds a package) |
| `--os-full`  | all enabled repos (e.g. EPEL)                    | all sources, `apt-get dist-upgrade` (full dependency resolution, can add/remove packages, install a new kernel) |

`--os-safe` is the low-risk default, also used by `--all`. `--os-full` must
be requested explicitly.

On Debian/Ubuntu, both modes add `--force-confdef --force-confold`: on a
config file conflict, dpkg keeps your local version instead of prompting or
overwriting it. Fully non-interactive, no manual step needed.

### Reboot detection

The script never reboots. It only reports, at the end, whether any node
needs one:

- dnf: `needs-restarting -r`.
- apt: `/var/run/reboot-required`, else `needrestart -b`, else compare
  running kernel (`uname -r`) to the newest installed `linux-image-*`
  package (ignoring the transitional `-unsigned` build, an installer
  artifact that never matches `uname -r`).

## Logging

Everything appends to one file, `/var/log/ns8-full-update.log`, timestamped
per line, ready for `logrotate`:

```
cp logrotate.d/ns8-cluster-updater /etc/logrotate.d/ns8-cluster-updater
```

## Example: cron

```cron
# Every night at 2am, update core+apps, and OS packages (safe mode only)
0 2 * * * root /usr/local/sbin/ns8-cluster-updater.sh --all >/dev/null 2>&1
```

## Known limitations

- `--os-full` on Debian can install a new kernel; the script warns but never
  reboots. Tested with a real reboot: node rejoins the cluster fine.
- NS8's own `update-os` node action only supports `dnf`. This script's `apt`
  support is its own addition, not an NS8 core feature.
- If NS8's native automatic updates are already enabled
  (`set-automatic-updates --data '{"apply_updates_is_active": true}'`), they
  run independently of this script, no coordination between them.
