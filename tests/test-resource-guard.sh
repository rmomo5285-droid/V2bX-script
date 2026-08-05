#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_dir/resource-guard.sh"
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is required"; exit 0; }

root="$temp_dir/root"
mkdir -p "$root/etc/V2bX" "$root/proc" "$temp_dir/bin"
cat > "$root/proc/meminfo" <<'EOF'
MemTotal:         934912 kB
MemFree:          100000 kB
EOF
cat > "$root/etc/V2bX/config.json" <<'EOF'
{
  "Cores": [{"Type":"hysteria2","Name":"native-hy2"}],
  "Nodes": [{"CoreName":"native-hy2","NodeType":"hysteria2"}]
}
EOF
cat > "$temp_dir/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  is-active) exit 0 ;;
  daemon-reload|restart) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$temp_dir/bin/systemctl"

run_guard() {
    V2BX_RESOURCE_ROOT="$root" \
    V2BX_RESOURCE_SYSTEMCTL_CMD="$temp_dir/bin/systemctl" \
    V2BX_RESOURCE_SKIP_ROOT_CHECK=1 \
    V2BX_RESOURCE_HEALTH_CONSECUTIVE=1 \
    V2BX_RESOURCE_HEALTH_ATTEMPTS=1 \
        bash "$script" "$@"
}

set +e
check_output=$(run_guard check 2>&1)
check_status=$?
set -e
[[ "$check_status" == "3" && "$check_output" == *"NEEDS APPLY"* ]]

apply_output=$(run_guard apply)
[[ "$apply_output" == *"APPLIED"* ]]
dropin="$root/etc/systemd/system/V2bX.service.d/20-resource-guard.conf"
grep -Fxq 'MemoryHigh=456M' "$dropin"
grep -Fxq 'MemoryMax=684M' "$dropin"
grep -Fxq 'OOMPolicy=stop' "$dropin"

run_guard check | grep -Fq 'OK: resource guard already matches'
run_guard rollback | grep -Fq 'ROLLED BACK'
[[ ! -e "$dropin" ]]

cat > "$root/etc/V2bX/config.json" <<'EOF'
{
  "Cores": [{"Type":"sing"}],
  "Nodes": [{"Core":"sing","NodeType":"hysteria2"}]
}
EOF
run_guard apply | grep -Fq 'NOT APPLICABLE: not-native-hy2-only'
[[ ! -e "$dropin" ]]

cat > "$root/proc/meminfo" <<'EOF'
MemTotal:        4194304 kB
EOF
run_guard apply | grep -Fq 'NOT APPLICABLE: memory-above-1280MiB'
[[ ! -e "$dropin" ]]

echo "PASS: resource guard is scoped to low-memory native Hy2 and rolls back"
