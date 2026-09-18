#!/bin/bash

set -uo pipefail

LOGFILE="/var/log/ns8-full-update.log"

DO_CORE=no
DO_MODULES=no
DO_OS=no
OS_MODE=""

usage() {
    cat <<'EOF'
Usage: ns8-full-update.sh [--core] [--modules] [--os-safe|--os-full] [--all] [-h|--help]

  --core       update NS8 core on all cluster nodes
  --modules    update all NS8 app instances (all nodes)
  --os-safe    update OS packages, restricted to official distro repos only,
               no package removal/addition (dnf: ns-baseos+ns-appstream only;
               apt: sources.list only, plain upgrade)
  --os-full    update OS packages, all enabled repos, full dependency
               resolution (dnf: all repos, e.g. EPEL; apt: dist-upgrade)
  --all        shortcut for --os-safe --core --modules (same order NS8's own
               automatic updates use: OS, then core, then apps)
  -h, --help   show this help and exit

No flag given: print this help, do nothing.
Must run as root on the cluster leader.
Log file: /var/log/ns8-full-update.log (single file, append only, safe for logrotate)
EOF
}

if [ "$#" -eq 0 ]; then
    usage
    exit 0
fi

for arg in "$@"; do
    case "$arg" in
        --core) DO_CORE=yes ;;
        --modules) DO_MODULES=yes ;;
        --os-safe) DO_OS=yes; OS_MODE=safe ;;
        --os-full) DO_OS=yes; OS_MODE=full ;;
        --all) DO_OS=yes; OS_MODE=safe; DO_CORE=yes; DO_MODULES=yes ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $arg" >&2; usage; exit 1 ;;
    esac
done

touch "$LOGFILE"

log() {
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" | tee -a "$LOGFILE"
}

run_step() {
    local label="$1"; shift
    log STEP "start: $label"
    local out
    if out=$("$@" 2>&1); then
        printf '%s\n' "$out" >>"$LOGFILE"
        log OK "$label"
        return 0
    else
        local rc=$?
        printf '%s\n' "$out" >>"$LOGFILE"
        log FAIL "$label (exit $rc)"
        return "$rc"
    fi
}

die() {
    log FATAL "$1"
    exit 1
}

dump_json() {
    printf '%s: %s\n' "$1" "$2" >>"$LOGFILE"
}

api_cli_silent() {
    # Same contract as `api-cli run <action> --data <json>`, but submits with
    # extra.isNotificationHidden so it doesn't toast in every admin's UI.
    # api-cli itself hardcodes that flag to false with no way to override it.
    local action="$1"
    # Match api-cli's own default: no data means JSON null, not "{}"
    # (some actions, e.g. list-updates, reject an object as input).
    local data="${2:-null}"
    runagent python3 -c '
import sys, json
import agent, agent.tasks
action, data = sys.argv[1], json.loads(sys.argv[2])
extra = {"title": f"cluster/{action}", "description": "ns8-cluster-updater", "isNotificationHidden": True}
response = agent.tasks.run("cluster", action, data, extra=extra, endpoint="redis://cluster-leader")
if response["exit_code"] != 0:
    print(response.get("error", ""), file=sys.stderr, end="")
print(json.dumps(response["output"]))
sys.exit(response["exit_code"])
' "$action" "$data"
}

snapshot_core_modules() {
    api_cli_silent list-core-modules 2>>"$LOGFILE" | jq -c '[.[] | .instances[] | {id, version, update, node: .node_id}]'
}

snapshot_installed_modules() {
    api_cli_silent list-installed-modules 2>>"$LOGFILE" | jq -c '[.[] | .[] | {id, version, node}]'
}

any_update_pending() {
    jq -e 'any(.[]; .update != "")' <<<"$1" >/dev/null
}

log_version_diff() {
    local label="$1" before="$2" after="$3"
    local diff_lines
    diff_lines=$(jq -n -r --argjson before "$before" --argjson after "$after" '
        ($before | map({(.id): .version}) | add // {}) as $b |
        ($after  | map({(.id): {version, node}}) | add // {}) as $a |
        $a | to_entries[]
        | select($b[.key] != .value.version)
        | "\(.key) (node \(.value.node // "?")): \($b[.key] // "new") -> \(.value.version)"
    ')
    if [ -z "$diff_lines" ]; then
        log INFO "$label: no version change"
    else
        log INFO "$label: version changes:"
        printf '%s\n' "$diff_lines" >>"$LOGFILE"
        printf '%s\n' "$diff_lines"
    fi
}

os_update_local() {
    # shipped to remote nodes via `declare -f` over ssh, must stay self-contained
    local mode="$1"
    if command -v dnf >/dev/null 2>&1; then
        if [ "$mode" = safe ]; then
            echo "dnf mode: safe, repos restricted to ns-baseos,ns-appstream"
            dnf --disablerepo='*' --enablerepo=ns-baseos,ns-appstream --refresh update -y || exit 1
        else
            echo "dnf mode: full, all enabled repos"
            dnf makecache -y && dnf upgrade -y || exit 1
        fi
        if command -v needs-restarting >/dev/null 2>&1 && ! needs-restarting -r >/dev/null 2>&1; then
            echo "REBOOT_NEEDED=yes"
        else
            echo "REBOOT_NEEDED=no"
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        # Keep the locally modified conffile on conflict instead of prompting
        # or silently taking the maintainer's version.
        local confopts=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
        if [ "$mode" = safe ]; then
            echo "apt mode: safe, sources.list only, no package removal/addition"
            apt-get -o Dir::Etc::SourceParts=/dev/null update -y \
                && apt-get -o Dir::Etc::SourceParts=/dev/null "${confopts[@]}" upgrade -y || exit 1
        else
            echo "apt mode: full, all sources, dist-upgrade"
            apt-get update -y && apt-get "${confopts[@]}" dist-upgrade -y || exit 1
        fi
        # /var/run/reboot-required needs update-notifier-common, not always installed.
        # Fallback: needrestart -b, then compare running vs newest installed kernel.
        if [ -f /var/run/reboot-required ]; then
            echo "REBOOT_NEEDED=yes"
        elif command -v needrestart >/dev/null 2>&1; then
            if needrestart -b 2>/dev/null | grep -q '^NEEDRESTART-KSTA: [23]'; then
                echo "REBOOT_NEEDED=yes"
            else
                echo "REBOOT_NEEDED=no"
            fi
        else
            running_kernel=$(uname -r)
            # Exclude the transitional -unsigned build: it's an installer artifact,
            # not a distinct bootable kernel, and never matches `uname -r`.
            latest_kernel=$(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null \
                | grep -v -- '-unsigned$' \
                | sed 's/^linux-image-//' | sort -V | tail -1)
            if [ -n "$latest_kernel" ] && [ "$latest_kernel" != "$running_kernel" ]; then
                echo "REBOOT_NEEDED=yes (kernel: running $running_kernel, installed $latest_kernel)"
            else
                echo "REBOOT_NEEDED=no"
            fi
        fi
    else
        echo "no apt or dnf found" >&2
        exit 1
    fi
}
export -f os_update_local

[ "$(id -u)" -eq 0 ] || die "must run as root"
command -v runagent >/dev/null 2>&1 || die "runagent not found, not an NS8 node"

log INFO "===== run start ====="
log INFO "log file: $LOGFILE"
log INFO "steps enabled: core=$DO_CORE modules=$DO_MODULES os=$DO_OS"

STATUS=$(api_cli_silent get-cluster-status 2>>"$LOGFILE") || die "get-cluster-status failed"
dump_json "get-cluster-status" "$STATUS"
IS_LEADER=$(jq -r '.leader' <<<"$STATUS") || die "get-cluster-status returned invalid data"
[ "$IS_LEADER" = "true" ] || die "this node is not the cluster leader, aborting"
log OK "running on cluster leader"

# Order matches NS8's own automatic updates (cluster/bin/apply-updates):
# OS packages first, then core, then apps.

if [ "$DO_OS" = yes ]; then
    ANY_REBOOT=no
    log INFO "OS update mode: $OS_MODE"
    while IFS=$'\t' read -r NID LOCAL HOSTNAME VPNIP; do
        if [ "$LOCAL" = "true" ]; then
            log STEP "OS update on node $NID (local, $HOSTNAME)"
            OUT=$(os_update_local "$OS_MODE" 2>&1)
            RC=$?
        else
            [ -n "$VPNIP" ] || { log FAIL "no vpn ip for node $NID"; continue; }
            log STEP "OS update on node $NID (remote, $HOSTNAME, $VPNIP)"
            OUT=$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@$VPNIP" \
                "$(declare -f os_update_local); os_update_local \"$OS_MODE\"" 2>&1)
            RC=$?
        fi
        printf '%s\n' "$OUT" >>"$LOGFILE"
        if [ "$RC" -eq 0 ]; then
            log OK "OS update node $NID"
            echo "$OUT" | grep -q 'REBOOT_NEEDED=yes' && ANY_REBOOT=yes
        else
            log FAIL "OS update node $NID (exit $RC)"
        fi
    done < <(echo "$STATUS" | jq -r '.nodes[] | [.id, .local, .hostname, .vpn.ip_address] | @tsv')

    log INFO "reboot needed on at least one node: $ANY_REBOOT"
    [ "$ANY_REBOOT" = yes ] && log WARN "reboot manually the affected node(s), script does not reboot"
fi

if [ "$DO_CORE" = yes ]; then
    CORE_BEFORE=$(snapshot_core_modules) || die "failed to fetch core modules status, check $LOGFILE"
    if any_update_pending "$CORE_BEFORE"; then
        NODE_IDS=$(jq -c '[.nodes[].id]' <<<"$STATUS") || die "failed to compute node list"
        log INFO "updating core on nodes: $NODE_IDS"
        run_step "update-core" api_cli_silent update-core "{\"nodes\":$NODE_IDS}" \
            || die "core update failed, check $LOGFILE"
        run_step "verify cluster status after core update" api_cli_silent get-cluster-status \
            || die "cluster not responsive after core update"
        CORE_AFTER=$(snapshot_core_modules) || die "failed to fetch core modules status after update, check $LOGFILE"
        log_version_diff "core components" "$CORE_BEFORE" "$CORE_AFTER"
    else
        log INFO "no core update available, skipping update-core"
    fi
fi

if [ "$DO_MODULES" = yes ]; then
    PENDING=$(api_cli_silent list-updates 2>>"$LOGFILE") || die "list-updates failed, check $LOGFILE"
    dump_json "list-updates (before)" "$PENDING"
    PENDING_COUNT=$(jq 'length' <<<"$PENDING") || die "list-updates returned invalid data"
    if [ "$PENDING_COUNT" -gt 0 ]; then
        MODULES_BEFORE=$(snapshot_installed_modules) || die "failed to fetch installed modules, check $LOGFILE"
        run_step "update-modules" api_cli_silent update-modules '{}' \
            || die "modules update failed, check $LOGFILE"
        MODULES_AFTER=$(snapshot_installed_modules) || die "failed to fetch installed modules after update, check $LOGFILE"
        log_version_diff "app instances" "$MODULES_BEFORE" "$MODULES_AFTER"
        REMAINING=$(api_cli_silent list-updates 2>>"$LOGFILE") || die "list-updates failed after update-modules, check $LOGFILE"
        dump_json "list-updates (after)" "$REMAINING"
        REMAINING_COUNT=$(jq 'length' <<<"$REMAINING") || die "list-updates returned invalid data"
        if [ "$REMAINING_COUNT" -eq 0 ]; then
            log OK "no pending app updates left"
        else
            log WARN "still $REMAINING_COUNT app update(s) pending after update-modules"
        fi
    else
        log INFO "no app update available, skipping update-modules"
    fi
fi

log OK "requested steps done, full log: $LOGFILE"
log INFO "===== run end ====="
