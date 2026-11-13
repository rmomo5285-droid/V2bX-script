#!/usr/bin/env bash
set -Eeuo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir "$tmp_dir/bin"
export PATH="$tmp_dir/bin:$PATH"
cat > "$tmp_dir/bin/ss" <<'EOF'
#!/usr/bin/env bash
case "${TEST_SS:-}" in
  occupied) echo 'LISTEN 0 4096 0.0.0.0:80 0.0.0.0:*' ;;
  failed) exit 1 ;;
esac
EOF
cat > "$tmp_dir/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == restart ]]; then
    echo restart >> "$TEST_RESTART_LOG"
    if [[ "${TEST_SERVICE:-}" == fail-restart && ! -f "$TEST_RESTART_LOG.failed" ]]; then
        touch "$TEST_RESTART_LOG.failed"
        exit 1
    fi
    if [[ "${TEST_SERVICE:-}" == concurrent ]]; then
        printf '{"external":true}\n' > "$V2BX_CONFIG_PATH"
        exit 1
    fi
fi
if [[ "$1" == is-active && "${TEST_SERVICE:-}" == stopped ]]; then exit 1; fi
if [[ "$1" == is-active && "${TEST_SERVICE:-}" == dies && -f "$TEST_RESTART_LOG" ]]; then exit 1; fi
exit 0
EOF
cat > "$tmp_dir/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$tmp_dir/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
printf 'startup-certificate-error config-nodes=%s dummy-private-key\n' "$(jq '.Nodes | length' "$V2BX_CONFIG_PATH")"
EOF
chmod +x "$tmp_dir/bin/"*
export V2BX_APPEND_NONINTERACTIVE=1 V2BX_TEMPLATE_INDEX=1 V2BX_NODE_ID=202 V2BX_RESTART=0
export V2BX_DOMAIN=hy2.example.com V2BX_EMAIL=admin@example.com
export V2BX_CONFIG_PATH="$tmp_dir/config.json" TEST_RESTART_LOG="$tmp_dir/restarts"

reset_config() {
    unset TEST_SS TEST_SERVICE
    export V2BX_NODE_ID=202 V2BX_RESTART=0 V2BX_DOMAIN=hy2.example.com V2BX_TEMPLATE_INDEX=1
    rm -f "$TEST_RESTART_LOG" "$TEST_RESTART_LOG.failed"
    cat > "$V2BX_CONFIG_PATH" <<'EOF'
{"Log":{"Level":"info"},"Cores":[{"Type":"xray","Name":"reality","RouteConfigPath":"/keep/route.json"}],"Nodes":[{"Core":"xray","CoreName":"reality","ApiHost":"https://panel.example.com/","ApiKey":"dummy-private-key","NodeID":105,"NodeType":"vless","ApiProtocol":"uniproxy","Timeout":30,"Flow":"xtls-rprx-vision","XrayOptions":{"RealityConfig":{"Dest":"keep.example.com:443"}},"CertConfig":{"CertMode":"none"},"LimitConfig":{"EnableRealtimeRateLimit":true}}],"Custom":{"keep":[1,2,3]}}
EOF
    cp "$V2BX_CONFIG_PATH" "$tmp_dir/original.json"
}
run_append() {
    bash -c 'source "$1"; append_node_config "$2" "$3"' _ "$repo_dir/initconfig.sh" "$V2BX_CONFIG_PATH" "${1:-clone}" </dev/null > "$tmp_dir/output" 2>&1
}
unchanged() { cmp -s "$V2BX_CONFIG_PATH" "$tmp_dir/original.json" || fail 'original config changed'; }
preserved() {
    jq -e --slurpfile old "$tmp_dir/original.json" '
      .Nodes[0] == $old[0].Nodes[0] and .Cores[0] == $old[0].Cores[0]
      and .Custom == $old[0].Custom and .Log == $old[0].Log
    ' "$V2BX_CONFIG_PATH" >/dev/null || fail 'existing fields changed'
    ! grep -q dummy-private-key "$tmp_dir/output" || fail 'API key leaked'
}
reset_config
run_append || { cat "$tmp_dir/output"; fail clone; }
preserved
jq -e '.Nodes | length == 2 and .[1].NodeID == 202 and .[1].Flow == "xtls-rprx-vision"' "$V2BX_CONFIG_PATH" >/dev/null
if run_append; then fail 'duplicate accepted'; fi
[[ ! -d "$V2BX_CONFIG_PATH.append.lock" ]] || fail 'lock leaked'

reset_config
run_append --hy2-http || { cat "$tmp_dir/output"; fail hy2; }
preserved
jq -e '.Cores | length == 2 and .[1].Name == "hy2-append-202"' "$V2BX_CONFIG_PATH" >/dev/null
jq -e '.Nodes[1] | .ApiConfig.NodeType == "hysteria2" and .ApiConfig.NodeID == 202
  and .ApiConfig.ApiKey == "dummy-private-key" and .ApiConfig.ApiProtocol == "uniproxy"
  and .Options.CoreName == "hy2-append-202" and .Options.CertConfig.CertMode == "http"
  and .Options.CertConfig.CertDomain == "hy2.example.com"
  and .Options.CertConfig.CertFile == "/etc/V2bX/certs/hy2-append-202/fullchain.cer"
  and (.Options | has("Flow") or has("XrayOptions") or has("Hysteria2ConfigPath") | not)' "$V2BX_CONFIG_PATH" >/dev/null
if run_append --hy2-http; then fail 'duplicate Hy2 accepted'; fi

reset_config
jq '.Nodes |= map({ApiConfig:{ApiHost:.ApiHost,ApiKey:.ApiKey,NodeID:.NodeID,NodeType:.NodeType},Options:{Core:.Core,CoreName:.CoreName,Flow:.Flow}})' "$tmp_dir/original.json" > "$V2BX_CONFIG_PATH"
cp "$V2BX_CONFIG_PATH" "$tmp_dir/original.json"
run_append || fail 'nested clone'
preserved
jq -e '.Nodes[1].ApiConfig.NodeID == 202 and .Nodes[1].Options.Flow == "xtls-rprx-vision"' "$V2BX_CONFIG_PATH" >/dev/null

for state in occupied failed; do
    reset_config
    export TEST_SS="$state"
    if run_append --hy2-http; then fail "ss $state accepted"; fi
    unchanged
done
for domain in '-bad.example.com' 'good.-bad.com' 'bad..com' 'example.com/path' ''; do
    reset_config
    export V2BX_DOMAIN="$domain"
    if run_append --hy2-http; then fail 'invalid domain accepted'; fi
    unchanged
done
reset_config
export V2BX_TEMPLATE_INDEX=99
if run_append; then fail 'unknown template accepted'; fi
unchanged
reset_config
export V2BX_NODE_ID='001'
if run_append; then fail 'invalid ID accepted'; fi
unchanged
reset_config
mkdir "$V2BX_CONFIG_PATH.append.lock"
if run_append; then fail 'concurrent lock ignored'; fi
unchanged
rmdir "$V2BX_CONFIG_PATH.append.lock"
reset_config
printf '{"Cores":[{}],"Nodes":[{"Include":"external.json"}]}\n' > "$V2BX_CONFIG_PATH"
cp "$V2BX_CONFIG_PATH" "$tmp_dir/original.json"
if run_append; then fail 'Include accepted'; fi
unchanged
reset_config
printf '{malformed' > "$V2BX_CONFIG_PATH"
cp "$V2BX_CONFIG_PATH" "$tmp_dir/original.json"
if run_append; then fail 'malformed JSON accepted'; fi
unchanged

reset_config
V2BX_APPEND_NONINTERACTIVE=0 bash -c 'source "$1"; append_node_config "$2" clone' _ "$repo_dir/initconfig.sh" "$V2BX_CONFIG_PATH" <<< $'1\n202\nn' > "$tmp_dir/output" 2>&1 || fail cancel
unchanged
for state in fail-restart dies stopped; do
    reset_config
    export V2BX_RESTART=1 TEST_SERVICE="$state"
    if run_append; then fail "service $state accepted"; fi
    unchanged
    if [[ "$state" != stopped ]]; then
        grep -q '诊断已保存' "$tmp_dir/output" || fail 'startup diagnostics missing'
        ! grep -q dummy-private-key "$tmp_dir/output" || fail 'diagnostic output leaked credentials'
        grep -l 'startup-certificate-error config-nodes=2' "$V2BX_CONFIG_PATH".add-node-failure.* >/dev/null || fail 'startup diagnostics captured after rollback'
    fi
done
reset_config
export V2BX_RESTART=1
run_append || fail 'healthy restart'
[[ $(wc -l < "$TEST_RESTART_LOG") == 1 ]] || fail 'unexpected restart count'
preserved
reset_config
export V2BX_RESTART=1 TEST_SERVICE=concurrent
if run_append; then fail 'concurrent restart failure accepted'; fi
jq -e '.external == true' "$V2BX_CONFIG_PATH" >/dev/null || fail 'concurrent edit overwritten'

reset_config
bash "$repo_dir/append-hy2-http.sh" </dev/null > "$tmp_dir/output" 2>&1 || { cat "$tmp_dir/output"; fail 'standalone entrypoint'; }
preserved
jq -e '.Nodes[1].ApiConfig.NodeType == "hysteria2"' "$V2BX_CONFIG_PATH" >/dev/null
reset_config
if V2BX_NODE_ID='' bash "$repo_dir/append-hy2-http.sh" </dev/null > "$tmp_dir/output" 2>&1; then fail 'missing standalone parameter accepted'; fi
unchanged
echo 'PASS: append preserves flat/nested nodes, noninteractive Hy2, validation, cancellation, locking and service rollback'
