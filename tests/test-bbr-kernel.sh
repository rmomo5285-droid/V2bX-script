#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_dir/bbr-kernel.sh"
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT

state="$temp_dir/sysctl.state"
event_log="$temp_dir/events.log"
fake_bin="$temp_dir/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/sysctl" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-n" && "${2:-}" == "net.ipv4.tcp_available_congestion_control" ]]
cat "${FAKE_BBR_STATE:?}"
EOF
cat > "$fake_bin/systemd-detect-virt" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--container" ]]
[[ -n "${FAKE_CONTAINER:-}" ]] || exit 1
printf '%s\n' "$FAKE_CONTAINER"
EOF
cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
destination=""
while (($# > 0)); do
    case "$1" in
        -o) destination="$2"; shift 2 ;;
        *) shift ;;
    esac
done
cp -- "${FAKE_INSTALLER:?}" "$destination"
EOF
chmod 0755 "$fake_bin"/*

cat > "$temp_dir/installer.sh" <<'EOF'
#!/usr/bin/env bash
printf 'installer-ran\n' >> "${FAKE_EVENT_LOG:?}"
EOF
installer_sha=$(sha256sum "$temp_dir/installer.sh" | awk '{print $1}')

run_helper() {
    PATH="$fake_bin:$PATH" \
    FAKE_BBR_STATE="$state" FAKE_INSTALLER="$temp_dir/installer.sh" \
    FAKE_EVENT_LOG="$event_log" V2BX_BBR_SKIP_ROOT_CHECK=1 \
    V2BX_BBR_SYSCTL_CMD="$fake_bin/sysctl" \
    V2BX_BBR_VIRT_CMD="$fake_bin/systemd-detect-virt" \
    V2BX_BBR_CURL_CMD="$fake_bin/curl" \
    V2BX_BBR_SCRIPT_SHA256="${V2BX_BBR_SCRIPT_SHA256:-$installer_sha}" \
        bash "$script" "$@"
}

printf 'cubic reno\n' > "$state"
set +e
missing_output=$(run_helper check 2>&1)
missing_status=$?
set -e
[[ "$missing_status" == "3" && "$missing_output" == *"MISSING:"* ]]

run_helper install --yes > "$temp_dir/install.log"
grep -Fxq 'installer-ran' "$event_log"
grep -Fq 'REBOOT MAY BE REQUIRED' "$temp_dir/install.log"

printf 'cubic bbr reno\n' > "$state"
run_helper check | grep -Fq 'OK: the running kernel exposes BBR'
before_count=$(wc -l < "$event_log")
run_helper install --yes | grep -Fq 'ALREADY AVAILABLE'
[[ $(wc -l < "$event_log") -eq "$before_count" ]]

printf 'cubic\n' > "$state"
set +e
container_output=$(FAKE_CONTAINER=lxc run_helper install --yes 2>&1)
container_status=$?
set -e
[[ "$container_status" == "4" && "$container_output" == *"cannot install a host kernel"* ]]

set +e
hash_output=$(V2BX_BBR_SCRIPT_SHA256="$(printf '0%.0s' {1..64})" run_helper install --yes 2>&1)
hash_status=$?
set -e
[[ "$hash_status" != "0" && "$hash_output" == *"SHA-256 mismatch"* ]]

echo 'PASS: BBR kernel helper detects support and verifies the optional installer'
