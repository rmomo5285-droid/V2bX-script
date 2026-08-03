#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$repo_dir/components.sha256"
mode="${1:-check}"
components=(
    V2bX.sh
    initconfig.sh
    network-tune.sh
    resource-guard.sh
    fix-legacy-hy2-config.sh
    migrate-to-rmomo-v2bx.sh
    V2bX.service
    v2bx.logrotate
)

generate() {
    (cd "$repo_dir" && sha256sum "${components[@]}")
}

case "$mode" in
    check)
        [[ -f "$manifest" ]] || {
            echo "ERROR: components.sha256 is missing" >&2
            exit 1
        }
        expected=$(mktemp)
        trap 'rm -f -- "$expected"' EXIT
        generate > "$expected"
        if ! cmp -s -- "$expected" "$manifest"; then
            echo "ERROR: components.sha256 is stale" >&2
            diff -u -- "$manifest" "$expected" || true
            exit 1
        fi
        (cd "$repo_dir" && sha256sum -c components.sha256)
        ;;
    write)
        staged=$(mktemp "$repo_dir/.components.sha256.XXXXXX")
        trap 'rm -f -- "$staged"' EXIT
        generate > "$staged"
        mv -f -- "$staged" "$manifest"
        trap - EXIT
        ;;
    *)
        echo "Usage: scripts/components-manifest.sh [check|write]" >&2
        exit 2
        ;;
esac
