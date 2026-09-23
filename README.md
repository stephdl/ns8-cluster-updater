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
| `--os-safe`   | Update OS packages of Rocky-like nodes with NS8's `update-os` node action. Debian nodes are skipped. |
| `--all`       | Shortcut for `--os-safe --core --modules`, run in that order (same as NS8's own automatic updates). |
| `-h`, `--help`| Show usage and exit. |

No option: prints usage, does nothing.

### OS updates

`--os-safe` runs NS8's own `update-os` action on each node, one node at a
time. That action runs `dnf update` restricted to `ns-baseos` and
`ns-appstream`, the same repositories NS8 automatic updates use.

Only Rocky-like nodes (Rocky Linux, AlmaLinux) are supported. The node OS
comes from `cluster/list-nodes`. Debian and Ubuntu nodes get a warning and
are skipped: update them by hand.

### Managed repository view

`update-core` and `update-modules` read the repository "managed" view
when they are not started by a user, as with NS8's own automatic
updates. With a subscription, that view gets new versions later than
the "latest" view shown in the UI. The pre-checks read the managed view
too, so the script skips an update the actions would not apply.

### Reboot detection

The script never reboots. For the leader, it runs `needs-restarting -r`
(or compares `uname -r` with the newest `kernel-core` when dnf-utils is
missing) and reports whether a reboot is needed. `update-os` does not report it, so
check the other nodes by hand with `needs-restarting -r`.

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

## Known limitations

- Only Rocky-like nodes get OS updates. Debian and Ubuntu nodes are
  skipped. Update them locally on each node, for example with
  `unattended-upgrades` or
  [proxmox-updater](https://github.com/stephdl/proxmox-updater), on a day
  this timer does not run.
- `--os-full` was removed. Updating from all enabled repos (for example
  EPEL) could pull a `podman` build NS8 was not tested with.
- If NS8's native automatic updates are already enabled
  (`set-automatic-updates --data '{"apply_updates_is_active": true}'`), they
  run independently of this script, no coordination between them.
