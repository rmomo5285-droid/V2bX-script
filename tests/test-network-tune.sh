#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_dir/network-tune.sh"
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT

root="$temp_dir/root"
state="$temp_dir/sysctl.state"
mkdir -p "$root/proc/self" "$root/etc/sysctl.d" "$root/run/sysctl.d" \
    "$root/usr/local/lib/sysctl.d" "$root/usr/lib/sysctl.d" "$root/lib/sysctl.d" "$temp_dir/bin"
cat > "$root/proc/meminfo" <<'EOF'
MemTotal:         934912 kB
EOF
cat > "$state" <<'EOF'
net.ipv4.tcp_available_congestion_control=cubic bbr
net.core.default_qdisc=pfifo_fast
net.ipv4.tcp_congestion_control=cubic
net.ipv4.tcp_ecn=2
net.ipv4.tcp_ecn_fallback=1
net.core.rmem_max=212992
net.core.wmem_max=212992
net.ipv4.tcp_rmem=4096 131072 6291456
net.ipv4.tcp_wmem=4096 16384 4194304
EOF

cat > "$temp_dir/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
state=${FAKE_SYSCTL_STATE:?}
get_value() {
    awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$state"
}
set_value() {
    local key="$1" value="$2" staged="${state}.new"
    awk -F= -v key="$key" -v value="$value" '
        BEGIN { found=0 }
        $1 == key { print key "=" value; found=1; next }
        { print }
        END { if (!found) print key "=" value }
    ' "$state" > "$staged"
    mv -f -- "$staged" "$state"
}
case "${1:-}" in
    -n)
        get_value "${2:?}"
        ;;
    -w)
        assignment="${2:?}"
        key="${assignment%%=*}"
        value="${assignment#*=}"
        set_value "$key" "$value"
        printf '%s = %s\n' "$key" "$value"
        ;;
    -p)
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}"
            [[ "$line" == *"="* ]] || continue
            key="${line%%=*}"
            value="${line#*=}"
            key=$(awk '{$1=$1; print}' <<<"$key")
            value=$(awk '{$1=$1; print}' <<<"$value")
            set_value "$key" "$value"
        done < "${2:?}"
        ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$temp_dir/bin/sysctl"

run_tuner() {
    FAKE_SYSCTL_STATE="$state" \
    V2BX_TUNE_ROOT="$root" \
    V2BX_TUNE_SYSCTL_CMD="$temp_dir/bin/sysctl" \
    V2BX_TUNE_MODPROBE_CMD="v2bx-test-no-modprobe" \
    V2BX_TUNE_MODINFO_CMD="v2bx-test-no-modinfo" \
    V2BX_TUNE_SKIP_ROOT_CHECK=1 \
        bash "$script" "$@"
}

set +e
check_output=$(run_tuner check 2>&1)
check_status=$?
set -e
[[ "$check_status" == "3" && "$check_output" == *"NEEDS APPLY"* ]]

apply_output=$(run_tuner apply)
[[ "$apply_output" == *"APPLIED"* && "$apply_output" == *"BACKUP:"* ]]
config="$root/etc/sysctl.d/99-v2bx-network-tune.conf"
grep -Fxq 'net.core.default_qdisc = fq' "$config"
grep -Fxq 'net.ipv4.tcp_congestion_control = bbr' "$config"
grep -Fxq 'net.ipv4.tcp_ecn = 1' "$config"
grep -Fxq 'net.core.rmem_max = 4194304' "$config"
[[ $(awk -F= '$1 == "net.core.default_qdisc" { print $2 }' "$state") == "fq" ]]
run_tuner check | grep -Fq 'OK: managed TCP/socket runtime defaults match'

run_tuner rollback | grep -Fq 'ROLLED BACK'
[[ ! -e "$config" ]]
[[ $(awk -F= '$1 == "net.core.default_qdisc" { print $2 }' "$state") == "pfifo_fast" ]]
[[ $(awk -F= '$1 == "net.ipv4.tcp_congestion_control" { print $2 }' "$state") == "cubic" ]]

cat > "$root/etc/sysctl.conf" <<'EOF'
net.ipv4.tcp_ecn = 0
EOF
set +e
conflict_output=$(run_tuner check 2>&1)
conflict_status=$?
set -e
[[ "$conflict_status" != "0" && "$conflict_output" == *"later-loading sysctl configuration"* ]]

echo "PASS: network tuning applies RAM-scaled settings, detects conflicts, and rolls back"
