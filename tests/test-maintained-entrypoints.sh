#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

! grep -Eq '^install_V2bX\(\)[[:space:]]*\{' "$repo_dir/install.sh" ||
    fail "legacy unchecked install_V2bX implementation remains"
grep -Eq '^install_V2bX_safe\(\)[[:space:]]*\{' "$repo_dir/install.sh" ||
    fail "safe installer entrypoint is missing"
[[ $(grep -Ec '^generate_config_file\(\)[[:space:]]*\{' "$repo_dir/initconfig.sh") -eq 1 ]] ||
    fail "initconfig.sh must own exactly one config generator"
! grep -Eq '^generate_config_file\(\)[[:space:]]*\{' "$repo_dir/V2bX.sh" ||
    fail "duplicate config generator remains in V2bX.sh"
grep -q 'run_config_generator' "$repo_dir/V2bX.sh" ||
    fail "manager no longer delegates config generation"
grep -Eq '^skip_resource_guard=1$' "$repo_dir/migrate-to-rmomo-v2bx.sh" ||
    fail "migration must keep the optional memory guard disabled by default"
grep -q -- '--apply-resource-guard' "$repo_dir/migrate-to-rmomo-v2bx.sh" ||
    fail "migration has no explicit memory-guard opt-in"
grep -q 'V2BX_ENABLE_RESOURCE_GUARD' "$repo_dir/install.sh" ||
    fail "installer has no explicit memory-guard opt-in"

echo "PASS: installer and config generator have single maintained implementations"
