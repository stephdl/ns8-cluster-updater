# ns8-cluster-updater

Bash script to update a [NethServer 8](https://nethserver.org) cluster: core,
applications and OS packages, in one run or separately, with a pre-check that
skips an update call entirely when nothing is pending.

It targets clusters without a subscription: with one, it does nothing (see
Subscription below). OS updates cover Rocky Linux nodes only.

## Why

`update-core` restarts `redis.service` and `api-server.service` on every
node, even with nothing new to install. This drops the UI websocket and any
in-flight `api-cli` task for a few seconds. The script checks first, reading
the same repository view as the update actions, and skips the call when
there's nothing pending. A failed check dies loudly instead of being read as
"nothing pending".

Every task is also submitted with `extra.isNotificationHidden`, so it
doesn't toast in every admin's UI. `api-cli` hardcodes that flag to `false`
with no override, so the script calls the underlying `agent.tasks` Python
API directly for this. Failures still show up normally.

## Install

```
curl -o /usr/local/sbin/ns8-cluster-updater.sh https://raw.githubusercontent.com/stephdl/ns8-cluster-updater/main/ns8-cluster-updater.sh
chmod +x /usr/local/sbin/ns8-cluster-updater.sh
```

For the systemd timer (see Scheduling below), also grab the unit files:

```
curl -o /etc/systemd/system/ns8-cluster-updater.service https://raw.githubusercontent.com/stephdl/ns8-cluster-updater/main/ns8-cluster-updater.service
curl -o /etc/systemd/system/ns8-cluster-updater.timer https://raw.githubusercontent.com/stephdl/ns8-cluster-updater/main/ns8-cluster-updater.timer
systemctl daemon-reload
```

## Requirements

- `root`, on the cluster leader (checks `get-cluster-status .leader`).
- `runagent` and `jq`.
- No SSH between nodes: OS updates run as NS8 `update-os` node tasks.

## Usage

```
ns8-cluster-updater.sh [--core] [--modules] [--os-safe] [--all] [-h|--help]
```

| Option        | Effect |
|---------------|--------|
| `--core`      | Update NS8 core on all cluster nodes, only if a newer version is available. |
| `--modules`   | Update all NS8 app instances, on all nodes, only if at least one has a pending update. |
| `--os-safe`   | Update OS packages of Rocky Linux nodes with NS8's `update-os` node action. Other nodes are skipped. |
| `--all`       | Shortcut for `--os-safe --core --modules`, run in that order (same as NS8's own automatic updates). |
| `-h`, `--help`| Show usage and exit. |

No option: prints usage, does nothing.

### OS updates

`--os-safe` runs NS8's own `update-os` action on each node, one node at a
time. That action runs `dnf update` restricted to `ns-baseos` and
`ns-appstream`, the same repositories NS8 automatic updates use.
The dnf output of each node is printed once that node is done, on
success too. A long update can keep the run silent for minutes: the task
returns its output only at the end. To follow it live, open a shell on
that node and run:

```
journalctl -f -u agent@node
```

`update-os` needs the `ns-baseos` and `ns-appstream` repositories. The NS8
installer creates them on Rocky Linux only. On other EL9 systems (AlmaLinux,
RHEL) the action fails, and on Debian it does nothing. So the script runs
it only on Rocky Linux nodes, and skips every other node with a warning
(see Known limitations).

The node OS comes from `cluster/list-nodes`, which reads it from the
metrics module. If it is missing, the node is skipped with a separate
"OS unknown, metrics unavailable" warning: check the metrics module.

A failed OS update on one node does not stop the other steps. Core and apps
are still updated, then the script exits 1 so the systemd run shows as
failed.

### Subscription

With a subscription, the script logs a notice and exits 0 without doing
anything. NS8's own automatic updates handle subscribed clusters, and
running both would race on the same actions and on the dnf lock. The
script targets clusters without a subscription.

The pre-checks still read the repository "managed" view, the same view
`update-core` and `update-modules` use when no user starts them. Today
that view matches "latest" on the community repository.

### Reboot detection

The script never reboots. For the leader, it runs `needs-restarting -r`
(or compares `uname -r` with the newest `kernel-core` when dnf-utils is
missing) and reports whether a reboot is needed. `update-os` does not
report it for the other nodes. When the leader needs a reboot, the script
warns that the other updated nodes most likely need one too: they got the
same packages from the same repositories in the same run. Check each one
with `needs-restarting -r`.

## Logging

Every message goes to stderr with a systemd journal priority prefix
(`<3>` error, `<4>` warning, `<5>` notice, `<6>` info — same convention
NS8 core itself uses in `agent/__init__.py`'s `SD_*` constants). Run
interactively, they print straight to the terminal; run under the shipped
service, journald picks up the prefix and stores the right severity.

## Scheduling

```
systemctl enable --now ns8-cluster-updater.timer
```

`ns8-cluster-updater.timer` fires Tuesday to Friday at 00:00, with a 6h
randomized delay (`FixedRandomDelay=true`, so the offset is stable per
host), same window as NS8's own `apply-updates.timer`. `Persistent=true`
catches up on next boot if the host was off at the scheduled time.

Check a run:

```
journalctl -u ns8-cluster-updater.service -e
```

Run it once now, without waiting for the timer:

```
systemctl start ns8-cluster-updater.service
```

The shipped `.service` always runs `--all`. Don't edit
`ns8-cluster-updater.service` directly: a later `curl` reinstall overwrites
it, same reason as the timer below. Use a drop-in instead:

```
systemctl edit ns8-cluster-updater.service
```

```ini
[Service]
ExecStart=
ExecStart=/usr/local/sbin/ns8-cluster-updater.sh --core --modules
```

The empty `ExecStart=` first clears the shipped `--all` command; like
`OnCalendar`, systemd appends `ExecStart=` lines instead of replacing them.
`systemctl edit` reloads the unit itself on save, no manual
`daemon-reload` needed.

### Changing the schedule

Don't edit `ns8-cluster-updater.timer` directly: a later `curl` reinstall
overwrites it. Use a drop-in instead:

```
systemctl edit ns8-cluster-updater.timer
```

This opens an editor on an override file. Add only the keys you want to
change, under `[Timer]`:

```ini
[Timer]
OnCalendar=
OnCalendar=Sun 03:00:00
```

The empty `OnCalendar=` first clears the shipped `Tue..Fri 00:00:00` value;
systemd appends settings instead of replacing them, so skipping that line
would leave both active. Some other schedules:

```ini
# Every day at 1am
OnCalendar=*-*-* 01:00:00

# Twice a week, Monday and Thursday at 22:00
OnCalendar=Mon,Thu 22:00:00

# First day of the month, 4am
OnCalendar=*-*-01 04:00:00
```

To change the randomized delay or drop it entirely:

```ini
[Timer]
RandomizedDelaySec=1h
```

`systemctl edit` reloads the unit itself on save. Check the next run time:

```
systemctl list-timers ns8-cluster-updater.timer
```

## Other OS updates

The script only runs what NS8 supports. Any other OS update is up to you:
set it up yourself on each node, and schedule it on a day this timer does
not run (it runs Tuesday to Friday), so a package upgrade never overlaps a
core update. Some ideas:

- Rocky Linux with EPEL or another extra repository: `dnf-automatic` on
  each node, with the repositories you want enabled. Exclude `podman*`
  there (`excludepkgs=podman*` in the repository file), so a third-party
  build never replaces the one NS8 is tested with.
- AlmaLinux or RHEL: `dnf-automatic` on each node, with the distribution's
  own repositories.
- Debian: `unattended-upgrades`, or
  [proxmox-updater](https://github.com/stephdl/proxmox-updater) for a full
  upgrade.

Whatever you use, reboot the node yourself when a new kernel is
installed.

## Known limitations

- Only Rocky Linux nodes get OS updates, from `ns-baseos` and
  `ns-appstream` only. For anything else, see Other OS updates above.
- If NS8's native automatic updates are already enabled
  (`set-automatic-updates --data '{"apply_updates_is_active": true}'`), they
  run independently of this script, no coordination between them.
