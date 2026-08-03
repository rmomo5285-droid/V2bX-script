#!/usr/bin/env bash
set -Eeuo pipefail

mode="check"
backup_id=""
root_dir="${V2BX_RESOURCE_ROOT:-/}"
service_name="${V2BX_RESOURCE_SERVICE:-V2bX}"
systemctl_cmd="${V2BX_RESOURCE_SYSTEMCTL_CMD:-systemctl}"

usage() {
    cat <<'EOF'
Usage: resource-guard.sh [check | apply | status | rollback [BACKUP_ID]]

Adds a transactional systemd memory guard only on low-memory installations
whose configured nodes all use the native hysteria2 core. Xray, sing-box,
mixed-core, non-systemd, and larger hosts are reported as not applicable.

Environment variables used by tests:
  V2BX_RESOURCE_ROOT, V2BX_RESOURCE_SYSTEMCTL_CMD,
  V2BX_RESOURCE_SKIP_ROOT_CHECK=1
EOF
}

while (($# > 0)); do
    case "$1" in
        check|--check|apply|--apply|status|--status)
            mode="${1#--}"
            shift
            ;;
        rollback|--rollback)
            mode="rollback"
            shift
            if (($# > 0)) && [[ "$1" != --* ]]; then
                backup_id="$1"
                shift
            fi
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ "$root_dir" == /* ]] || { echo "ERROR: V2BX_RESOURCE_ROOT must be absolute" >&2; exit 2; }
root_dir="${root_dir%/}"
[[ -n "$root_dir" ]] || root_dir="/"

root_path() {
    local relative="${1#/}"
    if [[ "$root_dir" == "/" ]]; then
        printf '/%s\n' "$relative"
    else
        printf '%s/%s\n' "$root_dir" "$relative"
    fi
}

config_path=$(root_path /etc/V2bX/config.json)
meminfo_path=$(root_path /proc/meminfo)
dropin_dir=$(root_path /etc/systemd/system/V2bX.service.d)
dropin_path="$dropin_dir/20-resource-guard.conf"
state_dir=$(root_path /var/lib/v2bx-resource-guard)
backups_dir="$state_dir/backups"
latest_path="$state_dir/latest"

if [[ "$mode" != "check" && "$mode" != "status" && "${V2BX_RESOURCE_SKIP_ROOT_CHECK:-0}" != "1" && "$(id -u)" -ne 0 ]]; then
    echo "ERROR: $mode must run as root" >&2
    exit 1
fi

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

service_active() {
    "$systemctl_cmd" is-active --quiet "$service_name"
}

mem_mib() {
    local kib
    [[ -r "$meminfo_path" ]] || return 1
    kib=$(awk '$1 == "MemTotal:" { print $2; exit }' "$meminfo_path")
    [[ "$kib" =~ ^[0-9]+$ && "$kib" -gt 0 ]] || return 1
    printf '%s\n' "$((kib / 1024))"
}

config_is_native_hy2_only() {
    command_exists jq || { echo "ERROR: jq is required" >&2; return 1; }
    [[ -f "$config_path" && ! -L "$config_path" ]] || return 1
    jq -e '
      . as $root |
      (.Cores | type) == "array" and (.Cores | length) > 0 and
      (.Nodes | type) == "array" and (.Nodes | length) > 0 and
      ([.Cores[] | (.Type // "" | ascii_downcase) == "hysteria2"] | all) and
      ([.Nodes[] | (.NodeType // "" | ascii_downcase) == "hysteria2"] | all) and
      ([.Nodes[] |
        ((if ((.CoreName // "") | length) > 0 then .CoreName else (.Core // "hysteria2") end) |
          ascii_downcase) as $selected |
        any($root.Cores[]; (((.Name // .Type) | ascii_downcase) == $selected) and
            ((.Type // "" | ascii_downcase) == "hysteria2"))] | all)
    ' "$config_path" >/dev/null 2>&1
}

eligibility() {
    local memory
    command_exists "$systemctl_cmd" || { printf 'not-systemd\n'; return; }
    memory=$(mem_mib) || { printf 'memory-unknown\n'; return; }
    ((memory <= 1280)) || { printf 'memory-above-1280MiB\n'; return; }
    config_is_native_hy2_only || { printf 'not-native-hy2-only\n'; return; }
    printf 'eligible\n'
}

limits_for_host() {
    local memory
    memory=$(mem_mib)
    if ((memory <= 1024)); then
        printf '400M 550M\n'
    else
        printf '500M 700M\n'
    fi
}

render_dropin() {
    local destination="$1" high max
    read -r high max < <(limits_for_host)
    cat > "$destination" <<EOF
# Managed by V2bX resource-guard.sh. Use its rollback command to restore.
[Service]
MemoryAccounting=yes
MemoryHigh=$high
MemoryMax=$max
OOMPolicy=stop
EOF
}

fallback_lock=""
stage_path=""
transaction_backup=""
transaction_changed=0

cleanup() {
    [[ -n "$stage_path" ]] && rm -f -- "$stage_path" 2>/dev/null || true
    [[ -n "$fallback_lock" ]] && rmdir -- "$fallback_lock" 2>/dev/null || true
}
trap cleanup EXIT

acquire_lock() {
    mkdir -p -- "$state_dir" "$backups_dir"
    chmod 0700 "$state_dir" "$backups_dir" 2>/dev/null || true
    if command_exists flock; then
        exec 9>"$state_dir/lock"
        flock -n 9 || { echo "ERROR: another resource-guard operation is active" >&2; return 1; }
    else
        fallback_lock="$state_dir/lock.d"
        mkdir -- "$fallback_lock" 2>/dev/null || { echo "ERROR: another resource-guard operation may be active" >&2; return 1; }
    fi
}

create_backup() {
    local id dir was_active=0
    id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    dir="$backups_dir/$id"
    (umask 077; mkdir -- "$dir")
    if [[ -e "$dropin_path" || -L "$dropin_path" ]]; then
        [[ -f "$dropin_path" && ! -L "$dropin_path" ]] || { echo "ERROR: unsafe existing drop-in: $dropin_path" >&2; return 1; }
        cp -a -- "$dropin_path" "$dir/dropin"
        cmp -s -- "$dropin_path" "$dir/dropin"
        printf '1\n' > "$dir/dropin-existed"
    else
        printf '0\n' > "$dir/dropin-existed"
    fi
    service_active && was_active=1 || true
    printf '%s\n' "$was_active" > "$dir/service-was-active"
    printf 'complete\n' > "$dir/complete"
    transaction_backup="$dir"
}

validate_backup() {
    local dir="$1" existed active
    [[ -d "$dir" && ! -L "$dir" && -f "$dir/complete" ]] || return 1
    existed=$(<"$dir/dropin-existed")
    active=$(<"$dir/service-was-active")
    [[ "$existed" == "0" || "$existed" == "1" ]] || return 1
    [[ "$active" == "0" || "$active" == "1" ]] || return 1
    [[ "$existed" == "0" || ( -f "$dir/dropin" && ! -L "$dir/dropin" ) ]] || return 1
}

wait_for_service() {
    local attempt consecutive=0
    for attempt in {1..15}; do
        if service_active; then
            ((++consecutive))
            ((consecutive >= 5)) && return 0
        else
            consecutive=0
        fi
        sleep 1
    done
    return 1
}

restore_backup() {
    local dir="$1" existed active
    validate_backup "$dir" || { echo "ERROR: invalid resource-guard backup: $dir" >&2; return 1; }
    existed=$(<"$dir/dropin-existed")
    active=$(<"$dir/service-was-active")
    mkdir -p -- "$dropin_dir"
    if [[ "$existed" == "1" ]]; then
        stage_path=$(mktemp "$dropin_dir/.20-resource-guard.restore.XXXXXX")
        cp -a -- "$dir/dropin" "$stage_path"
        mv -fT -- "$stage_path" "$dropin_path"
        stage_path=""
    else
        rm -f -- "$dropin_path"
    fi
    "$systemctl_cmd" daemon-reload
    if [[ "$active" == "1" ]]; then
        "$systemctl_cmd" restart "$service_name"
        wait_for_service
    fi
}

transaction_failure() {
    local status="$1"
    trap - ERR INT TERM
    set +e
    if ((transaction_changed)) && [[ -n "$transaction_backup" ]]; then
        echo "ERROR: resource guard failed; restoring the previous drop-in" >&2
        restore_backup "$transaction_backup" || echo "CRITICAL: automatic rollback was incomplete: $transaction_backup" >&2
    fi
    exit "$status"
}

run_status() {
    local state memory="unknown"
    state=$(eligibility)
    memory=$(mem_mib 2>/dev/null || printf 'unknown')
    echo "Eligibility: $state"
    echo "Memory: ${memory} MiB"
    if [[ -f "$dropin_path" && ! -L "$dropin_path" ]]; then
        echo "Guard: installed at $dropin_path"
        grep -E '^(MemoryHigh|MemoryMax|OOMPolicy)=' "$dropin_path" || true
    else
        echo "Guard: not installed"
    fi
    [[ -f "$latest_path" ]] && echo "Latest backup: $(<"$latest_path")"
    return 0
}

run_check() {
    local state candidate
    state=$(eligibility)
    run_status
    [[ "$state" == "eligible" ]] || { echo "NOT APPLICABLE: no memory limit will be changed"; return 0; }
    candidate=$(mktemp)
    render_dropin "$candidate"
    if [[ -f "$dropin_path" ]] && cmp -s -- "$candidate" "$dropin_path"; then
        rm -f -- "$candidate"
        echo "OK: resource guard already matches"
        return 0
    fi
    rm -f -- "$candidate"
    echo "NEEDS APPLY: eligible native Hy2 host"
    return 3
}

run_apply() {
    local state id latest_stage was_active=0
    state=$(eligibility)
    [[ "$state" == "eligible" ]] || { echo "NOT APPLICABLE: $state; no file or service changed"; return 0; }
    acquire_lock
    mkdir -p -- "$dropin_dir"
    [[ ! -e "$dropin_path" && ! -L "$dropin_path" || ( -f "$dropin_path" && ! -L "$dropin_path" ) ]] || {
        echo "ERROR: refusing unsafe drop-in path: $dropin_path" >&2
        return 1
    }
    stage_path=$(mktemp "$dropin_dir/.20-resource-guard.XXXXXX")
    render_dropin "$stage_path"
    chmod 0644 "$stage_path"
    if [[ -f "$dropin_path" ]] && cmp -s -- "$stage_path" "$dropin_path"; then
        rm -f -- "$stage_path"
        stage_path=""
        echo "OK: resource guard already matches"
        return 0
    fi
    create_backup
    validate_backup "$transaction_backup"
    id="${transaction_backup##*/}"
    service_active && was_active=1 || true
    trap 'transaction_failure $?' ERR
    trap 'transaction_failure 130' INT
    trap 'transaction_failure 143' TERM
    transaction_changed=1
    mv -fT -- "$stage_path" "$dropin_path"
    stage_path=""
    "$systemctl_cmd" daemon-reload
    if ((was_active)); then
        "$systemctl_cmd" restart "$service_name"
        wait_for_service
    fi
    latest_stage=$(mktemp "$state_dir/.latest.XXXXXX")
    printf '%s\n' "$id" > "$latest_stage"
    mv -fT -- "$latest_stage" "$latest_path"
    transaction_changed=0
    trap - ERR INT TERM
    echo "APPLIED: low-memory native Hy2 guard"
    echo "BACKUP: $id"
}

run_rollback() {
    local id="$backup_id" dir
    acquire_lock
    if [[ -z "$id" ]]; then
        [[ -f "$latest_path" && ! -L "$latest_path" ]] || { echo "ERROR: no resource-guard backup is recorded" >&2; return 1; }
        id=$(<"$latest_path")
    fi
    [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: invalid backup ID" >&2; return 1; }
    dir="$backups_dir/$id"
    restore_backup "$dir"
    echo "ROLLED BACK: resource guard restored from $id"
}

case "$mode" in
    check) run_check ;;
    apply) run_apply ;;
    status) run_status ;;
    rollback) run_rollback ;;
esac
