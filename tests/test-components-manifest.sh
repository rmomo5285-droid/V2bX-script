#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
bash "$repo_dir/scripts/components-manifest.sh" check >/dev/null

expected=(
    V2bX.sh
    initconfig.sh
    network-tune.sh
    resource-guard.sh
    fix-legacy-hy2-config.sh
    migrate-to-rmomo-v2bx.sh
    V2bX.service
    v2bx.logrotate
)

[[ $(wc -l < "$repo_dir/components.sha256") -eq ${#expected[@]} ]]
for component in "${expected[@]}"; do
    [[ $(awk -v name="$component" '$2 == name || $2 == "*" name { count++ } END { print count + 0 }' \
        "$repo_dir/components.sha256") -eq 1 ]] || {
        echo "FAIL: manifest entry is missing or duplicated: $component" >&2
        exit 1
    }
done

echo "PASS: component manifest is complete and current"
