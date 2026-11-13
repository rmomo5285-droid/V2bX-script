#!/usr/bin/env bash
# Independent, noninteractive entrypoint. Never run the config generator.
set -Eeuo pipefail
umask 077

: "${V2BX_NODE_ID:?Set V2BX_NODE_ID to the new panel Hy2 node ID}"
: "${V2BX_DOMAIN:?Set V2BX_DOMAIN to the certificate domain}"
: "${V2BX_EMAIL:?Set V2BX_EMAIL to the ACME contact email}"
export V2BX_APPEND_NONINTERACTIVE=1
export V2BX_TEMPLATE_INDEX="${V2BX_TEMPLATE_INDEX:-1}"
export V2BX_RESTART="${V2BX_RESTART:-1}"

# A checked-out copy uses its matching helper. curl | bash downloads and verifies
# the helper from the same explicitly selectable revision. No installed manager
# upgrade or replacement is required.
helper_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    helper_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fi
if [[ -n "$helper_dir" && -f "$helper_dir/initconfig.sh" ]]; then
    source "$helper_dir/initconfig.sh"
else
    command -v curl >/dev/null || { echo 'ERROR: curl is required' >&2; exit 1; }
    tmp_dir=$(mktemp -d)
    trap 'rm -rf -- "$tmp_dir"' EXIT
    revision="${V2BX_SCRIPT_REF:-feat/add-node-v013}"
    base_url="https://raw.githubusercontent.com/rmomo5285-droid/V2bX-script/$revision"
    for component in initconfig.sh components.sha256; do
        curl --proto '=https' --tlsv1.2 -fLsS --retry 3 -o "$tmp_dir/$component" "$base_url/$component"
    done
    digest=$(awk '$2 == "initconfig.sh" { print $1 }' "$tmp_dir/components.sha256")
    [[ "$digest" =~ ^[a-f0-9]{64}$ ]] || { echo 'ERROR: invalid helper checksum manifest' >&2; exit 1; }
    printf '%s  %s\n' "$digest" "$tmp_dir/initconfig.sh" | sha256sum -c - >/dev/null
    bash -n "$tmp_dir/initconfig.sh"
    source "$tmp_dir/initconfig.sh"
fi
declare -F append_node_config >/dev/null || { echo 'ERROR: matching append helper required' >&2; exit 1; }
append_node_config "${V2BX_CONFIG_PATH:-/etc/V2bX/config.json}" --hy2-http </dev/null
