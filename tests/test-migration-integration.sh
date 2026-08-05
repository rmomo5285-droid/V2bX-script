#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
migrator="$repo_dir/migrate-to-rmomo-v2bx.sh"
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for command_name in jq sha256sum zip unzip; do
    command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done

fixture_dir="$temp_dir/fixtures"
release_dir="$temp_dir/release"
fake_bin="$temp_dir/fake-bin"
mkdir -p "$fixture_dir" "$release_dir" "$fake_bin"

cat > "$release_dir/V2bX" <<'EOF'
#!/usr/bin/env bash
# NEW_V2BX_FIXTURE
[[ "${1:-}" == "version" ]] && printf 'new-v2bx v1.2.3\n'
exit 0
EOF
chmod 0755 "$release_dir/V2bX"
(
    cd "$release_dir"
    zip -q "$fixture_dir/V2bX-linux-64.zip" V2bX
)
(
    cd "$fixture_dir"
    sha256sum V2bX-linux-64.zip > V2bX-linux-64.zip.sha256
)

cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
destination=""
url=""
while (($# > 0)); do
    case "$1" in
        -o)
            destination="$2"
            shift 2
            ;;
        http://*|https://*)
            url="$1"
            shift
            ;;
        *) shift ;;
    esac
done
[[ -n "$destination" && -n "$url" ]]
printf 'curl %s\n' "$url" >> "${EVENT_LOG:?}"
case "$url" in
    */V2bX-linux-64.zip.sha256) source_path="${FIXTURE_DIR:?}/V2bX-linux-64.zip.sha256" ;;
    */V2bX-linux-64.zip) source_path="${FIXTURE_DIR:?}/V2bX-linux-64.zip" ;;
    */components.sha256) source_path="${REPO_DIR:?}/components.sha256" ;;
    */V2bX.sh|*/initconfig.sh|*/fix-legacy-hy2-config.sh|*/network-tune.sh|*/resource-guard.sh|*/migrate-to-rmomo-v2bx.sh|*/v2bx.logrotate)
        source_path="${REPO_DIR:?}/${url##*/}"
        ;;
    *)
        echo "unexpected fixture URL: $url" >&2
        exit 1
        ;;
esac
cp -- "$source_path" "$destination"
EOF

cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
command_name="${1:-}"
printf 'systemctl %s\n' "$*" >> "${EVENT_LOG:?}"
case "$command_name" in
    is-active)
        [[ "$(<"${SERVICE_STATE:?}")" == "active" ]] || exit 3
        if [[ "${FAKE_FAIL_NEW:-0}" == "1" ]] &&
           grep -q 'NEW_V2BX_FIXTURE' "${MIGRATE_ROOT:?}/usr/local/V2bX/V2bX"; then
            exit 3
        fi
        ;;
    stop)
        printf 'inactive\n' > "${SERVICE_STATE:?}"
        ;;
    start|restart)
        printf 'active\n' > "${SERVICE_STATE:?}"
        ;;
    daemon-reload) ;;
    *)
        echo "unexpected systemctl command: $*" >&2
        exit 1
        ;;
esac
EOF

cat > "$fake_bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >> "${EVENT_LOG:?}"
exit 0
EOF
chmod 0755 "$fake_bin/curl" "$fake_bin/systemctl" "$fake_bin/sleep"

create_root() {
    local root="$1"
    mkdir -p "$root/usr/local/V2bX" "$root/usr/bin" "$root/etc/V2bX" \
        "$root/etc/systemd/system"
    cat > "$root/usr/local/V2bX/V2bX" <<'EOF'
#!/usr/bin/env bash
# OLD_V2BX_FIXTURE
[[ "${1:-}" == "version" ]] && printf 'old-v2bx\n'
exit 0
EOF
    chmod 0755 "$root/usr/local/V2bX/V2bX"
    cat > "$root/etc/V2bX/config.json" <<'EOF'
{
  "CustomTopLevel": "preserve-me",
  "Log": {"Level": "error", "Output": "/custom/main.log"},
  "Cores": [{"Type": "xray", "Log": {"ErrorPath": "/custom/xray.log"}}],
  "Nodes": [{
    "Core": "xray",
    "NodeID": 7,
    "NodeType": "vless",
    "LimitConfig": {"AbuseGuardConfig": {"BlockSeconds": 42}}
  }]
}
EOF
    cat > "$root/etc/V2bX/hy2config.yaml" <<'EOF'
acl:
  inline:
    - direct(geosite:google)
    # codex-bilibili-cn-exception-begin
    - direct(suffix:acg.tv)
    - direct(suffix:acgvideo.com)
    - direct(suffix:b23.tv)
    - direct(suffix:bili22.cn)
    - direct(suffix:bili2233.cn)
    - direct(suffix:bili23.cn)
    - direct(suffix:bili33.cn)
    - direct(suffix:biliapi.com)
    - direct(suffix:biliapi.net)
    - direct(suffix:bilibili.cc)
    - direct(suffix:bilibili.cn)
    - direct(suffix:bilibili.com)
    - direct(suffix:bilibili.net)
    - direct(suffix:bilibili.tv)
    - direct(suffix:bilicdn1.com)
    - direct(suffix:bilicdn2.com)
    - direct(suffix:bilicdn3.com)
    - direct(suffix:bilicdn4.com)
    - direct(suffix:bilicdn5.com)
    - direct(suffix:biliimg.com)
    - direct(suffix:biliintl.com)
    - direct(suffix:bilivideo.cn)
    - direct(suffix:bilivideo.com)
    - direct(suffix:bilivideo.net)
    - direct(suffix:bstarstatic.com)
    - direct(suffix:bstarstatic.net)
    - direct(suffix:hdslb.com)
    - direct(suffix:hdslb.org)
    - direct(p-bstarstatic.akamaized.net)
    - direct(upos-bstar-mirrorakam.akamaized.net)
    - direct(upos-bstar1-mirrorakam.akamaized.net)
    - direct(upos-hz-mirrorakam.akamaized.net)
    # codex-bilibili-cn-exception-end
    - reject(geosite:cn)
    - reject(geoip:cn)
masquerade:
  type: 404
EOF
    printf 'old-manager\n' > "$root/usr/bin/V2bX"
    printf 'old-service\n' > "$root/etc/systemd/system/V2bX.service"
}

run_migration() {
    local root="$1" event_log="$2" service_state="$3" fail_new="$4"
    PATH="$fake_bin:$PATH" \
    FIXTURE_DIR="$fixture_dir" REPO_DIR="$repo_dir" EVENT_LOG="$event_log" \
    SERVICE_STATE="$service_state" MIGRATE_ROOT="$root" FAKE_FAIL_NEW="$fail_new" \
    V2BX_MIGRATE_ROOT="$root" V2BX_MIGRATE_SKIP_ROOT_CHECK=1 \
    V2BX_SCRIPT_REF=v1.2.3 bash "$migrator" apply --version v1.2.3 \
        --skip-network-tune --skip-resource-guard
}

# Successful switch: everything is staged before stop, then explicit rollback restores it.
success_root="$temp_dir/success-root"
success_events="$temp_dir/success-events"
success_state="$temp_dir/success-state"
create_root "$success_root"
cp -a "$success_root/etc/V2bX/config.json" "$temp_dir/success-config.before"
cp -a "$success_root/etc/V2bX/hy2config.yaml" "$temp_dir/success-hy2.before"
cp -a "$success_root/usr/bin/V2bX" "$temp_dir/success-manager.before"
cp -a "$success_root/etc/systemd/system/V2bX.service" "$temp_dir/success-service.before"
printf 'active\n' > "$success_state"
: > "$success_events"
if ! run_migration "$success_root" "$success_events" "$success_state" 0 > "$temp_dir/success.log" 2>&1; then
    cat "$temp_dir/success.log" >&2
    cat "$success_events" >&2
    fail "successful migration fixture exited nonzero"
fi

grep -q 'NEW_V2BX_FIXTURE' "$success_root/usr/local/V2bX/V2bX" || fail "new binary was not installed"
jq -e '
    .CustomTopLevel == "preserve-me"
    and .Log.Output == "/custom/main.log"
    and .Cores[0].Log.ErrorPath == "/custom/xray.log"
    and .Nodes[0].LimitConfig.AbuseGuardConfig.Enable == true
    and .Nodes[0].LimitConfig.AbuseGuardConfig.BlockSeconds == 42
' "$success_root/etc/V2bX/config.json" >/dev/null || fail "config merge did not preserve custom values"
! grep -q 'codex-bilibili\|geosite:cn\|geoip:cn\|direct(geosite:google)' \
    "$success_root/etc/V2bX/hy2config.yaml" || fail "managed legacy Hy2 ACL was not removed during migration"
grep -q '^masquerade:' "$success_root/etc/V2bX/hy2config.yaml" || fail "migration removed the following Hy2 section"
[[ -s "$success_root/var/lib/v2bx-migrate/latest" ]] || fail "successful migration did not record latest backup"
[[ "$(<"$success_state")" == "active" ]] || fail "successful migration did not leave service active"
last_curl=$(grep -n '^curl ' "$success_events" | tail -n1 | cut -d: -f1)
first_stop=$(grep -n '^systemctl stop ' "$success_events" | head -n1 | cut -d: -f1)
[[ -n "$last_curl" && -n "$first_stop" && "$last_curl" -lt "$first_stop" ]] ||
    fail "service stopped before every release component was staged"

PATH="$fake_bin:$PATH" EVENT_LOG="$success_events" SERVICE_STATE="$success_state" \
MIGRATE_ROOT="$success_root" V2BX_MIGRATE_ROOT="$success_root" \
V2BX_MIGRATE_SKIP_ROOT_CHECK=1 bash "$migrator" rollback > "$temp_dir/rollback.log" 2>&1
grep -q 'OLD_V2BX_FIXTURE' "$success_root/usr/local/V2bX/V2bX" || fail "explicit rollback did not restore binary"
cmp -s "$temp_dir/success-config.before" "$success_root/etc/V2bX/config.json" || fail "explicit rollback changed original config"
cmp -s "$temp_dir/success-hy2.before" "$success_root/etc/V2bX/hy2config.yaml" || fail "explicit rollback changed original Hy2 config"
cmp -s "$temp_dir/success-manager.before" "$success_root/usr/bin/V2bX" || fail "explicit rollback did not restore manager"
cmp -s "$temp_dir/success-service.before" "$success_root/etc/systemd/system/V2bX.service" || fail "explicit rollback did not restore service"
[[ "$(<"$success_state")" == "active" ]] || fail "explicit rollback did not restore active state"
[[ ! -e "$success_root/usr/local/share/v2bx/initconfig.sh" ]] || fail "explicit rollback left a newly installed helper"

# Failed health check: the ERR transaction handler must restore byte-identical originals.
failure_root="$temp_dir/failure-root"
failure_events="$temp_dir/failure-events"
failure_state="$temp_dir/failure-state"
create_root "$failure_root"
cp -a "$failure_root/etc/V2bX/config.json" "$temp_dir/failure-config.before"
cp -a "$failure_root/etc/V2bX/hy2config.yaml" "$temp_dir/failure-hy2.before"
cp -a "$failure_root/usr/bin/V2bX" "$temp_dir/failure-manager.before"
printf 'active\n' > "$failure_state"
: > "$failure_events"
set +e
run_migration "$failure_root" "$failure_events" "$failure_state" 1 > "$temp_dir/failure.log" 2>&1
failure_status=$?
set -e
[[ "$failure_status" -ne 0 ]] || fail "failed health check unexpectedly succeeded"
grep -q 'restoring the previous V2bX' "$temp_dir/failure.log" || fail "automatic rollback was not reported"
grep -q 'OLD_V2BX_FIXTURE' "$failure_root/usr/local/V2bX/V2bX" || fail "automatic rollback did not restore binary"
cmp -s "$temp_dir/failure-config.before" "$failure_root/etc/V2bX/config.json" || fail "automatic rollback changed original config"
cmp -s "$temp_dir/failure-hy2.before" "$failure_root/etc/V2bX/hy2config.yaml" || fail "automatic rollback changed original Hy2 config"
cmp -s "$temp_dir/failure-manager.before" "$failure_root/usr/bin/V2bX" || fail "automatic rollback did not restore manager"
[[ "$(<"$failure_state")" == "active" ]] || fail "automatic rollback did not restore active state"
[[ ! -e "$failure_root/var/lib/v2bx-migrate/latest" ]] || fail "failed migration was recorded as latest"
[[ ! -e "$failure_root/usr/local/share/v2bx/initconfig.sh" ]] || fail "automatic rollback left a newly installed helper"
find "$failure_root/var/lib/v2bx-migrate/backups" -mindepth 1 -maxdepth 1 -type d | grep -q . ||
    fail "failed migration did not retain its recovery backup"

echo "PASS: migration stages before stop and supports explicit and automatic rollback"
