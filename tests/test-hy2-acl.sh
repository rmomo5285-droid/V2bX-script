#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repair_script="$repo_root/repair-hy2-cn-route.sh"
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_repair() {
    V2BX_REPAIR_SKIP_ROOT_CHECK=1 bash "$repair_script" "$@"
}

write_base_config() {
    local path="$1"
    cat > "$path" <<'EOF'
resolver:
  type: system
acl:
  inline:
    - direct(suffix:bilibili.com) # administrator-owned duplicate must remain
    - direct(geosite:google)
    - reject(all, tcp/25)
    - reject(geosite:cn)
    - reject(geoip:cn)
masquerade:
  type: 404
EOF
}

bilibili_rules=(
    'direct(suffix:acg.tv)'
    'direct(suffix:acgvideo.com)'
    'direct(suffix:b23.tv)'
    'direct(suffix:bili22.cn)'
    'direct(suffix:bili2233.cn)'
    'direct(suffix:bili23.cn)'
    'direct(suffix:bili33.cn)'
    'direct(suffix:biliapi.com)'
    'direct(suffix:biliapi.net)'
    'direct(suffix:bilibili.cc)'
    'direct(suffix:bilibili.cn)'
    'direct(suffix:bilibili.com)'
    'direct(suffix:bilibili.net)'
    'direct(suffix:bilibili.tv)'
    'direct(suffix:bilicdn1.com)'
    'direct(suffix:bilicdn2.com)'
    'direct(suffix:bilicdn3.com)'
    'direct(suffix:bilicdn4.com)'
    'direct(suffix:bilicdn5.com)'
    'direct(suffix:biliimg.com)'
    'direct(suffix:biliintl.com)'
    'direct(suffix:bilivideo.cn)'
    'direct(suffix:bilivideo.com)'
    'direct(suffix:bilivideo.net)'
    'direct(suffix:bstarstatic.com)'
    'direct(suffix:bstarstatic.net)'
    'direct(suffix:hdslb.com)'
    'direct(suffix:hdslb.org)'
    'direct(p-bstarstatic.akamaized.net)'
    'direct(upos-bstar-mirrorakam.akamaized.net)'
    'direct(upos-bstar1-mirrorakam.akamaized.net)'
    'direct(upos-hz-mirrorakam.akamaized.net)'
)

validate_repaired_config() {
    local path="$1" begin_line end_line geosite_line geoip_line rule count

    [[ "$(grep -Ec '^[[:space:]]*-[[:space:]]*reject\(geosite:cn\)[[:space:]]*$' "$path")" -eq 1 ]] ||
        fail "geosite:cn reject was not preserved exactly once"
    [[ "$(grep -Ec '^[[:space:]]*-[[:space:]]*reject\(geoip:cn\)[[:space:]]*$' "$path")" -eq 1 ]] ||
        fail "geoip:cn reject was not preserved exactly once"

    begin_line=$(grep -En '^[[:space:]]*#[[:space:]]*codex-bilibili-cn-exception-begin[[:space:]]*$' "$path" | cut -d: -f1)
    end_line=$(grep -En '^[[:space:]]*#[[:space:]]*codex-bilibili-cn-exception-end[[:space:]]*$' "$path" | cut -d: -f1)
    geosite_line=$(grep -En '^[[:space:]]*-[[:space:]]*reject\(geosite:cn\)[[:space:]]*$' "$path" | cut -d: -f1)
    geoip_line=$(grep -En '^[[:space:]]*-[[:space:]]*reject\(geoip:cn\)[[:space:]]*$' "$path" | cut -d: -f1)
    ((begin_line < end_line && end_line < geosite_line && geoip_line == geosite_line + 1)) ||
        fail "managed block and China reject pair are not ordered correctly"

    for rule in "${bilibili_rules[@]}"; do
        count=$(awk -v start="$begin_line" -v end="$end_line" -v expected="$rule" '
            NR > start && NR < end {
                line = $0
                sub(/\r$/, "", line)
                sub(/^[ \t]*-[ \t]*/, "", line)
                sub(/[ \t]+$/, "", line)
                if (line == expected) count++
            }
            END { print count + 0 }
        ' "$path")
        [[ "$count" -eq 1 ]] || fail "managed block is missing or duplicates $rule"
    done

    [[ "$(sed -n "$((begin_line + 1)),$((end_line - 1))p" "$path" | wc -l)" -eq "${#bilibili_rules[@]}" ]] ||
        fail "managed block contains an unexpected rule"
    grep -Fq -- '- direct(suffix:bilibili.com) # administrator-owned duplicate must remain' "$path" ||
        fail "an administrator-owned Bilibili rule was removed"
    grep -Fq -- '- reject(all, tcp/25)' "$path" || fail "custom anti-abuse ACL was removed"
    ! grep -Eq -- 'direct\(suffix:(qq|baidu)\.com\)' "$path" || fail "QQ or Baidu was unexpectedly allowed"
}

assert_rejected_unchanged() {
    local label="$1" path="$2" status
    cp -a -- "$path" "${path}.before"
    set +e
    run_repair --apply --skip-restart --config "$path" >"$temp_dir/$label.log" 2>&1
    status=$?
    set -e
    [[ "$status" -eq 1 ]] || fail "$label should be rejected with status 1, got $status"
    cmp -s -- "${path}.before" "$path" || fail "$label modified the config"
    if compgen -G "${path}.bak-bilibili-*" >/dev/null; then
        fail "$label created a backup despite refusing before mutation"
    fi
}

bash -n "$repair_script"

# Check is read-only and apply is complete, conservative, and idempotent.
base_config="$temp_dir/hy2config.yaml"
write_base_config "$base_config"
cp -a -- "$base_config" "$base_config.before-check"
set +e
run_repair --check --config "$base_config" >"$temp_dir/check.log" 2>&1
check_status=$?
set -e
[[ "$check_status" -eq 3 ]] || fail "check should return 3 when repair is needed, got $check_status"
cmp -s -- "$base_config.before-check" "$base_config" || fail "check mode modified the config"

run_repair --apply --skip-restart --config "$base_config" >"$temp_dir/apply.log" 2>&1
validate_repaired_config "$base_config"
backup_count=$(find "$temp_dir" -maxdepth 1 -type f -name 'hy2config.yaml.bak-bilibili-*' | wc -l)
[[ "$backup_count" -eq 1 ]] || fail "apply should create exactly one backup"

cp -a -- "$base_config" "$base_config.after-apply"
run_repair --check --config "$base_config" >"$temp_dir/idempotent-check.log" 2>&1
cmp -s -- "$base_config.after-apply" "$base_config" || fail "idempotent check changed the config"
run_repair --apply --skip-restart --config "$base_config" >"$temp_dir/idempotent-apply.log" 2>&1
cmp -s -- "$base_config.after-apply" "$base_config" || fail "idempotent apply changed the config"
backup_count_after=$(find "$temp_dir" -maxdepth 1 -type f -name 'hy2config.yaml.bak-bilibili-*' | wc -l)
[[ "$backup_count_after" -eq "$backup_count" ]] || fail "idempotent apply created another backup"

# A config with no China reject pair stays byte-identical and is never broadened.
no_pair="$temp_dir/no-pair.yaml"
cat > "$no_pair" <<'EOF'
acl:
  inline:
    - direct(geosite:google)
EOF
cp -a -- "$no_pair" "$no_pair.before"
run_repair --apply --skip-restart --config "$no_pair" >"$temp_dir/no-pair.log" 2>&1
cmp -s -- "$no_pair.before" "$no_pair" || fail "pair-absent config was modified"

# Customized, incomplete, misplaced, or damaged fingerprints are refused.
single_rule="$temp_dir/single-rule.yaml"
cat > "$single_rule" <<'EOF'
acl:
  inline:
    - reject(geosite:cn)
EOF
assert_rejected_unchanged "single-rule" "$single_rule"

duplicate_rule="$temp_dir/duplicate-rule.yaml"
cat > "$duplicate_rule" <<'EOF'
acl:
  inline:
    - reject(geosite:cn)
    - reject(geoip:cn)
    - reject(geosite:cn)
EOF
assert_rejected_unchanged "duplicate-rule" "$duplicate_rule"

nonconsecutive_pair="$temp_dir/nonconsecutive-pair.yaml"
cat > "$nonconsecutive_pair" <<'EOF'
acl:
  inline:
    - reject(geosite:cn)
    - reject(all, tcp/25)
    - reject(geoip:cn)
EOF
assert_rejected_unchanged "nonconsecutive-pair" "$nonconsecutive_pair"

sibling_pair="$temp_dir/sibling-pair.yaml"
cat > "$sibling_pair" <<'EOF'
acl:
  inline:
    - direct(geosite:google)
  unrelated:
    - reject(geosite:cn)
    - reject(geoip:cn)
EOF
assert_rejected_unchanged "sibling-pair" "$sibling_pair"

partial_marker="$temp_dir/partial-marker.yaml"
cat > "$partial_marker" <<'EOF'
acl:
  inline:
    # codex-bilibili-cn-exception-begin
    - direct(suffix:bilibili.com)
    - reject(geosite:cn)
    - reject(geoip:cn)
EOF
assert_rejected_unchanged "partial-marker" "$partial_marker"

# Exercise systemd state preservation and failure rollback with a deterministic stub.
fake_bin="$temp_dir/fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -u
command_name="${1:-}"
case "$command_name" in
    cat)
        [[ "${FAKE_UNIT_MISSING:-0}" != "1" ]]
        ;;
    is-active)
        [[ "${FAKE_SERVICE_STATE:-active}" == "active" ]]
        ;;
    restart)
        printf 'restart\n' >> "${FAKE_SYSTEMCTL_LOG:?}"
        [[ "${FAKE_RESTART_MODE:-ok}" != "fail" ]]
        ;;
    show)
        case " $* " in
            *' NRestarts '*)
                if [[ "${FAKE_NRESTARTS_MODE:-stable}" == "grow" ]]; then
                    if [[ -f "${FAKE_NRESTARTS_FILE:?}" ]]; then
                        cat "${FAKE_NRESTARTS_FILE}"
                    else
                        printf '0\n'
                        printf '1\n' > "${FAKE_NRESTARTS_FILE}"
                    fi
                else
                    printf '0\n'
                fi
                ;;
            *' ActiveState '*) printf '%s\n' "${FAKE_ACTIVE_STATE:-active}" ;;
            *' SubState '*) printf '%s\n' "${FAKE_SUB_STATE:-running}" ;;
            *' Result '*) printf '%s\n' "${FAKE_RESULT:-success}" ;;
            *' ExecMainStatus '*) printf '%s\n' "${FAKE_EXEC_STATUS:-0}" ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$fake_bin/sleep" "$fake_bin/systemctl"

active_config="$temp_dir/active.yaml"
active_log="$temp_dir/active-systemctl.log"
write_base_config "$active_config"
FAKE_SYSTEMCTL_LOG="$active_log" PATH="$fake_bin:$PATH" V2BX_REPAIR_SKIP_ROOT_CHECK=1 \
    bash "$repair_script" --apply --config "$active_config" >"$temp_dir/active.log" 2>&1
validate_repaired_config "$active_config"
[[ "$(grep -c '^restart$' "$active_log")" -eq 1 ]] || fail "active service was not restarted exactly once"

inactive_config="$temp_dir/inactive.yaml"
inactive_log="$temp_dir/inactive-systemctl.log"
write_base_config "$inactive_config"
FAKE_SERVICE_STATE=inactive FAKE_SYSTEMCTL_LOG="$inactive_log" PATH="$fake_bin:$PATH" \
    V2BX_REPAIR_SKIP_ROOT_CHECK=1 bash "$repair_script" --apply --config "$inactive_config" \
    >"$temp_dir/inactive.log" 2>&1
validate_repaired_config "$inactive_config"
[[ ! -e "$inactive_log" ]] || fail "inactive service was unexpectedly restarted"

restart_failure="$temp_dir/restart-failure.yaml"
restart_failure_log="$temp_dir/restart-failure-systemctl.log"
write_base_config "$restart_failure"
cp -a -- "$restart_failure" "$restart_failure.before"
set +e
FAKE_RESTART_MODE=fail FAKE_SYSTEMCTL_LOG="$restart_failure_log" PATH="$fake_bin:$PATH" \
    V2BX_REPAIR_SKIP_ROOT_CHECK=1 bash "$repair_script" --apply --config "$restart_failure" \
    >"$temp_dir/restart-failure.log" 2>&1
restart_failure_status=$?
set -e
[[ "$restart_failure_status" -ne 0 ]] || fail "restart failure should fail the repair"
cmp -s -- "$restart_failure.before" "$restart_failure" || fail "restart failure did not roll back byte-for-byte"

restart_loop="$temp_dir/restart-loop.yaml"
restart_loop_log="$temp_dir/restart-loop-systemctl.log"
restart_counter="$temp_dir/restart-counter"
write_base_config "$restart_loop"
cp -a -- "$restart_loop" "$restart_loop.before"
set +e
FAKE_NRESTARTS_MODE=grow FAKE_NRESTARTS_FILE="$restart_counter" \
    FAKE_SYSTEMCTL_LOG="$restart_loop_log" PATH="$fake_bin:$PATH" V2BX_REPAIR_SKIP_ROOT_CHECK=1 \
    bash "$repair_script" --apply --config "$restart_loop" >"$temp_dir/restart-loop.log" 2>&1
restart_loop_status=$?
set -e
[[ "$restart_loop_status" -ne 0 ]] || fail "NRestarts growth should fail the repair"
cmp -s -- "$restart_loop.before" "$restart_loop" || fail "restart-loop detection did not roll back byte-for-byte"

# A held lock refuses mutation before any backup or service operation.
lock_bin="$temp_dir/lock-bin"
mkdir -p "$lock_bin"
cat > "$lock_bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$lock_bin/flock"
locked_config="$temp_dir/locked.yaml"
write_base_config "$locked_config"
cp -a -- "$locked_config" "$locked_config.before"
set +e
PATH="$lock_bin:$PATH" run_repair --apply --skip-restart --config "$locked_config" >"$temp_dir/locked.log" 2>&1
locked_status=$?
set -e
[[ "$locked_status" -eq 1 ]] || fail "held lock should return status 1"
cmp -s -- "$locked_config.before" "$locked_config" || fail "held lock modified the config"

# Quoted paths and metadata preservation are part of the fleet-safe contract.
space_dir="$temp_dir/path with spaces"
mkdir -p "$space_dir"
space_config="$space_dir/hy2 config.yaml"
write_base_config "$space_config"
chmod 640 "$space_config"
mode_before=$(stat -c '%a' "$space_config")
run_repair --apply --skip-restart --config "$space_config" >"$temp_dir/space-path.log" 2>&1
mode_after=$(stat -c '%a' "$space_config")
[[ "$mode_after" == "$mode_before" ]] || fail "config mode changed from $mode_before to $mode_after"
validate_repaired_config "$space_config"

echo "PASS: Hy2 Bilibili exception repair is conservative, idempotent, and rollback-safe."
