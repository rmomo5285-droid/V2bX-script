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

managed="$temp_dir/managed.yaml"
cat > "$managed" <<'EOF'
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
set +e
run_fix check --config "$managed" > "$temp_dir/managed-check.out" 2>&1
status=$?
set -e
[[ "$status" -eq 3 ]] || fail "managed compatibility block check returned $status instead of 3"
grep -q 'managed Bilibili compatibility ACL' "$temp_dir/managed-check.out" || fail "managed block was not identified"
run_fix apply --skip-restart --config "$managed" >/dev/null
! grep -q 'codex-bilibili\|geosite:cn\|geoip:cn\|direct(geosite:google)' "$managed" || fail "managed compatibility ACL remains"
! grep -q '^acl:' "$managed" || fail "empty managed acl section remains"
grep -q '^masquerade:' "$managed" || fail "managed layout removed the following YAML section"

tampered="$temp_dir/tampered.yaml"
cp "$temp_dir/managed.yaml.before-cn-acl-fix."* "$tampered"
sed -i 's/direct(suffix:b23.tv)/direct(suffix:example.com)/' "$tampered"
tampered_before=$(sha256sum "$tampered" | awk '{print $1}')
set +e
run_fix apply --skip-restart --config "$tampered" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "tampered managed block was accepted"
tampered_after=$(sha256sum "$tampered" | awk '{print $1}')
[[ "$tampered_before" == "$tampered_after" ]] || fail "tampered managed config changed"

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
