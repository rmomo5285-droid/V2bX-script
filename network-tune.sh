#!/usr/bin/env bash
set -Eeuo pipefail

mode="check"
backup_id=""
root_dir="${V2BX_TUNE_ROOT-/}"
sysctl_cmd="${V2BX_TUNE_SYSCTL_CMD-sysctl}"
modprobe_cmd="${V2BX_TUNE_MODPROBE_CMD-modprobe}"
modinfo_cmd="${V2BX_TUNE_MODINFO_CMD-modinfo}"

usage() {
    cat <<'EOF'
Usage: network-tune.sh [check | apply | rollback [BACKUP_ID]] [options]

Conservatively enables BBR with fq as the default qdisc, enables ECN (and ECN
fallback when the running kernel exposes it), and sets RAM-scaled TCP/socket
buffer ceilings. The script never replaces the kernel, downloads code, or
changes a live interface qdisc. The default command is the read-only check.

Options:
  --root PATH       Prefix for /etc, /proc, /sys, and /var (tests only)
  --backup ID       Backup to restore with rollback (default: latest)
  -h, --help        Show this help

Command injection for tests:
  V2BX_TUNE_SYSCTL_CMD, V2BX_TUNE_MODPROBE_CMD, V2BX_TUNE_MODINFO_CMD
  V2BX_TUNE_SKIP_ROOT_CHECK=1
EOF
}

while (($# > 0)); do
    case "$1" in
        check|--check)
            mode="check"
            shift
            ;;
        apply|--apply)
            mode="apply"
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
        --backup)
            [[ $# -ge 2 ]] || { echo "ERROR: --backup requires an ID" >&2; exit 2; }
            backup_id="$2"
            shift 2
            ;;
        --root)
            [[ $# -ge 2 ]] || { echo "ERROR: --root requires a path" >&2; exit 2; }
            root_dir="$2"
            shift 2
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

[[ "$root_dir" == /* ]] || { echo "ERROR: --root must be an absolute path" >&2; exit 2; }
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

config_path=$(root_path "/etc/sysctl.d/99-v2bx-network-tune.conf")
config_basename="${config_path##*/}"
state_dir=$(root_path "/var/lib/v2bx-network-tune")
backups_dir="$state_dir/backups"
latest_path="$state_dir/latest"

if [[ "$mode" != "check" && "${V2BX_TUNE_SKIP_ROOT_CHECK:-0}" != "1" && "$(id -u)" -ne 0 ]]; then
    echo "ERROR: $mode must run as root" >&2
    exit 1
fi

command_available() {
    [[ -n "$1" ]] && command -v "$1" >/dev/null 2>&1
}

if ! command_available "$sysctl_cmd"; then
    echo "ERROR: sysctl command not found: ${sysctl_cmd:-<empty>}" >&2
    exit 1
fi

temp_files=()
stage_path=""
fallback_lock_dir=""
transaction_backup=""
transaction_changed=0

cleanup() {
    local path
    for path in "${temp_files[@]:-}"; do
        [[ -n "$path" ]] && rm -f -- "$path" 2>/dev/null || true
    done
    [[ -n "$stage_path" ]] && rm -f -- "$stage_path" 2>/dev/null || true
    if [[ -n "$fallback_lock_dir" && -d "$fallback_lock_dir" ]]; then
        rmdir -- "$fallback_lock_dir" 2>/dev/null || true
    fi
}
trap cleanup EXIT

normalize_value() {
    awk '{$1=$1; print}' <<<"$1"
}

sysctl_get() {
    local key="$1" value
    if ! value=$("$sysctl_cmd" -n "$key" 2>/dev/null); then
        echo "ERROR: required sysctl is unavailable: $key" >&2
        return 1
    fi
    value=${value//$'\r'/}
    normalize_value "$value"
}

sysctl_get_optional() {
    local key="$1" value
    value=$("$sysctl_cmd" -n "$key" 2>/dev/null) || return 1
    value=${value//$'\r'/}
    normalize_value "$value"
}

contains_word() {
    local words=" $1 " expected=" $2 "
    [[ "$words" == *"$expected"* ]]
}

min_positive() {
    local current="$1" candidate="$2"
    if [[ "$current" == "0" ]] || decimal_less_than "$candidate" "$current"; then
        printf '%s\n' "$candidate"
    else
        printf '%s\n' "$current"
    fi
}

decimal_less_than() {
    local left="$1" right="$2"
    if ((${#left} != ${#right})); then
        ((${#left} < ${#right}))
    else
        [[ "$left" < "$right" ]]
    fi
}

read_limit_file() {
    local path="$1" value
    [[ -r "$path" ]] || return 1
    IFS= read -r value < "$path" || true
    value=$(normalize_value "$value")
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    while [[ "${#value}" -gt 1 && "$value" == 0* ]]; do
        value="${value#0}"
    done
    # Values at or above 1 PiB are cgroup v1 unlimited sentinels in practice.
    [[ "$value" != "0" ]] || return 1
    decimal_less_than "$value" 1125899906842624 || return 1
    printf '%s\n' "$value"
}

valid_cgroup_path() {
    local path="$1"
    [[ "$path" == /* && "$path" != *$'\n'* && "/$path/" != *"/../"* ]]
}

decode_mountinfo_path() {
    local value="$1"
    value="${value//\\040/ }"
    value="${value//\\011/$'\t'}"
    value="${value//\\012/$'\n'}"
    value="${value//\\134/\\}"
    printf '%s\n' "$value"
}

found_mount_root=""
found_mount_point=""

find_cgroup_mount() {
    local mountinfo="$1" wanted="$2" line before after fs_type source super_options
    local -a fields
    found_mount_root=""
    found_mount_point=""
    [[ -r "$mountinfo" ]] || return 1

    while IFS= read -r line; do
        [[ "$line" == *" - "* ]] || continue
        before="${line%% - *}"
        after="${line#* - }"
        read -r -a fields <<<"$before"
        ((${#fields[@]} >= 6)) || continue
        read -r fs_type source super_options _ <<<"$after"
        case "$wanted" in
            v2)
                [[ "$fs_type" == "cgroup2" ]] || continue
                ;;
            v1)
                [[ "$fs_type" == "cgroup" && ",$super_options," == *",memory,"* ]] || continue
                ;;
            *) return 1 ;;
        esac
        found_mount_root=$(decode_mountinfo_path "${fields[3]}")
        found_mount_point=$(decode_mountinfo_path "${fields[4]}")
        valid_cgroup_path "$found_mount_root" && valid_cgroup_path "$found_mount_point" || return 1
        return 0
    done < "$mountinfo"
    return 1
}

consider_cgroup_tree() {
    local cgroup_path="$1" mount_root="$2" mount_point="$3" limit_filename="$4"
    local relative base current value parent
    valid_cgroup_path "$cgroup_path" && valid_cgroup_path "$mount_root" && valid_cgroup_path "$mount_point" || return 0

    if [[ "$mount_root" == "/" ]]; then
        relative="${cgroup_path#/}"
    elif [[ "$cgroup_path" == "$mount_root" ]]; then
        relative=""
    elif [[ "$cgroup_path" == "$mount_root/"* ]]; then
        relative="${cgroup_path#"$mount_root"/}"
    else
        return 0
    fi

    base=$(root_path "$mount_point")
    current="$base${relative:+/$relative}"
    while [[ "$current" == "$base" || "$current" == "$base/"* ]]; do
        if value=$(read_limit_file "$current/$limit_filename" 2>/dev/null); then
            limit=$(min_positive "$limit" "$value")
        fi
        [[ "$current" == "$base" ]] && break
        parent="${current%/*}"
        [[ -n "$parent" && "$parent" != "$current" ]] || break
        current="$parent"
    done
}

effective_memory_bytes() {
    local meminfo self_cgroup mountinfo cg_root mem_kib effective=0 limit=0 value path
    local have_v2_mount=0 have_v1_mount=0 v2_root="" v2_point="" v1_root="" v1_point=""
    meminfo=$(root_path "/proc/meminfo")
    self_cgroup=$(root_path "/proc/self/cgroup")
    mountinfo=$(root_path "/proc/self/mountinfo")
    cg_root=$(root_path "/sys/fs/cgroup")

    [[ -r "$meminfo" ]] || { echo "ERROR: cannot read $meminfo" >&2; return 1; }
    mem_kib=$(awk '$1 == "MemTotal:" { print $2; exit }' "$meminfo")
    [[ "$mem_kib" =~ ^[0-9]+$ && "$mem_kib" -gt 0 ]] || {
        echo "ERROR: invalid MemTotal in $meminfo" >&2
        return 1
    }
    effective=$((mem_kib * 1024))

    if find_cgroup_mount "$mountinfo" v2; then
        have_v2_mount=1
        v2_root="$found_mount_root"
        v2_point="$found_mount_point"
    fi
    if find_cgroup_mount "$mountinfo" v1; then
        have_v1_mount=1
        v1_root="$found_mount_root"
        v1_point="$found_mount_point"
    fi

    if [[ -r "$self_cgroup" ]]; then
        path=$(awk -F: '$1 == "0" && $2 == "" { print $3; exit }' "$self_cgroup")
        if [[ -n "$path" ]]; then
            if ((have_v2_mount)); then
                consider_cgroup_tree "$path" "$v2_root" "$v2_point" memory.max
            else
                consider_cgroup_tree "$path" / /sys/fs/cgroup memory.max
            fi
        fi

        path=$(awk -F: '$2 ~ /(^|,)memory(,|$)/ { print $3; exit }' "$self_cgroup")
        if [[ -n "$path" ]]; then
            if ((have_v1_mount)); then
                consider_cgroup_tree "$path" "$v1_root" "$v1_point" memory.limit_in_bytes
            else
                consider_cgroup_tree "$path" / /sys/fs/cgroup/memory memory.limit_in_bytes
            fi
        fi
    elif [[ -e "$cg_root/memory.max" ]]; then
        if value=$(read_limit_file "$cg_root/memory.max" 2>/dev/null); then
            limit=$(min_positive "$limit" "$value")
        fi
    fi
    if ((limit > 0 && limit < effective)); then
        effective="$limit"
    fi
    printf '%s\n' "$effective"
}

buffer_target_for_memory() {
    local bytes="$1"
    if ((bytes < 268435456)); then
        printf '1048576\n'
    elif ((bytes < 536870912)); then
        printf '2097152\n'
    elif ((bytes < 1073741824)); then
        printf '4194304\n'
    elif ((bytes < 2147483648)); then
        printf '8388608\n'
    elif ((bytes < 4294967296)); then
        printf '16777216\n'
    else
        printf '33554432\n'
    fi
}

desired_keys=()
desired_values=()
effective_bytes=0
buffer_target=0
available_cc=""
current_qdisc=""
current_cc=""
current_ecn=""
current_ecn_fallback=""
ecn_fallback_supported=0

add_desired() {
    desired_keys+=("$1")
    desired_values+=("$2")
}

prepare_desired() {
    local core_rmem core_wmem tcp_rmem tcp_wmem
    local rmem_min rmem_default rmem_max rmem_extra
    local wmem_min wmem_default wmem_max wmem_extra
    local desired_rmem_min desired_rmem_default desired_wmem_min desired_wmem_default

    desired_keys=()
    desired_values=()
    available_cc=$(sysctl_get net.ipv4.tcp_available_congestion_control)
    current_qdisc=$(sysctl_get net.core.default_qdisc)
    current_cc=$(sysctl_get net.ipv4.tcp_congestion_control)
    current_ecn=$(sysctl_get net.ipv4.tcp_ecn)
    if current_ecn_fallback=$(sysctl_get_optional net.ipv4.tcp_ecn_fallback); then
        ecn_fallback_supported=1
    else
        current_ecn_fallback=""
        ecn_fallback_supported=0
    fi
    effective_bytes=$(effective_memory_bytes)
    buffer_target=$(buffer_target_for_memory "$effective_bytes")

    add_desired net.core.default_qdisc fq
    add_desired net.ipv4.tcp_congestion_control bbr
    add_desired net.ipv4.tcp_ecn 1
    ((ecn_fallback_supported)) && add_desired net.ipv4.tcp_ecn_fallback 1

    core_rmem=$(sysctl_get net.core.rmem_max)
    core_wmem=$(sysctl_get net.core.wmem_max)
    tcp_rmem=$(sysctl_get net.ipv4.tcp_rmem)
    tcp_wmem=$(sysctl_get net.ipv4.tcp_wmem)
    [[ "$core_rmem" =~ ^[0-9]+$ && "$core_wmem" =~ ^[0-9]+$ ]] || {
        echo "ERROR: socket buffer sysctls are not numeric" >&2
        return 1
    }
    read -r rmem_min rmem_default rmem_max rmem_extra <<<"$tcp_rmem"
    read -r wmem_min wmem_default wmem_max wmem_extra <<<"$tcp_wmem"
    [[ "$rmem_min" =~ ^[0-9]+$ && "$rmem_default" =~ ^[0-9]+$ && "$rmem_max" =~ ^[0-9]+$ && -z "${rmem_extra:-}" ]] || {
        echo "ERROR: net.ipv4.tcp_rmem must contain exactly three integers" >&2
        return 1
    }
    [[ "$wmem_min" =~ ^[0-9]+$ && "$wmem_default" =~ ^[0-9]+$ && "$wmem_max" =~ ^[0-9]+$ && -z "${wmem_extra:-}" ]] || {
        echo "ERROR: net.ipv4.tcp_wmem must contain exactly three integers" >&2
        return 1
    }

    desired_rmem_min="$rmem_min"
    desired_rmem_default="$rmem_default"
    desired_wmem_min="$wmem_min"
    desired_wmem_default="$wmem_default"
    ((desired_rmem_min > buffer_target)) && desired_rmem_min="$buffer_target"
    ((desired_rmem_default > buffer_target)) && desired_rmem_default="$buffer_target"
    ((desired_rmem_default < desired_rmem_min)) && desired_rmem_default="$desired_rmem_min"
    ((desired_wmem_min > buffer_target)) && desired_wmem_min="$buffer_target"
    ((desired_wmem_default > buffer_target)) && desired_wmem_default="$buffer_target"
    ((desired_wmem_default < desired_wmem_min)) && desired_wmem_default="$desired_wmem_min"

    add_desired net.core.rmem_max "$buffer_target"
    add_desired net.core.wmem_max "$buffer_target"
    add_desired net.ipv4.tcp_rmem "$desired_rmem_min $desired_rmem_default $buffer_target"
    add_desired net.ipv4.tcp_wmem "$desired_wmem_min $desired_wmem_default $buffer_target"
}

bbr_capability() {
    if contains_word "$available_cc" bbr; then
        printf 'available\n'
    elif command_available "$modinfo_cmd" && "$modinfo_cmd" tcp_bbr >/dev/null 2>&1; then
        printf 'loadable\n'
    elif command_available "$modprobe_cmd"; then
        printf 'probe-required\n'
    else
        printf 'unsupported\n'
    fi
}

ensure_bbr_available() {
    if contains_word "$available_cc" bbr; then
        return 0
    fi
    if ! command_available "$modprobe_cmd"; then
        echo "ERROR: BBR is not registered and modprobe is unavailable" >&2
        return 1
    fi
    if ! "$modprobe_cmd" tcp_bbr >/dev/null 2>&1; then
        echo "ERROR: the running kernel could not load tcp_bbr; no sysctl file was changed" >&2
        return 1
    fi
    available_cc=$(sysctl_get net.ipv4.tcp_available_congestion_control)
    if ! contains_word "$available_cc" bbr; then
        echo "ERROR: tcp_bbr loaded without registering bbr; no sysctl file was changed" >&2
        return 1
    fi
}

render_config() {
    local destination="$1" index
    {
        echo '# Managed by V2bX network-tune.sh. Use its rollback command to restore.'
        echo '# This changes only defaults for new sockets/qdiscs; it does not replace a live interface qdisc.'
        for index in "${!desired_keys[@]}"; do
            printf '%s = %s\n' "${desired_keys[$index]}" "${desired_values[$index]}"
        done
    } > "$destination"
}

runtime_matches_desired() {
    local index actual expected
    for index in "${!desired_keys[@]}"; do
        actual=$(sysctl_get "${desired_keys[$index]}") || return 1
        expected=$(normalize_value "${desired_values[$index]}")
        [[ "$actual" == "$expected" ]] || return 1
    done
}

config_matches_desired() {
    local candidate="$1"
    [[ -f "$config_path" && ! -L "$config_path" ]] && cmp -s -- "$candidate" "$config_path"
}

override_conflicts=()

record_managed_keys_in_file() {
    local file="$1" line key normalized expected
    [[ -r "$file" ]] || {
        override_conflicts+=("$file (unreadable)")
        return 0
    }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line%%;*}"
        if [[ "$line" =~ ^[[:space:]]*-?([A-Za-z0-9_./-]+)[[:space:]]*= ]]; then
            key="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*-?([A-Za-z0-9_./-]+)[[:space:]]+[^[:space:]] ]]; then
            key="${BASH_REMATCH[1]}"
        else
            continue
        fi
        normalized="${key//\//.}"
        normalized="${normalized#.}"
        for expected in "${desired_keys[@]}"; do
            if [[ "$normalized" == "$expected" ]]; then
                override_conflicts+=("$file: $expected")
                break
            fi
        done
    done < "$file"
}

find_later_overrides() {
    local -a directories files
    local directory file base
    local LC_ALL=C
    declare -A effective_files=()
    override_conflicts=()
    directories=(
        "$(root_path /etc/sysctl.d)"
        "$(root_path /run/sysctl.d)"
        "$(root_path /usr/local/lib/sysctl.d)"
        "$(root_path /usr/lib/sysctl.d)"
        "$(root_path /lib/sysctl.d)"
    )

    shopt -s nullglob
    for directory in "${directories[@]}"; do
        [[ -d "$directory" ]] || continue
        files=("$directory"/*.conf)
        for file in "${files[@]}"; do
            base="${file##*/}"
            [[ -n "${effective_files[$base]+set}" ]] || effective_files["$base"]="$file"
        done
    done
    shopt -u nullglob

    for base in "${!effective_files[@]}"; do
        [[ "$base" > "$config_basename" ]] || continue
        record_managed_keys_in_file "${effective_files[$base]}"
    done
    file=$(root_path /etc/sysctl.conf)
    [[ -e "$file" ]] && record_managed_keys_in_file "$file"
    ((${#override_conflicts[@]} == 0))
}

assert_no_later_overrides() {
    local conflict
    if find_later_overrides; then
        return 0
    fi
    echo "ERROR: later-loading sysctl configuration defines managed keys:" >&2
    for conflict in "${override_conflicts[@]}"; do
        printf '  %s\n' "$conflict" >&2
    done
    echo "ERROR: remove or reconcile those definitions before applying network tuning" >&2
    return 1
}

acquire_lock() {
    mkdir -p -- "$state_dir" "$backups_dir"
    chmod 700 "$state_dir" "$backups_dir" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$state_dir/lock"
        if ! flock -n 9; then
            echo "ERROR: another network-tune operation is active" >&2
            return 1
        fi
    else
        fallback_lock_dir="$state_dir/lock.d"
        if ! mkdir -- "$fallback_lock_dir" 2>/dev/null; then
            echo "ERROR: another network-tune operation may be active" >&2
            return 1
        fi
    fi
}

read_backup_scalar() {
    local file="$1" destination="$2" scalar
    [[ -f "$file" && ! -L "$file" ]] || return 1
    scalar=$(<"$file")
    [[ -n "$scalar" && "$scalar" != *$'\n'* && "$scalar" != *$'\r'* ]] || return 1
    printf -v "$destination" '%s' "$scalar"
}

valid_backup_value() {
    local key="$1" value="$2" first second third extra
    case "$key" in
        net.core.default_qdisc|net.ipv4.tcp_congestion_control)
            [[ "$value" =~ ^[A-Za-z0-9_.+-]+$ ]]
            ;;
        net.ipv4.tcp_ecn|net.ipv4.tcp_ecn_fallback|net.core.rmem_max|net.core.wmem_max)
            [[ "$value" =~ ^[0-9]+$ ]]
            ;;
        net.ipv4.tcp_rmem|net.ipv4.tcp_wmem)
            read -r first second third extra <<<"$value"
            [[ "$first" =~ ^[0-9]+$ && "$second" =~ ^[0-9]+$ && "$third" =~ ^[0-9]+$ && -z "${extra:-}" ]]
            ;;
        *) return 1 ;;
    esac
}

validate_backup() {
    local backup_dir="$1" count existed complete index key value entry name
    local -a entries
    declare -A seen_keys=() allowed_files=()
    [[ -d "$backup_dir" && ! -L "$backup_dir" ]] || {
        echo "ERROR: backup is not a regular directory: $backup_dir" >&2
        return 1
    }
    read_backup_scalar "$backup_dir/complete" complete && [[ "$complete" == "complete" ]] || {
        echo "ERROR: incomplete backup: $backup_dir" >&2
        return 1
    }
    read_backup_scalar "$backup_dir/runtime-count" count && [[ "$count" =~ ^[0-9]+$ ]] &&
        ((count > 0 && count <= 16)) || {
        echo "ERROR: invalid backup runtime count: $backup_dir" >&2
        return 1
    }
    read_backup_scalar "$backup_dir/config-existed" existed && [[ "$existed" == "0" || "$existed" == "1" ]] || {
        echo "ERROR: invalid backup config metadata: $backup_dir" >&2
        return 1
    }
    if [[ "$existed" == "1" ]]; then
        [[ -f "$backup_dir/config" && ! -L "$backup_dir/config" ]] || {
            echo "ERROR: backed-up sysctl file is missing or unsafe: $backup_dir" >&2
            return 1
        }
        allowed_files[config]=1
    elif [[ -e "$backup_dir/config" || -L "$backup_dir/config" ]]; then
        echo "ERROR: backup unexpectedly contains a sysctl file: $backup_dir" >&2
        return 1
    fi

    allowed_files[complete]=1
    allowed_files[runtime-count]=1
    allowed_files[config-existed]=1
    for ((index = 0; index < count; index++)); do
        read_backup_scalar "$backup_dir/key.$index" key &&
            read_backup_scalar "$backup_dir/value.$index" value || {
            echo "ERROR: backup runtime entry $index is missing or malformed" >&2
            return 1
        }
        [[ -z "${seen_keys[$key]+set}" ]] && valid_backup_value "$key" "$value" || {
            echo "ERROR: backup runtime entry $index is unsafe or duplicated" >&2
            return 1
        }
        seen_keys["$key"]=1
        allowed_files["key.$index"]=1
        allowed_files["value.$index"]=1
    done

    shopt -s nullglob dotglob
    entries=("$backup_dir"/*)
    shopt -u nullglob dotglob
    for entry in "${entries[@]}"; do
        name="${entry##*/}"
        [[ -n "${allowed_files[$name]+set}" && -f "$entry" && ! -L "$entry" ]] || {
            echo "ERROR: backup contains an unexpected or unsafe entry: $entry" >&2
            return 1
        }
    done
}

discard_partial_backup() {
    local path="$1"
    [[ -n "$path" && "$path" == "$backups_dir/.creating."* && -d "$path" && ! -L "$path" ]] || return 0
    rm -rf -- "$path"
}

create_backup() {
    local id backup_dir partial_dir index value
    partial_dir=$(umask 077; mktemp -d "$backups_dir/.creating.XXXXXXXX") || {
        echo "ERROR: could not create a backup staging directory" >&2
        return 1
    }
    id="$(date -u +%Y%m%dT%H%M%SZ)-$$-${partial_dir##*.}"
    backup_dir="$backups_dir/$id"

    if [[ -e "$config_path" || -L "$config_path" ]]; then
        if [[ ! -f "$config_path" || -L "$config_path" ]]; then
            echo "ERROR: refusing to replace non-regular or symlinked $config_path" >&2
            discard_partial_backup "$partial_dir"
            return 1
        fi
        if ! cp -a -- "$config_path" "$partial_dir/config" ||
            ! cmp -s -- "$config_path" "$partial_dir/config" ||
            ! printf '1\n' > "$partial_dir/config-existed"; then
            echo "ERROR: failed to capture the existing sysctl file; apply aborted" >&2
            discard_partial_backup "$partial_dir"
            return 1
        fi
    elif ! printf '0\n' > "$partial_dir/config-existed"; then
        echo "ERROR: failed to record backup metadata; apply aborted" >&2
        discard_partial_backup "$partial_dir"
        return 1
    fi

    if ! printf '%s\n' "${#desired_keys[@]}" > "$partial_dir/runtime-count"; then
        echo "ERROR: failed to record backup metadata; apply aborted" >&2
        discard_partial_backup "$partial_dir"
        return 1
    fi
    for index in "${!desired_keys[@]}"; do
        if ! value=$(sysctl_get "${desired_keys[$index]}") ||
            ! printf '%s\n' "${desired_keys[$index]}" > "$partial_dir/key.$index" ||
            ! printf '%s\n' "$value" > "$partial_dir/value.$index"; then
            echo "ERROR: failed to capture runtime sysctl entry $index; apply aborted" >&2
            discard_partial_backup "$partial_dir"
            return 1
        fi
    done
    if ! printf 'complete\n' > "$partial_dir/complete" || ! validate_backup "$partial_dir"; then
        echo "ERROR: backup validation failed; apply aborted" >&2
        discard_partial_backup "$partial_dir"
        return 1
    fi
    if ! mv -T -- "$partial_dir" "$backup_dir" || ! validate_backup "$backup_dir"; then
        echo "ERROR: failed to publish a complete backup; apply aborted" >&2
        discard_partial_backup "$partial_dir"
        return 1
    fi
    printf '%s\n' "$backup_dir"
}

restore_backup() {
    local backup_dir="$1" count index key value existed restore_stage="" restore_failed=0
    validate_backup "$backup_dir" || return 1
    read_backup_scalar "$backup_dir/runtime-count" count
    read_backup_scalar "$backup_dir/config-existed" existed

    if ! mkdir -p -- "$(dirname "$config_path")"; then
        echo "ERROR: failed to prepare the sysctl directory for restore" >&2
        return 1
    fi
    if [[ "$existed" == "1" ]]; then
        restore_stage=$(mktemp "$(dirname "$config_path")/.99-v2bx-network-tune.restore.XXXXXX") || return 1
        if ! cp -a -- "$backup_dir/config" "$restore_stage" ||
            ! cmp -s -- "$backup_dir/config" "$restore_stage" ||
            ! mv -fT -- "$restore_stage" "$config_path"; then
            rm -f -- "$restore_stage" 2>/dev/null || true
            echo "ERROR: failed to restore $config_path" >&2
            return 1
        fi
    elif ! rm -f -- "$config_path"; then
        echo "ERROR: failed to remove newly-created $config_path" >&2
        return 1
    fi

    for ((index = 0; index < count; index++)); do
        read_backup_scalar "$backup_dir/key.$index" key
        read_backup_scalar "$backup_dir/value.$index" value
        if ! "$sysctl_cmd" -w "$key=$value" >/dev/null 2>&1; then
            echo "ERROR: failed to restore runtime sysctl $key" >&2
            restore_failed=1
        fi
    done
    ((restore_failed == 0))
}

transaction_failure() {
    local status="$1"
    trap - ERR
    trap '' INT TERM
    set +e
    if ((transaction_changed)) && [[ -n "$transaction_backup" ]]; then
        echo "ERROR: apply failed; restoring the previous sysctl file and runtime values" >&2
        if ! restore_backup "$transaction_backup"; then
            echo "CRITICAL: automatic rollback was incomplete: $transaction_backup" >&2
            status=1
        else
            echo "ROLLBACK: previous sysctl file and runtime values restored" >&2
        fi
    fi
    exit "$status"
}

run_check() {
    local capability candidate runtime_ok=0 config_ok=0
    prepare_desired
    assert_no_later_overrides
    capability=$(bbr_capability)
    printf 'Effective memory: %s MiB\n' "$((effective_bytes / 1048576))"
    printf 'Buffer ceiling: %s MiB (RAM-scaled; larger existing maxima will be reduced)\n' "$((buffer_target / 1048576))"
    printf 'Runtime default qdisc: %s (desired: fq; applies to newly created qdiscs)\n' "$current_qdisc"
    echo 'Live interface qdiscs: not inspected and never changed by this script'
    if ((ecn_fallback_supported)); then
        printf 'ECN fallback sysctl: available (current: %s)\n' "$current_ecn_fallback"
    else
        echo 'ECN fallback sysctl: unavailable on this kernel (skipped)'
    fi
    printf 'BBR capability: %s\n' "$capability"
    [[ "$capability" != "unsupported" ]] || {
        echo "ERROR: the running kernel does not expose BBR and no module probe is available" >&2
        return 1
    }

    candidate=$(mktemp)
    temp_files+=("$candidate")
    render_config "$candidate"
    runtime_matches_desired && runtime_ok=1
    config_matches_desired "$candidate" && config_ok=1
    if ((runtime_ok && config_ok)); then
        echo "OK: managed TCP/socket runtime defaults match the persistent configuration"
        echo "NOTE: BBR applies to TCP; UDP/QUIC transports and live interface qdiscs are not changed"
        return 0
    fi
    ((runtime_ok)) || echo "NEEDS APPLY: one or more runtime values differ"
    ((config_ok)) || echo "NEEDS APPLY: $config_path differs or is absent"
    return 3
}

run_apply() {
    local candidate backup_dir id latest_stage
    acquire_lock
    mkdir -p -- "$(dirname "$config_path")"
    if [[ -e "$config_path" || -L "$config_path" ]]; then
        [[ -f "$config_path" && ! -L "$config_path" ]] || {
            echo "ERROR: refusing non-regular or symlinked $config_path" >&2
            return 1
        }
    fi

    prepare_desired
    assert_no_later_overrides

    candidate=$(mktemp)
    temp_files+=("$candidate")
    render_config "$candidate"
    if runtime_matches_desired && config_matches_desired "$candidate"; then
        echo "OK: managed TCP/socket runtime defaults already match the persistent configuration"
        echo "NOTE: live interface qdiscs were not inspected or changed"
        return 0
    fi

    if ! backup_dir=$(create_backup); then
        echo "ERROR: no runtime or persistent network setting was changed" >&2
        return 1
    fi
    validate_backup "$backup_dir" || {
        echo "ERROR: published backup failed validation; no network setting was changed" >&2
        return 1
    }
    transaction_backup="$backup_dir"
    id="${backup_dir##*/}"
    stage_path=$(mktemp "$(dirname "$config_path")/.99-v2bx-network-tune.XXXXXX")
    render_config "$stage_path"
    chmod 0644 "$stage_path"
    assert_no_later_overrides

    trap 'transaction_failure "$?"' ERR
    trap 'transaction_failure 130' INT
    trap 'transaction_failure 143' TERM
    transaction_changed=1

    ensure_bbr_available
    # sch_fq may be a module or built in. This never replaces a live interface qdisc.
    if command_available "$modprobe_cmd"; then
        "$modprobe_cmd" sch_fq >/dev/null 2>&1 || true
    fi

    mv -fT -- "$stage_path" "$config_path"
    stage_path=""

    if ! "$sysctl_cmd" -p "$config_path" >/dev/null; then
        echo "ERROR: sysctl rejected the managed file" >&2
        transaction_failure 1
    fi
    if ! runtime_matches_desired; then
        echo "ERROR: sysctl values did not match after apply" >&2
        transaction_failure 1
    fi
    assert_no_later_overrides

    latest_stage=$(mktemp "$state_dir/.latest.XXXXXX")
    temp_files+=("$latest_stage")
    printf '%s\n' "$id" > "$latest_stage"
    mv -fT -- "$latest_stage" "$latest_path"
    transaction_changed=0
    trap - ERR INT TERM
    echo "APPLIED: managed TCP/socket defaults and RAM-scaled buffer ceilings"
    echo "DEFAULT QDISC: fq for newly created qdiscs; live interface qdiscs were not inspected or changed"
    echo "PROTOCOL NOTE: BBR applies to TCP; UDP/QUIC transports keep their own congestion control"
    echo "BACKUP: $id"
}

run_rollback() {
    local id="$backup_id" backup_dir
    acquire_lock
    if [[ -z "$id" ]]; then
        read_backup_scalar "$latest_path" id || { echo "ERROR: no valid latest backup exists" >&2; return 1; }
    fi
    [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: invalid backup ID" >&2; return 1; }
    backup_dir="$backups_dir/$id"
    [[ -d "$backup_dir" && ! -L "$backup_dir" ]] || { echo "ERROR: backup not found: $id" >&2; return 1; }
    validate_backup "$backup_dir"
    trap '' INT TERM
    if ! restore_backup "$backup_dir"; then
        trap - INT TERM
        return 1
    fi
    trap - INT TERM
    echo "ROLLED BACK: $config_path and runtime values restored from $id"
}

case "$mode" in
    check) run_check ;;
    apply) run_apply ;;
    rollback) run_rollback ;;
esac
