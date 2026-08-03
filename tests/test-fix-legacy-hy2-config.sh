#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/fix-legacy-hy2-config.sh"
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_fix() {
    V2BX_FIX_SKIP_ROOT_CHECK=1 bash "$script" "$@"
}

base="$temp_dir/base.yaml"
cat > "$base" <<'EOF'
quic:
  maxIncomingStreams: 1024
resolver:
  type: system
acl:
  inline:
    - direct(geosite:google)
    - reject(geosite:cn)
    - reject(geoip:cn)
masquerade:
  type: 404
EOF

set +e
run_fix check --config "$base" > "$temp_dir/check.out" 2>&1
status=$?
set -e
[[ "$status" -eq 3 ]] || fail "check returned $status instead of 3"
grep -q 'NEEDS APPLY' "$temp_dir/check.out" || fail "check did not report the exact block"

run_fix apply --skip-restart --config "$base" > "$temp_dir/apply.out"
! grep -q 'geosite:cn\|geoip:cn\|direct(geosite:google)' "$base" || fail "legacy rules remain"
! grep -q '^acl:' "$base" || fail "empty acl section remains"
grep -q '^masquerade:' "$base" || fail "following YAML section was removed"
backup_count=$(find "$temp_dir" -maxdepth 1 -name 'base.yaml.before-cn-acl-fix.*' | wc -l)
[[ "$backup_count" -eq 1 ]] || fail "expected one backup, got $backup_count"

custom="$temp_dir/custom.yaml"
cat > "$custom" <<'EOF'
acl:
  inline:
    - reject(all, tcp/25)
    - direct(geosite:google)
    - reject(geosite:cn)
    - reject(geoip:cn)
masquerade:
  type: 404
EOF
run_fix apply --skip-restart --config "$custom" >/dev/null
grep -q '^acl:' "$custom" || fail "custom acl section was removed"
grep -q 'reject(all, tcp/25)' "$custom" || fail "custom rule was removed"
! grep -q 'geosite:cn\|geoip:cn\|direct(geosite:google)' "$custom" || fail "legacy block remains in custom acl"

partial="$temp_dir/partial.yaml"
cat > "$partial" <<'EOF'
acl:
  inline:
    - reject(geosite:cn)
masquerade:
  type: 404
EOF
partial_before=$(sha256sum "$partial" | awk '{print $1}')
set +e
run_fix apply --skip-restart --config "$partial" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "partial block was accepted"
partial_after=$(sha256sum "$partial" | awk '{print $1}')
[[ "$partial_before" == "$partial_after" ]] || fail "partial config changed"

echo "PASS: legacy Hy2 ACL fixer is conservative, repeatable, and backed up"
