#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_dir/initconfig.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_protocol() {
    local core="$1" choice="$2" expected="$3" actual
    actual=$(protocol_from_choice "$core" "$choice") || fail "$core choice $choice was rejected"
    [[ "$actual" == "$expected" ]] || fail "$core choice $choice produced $actual"
}

assert_protocol xray 1 shadowsocks
assert_protocol xray 2 vless
assert_protocol xray 3 vmess
assert_protocol xray 6 trojan
assert_protocol sing 1 shadowsocks
assert_protocol sing 2 vless
assert_protocol sing 3 vmess
assert_protocol sing 4 hysteria
assert_protocol sing 5 hysteria2
assert_protocol sing 6 trojan
assert_protocol sing 7 tuic
assert_protocol sing 8 anytls
! protocol_from_choice xray 4 >/dev/null 2>&1 || fail "xray accepted hysteria"
! protocol_from_choice xray 5 >/dev/null 2>&1 || fail "xray accepted hysteria2"
! protocol_from_choice xray 7 >/dev/null 2>&1 || fail "xray accepted tuic"
! protocol_from_choice xray 8 >/dev/null 2>&1 || fail "xray accepted anytls"

command -v jq >/dev/null 2>&1 || fail "jq is required"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

extract_heredoc() {
    local destination="$1" output="$2"
    awk -v marker="    cat <<EOF > $destination" '
        $0 == marker { copying = 1; next }
        copying && $0 == "EOF" { exit }
        copying { print }
    ' "$repo_dir/initconfig.sh" > "$output"
    [[ -s "$output" ]] || fail "could not extract $destination"
}

extract_heredoc /etc/V2bX/route.json "$tmp_dir/route.json"
extract_heredoc /etc/V2bX/sing_origin.json "$tmp_dir/sing.json.in"
sed 's/\$dnsstrategy/prefer_ipv4/g' "$tmp_dir/sing.json.in" > "$tmp_dir/sing.json"
extract_heredoc /etc/V2bX/hy2config.yaml "$tmp_dir/hy2config.yaml"

jq -e '
    .domainStrategy == "IPIfNonMatch"
    and (.rules | length == 5)
    and ([.rules[].type] | all(. == "field"))
    and (.rules[0] | .outboundTag == "IPv4_out" and .ip == ["192.0.0.9/32", "192.0.0.10/32"])
    and (.rules[1] | .outboundTag == "block" and (.ip | index("192.0.0.0/24")) != null)
    and (.rules[2] | .network == "tcp" and .port == "25")
    and (.rules[3].protocol == ["bittorrent"])
    and (.rules[4] | .outboundTag == "IPv4_out" and .network == "udp,tcp")
    and ([.rules[] | has("domain")] | any | not)
' "$tmp_dir/route.json" >/dev/null || fail "Xray route is invalid"

jq -e '
    .outbounds[0].type == "direct"
    and .outbounds[1].type == "block"
    and (.route.rules | length == 6)
    and (.route.rules[0] | .outbound == "direct" and .ip_cidr == ["192.0.0.9/32", "192.0.0.10/32"])
    and (.route.rules[1] | .ip_is_private == true and .outbound == "block")
    and (.route.rules[2] | .outbound == "block" and (.ip_cidr | index("192.0.0.0/24")) != null)
    and (.route.rules[3] | .network == "tcp" and .port == [25])
    and (.route.rules[4].protocol == ["bittorrent"])
    and (.route.rules[5] | .outbound == "direct" and .network == ["udp", "tcp"])
    and ([.route.rules[] | has("domain_regex")] | any | not)
' "$tmp_dir/sing.json" >/dev/null || fail "sing-box route is invalid"

grep -q '^  maxStreamReceiveWindow: 4194304$' "$tmp_dir/hy2config.yaml" || fail "Hy2 stream window changed"
grep -q '^  maxConnReceiveWindow: 16777216$' "$tmp_dir/hy2config.yaml" || fail "Hy2 connection window changed"
grep -q '^  maxIncomingStreams: 256$' "$tmp_dir/hy2config.yaml" || fail "Hy2 stream cap changed"
! grep -Eq '^[[:space:]]*acl:|reject\((geosite|geoip):cn\)' "$tmp_dir/hy2config.yaml" || fail "legacy Hy2 China ACL returned"

[[ $(grep -c '"ReportMinTraffic": 0' "$repo_dir/initconfig.sh") -eq 3 ]] || fail "ReportMinTraffic is not emitted for all cores"
! grep -q 'MinReportTraffic' "$repo_dir/initconfig.sh" || fail "obsolete MinReportTraffic remains"
[[ $(grep -c '"AbuseGuardConfig"' "$repo_dir/initconfig.sh") -eq 1 ]] || fail "abuse guard template changed unexpectedly"
grep -q '\\"Output\\": \\"/var/log/V2bX/sing.log\\"' "$repo_dir/initconfig.sh" || fail "sing-box bounded log output is absent"
grep -q '\\"Output\\": \\"/var/log/V2bX/hy2.log\\"' "$repo_dir/initconfig.sh" || fail "native Hy2 bounded log output is absent"
grep -q '"Output": "/var/log/V2bX/v2bx.log"' "$repo_dir/initconfig.sh" || fail "main bounded log output is absent"

echo "PASS: config generator protocol matrix and route templates"
