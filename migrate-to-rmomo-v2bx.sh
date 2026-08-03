#!/usr/bin/env bash
set -Eeuo pipefail

mode="check"
version=""
backup_id=""
skip_config_patch=0
skip_hy2_fix=0
skip_network_tune=0
skip_resource_guard=0

core_repo="${V2BX_CORE_REPO:-rmomo5285-droid/V2bX}"
script_repo="${V2BX_SCRIPT_REPO:-rmomo5285-droid/V2bX-script}"
script_ref="${V2BX_SCRIPT_REF:-v0.1.0}"
root_dir="${V2BX_MIGRATE_ROOT:-/}"
service_name="${V2BX_SERVICE_NAME:-V2bX}"

usage() {
    cat <<'EOF'
Usage: migrate-to-rmomo-v2bx.sh [check | apply | status | rollback [ID]] [options]

Production-safe, per-server migration from an upstream V2bX installation to
rmomo5285-droid/V2bX. The default check is read-only.

Commands:
  check                 Inspect compatibility and report planned changes
  apply                 Download, verify, back up, switch, and health-check
  status                Show service, binary, config, and legacy-ACL status
  rollback [ID]         Restore a completed migration backup (latest by default)

Options:
  --version TAG         Install an exact core release instead of latest
  --backup ID           Select a backup for rollback
  --skip-config-patch   Do not add missing AbuseGuardConfig defaults
  --skip-hy2-fix        Do not remove the exact old generated Hy2 China ACL
  --skip-network-tune   Do not run the conservative network tuner after success
  --skip-resource-guard Do not apply the low-memory native-Hy2 systemd guard
  -h, --help            Show this help

The script preserves /etc/V2bX, rejects unverified release assets, keeps the
old service running during downloads/preparation, and automatically restores
the old installation if the switched service fails its health check.
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
        --version)
            [[ $# -ge 2 ]] || { echo "ERROR: --version requires a tag" >&2; exit 2; }
            version="$2"
            shift 2
            ;;
        --backup)
            [[ $# -ge 2 ]] || { echo "ERROR: --backup requires an ID" >&2; exit 2; }
            backup_id="$2"
            shift 2
            ;;
        --skip-config-patch)
            skip_config_patch=1
            shift
            ;;
        --skip-hy2-fix)
            skip_hy2_fix=1
            shift
            ;;
        --skip-network-tune)
            skip_network_tune=1
            shift
            ;;
        --skip-resource-guard)
            skip_resource_guard=1
            shift
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

[[ "$root_dir" == /* ]] || { echo "ERROR: V2BX_MIGRATE_ROOT must be absolute" >&2; exit 2; }
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

binary_path=$(root_path /usr/local/V2bX/V2bX)
config_path=$(root_path /etc/V2bX/config.json)
hy2_path=$(root_path /etc/V2bX/hy2config.yaml)
manager_path=$(root_path /usr/bin/V2bX)
state_dir=$(root_path /var/lib/v2bx-migrate)
backups_dir="$state_dir/backups"
latest_path="$state_dir/latest"
service_path=$(root_path /etc/systemd/system/V2bX.service)
share_dir=$(root_path /usr/local/share/v2bx)
initconfig_path="$share_dir/initconfig.sh"
fixer_path="$share_dir/fix-legacy-hy2-config.sh"
tuner_path="$share_dir/network-tune.sh"
resource_path="$share_dir/resource-guard.sh"
migrator_path="$share_dir/migrate-to-rmomo-v2bx.sh"
logrotate_path=$(root_path /etc/logrotate.d/v2bx)

if [[ "$mode" != "check" && "$mode" != "status" && "${V2BX_MIGRATE_SKIP_ROOT_CHECK:-0}" != "1" && "$(id -u)" -ne 0 ]]; then
    echo "ERROR: $mode must run as root" >&2
    exit 1
fi

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

service_backend() {
    if command_exists systemctl; then
        printf 'systemd\n'
    elif command_exists rc-service; then
        printf 'openrc\n'
    else
        printf 'unsupported\n'
    fi
}

service_active() {
    case "$(service_backend)" in
        systemd) systemctl is-active --quiet "$service_name" ;;
        openrc) rc-service "$service_name" status >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

service_stop() {
    case "$(service_backend)" in
        systemd) systemctl stop "$service_name" ;;
        openrc) rc-service "$service_name" stop ;;
        *) return 1 ;;
    esac
}

service_start() {
    case "$(service_backend)" in
        systemd) systemctl daemon-reload && systemctl start "$service_name" ;;
        openrc) rc-service "$service_name" start ;;
        *) return 1 ;;
    esac
}

service_restart() {
    case "$(service_backend)" in
        systemd) systemctl daemon-reload && systemctl restart "$service_name" ;;
        openrc) rc-service "$service_name" restart ;;
        *) return 1 ;;
    esac
}

detect_asset_name() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'linux-64\n' ;;
        aarch64|arm64) printf 'linux-arm64-v8a\n' ;;
        s390x) printf 'linux-s390x\n' ;;
        *) echo "ERROR: unsupported architecture: $(uname -m)" >&2; return 1 ;;
    esac
}

download_file() {
    local url="$1" destination="$2"
    if command_exists curl; then
        curl --proto '=https' --tlsv1.2 -fL --retry 3 --retry-delay 2 \
            --connect-timeout 15 --max-time 600 -o "$destination" "$url"
    elif command_exists wget; then
        wget --https-only --tries=3 --timeout=30 -O "$destination" "$url"
    else
        echo "ERROR: curl or wget is required" >&2
        return 1
    fi
}

resolve_latest_version() {
    local metadata
    metadata=$(mktemp)
    temp_paths+=("$metadata")
    download_file "https://api.github.com/repos/$core_repo/releases/latest" "$metadata"
    version=$(sed -nE 's/^[[:space:]]*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' "$metadata" | head -n1)
    [[ "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
        echo "ERROR: GitHub did not return a valid release tag" >&2
        return 1
    }
}

install_jq_if_needed() {
    command_exists jq && return 0
    echo "INFO: jq is required to patch and validate config.json; installing it before any service change"
    if command_exists apt-get; then
        apt-get update -y && apt-get install -y jq
    elif command_exists dnf; then
        dnf install -y jq
    elif command_exists yum; then
        yum install -y jq
    elif command_exists apk; then
        apk add --no-cache jq
    elif command_exists pacman; then
        pacman -Sy --noconfirm --needed jq
    else
        echo "ERROR: jq is absent and no supported package manager was found" >&2
        return 1
    fi
}

redact() {
    sed -E \
        -e 's/([?&](token|api[_-]?key)=)[^&[:space:]]+/\1REDACTED/Ig' \
        -e 's/(ApiKey["=:[:space:]]+)[^",[:space:]]+/\1REDACTED/Ig'
}

legacy_acl_state() {
    if [[ ! -f "$hy2_path" ]]; then
        printf 'not-applicable\n'
        return
    fi
    local google geosite geoip
    google=$(grep -Ec '^[[:space:]]*-[[:space:]]*direct\(geosite:google\)[[:space:]]*(#.*)?$' "$hy2_path" || true)
    geosite=$(grep -Ec '^[[:space:]]*-[[:space:]]*reject\(geosite:cn\)[[:space:]]*(#.*)?$' "$hy2_path" || true)
    geoip=$(grep -Ec '^[[:space:]]*-[[:space:]]*reject\(geoip:cn\)[[:space:]]*(#.*)?$' "$hy2_path" || true)
    if ((google == 0 && geosite == 0 && geoip == 0)); then
        printf 'absent\n'
    elif ((google == 1 && geosite == 1 && geoip == 1)); then
        printf 'exact-or-customized\n'
    else
        printf 'partial-or-duplicated\n'
    fi
}

config_guard_state() {
    if [[ ! -f "$config_path" ]]; then
        printf 'missing\n'
    elif ! command_exists jq || ! jq -e '(.Cores | type) == "array" and (.Nodes | type) == "array"' "$config_path" >/dev/null 2>&1; then
        printf 'unparseable\n'
    else
        local total enabled
        total=$(jq '.Nodes | length' "$config_path")
        enabled=$(jq '[.Nodes[] | select(.LimitConfig.AbuseGuardConfig.Enable == true)] | length' "$config_path")
        printf '%s/%s-enabled\n' "$enabled" "$total"
    fi
}

run_status() {
    echo "Core repository: $core_repo"
    if [[ -x "$binary_path" ]]; then
        "$binary_path" version 2>&1 | head -n3 | redact || true
        if command_exists sha256sum; then
            printf 'Binary SHA-256: '
            sha256sum "$binary_path" | awk '{print $1}'
        fi
    else
        echo "Binary: missing at $binary_path"
    fi
    if service_active; then
        echo "Service: active"
    else
        echo "Service: inactive"
    fi
    echo "Abuse guard: $(config_guard_state)"
    echo "Legacy Hy2 ACL: $(legacy_acl_state)"
    if command_exists jq && [[ -f "$config_path" ]]; then
        echo "Configured cores:"
        jq -r '.Cores[] | "  - " + ((.Name // .Type) | tostring) + ": " + (.Type | tostring)' "$config_path" 2>/dev/null || true
        echo "Configured nodes:"
        jq -r '.Nodes[] | "  - ID " + (.NodeID | tostring) + ": " + (.NodeType | tostring) + " via " + ((if ((.CoreName // "") | length) > 0 then .CoreName else .Core end) | tostring)' "$config_path" 2>/dev/null || true
    fi
    [[ -x "$resource_path" ]] && "$resource_path" status 2>/dev/null || true
    if [[ -f "$latest_path" ]]; then
        echo "Latest migration backup: $(<"$latest_path")"
    fi
}

run_check() {
    local failed=0 backend asset
    backend=$(service_backend)
    asset=$(detect_asset_name) || failed=1
    [[ -x "$binary_path" ]] || { echo "ERROR: current binary missing: $binary_path" >&2; failed=1; }
    [[ -f "$config_path" && ! -L "$config_path" ]] || { echo "ERROR: regular config missing: $config_path" >&2; failed=1; }
    [[ "$backend" != "unsupported" ]] || { echo "ERROR: neither systemd nor OpenRC is available" >&2; failed=1; }
    command_exists unzip || { echo "ERROR: unzip is required" >&2; failed=1; }
    command_exists sha256sum || { echo "ERROR: sha256sum is required" >&2; failed=1; }
    if ((skip_config_patch == 0)); then
        if command_exists jq; then
            jq -e '(.Cores | type) == "array" and (.Cores | length > 0) and (.Nodes | type) == "array" and (.Nodes | length > 0)' "$config_path" >/dev/null || {
                echo "ERROR: config is not strict JSON with non-empty Cores and Nodes arrays" >&2
                failed=1
            }
        else
            echo "INFO: jq will be installed during apply while the old service remains running"
        fi
    fi
    echo "Service backend: $backend"
    echo "Release asset: V2bX-$asset.zip"
    echo "Current abuse guard: $(config_guard_state)"
    echo "Legacy Hy2 ACL: $(legacy_acl_state)"
    if ((failed)); then
        return 1
    fi
    echo "READY: apply can prepare and verify the replacement before stopping V2bX"
}

temp_dir=""
temp_paths=()
fallback_lock=""
transaction_backup=""
transaction_started=0
service_was_active=0
backup_result=""

cleanup() {
    local path
    for path in "${temp_paths[@]:-}"; do
        [[ -n "$path" ]] && rm -f -- "$path" 2>/dev/null || true
    done
    [[ -n "$temp_dir" ]] && rm -rf -- "$temp_dir" 2>/dev/null || true
    [[ -n "$fallback_lock" ]] && rmdir -- "$fallback_lock" 2>/dev/null || true
}
trap cleanup EXIT

acquire_lock() {
    mkdir -p -- "$state_dir" "$backups_dir"
    chmod 0700 "$state_dir" "$backups_dir" 2>/dev/null || true
    if command_exists flock; then
        exec 9>"$state_dir/lock"
        flock -n 9 || { echo "ERROR: another migration is active" >&2; return 1; }
    else
        fallback_lock="$state_dir/lock.d"
        mkdir -- "$fallback_lock" 2>/dev/null || { echo "ERROR: another migration may be active" >&2; return 1; }
    fi
}

backup_copy() {
    local source="$1" destination="$2" marker="$3"
    if [[ -e "$source" ]]; then
        [[ -f "$source" && ! -L "$source" ]] || { echo "ERROR: refusing non-regular backup source: $source" >&2; return 1; }
        cp -a -- "$source" "$destination" || return 1
        printf '1\n' > "$marker" || return 1
    else
        printf '0\n' > "$marker" || return 1
    fi
}

create_backup() {
    local id dir
    id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    dir="$backups_dir/$id"
    (umask 077; mkdir -- "$dir") || return 1
    backup_copy "$binary_path" "$dir/V2bX" "$dir/binary-existed" || return 1
    backup_copy "$config_path" "$dir/config.json" "$dir/config-existed" || return 1
    backup_copy "$hy2_path" "$dir/hy2config.yaml" "$dir/hy2-existed" || return 1
    backup_copy "$manager_path" "$dir/manager" "$dir/manager-existed" || return 1
    backup_copy "$service_path" "$dir/V2bX.service" "$dir/service-existed" || return 1
    backup_copy "$initconfig_path" "$dir/initconfig.sh" "$dir/initconfig-existed" || return 1
    backup_copy "$fixer_path" "$dir/fixer.sh" "$dir/fixer-existed" || return 1
    backup_copy "$tuner_path" "$dir/tuner.sh" "$dir/tuner-existed" || return 1
    backup_copy "$resource_path" "$dir/resource-guard.sh" "$dir/resource-existed" || return 1
    backup_copy "$migrator_path" "$dir/migrator.sh" "$dir/migrator-existed" || return 1
    backup_copy "$logrotate_path" "$dir/logrotate" "$dir/logrotate-existed" || return 1
    printf '%s\n' "$service_was_active" > "$dir/service-was-active" || return 1
    printf '%s\n' "$version" > "$dir/installed-version" || return 1
    printf 'complete\n' > "$dir/complete" || return 1
    backup_result="$dir"
}

validate_backup() {
    local dir="$1" marker value
    [[ -d "$dir" && -f "$dir/complete" && -f "$dir/service-was-active" ]] || return 1
    for marker in binary config hy2 manager service initconfig fixer tuner resource migrator logrotate; do
        [[ -f "$dir/$marker-existed" ]] || return 1
        value=$(<"$dir/$marker-existed")
        [[ "$value" == "0" || "$value" == "1" ]] || return 1
        if [[ "$value" == "1" ]]; then
            case "$marker" in
                binary) [[ -f "$dir/V2bX" ]] || return 1 ;;
                config) [[ -f "$dir/config.json" ]] || return 1 ;;
                hy2) [[ -f "$dir/hy2config.yaml" ]] || return 1 ;;
                manager) [[ -f "$dir/manager" ]] || return 1 ;;
                service) [[ -f "$dir/V2bX.service" ]] || return 1 ;;
                initconfig) [[ -f "$dir/initconfig.sh" ]] || return 1 ;;
                fixer) [[ -f "$dir/fixer.sh" ]] || return 1 ;;
                tuner) [[ -f "$dir/tuner.sh" ]] || return 1 ;;
                resource) [[ -f "$dir/resource-guard.sh" ]] || return 1 ;;
                migrator) [[ -f "$dir/migrator.sh" ]] || return 1 ;;
                logrotate) [[ -f "$dir/logrotate" ]] || return 1 ;;
            esac
        fi
    done
}

restore_one() {
    local marker="$1" backup="$2" destination="$3" stage
    if [[ "$(<"$marker")" == "1" ]]; then
        mkdir -p -- "$(dirname "$destination")"
        stage=$(mktemp "$(dirname "$destination")/.v2bx-restore.XXXXXX")
        cp -a -- "$backup" "$stage"
        cmp -s -- "$backup" "$stage"
        mv -fT -- "$stage" "$destination"
    else
        rm -f -- "$destination"
    fi
}

restore_backup() {
    local dir="$1" was_active
    validate_backup "$dir" || { echo "ERROR: backup is incomplete: $dir" >&2; return 1; }
    service_stop >/dev/null 2>&1 || true
    restore_one "$dir/binary-existed" "$dir/V2bX" "$binary_path"
    restore_one "$dir/config-existed" "$dir/config.json" "$config_path"
    restore_one "$dir/hy2-existed" "$dir/hy2config.yaml" "$hy2_path"
    restore_one "$dir/manager-existed" "$dir/manager" "$manager_path"
    restore_one "$dir/service-existed" "$dir/V2bX.service" "$service_path"
    restore_one "$dir/initconfig-existed" "$dir/initconfig.sh" "$initconfig_path"
    restore_one "$dir/fixer-existed" "$dir/fixer.sh" "$fixer_path"
    restore_one "$dir/tuner-existed" "$dir/tuner.sh" "$tuner_path"
    restore_one "$dir/resource-existed" "$dir/resource-guard.sh" "$resource_path"
    restore_one "$dir/migrator-existed" "$dir/migrator.sh" "$migrator_path"
    restore_one "$dir/logrotate-existed" "$dir/logrotate" "$logrotate_path"
    was_active=$(<"$dir/service-was-active")
    if [[ "$(service_backend)" == "systemd" ]]; then
        systemctl daemon-reload
    fi
    if [[ "$was_active" == "1" ]]; then
        service_start
        service_active
    fi
}

transaction_failure() {
    local status="$1"
    trap - ERR INT TERM
    set +e
    if ((transaction_started)) && [[ -n "$transaction_backup" ]]; then
        echo "ERROR: switched installation failed; restoring the previous V2bX" >&2
        if ! restore_backup "$transaction_backup"; then
            echo "CRITICAL: automatic rollback was incomplete: $transaction_backup" >&2
            status=1
        fi
    fi
    exit "$status"
}

prepare_config() {
    local source="$1" destination="$2"
    cp -a -- "$source" "$destination"
    ((skip_config_patch)) && return 0
    jq -e '(.Cores | type) == "array" and (.Cores | length > 0) and (.Nodes | type) == "array" and (.Nodes | length > 0)' "$destination" >/dev/null
    local patched="${destination}.patched"
    jq '
      .Log = ((.Log // {}) |
        if ((.Output // "") | length) == 0 then
          .Output = "/var/log/V2bX/v2bx.log"
        else . end)
      | .Cores |= map(
          .Type as $core_type
          | .Log = ((.Log // {}) |
              if $core_type == "xray" and ((.ErrorPath // "") | length) == 0 then
                .ErrorPath = "/var/log/V2bX/xray-error.log"
              elif $core_type == "sing" and ((.Output // "") | length) == 0 then
                .Output = "/var/log/V2bX/sing.log"
              elif $core_type == "hysteria2" and ((.Output // "") | length) == 0 then
                .Output = "/var/log/V2bX/hy2.log"
              else . end))
      | .Nodes |= map(
        .LimitConfig = ((.LimitConfig // {}) |
          .AbuseGuardConfig = ({
            Enable: true,
            WindowSeconds: 10,
            MaxClientConnections: 20,
            MaxOutboundConnections: 300,
            MaxDistinctDestinations: 128,
            MaxDistinctIPTargets: 32,
            MaxDistinctPorts: 16,
            BlockSeconds: 600,
            MaxTrackedUsers: 10000
          } + (.AbuseGuardConfig // {})))
      )
    ' "$destination" > "$patched"
    jq -e '(.Nodes | type) == "array" and ([.Nodes[] | .LimitConfig.AbuseGuardConfig.Enable] | all(type == "boolean"))' "$patched" >/dev/null
    chmod --reference="$destination" "$patched" 2>/dev/null || chmod 0600 "$patched"
    mv -f -- "$patched" "$destination"
}

prepare_hy2() {
    local source="$1" destination="$2" fixer="$3"
    [[ -f "$source" ]] || return 0
    cp -a -- "$source" "$destination"
    ((skip_hy2_fix)) && return 0
    set +e
    V2BX_FIX_SKIP_ROOT_CHECK=1 bash "$fixer" check --config "$destination" >/dev/null 2>&1
    local check_status=$?
    set -e
    case "$check_status" in
        0) ;;
        3) V2BX_FIX_SKIP_ROOT_CHECK=1 bash "$fixer" apply --skip-restart --config "$destination" >/dev/null ;;
        *) echo "ERROR: legacy Hy2 ACL is customized or malformed; refusing automatic migration" >&2; return 1 ;;
    esac
}

verify_component() {
    local manifest="$1" path="$2" name="$3" expected actual
    expected=$(awk -v component="$name" '$2 == component || $2 == "*" component { print $1; exit }' "$manifest")
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || {
        echo "ERROR: components.sha256 has no valid entry for $name" >&2
        return 1
    }
    actual=$(sha256sum "$path" | awk '{print $1}')
    [[ "${actual,,}" == "${expected,,}" ]] || {
        echo "ERROR: component SHA-256 mismatch: $name" >&2
        return 1
    }
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

run_apply() {
    run_check
    acquire_lock
    if ((skip_config_patch == 0)); then
        install_jq_if_needed
    fi
    [[ -n "$version" ]] || resolve_latest_version

    local asset release_base archive checksum expected actual unpack_dir
    local staged_config staged_hy2 staged_manager fixer tuner resource initconfig staged_migrator staged_logrotate
    local manifest helper name destination id latest_stage raw_base resource_output resource_backup network_output network_backup
    local -a component_names
    asset="V2bX-$(detect_asset_name).zip"
    release_base="https://github.com/$core_repo/releases/download/$version"
    temp_dir=$(mktemp -d)
    archive="$temp_dir/$asset"
    checksum="$archive.sha256"
    unpack_dir="$temp_dir/unpack"
    mkdir "$unpack_dir"

    echo "INFO: downloading and verifying $core_repo $version while the old service remains active"
    download_file "$release_base/$asset" "$archive"
    download_file "$release_base/$asset.sha256" "$checksum"
    expected=$(awk -v asset="$asset" '$2 == asset || $2 == "*" asset { print $1; exit }' "$checksum")
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "ERROR: release SHA-256 file is invalid" >&2; return 1; }
    actual=$(sha256sum "$archive" | awk '{print $1}')
    [[ "${actual,,}" == "${expected,,}" ]] || { echo "ERROR: release SHA-256 mismatch" >&2; return 1; }
    unzip -tq "$archive" >/dev/null
    unzip -q "$archive" -d "$unpack_dir"
    [[ -x "$unpack_dir/V2bX" || -f "$unpack_dir/V2bX" ]] || { echo "ERROR: release does not contain V2bX" >&2; return 1; }
    chmod 0755 "$unpack_dir/V2bX"
    "$unpack_dir/V2bX" version >/dev/null 2>&1

    staged_config="$temp_dir/config.json"
    prepare_config "$config_path" "$staged_config"
    raw_base="https://raw.githubusercontent.com/$script_repo/$script_ref"
    manifest="$temp_dir/components.sha256"
    download_file "$raw_base/components.sha256" "$manifest"
    component_names=(
        V2bX.sh
        initconfig.sh
        fix-legacy-hy2-config.sh
        network-tune.sh
        resource-guard.sh
        migrate-to-rmomo-v2bx.sh
        v2bx.logrotate
    )
    for name in "${component_names[@]}"; do
        helper="$temp_dir/$name"
        download_file "$raw_base/$name" "$helper"
        verify_component "$manifest" "$helper" "$name"
        [[ "$name" != *.sh ]] || bash -n "$helper"
    done
    staged_manager="$temp_dir/V2bX.sh"
    initconfig="$temp_dir/initconfig.sh"
    fixer="$temp_dir/fix-legacy-hy2-config.sh"
    tuner="$temp_dir/network-tune.sh"
    resource="$temp_dir/resource-guard.sh"
    staged_migrator="$temp_dir/migrate-to-rmomo-v2bx.sh"
    staged_logrotate="$temp_dir/v2bx.logrotate"
    chmod 0755 "$staged_manager" "$initconfig" "$fixer" "$tuner" "$resource" "$staged_migrator"
    staged_hy2="$temp_dir/hy2config.yaml"
    prepare_hy2 "$hy2_path" "$staged_hy2" "$fixer"

    service_active && service_was_active=1 || service_was_active=0
    create_backup
    transaction_backup="$backup_result"
    id="${transaction_backup##*/}"
    validate_backup "$transaction_backup"

    trap 'transaction_failure $?' ERR
    trap 'transaction_failure 130' INT
    trap 'transaction_failure 143' TERM
    transaction_started=1
    ((service_was_active)) && service_stop

    install -m 0755 "$unpack_dir/V2bX" "${binary_path}.new"
    mv -f -- "${binary_path}.new" "$binary_path"
    install -m 0600 "$staged_config" "${config_path}.new"
    mv -f -- "${config_path}.new" "$config_path"
    if [[ -f "$staged_hy2" ]]; then
        install -m 0644 "$staged_hy2" "${hy2_path}.new"
        mv -f -- "${hy2_path}.new" "$hy2_path"
    fi
    install -m 0755 "$staged_manager" "${manager_path}.new"
    mv -f -- "${manager_path}.new" "$manager_path"
    mkdir -p -- "$share_dir" "$(dirname "$logrotate_path")" "$(root_path /var/log/V2bX)"
    for name in initconfig fixer tuner resource migrator; do
        case "$name" in
            initconfig) helper="$initconfig"; destination="$initconfig_path" ;;
            fixer) helper="$fixer"; destination="$fixer_path" ;;
            tuner) helper="$tuner"; destination="$tuner_path" ;;
            resource) helper="$resource"; destination="$resource_path" ;;
            migrator) helper="$staged_migrator"; destination="$migrator_path" ;;
        esac
        install -m 0755 "$helper" "${destination}.new"
        mv -f -- "${destination}.new" "$destination"
    done
    install -m 0644 "$staged_logrotate" "${logrotate_path}.new"
    mv -f -- "${logrotate_path}.new" "$logrotate_path"

    if ((service_was_active)); then
        service_start
        wait_for_service
    fi
    "$binary_path" version >/dev/null 2>&1

    latest_stage=$(mktemp "$state_dir/.latest.XXXXXX")
    printf '%s\n' "$id" > "$latest_stage"
    mv -f -- "$latest_stage" "$latest_path"
    transaction_started=0
    trap - ERR INT TERM

    echo "APPLIED: switched to $core_repo $version"
    echo "BACKUP: $id"
    if ((skip_resource_guard == 0)); then
        if resource_output=$(bash "$resource_path" apply 2>&1); then
            printf '%s\n' "$resource_output"
            resource_backup=$(sed -nE 's/^BACKUP:[[:space:]]*([A-Za-z0-9._-]+)$/\1/p' <<<"$resource_output" | tail -n1)
            [[ -z "$resource_backup" ]] || printf '%s\n' "$resource_backup" > "$transaction_backup/resource-backup-id"
        else
            printf '%s\n' "$resource_output" >&2
            echo "WARNING: core migration succeeded; the separately transactional resource guard was not applied" >&2
        fi
    fi
    if ((skip_network_tune == 0)); then
        if network_output=$(bash "$tuner_path" apply 2>&1); then
            printf '%s\n' "$network_output"
            network_backup=$(sed -nE 's/^BACKUP:[[:space:]]*([A-Za-z0-9._-]+)$/\1/p' <<<"$network_output" | tail -n1)
            [[ -z "$network_backup" ]] || printf '%s\n' "$network_backup" > "$transaction_backup/network-backup-id"
            echo "NETWORK: conservative tuning applied in its own rollback transaction"
        else
            printf '%s\n' "$network_output" >&2
            echo "WARNING: core migration succeeded but network tuning was unsupported or failed; V2bX was not rolled back" >&2
        fi
    fi
    run_status
}

rollback_auxiliary_changes() {
    local dir="$1" id
    if [[ -f "$dir/resource-backup-id" ]]; then
        id=$(<"$dir/resource-backup-id")
        [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: invalid resource backup ID" >&2; return 1; }
        [[ -x "$resource_path" ]] || { echo "ERROR: resource guard helper is missing" >&2; return 1; }
        "$resource_path" rollback "$id"
    fi
    if [[ -f "$dir/network-backup-id" ]]; then
        id=$(<"$dir/network-backup-id")
        [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: invalid network backup ID" >&2; return 1; }
        [[ -x "$tuner_path" ]] || { echo "ERROR: network tuner helper is missing" >&2; return 1; }
        "$tuner_path" rollback "$id"
    fi
}

run_rollback() {
    acquire_lock
    local id="$backup_id" dir
    if [[ -z "$id" ]]; then
        [[ -f "$latest_path" ]] || { echo "ERROR: no migration backup is recorded" >&2; return 1; }
        id=$(<"$latest_path")
    fi
    [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: invalid backup ID" >&2; return 1; }
    dir="$backups_dir/$id"
    validate_backup "$dir"
    rollback_auxiliary_changes "$dir"
    restore_backup "$dir"
    echo "ROLLED BACK: restored V2bX from $id"
    run_status
}

case "$mode" in
    check) run_check ;;
    apply) run_apply ;;
    status) run_status ;;
    rollback) run_rollback ;;
esac
