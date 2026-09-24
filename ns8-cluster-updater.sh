#!/bin/bash

set -uo pipefail

# systemd journal priority prefixes (see systemd.journal-fields(7) and
# agent/__init__.py's SD_* constants), same convention NS8 core itself uses.
SD_ERR="<3>"
SD_WARNING="<4>"
SD_NOTICE="<5>"
SD_INFO="<6>"

DO_CORE=no
DO_MODULES=no
DO_OS=no

usage() {
    cat <<'EOF'
Usage: ns8-cluster-updater.sh [--core] [--modules] [--os-safe] [--all] [-h|--help]

  --core       update NS8 core on all cluster nodes
  --modules    update all NS8 app instances (all nodes)
  --os-safe    update OS packages with NS8's update-os node action
               (ns-baseos+ns-appstream only), on nodes that have those
               repositories; other nodes are skipped
  --all        shortcut for --os-safe --core --modules (same order NS8's own
               automatic updates use: OS, then core, then apps)
  -h, --help   show this help and exit

No flag given: print this help, do nothing.
Must run as root on the cluster leader.
Logs go to stderr with systemd priority prefixes; under the shipped
ns8-cluster-updater.service, journalctl -u ns8-cluster-updater.service
shows them. Run interactively, they print straight to the terminal.
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
        --os-safe) DO_OS=yes ;;
        --os-full) echo "--os-full was removed, use --os-safe" >&2; exit 1 ;;
        --all) DO_OS=yes; DO_CORE=yes; DO_MODULES=yes ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $arg" >&2; usage; exit 1 ;;
    esac
done

log() {
    local level="$1" msg="$2" prefix
    case "$level" in
        FATAL|FAIL) prefix="$SD_ERR" ;;
        WARN) prefix="$SD_WARNING" ;;
        STEP|OK) prefix="$SD_NOTICE" ;;
        *) prefix="$SD_INFO" ;;
    esac
    printf '%s%s: %s\n' "$prefix" "$level" "$msg" >&2
}

# Prints multi-line text one log() call per line, so every physical line
# always starts with our own controlled prefix. Without this, a line from
# untrusted content (e.g. an app's error message) starting with "<3>" or
# similar would be read by journald as a forged priority on its own entry.
log_lines() {
    local level="$1" text="$2"
    [ -n "$text" ] || return 0
    while IFS= read -r line; do
        log "$level" "$line"
    done <<<"$text"
}

run_step() {
    local label="$1"; shift
    log STEP "start: $label"
    local out
    if out=$("$@" 2>&1); then
        log_lines INFO "$out"
        log OK "$label"
        return 0
    else
        local rc=$?
        log_lines INFO "$out"
        log FAIL "$label (exit $rc)"
        return "$rc"
    fi
}

die() {
    log FATAL "$1"
    exit 1
}

dump_json() {
    log INFO "$1: $2"
}

api_cli_silent() {
    api_task_silent cluster "$@"
}

api_task_silent() {
    # Same contract as `api-cli run <action> --data <json>`, but submits with
    # extra.isNotificationHidden so it doesn't toast in every admin's UI.
    # api-cli itself hardcodes that flag to false with no way to override it.
    local agent_id="$1" action="$2"
    # Match api-cli's own default: no data means JSON null, not "{}"
    # (some actions, e.g. list-updates, reject an object as input).
    local data="${3:-null}"
    runagent python3 -c '
import os, re, sys, json
import agent, agent.tasks
agent_id, action, data = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
extra = {"title": f"{agent_id}/{action}", "description": "ns8-cluster-updater", "isNotificationHidden": True}
response = agent.tasks.run(agent_id, action, data, extra=extra, endpoint="redis://cluster-leader")
if response["exit_code"] != 0 or os.getenv("TASK_STDERR") == "always":
    # Drop the journald priority prefix of each line, log_lines adds ours.
    print(re.sub(r"(?m)^<[0-7]>", "", response.get("error", "")), file=sys.stderr, end="")
print(json.dumps(response["output"]))
sys.exit(response["exit_code"])
' "$agent_id" "$action" "$data"
}

managed_view_read() {
    # update-core and update-modules switch to the "managed" repository view
    # when the task has no user (as here), while the list-core-modules and
    # list-updates actions read the "latest" view. With a subscription the
    # managed view lags behind, so the pre-check must read the same view as
    # the update actions. Without a subscription both views are the same.
    runagent python3 -c '
import sys, json
import agent, cluster.modules
cluster.modules.select_repo_view("managed")
rdb = agent.redis_connect(privileged=True)
if sys.argv[1] == "core":
    json.dump(cluster.modules.list_core_modules(rdb), sys.stdout)
else:
    json.dump(cluster.modules.list_updates(rdb, skip_core_modules=True), sys.stdout)
' "$1"
}

snapshot_core_modules() {
    managed_view_read core | jq -c '[.[] | .instances[] | {id, version, update, node: .node_id}]'
}

snapshot_installed_modules() {
    api_cli_silent list-installed-modules | jq -c '[.[] | .[] | {id, version, node}]'
}

local_reboot_needed() {
    if command -v needs-restarting >/dev/null 2>&1; then
        ! needs-restarting -r >/dev/null 2>&1
        return
    fi
    # needs-restarting comes from dnf-utils, which is not always installed.
    local latest
    latest=$(rpm -q --last kernel-core 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^kernel-core-//')
    [ -n "$latest" ] && [ "$latest" != "$(uname -r)" ]
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
        log_lines INFO "$diff_lines"
    fi
}

[ "$(id -u)" -eq 0 ] || die "must run as root"
command -v runagent >/dev/null 2>&1 || die "runagent not found, not an NS8 node"

log INFO "===== run start ====="
log INFO "steps enabled: core=$DO_CORE modules=$DO_MODULES os=$DO_OS"

STATUS=$(api_cli_silent get-cluster-status) || die "get-cluster-status failed"
dump_json "get-cluster-status" "$STATUS"
IS_LEADER=$(jq -r '.leader' <<<"$STATUS") || die "get-cluster-status returned invalid data"
[ "$IS_LEADER" = "true" ] || die "this node is not the cluster leader, aborting"
log OK "running on cluster leader"

# With a subscription, NS8's own automatic updates (apply-updates) own this
# job; running both would race on the same actions and dnf lock.
SUBSCRIPTION=$(api_cli_silent get-subscription) || die "get-subscription failed"
if jq -e '.subscription != null' <<<"$SUBSCRIPTION" >/dev/null; then
    log OK "subscription found, updates are handled by NS8 automatic updates, nothing to do"
    log INFO "===== run end ====="
    exit 0
fi

# Order matches NS8's own automatic updates (cluster/bin/apply-updates):
# OS packages first, then core, then apps.

if [ "$DO_OS" = yes ]; then
    REBOOT_LOCAL=no
    OS_FAILED=no
    # update-os only works with the ns-baseos and ns-appstream repositories,
    # which the NS8 installer creates on Rocky Linux only: on any other OS it
    # fails (EL9 clones) or does nothing (Debian). os_release comes from the
    # metrics module.
    NODES_OS=$(api_cli_silent list-nodes | jq -c '[.nodes[] | {(.node_id | tostring): .os_release.name}] | add // {}') \
        || { log WARN "list-nodes failed, OS of nodes unknown"; NODES_OS='{}'; }
    while IFS=$'\t' read -r NID LOCAL HOSTNAME; do
        OS_NAME=$(jq -r --arg id "$NID" '.[$id] // ""' <<<"$NODES_OS")
        case "$OS_NAME" in
            Rocky*) ;;
            "")
                log WARN "OS update node $NID ($HOSTNAME): OS unknown, metrics unavailable, skipped"
                continue
                ;;
            *)
                log WARN "OS update node $NID ($HOSTNAME, $OS_NAME): no NS8 repositories on this OS, update it locally, skipped"
                continue
                ;;
        esac
        log STEP "OS update on node $NID ($HOSTNAME, $OS_NAME)"
        log INFO "please wait, dnf output shows when node $NID is done (live: journalctl -f -u agent@node on node $NID)"
        # The task returns the dnf output only in its stderr stream: show it
        # on success too, as the old local dnf run did.
        if OS_LOG=$(TASK_STDERR=always api_task_silent "node/$NID" update-os 2>&1 >/dev/null); then
            log_lines INFO "$OS_LOG"
            log OK "OS update node $NID"
        else
            RC=$?
            log_lines INFO "$OS_LOG"
            log FAIL "OS update node $NID (exit $RC)"
            OS_FAILED=yes
            continue
        fi
        [ "$LOCAL" = "true" ] && local_reboot_needed && REBOOT_LOCAL=yes
    done < <(echo "$STATUS" | jq -r '.nodes[] | [.id, .local, .hostname] | @tsv')

    log INFO "reboot needed on this node: $REBOOT_LOCAL"
    if [ "$REBOOT_LOCAL" = yes ]; then
        log WARN "reboot this node manually, script does not reboot"
        # update-os does not report reboot state, but every updated node got
        # the same packages from the same repositories in this run.
        log WARN "other updated nodes most likely need a reboot too, check each one with needs-restarting -r"
    else
        log INFO "reboot state of other nodes is not reported, check them with needs-restarting -r"
    fi
fi

if [ "$DO_CORE" = yes ]; then
    CORE_BEFORE=$(snapshot_core_modules) || die "failed to fetch core modules status"
    if any_update_pending "$CORE_BEFORE"; then
        NODE_IDS=$(jq -c '[.nodes[].id]' <<<"$STATUS") || die "failed to compute node list"
        log INFO "updating core on nodes: $NODE_IDS"
        run_step "update-core" api_cli_silent update-core "{\"nodes\":$NODE_IDS}" \
            || die "core update failed"
        run_step "verify cluster status after core update" api_cli_silent get-cluster-status \
            || die "cluster not responsive after core update"
        CORE_AFTER=$(snapshot_core_modules) || die "failed to fetch core modules status after update"
        log_version_diff "core components" "$CORE_BEFORE" "$CORE_AFTER"
    else
        log INFO "no core update available, skipping update-core"
    fi
fi

if [ "$DO_MODULES" = yes ]; then
    PENDING=$(managed_view_read updates) || die "list-updates failed"
    dump_json "list-updates (before)" "$PENDING"
    PENDING_COUNT=$(jq 'length' <<<"$PENDING") || die "list-updates returned invalid data"
    if [ "$PENDING_COUNT" -gt 0 ]; then
        MODULES_BEFORE=$(snapshot_installed_modules) || die "failed to fetch installed modules"
        run_step "update-modules" api_cli_silent update-modules '{}' \
            || die "modules update failed"
        MODULES_AFTER=$(snapshot_installed_modules) || die "failed to fetch installed modules after update"
        log_version_diff "app instances" "$MODULES_BEFORE" "$MODULES_AFTER"
        REMAINING=$(managed_view_read updates) || die "list-updates failed after update-modules"
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

# A failed OS update doesn't stop core and apps, but the run must still
# show as failed in systemd.
if [ "${OS_FAILED:-no}" = yes ]; then
    log FAIL "requested steps done, OS update failed on at least one node"
    log INFO "===== run end ====="
    exit 1
fi
log OK "requested steps done"
log INFO "===== run end ====="
