#!/bin/bash
# 一键配置

# 检查系统是否有 IPv6 地址
check_ipv6_support() {
    if ip -6 addr | grep -q "inet6"; then
        echo "1"  # 支持 IPv6
    else
        echo "0"  # 不支持 IPv6
    fi
}

protocol_from_choice() {
    local selected_core="$1" choice="$2"
    case "$selected_core:$choice" in
        xray:1|sing:1) printf 'shadowsocks\n' ;;
        xray:2|sing:2) printf 'vless\n' ;;
        xray:3|sing:3) printf 'vmess\n' ;;
        sing:4) printf 'hysteria\n' ;;
        sing:5) printf 'hysteria2\n' ;;
        xray:6|sing:6) printf 'trojan\n' ;;
        sing:7) printf 'tuic\n' ;;
        sing:8) printf 'anytls\n' ;;
        *) return 1 ;;
    esac
}

add_node_config() {
    echo -e "${green}请选择节点核心类型：${plain}"
    echo -e "${green}1. xray${plain}"
    echo -e "${green}2. singbox${plain}"
    echo -e "${green}3. hysteria2${plain}"
    read -rp "请输入：" core_type
    if [ "$core_type" == "1" ]; then
        core="xray"
        core_xray=true
    elif [ "$core_type" == "2" ]; then
        core="sing"
        core_sing=true
    elif [ "$core_type" == "3" ]; then
        core="hysteria2"
        core_hysteria2=true
    else
        echo "无效的选择。请选择 1 2 3。"
        continue
    fi
    while true; do
        read -rp "请输入节点Node ID：" NodeID
        # 判断NodeID是否为正整数
        if [[ "$NodeID" =~ ^[0-9]+$ ]] && ((NodeID > 0)); then
            break  # 输入正确，退出循环
        else
            echo "错误：请输入正确的数字作为Node ID。"
        fi
    done

    isreality=""
    istls=""
    if [ "$core_type" == "3" ]; then
        NodeType="hysteria2"
    else
        echo -e "${yellow}请选择节点传输协议：${plain}"
        echo -e "${green}1. Shadowsocks${plain}"
        echo -e "${green}2. Vless${plain}"
        echo -e "${green}3. Vmess${plain}"
        if [ "$core_sing" == true ]; then
            echo -e "${green}4. Hysteria${plain}"
            echo -e "${green}5. Hysteria2${plain}"
        fi
        if [ "$core_hysteria2" == true ] && [ "$core_sing" = false ]; then
            echo -e "${green}5. Hysteria2${plain}"
        fi
        echo -e "${green}6. Trojan${plain}"  
        if [ "$core_sing" == true ]; then
            echo -e "${green}7. Tuic${plain}"
            echo -e "${green}8. AnyTLS${plain}"
        fi
        while true; do
            read -rp "请输入：" protocol_choice
            if NodeType=$(protocol_from_choice "$core" "$protocol_choice"); then
                break
            fi
            echo "错误：当前核心不支持这个协议选项，请重新选择。"
        done
    fi
    fastopen=true
    if [ "$NodeType" == "vless" ]; then
        read -rp "请选择是否为reality节点？(y/n)" isreality
    elif [ "$NodeType" == "hysteria" ] || [ "$NodeType" == "hysteria2" ] || [ "$NodeType" == "tuic" ] || [ "$NodeType" == "anytls" ]; then
        fastopen=false
        istls="y"
    fi

    if [[ "$isreality" != "y" && "$isreality" != "Y" &&  "$istls" != "y" ]]; then
        read -rp "请选择是否进行TLS配置？(y/n)" istls
    fi

    certmode="none"
    certdomain="example.com"
    if [[ "$isreality" != "y" && "$isreality" != "Y" && ( "$istls" == "y" || "$istls" == "Y" ) ]]; then
        echo -e "${yellow}请选择证书申请模式：${plain}"
        echo -e "${green}1. http模式自动申请，节点域名已正确解析${plain}"
        echo -e "${green}2. dns模式自动申请，需填入正确域名服务商API参数${plain}"
        echo -e "${green}3. self模式，自签证书或提供已有证书文件${plain}"
        while true; do
            read -rp "请输入：" certmode_choice
            case "$certmode_choice" in
                1 ) certmode="http"; break ;;
                2 ) certmode="dns"; break ;;
                3 ) certmode="self"; break ;;
                * ) echo "错误：请选择 1、2 或 3。" ;;
            esac
        done
        read -rp "请输入节点证书域名(example.com)：" certdomain
        if [ "$certmode" != "http" ]; then
            echo -e "${red}请手动修改配置文件后重启V2bX！${plain}"
        fi
    fi
    cert_dir="/etc/V2bX/certs/${core}-${NodeType}-${NodeID}"
    abuse_guard_config='"LimitConfig": {
                "AbuseGuardConfig": {
                    "Enable": true,
                    "WindowSeconds": 10,
                    "MaxClientConnections": 20,
                    "MaxOutboundConnections": 300,
                    "MaxDistinctDestinations": 128,
                    "MaxDistinctIPTargets": 32,
                    "MaxDistinctPorts": 16,
                    "BlockSeconds": 600,
                    "MaxTrackedUsers": 10000
                }
            },'
    ipv6_support=$(check_ipv6_support)
    listen_ip="0.0.0.0"
    if [ "$ipv6_support" -eq 1 ]; then
        listen_ip="::"
    fi
    node_config=""
    if [ "$core_type" == "1" ]; then 
    node_config=$(cat <<EOF
{
            "Core": "$core",
            "ApiHost": "$ApiHost",
            "ApiKey": "$ApiKey",
            "NodeID": $NodeID,
            "NodeType": "$NodeType",
            "Timeout": 30,
            "ListenIP": "0.0.0.0",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "ReportMinTraffic": 0,
            $abuse_guard_config
            "EnableProxyProtocol": false,
            "EnableUot": true,
            "EnableTFO": true,
            "DNSType": "UseIPv4",
            "CertConfig": {
                "CertMode": "$certmode",
                "RejectUnknownSni": false,
                "CertDomain": "$certdomain",
                "CertFile": "$cert_dir/fullchain.cer",
                "KeyFile": "$cert_dir/cert.key",
                "Email": "v2bx@github.com",
                "Provider": "cloudflare",
                "DNSEnv": {
                    "EnvName": "env1"
                }
            }
        },
EOF
)
    elif [ "$core_type" == "2" ]; then
    node_config=$(cat <<EOF
{
            "Core": "$core",
            "ApiHost": "$ApiHost",
            "ApiKey": "$ApiKey",
            "NodeID": $NodeID,
            "NodeType": "$NodeType",
            "Timeout": 30,
            "ListenIP": "$listen_ip",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "ReportMinTraffic": 0,
            $abuse_guard_config
            "TCPFastOpen": $fastopen,
            "EnableSniff": true,
            "SniffOverrideDestination": true,
            "CertConfig": {
                "CertMode": "$certmode",
                "RejectUnknownSni": false,
                "CertDomain": "$certdomain",
                "CertFile": "$cert_dir/fullchain.cer",
                "KeyFile": "$cert_dir/cert.key",
                "Email": "v2bx@github.com",
                "Provider": "cloudflare",
                "DNSEnv": {
                    "EnvName": "env1"
                }
            }
        },
EOF
)
    elif [ "$core_type" == "3" ]; then
    node_config=$(cat <<EOF
{
            "Core": "$core",
            "ApiHost": "$ApiHost",
            "ApiKey": "$ApiKey",
            "NodeID": $NodeID,
            "NodeType": "$NodeType",
            "Hysteria2ConfigPath": "/etc/V2bX/hy2config.yaml",
            "Timeout": 30,
            "ListenIP": "",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "ReportMinTraffic": 0,
            $abuse_guard_config
            "CertConfig": {
                "CertMode": "$certmode",
                "RejectUnknownSni": false,
                "CertDomain": "$certdomain",
                "CertFile": "$cert_dir/fullchain.cer",
                "KeyFile": "$cert_dir/cert.key",
                "Email": "v2bx@github.com",
                "Provider": "cloudflare",
                "DNSEnv": {
                    "EnvName": "env1"
                }
            }
        },
EOF
)
    fi
    nodes_config+=("$node_config")
}

# Append clones an existing node or reuses its panel credentials for a new Hy2.
# Never invoke the destructive generator here.
append_node_config() (
    set -Eeuo pipefail
    umask 077
    local config_path="${1:-/etc/V2bX/config.json}"
    local template_index="${V2BX_TEMPLATE_INDEX:-}" new_id="${V2BX_NODE_ID:-}" answer work_dir="" lock_dir backup=""
    local original_hash candidate_hash committed=false restart_attempted=false backend restart_since="" failure_reason=""
    local mode="${2:-}" domain="${V2BX_DOMAIN:-}" port80="" email="${V2BX_EMAIL:-}" identity_type label
    local unattended="${V2BX_APPEND_NONINTERACTIVE:-0}" restart="${V2BX_RESTART:-0}"
    [[ "$unattended" == 0 || "$unattended" == 1 ]] || { echo "错误：V2BX_APPEND_NONINTERACTIVE 必须为 0 或 1。" >&2; exit 2; }
    if [[ "$unattended" == 1 ]]; then
        [[ -n "$mode" && -n "$template_index" && -n "$new_id" ]] || { echo "错误：非交互追加需要方式、V2BX_TEMPLATE_INDEX 和 V2BX_NODE_ID。" >&2; exit 2; }
        [[ "$restart" == 0 || "$restart" == 1 ]] || { echo "错误：V2BX_RESTART 必须为 0 或 1。" >&2; exit 2; }
    fi
    command -v jq >/dev/null || { echo "错误：需要先安装 jq。" >&2; exit 1; }
    [[ -f "$config_path" && ! -L "$config_path" ]] || {
        echo "错误：需要已有的普通 config.json 文件。" >&2; exit 1;
    }
    config_path="$(cd -- "$(dirname -- "$config_path")" && pwd)/$(basename -- "$config_path")"
    lock_dir="${config_path}.append.lock"
    mkdir -- "$lock_dir" 2>/dev/null || {
        echo "错误：已有追加操作，或遗留锁目录：$lock_dir" >&2; exit 1;
    }
    append_service() {
        if [[ "$backend" == openrc ]]; then
            service V2bX "$1"
        elif [[ "$1" == status ]]; then
            systemctl is-active --quiet V2bX
        else
            systemctl "$1" V2bX
        fi
    }
    append_cleanup() {
        local result=$? restore_stage
        trap - EXIT HUP INT TERM
        if [[ "$committed" == true && "$result" != 0 && "$restart_attempted" == true ]]; then
            # Capture the failed startup before rollback replaces its evidence.
            # Keep raw diagnostics private; they may contain panel credentials.
            local diagnostic
            diagnostic=$(mktemp "${config_path}.add-node-failure.$(date +%Y%m%d-%H%M%S).XXXXXX") || diagnostic=""
            if [[ -n "$diagnostic" ]]; then
                {
                    printf '%s\n' "${failure_reason:-追加过程中收到中断或发生错误。}"
                    cat "$work_dir/service.log" 2>/dev/null || true
                    if [[ "$backend" == systemd ]]; then
                        systemctl status V2bX --no-pager -l 2>&1 || true
                        journalctl -u V2bX --since "@$restart_since" -n 150 --no-pager 2>&1 || true
                    fi
                } > "$diagnostic"
                echo "${failure_reason:-追加过程中收到中断或发生错误。}" >&2
                echo "回滚前的诊断已保存（可能含凭据，请勿原样公开）：$diagnostic" >&2
            fi
        fi
        if [[ "$committed" == true && "$result" != 0 ]]; then
            if [[ ! -L "$config_path" && "$(sha256sum "$config_path" | awk '{print $1}')" == "$candidate_hash" ]]; then
                restore_stage=$(mktemp "${config_path}.restore.XXXXXX")
                if cp -p -- "$work_dir/original.json" "$restore_stage" && mv -f -- "$restore_stage" "$config_path"; then
                    echo "追加失败，已恢复原配置。" >&2
                    if [[ "$restart_attempted" == true ]]; then
                        append_service restart > "$work_dir/restore.log" 2>&1 || echo "错误：原服务恢复失败，请检查服务日志。" >&2
                    fi
                else
                    rm -f -- "$restore_stage"
                    echo "错误：自动恢复失败，请从备份恢复：$backup" >&2
                fi
            else
                echo "错误：配置已被其他操作修改，未覆盖；原配置备份：$backup" >&2
            fi
        fi
        [[ -z "$work_dir" ]] || rm -rf -- "$work_dir"
        rmdir -- "$lock_dir"
        exit "$result"
    }
    trap append_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
    work_dir=$(mktemp -d "$(dirname -- "$config_path")/.append-node.XXXXXX") || exit 1
    cp -p -- "$config_path" "$work_dir/original.json" || exit 1
    original_hash=$(sha256sum "$work_dir/original.json" | awk '{print $1}') || exit 1
    # jq must never print parsing errors containing credentials. Includes cannot
    # be checked for duplicate panel identities without resolving external data.
    jq -e 'type == "object" and (.Nodes | type == "array" and length > 0)
        and (.Cores | type == "array" and length > 0)
        and all(.Nodes[]; type == "object" and (has("Include") | not))' \
        "$work_dir/original.json" >/dev/null 2>&1 || {
        echo "错误：追加需要严格 JSON 和内联 Nodes；JSON5/Include 配置保持原样，请先人工处理。" >&2; exit 1;
    }
    if [[ -z "$mode" ]]; then
        read -rp "追加方式：1) 复制已有节点 2) 新增 Hy2（HTTP证书）[1]：" mode || exit 1
        mode="${mode:-1}"
    fi
    case "$mode" in
        1|clone) mode=clone ;;
        2|--hy2-http) mode=hy2-http ;;
        *) echo "错误：追加方式无效。" >&2; exit 1 ;;
    esac
    if [[ "$unattended" == 0 ]]; then
      echo "选择已有节点以复用面板信息（不会显示 API Key）。"
      jq -r '.Nodes | to_entries[] | .key as $i | .value |
        "\($i + 1)) \(.Core // .Options.Core // .CoreName // .Options.CoreName // "auto") / \(.NodeType // .ApiConfig.NodeType) / NodeID=\(.NodeID // .ApiConfig.NodeID)"' "$work_dir/original.json"
      read -rp "选择要复制的节点序号（不是 NodeID）：" template_index || exit 1
    fi
    [[ "$template_index" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "错误：节点序号无效。" >&2; exit 1; }
    template_index=$((10#$template_index - 1))
    jq -e --argjson i "$template_index" '.Nodes[$i] | type == "object"' "$work_dir/original.json" >/dev/null || {
        echo "错误：节点序号不存在。" >&2; exit 1;
    }
    echo "请先在面板新建对应协议的节点；同 IP、同传输层使用不同服务端端口。"
    echo "服务端端口由面板的新节点提供；VLESS TCP 与 Hy2 UDP 可以使用相同端口号。"
    if [[ "$unattended" == 0 ]]; then read -rp "请输入新节点 NodeID：" new_id || exit 1; fi
    [[ "$new_id" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "错误：NodeID 必须是正整数（最多9位）。" >&2; exit 1; }
    identity_type=$(jq -r --argjson i "$template_index" '.Nodes[$i] | .NodeType // .ApiConfig.NodeType' "$work_dir/original.json")
    if [[ "$mode" == hy2-http ]]; then
        identity_type=hysteria2
        if [[ "$unattended" == 0 ]]; then read -rp "Hy2 证书域名（须已解析到本机）：" domain || exit 1; fi
        domain="${domain,,}"
        [[ ${#domain} -le 253 && "$domain" == *.* && "$domain" != *..* && "$domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || {
            echo "错误：请输入有效域名，不含协议、端口、路径或通配符。" >&2; exit 1;
        }
        local -a labels
        IFS=. read -r -a labels <<< "$domain"
        for label in "${labels[@]}"; do
            [[ ${#label} -le 63 && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "错误：域名标签无效。" >&2; exit 1; }
        done
        if [[ "$unattended" == 0 ]]; then read -rp "ACME 证书联系邮箱：" email || exit 1; fi
        [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || { echo "错误：邮箱格式无效。" >&2; exit 1; }
        command -v ss >/dev/null || { echo "错误：请先安装 iproute2（需要 ss 检查 TCP 80）。" >&2; exit 1; }
        port80=$(ss -H -ltn 'sport = :80') || { echo "错误：无法检查 TCP 80 监听状态。" >&2; exit 1; }
        [[ -z "$port80" ]] || {
            echo "错误：TCP 80 已被占用，HTTP证书验证不能启动。请使用 DNS 验证或已有证书；未停止任何服务。" >&2; exit 1;
        }
        echo "请在面板的新 Hy2 节点中设置该域名和 UDP 服务端端口，并放行 UDP 入站及 TCP 80。"
    fi
    jq --argjson i "$template_index" --argjson id "$new_id" --arg kind "$identity_type" \
        --arg mode "$mode" --arg domain "$domain" --arg email "$email" '
        def api: .ApiConfig // .;
        .Nodes[$i] as $template | ($template | api) as $api |
        if ($api.ApiHost | type) != "string" or ($api.ApiHost | length) == 0
            or ($api.ApiKey | type) != "string" or ($api.ApiKey | length) == 0
            or ($api.NodeType | type) != "string" then
            error("unsupported template")
        elif any(.Nodes[]; (api | .NodeID == $id and .NodeType == $kind
            and (.ApiHost | rtrimstr("/")) == ($api.ApiHost | rtrimstr("/")))) then
            error("duplicate node")
        elif $mode == "hy2-http" then
            # A dedicated core avoids inheriting any existing Hy2 ACL/YAML.
            ("hy2-append-" + ($id|tostring)) as $name |
            if any(.Cores[]; (.Name // .Type) == $name) then error("duplicate core") else
                .Cores += [{Type:"hysteria2", Name:$name, Log:{Level:"warn",Output:"/var/log/V2bX/hy2.log"}}] |
                .Nodes += [{
                    ApiConfig: ($api | {ApiHost,ApiKey,ApiSendIP,Timeout,MachineID,ApiProtocol,RuleListPath} |
                        with_entries(select(.value != null)) | .NodeID=$id | .NodeType="hysteria2"),
                    Options: {Core:"hysteria2",CoreName:$name,ListenIP:"0.0.0.0",SendIP:"0.0.0.0",
                        DeviceOnlineMinTraffic:200,ReportMinTraffic:0,
                        LimitConfig: ($template.Options.LimitConfig // $template.LimitConfig // {}),
                        CertConfig: {CertMode:"http",CertDomain:$domain,Email:$email,
                            CertFile:("/etc/V2bX/certs/"+$name+"/fullchain.cer"),
                            KeyFile:("/etc/V2bX/certs/"+$name+"/cert.key")}}
                }]
            end
        else .Nodes += [($template | if has("ApiConfig") then .ApiConfig.NodeID = $id else .NodeID = $id end)] end
    ' "$work_dir/original.json" > "$work_dir/candidate.json" 2>/dev/null || {
        echo "错误：同面板同协议 NodeID 已存在，或模板缺少面板信息。" >&2; exit 1;
    }
    # Retain the original config metadata; only the backup is always private.
    cp -p -- "$work_dir/original.json" "$work_dir/staged.json" || exit 1
    cat "$work_dir/candidate.json" > "$work_dir/staged.json" || exit 1
    candidate_hash=$(sha256sum "$work_dir/staged.json" | awk '{print $1}') || exit 1
    if [[ "$unattended" == 0 ]]; then
        read -rp "确认追加 NodeID=$new_id？[y/N]：" answer || exit 1
        [[ "$answer" == y || "$answer" == Y ]] || { echo "已取消，原配置未修改。"; exit 0; }
        read -rp "保存后立即重启 V2bX？现有连接会短暂中断。[y/N]：" answer || exit 1
        if [[ "$answer" == y || "$answer" == Y ]]; then restart=1; else restart=0; fi
    fi
    backend=systemd
    [[ ! -f /etc/alpine-release ]] || backend=openrc
    if [[ "$restart" == 1 ]]; then
        append_service status >/dev/null 2>&1 || { echo "错误：服务未运行；请先修复服务，或选择仅保存。" >&2; exit 1; }
    fi
    [[ ! -L "$config_path" && "$(sha256sum "$config_path" | awk '{print $1}')" == "$original_hash" ]] || {
        echo "错误：配置在操作期间已变化，追加已取消。" >&2; exit 1;
    }
    backup=$(mktemp "${config_path}.before-add-node.$(date +%Y%m%d-%H%M%S).XXXXXX") || exit 1
    cat "$work_dir/original.json" > "$backup" || exit 1
    # Set before rename so signal/error cleanup covers the commit boundary.
    committed=true
    mv -f -- "$work_dir/staged.json" "$config_path" || exit 1
    if [[ "$restart" == 1 ]]; then
        restart_since=$(date +%s)
        restart_attempted=true
        append_service restart > "$work_dir/service.log" 2>&1 || {
            failure_reason="错误：V2bX 重启命令失败。"
            exit 1
        }
        for _ in 1 2 3 4 5; do
            sleep 1
            append_service status >> "$work_dir/service.log" 2>&1 || {
                failure_reason="错误：重启后第 ${_} 秒，V2bX 服务未处于运行状态。"
                exit 1
            }
        done
        echo "节点已追加，服务连续5秒存活；请在客户端验证新旧节点。"
    else
        echo "节点已保存，尚未重启生效；执行 V2bX restart 后验证新旧节点。"
    fi
    echo "原配置备份：$backup"
)

generate_config_file() {
    echo -e "${yellow}V2bX 配置文件生成向导${plain}"
    echo -e "${red}请阅读以下注意事项：${plain}"
    echo -e "${red}1. 目前该功能正处测试阶段${plain}"
    echo -e "${red}2. 生成的配置文件会保存到 /etc/V2bX/config.json${plain}"
    echo -e "${red}3. 原来的配置文件会保存到 /etc/V2bX/config.json.bak${plain}"
    echo -e "${red}4. 目前仅部分支持TLS${plain}"
    echo -e "${red}5. 使用此功能生成的配置文件会自带审计，确定继续？(y/n)${plain}"
    read -rp "请输入：" continue_prompt
    if [[ "$continue_prompt" =~ ^[Nn][Oo]? ]]; then
        exit 0
    fi
    
    nodes_config=()
    first_node=true
    core_xray=false
    core_sing=false
    core_hysteria2=false
    fixed_api_info=false
    check_api=false
    
    while true; do
        if [ "$first_node" = true ]; then
            read -rp "请输入机场网址(https://example.com)：" ApiHost
            read -rp "请输入面板对接API Key：" ApiKey
            read -rp "是否设置固定的机场网址和API Key？(y/n)" fixed_api
            if [ "$fixed_api" = "y" ] || [ "$fixed_api" = "Y" ]; then
                fixed_api_info=true
                echo -e "${red}成功固定地址${plain}"
            fi
            first_node=false
            add_node_config
        else
            read -rp "是否继续添加节点配置？(回车继续，输入n或no退出)" continue_adding_node
            if [[ "$continue_adding_node" =~ ^[Nn][Oo]? ]]; then
                break
            elif [ "$fixed_api_info" = false ]; then
                read -rp "请输入机场网址(https://example.com)：" ApiHost
                read -rp "请输入面板对接API Key：" ApiKey
            fi
            add_node_config
        fi
    done

    # 初始化核心配置数组
    cores_config="["

    # 检查并添加xray核心配置
    if [ "$core_xray" = true ]; then
        cores_config+="
    {
        \"Type\": \"xray\",
        \"Log\": {
            \"Level\": \"warning\",
            \"AccessPath\": \"\",
            \"ErrorPath\": \"/var/log/V2bX/xray-error.log\"
        },
        \"OutboundConfigPath\": \"/etc/V2bX/custom_outbound.json\",
        \"RouteConfigPath\": \"/etc/V2bX/route.json\"
    },"
    fi

    # 检查并添加sing核心配置
    if [ "$core_sing" = true ]; then
        cores_config+="
    {
        \"Type\": \"sing\",
        \"Log\": {
            \"Level\": \"warn\",
            \"Timestamp\": true,
            \"Output\": \"/var/log/V2bX/sing.log\"
        },
        \"NTP\": {
            \"Enable\": false,
            \"Server\": \"time.apple.com\",
            \"ServerPort\": 0
        },
        \"OriginalPath\": \"/etc/V2bX/sing_origin.json\"
    },"
    fi

    # 检查并添加hysteria2核心配置
    if [ "$core_hysteria2" = true ]; then
        cores_config+="
    {
        \"Type\": \"hysteria2\",
        \"Log\": {
            \"Level\": \"warn\",
            \"Output\": \"/var/log/V2bX/hy2.log\"
        }
    },"
    fi

    # 移除最后一个逗号并关闭数组
    cores_config+="]"
    cores_config=$(echo "$cores_config" | sed 's/},]$/}]/')

    # 切换到配置文件目录
    mkdir -p /etc/V2bX /var/log/V2bX
    chmod 0750 /var/log/V2bX
    cd /etc/V2bX
    
    # 备份旧的配置文件
    if [[ -f config.json ]]; then
        cp -a config.json config.json.bak
    fi
    nodes_config_str="${nodes_config[*]}"
    formatted_nodes_config="${nodes_config_str%,}"

    # 创建 config.json 文件
    cat <<EOF > /etc/V2bX/config.json
{
    "Log": {
        "Level": "warn",
        "Output": "/var/log/V2bX/v2bx.log"
    },
    "Cores": $cores_config,
    "Nodes": [$formatted_nodes_config]
}
EOF
    
    # 创建 custom_outbound.json 文件
    cat <<EOF > /etc/V2bX/custom_outbound.json
[
    {
        "tag": "IPv4_out",
        "protocol": "freedom",
        "settings": {
            "domainStrategy": "UseIPv4v6"
        }
    },
    {
        "tag": "IPv6_out",
        "protocol": "freedom",
        "settings": {
            "domainStrategy": "UseIPv6"
        }
    },
    {
        "protocol": "blackhole",
        "tag": "block"
    }
]
EOF
    
    # 创建 route.json 文件
    cat <<EOF > /etc/V2bX/route.json
{
    "domainStrategy": "IPIfNonMatch",
    "rules": [
        {
            "type": "field",
            "outboundTag": "IPv4_out",
            "ip": [
                "192.0.0.9/32",
                "192.0.0.10/32"
            ]
        },
        {
            "type": "field",
            "outboundTag": "block",
            "ip": [
                "geoip:private",
                "0.0.0.0/8",
                "10.0.0.0/8",
                "100.64.0.0/10",
                "127.0.0.0/8",
                "169.254.0.0/16",
                "172.16.0.0/12",
                "192.0.0.0/24",
                "192.0.2.0/24",
                "192.88.99.0/24",
                "192.168.0.0/16",
                "198.18.0.0/15",
                "198.51.100.0/24",
                "203.0.113.0/24",
                "224.0.0.0/4",
                "240.0.0.0/4",
                "::/128",
                "::1/128",
                "64:ff9b:1::/48",
                "100::/64",
                "100:0:0:1::/64",
                "2001:2::/48",
                "2001:10::/28",
                "2001:db8::/32",
                "3fff::/20",
                "5f00::/16",
                "fc00::/7",
                "fe80::/10",
                "ff00::/8"
            ]
        },
        {
            "type": "field",
            "outboundTag": "block",
            "network": "tcp",
            "port": "25"
        },
        {
            "type": "field",
            "outboundTag": "block",
            "protocol": [
                "bittorrent"
            ]
        },
        {
            "type": "field",
            "outboundTag": "IPv4_out",
            "network": "udp,tcp"
        }
    ]
}
EOF
    ipv6_support=$(check_ipv6_support)
    dnsstrategy="ipv4_only"
    if [ "$ipv6_support" -eq 1 ]; then
        dnsstrategy="prefer_ipv4"
    fi
    # 创建 sing_origin.json 文件
    cat <<EOF > /etc/V2bX/sing_origin.json
{
  "dns": {
    "servers": [
      {
        "tag": "cf",
        "address": "1.1.1.1"
      }
    ],
    "strategy": "$dnsstrategy"
  },
  "outbounds": [
    {
      "tag": "direct",
      "type": "direct",
      "domain_resolver": {
        "server": "cf",
        "strategy": "$dnsstrategy"
      }
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "ip_cidr": [
          "192.0.0.9/32",
          "192.0.0.10/32"
        ],
        "outbound": "direct"
      },
      {
        "ip_is_private": true,
        "outbound": "block"
      },
      {
        "ip_cidr": [
          "0.0.0.0/8",
          "100.64.0.0/10",
          "169.254.0.0/16",
          "192.0.0.0/24",
          "192.0.2.0/24",
          "192.88.99.0/24",
          "198.18.0.0/15",
          "198.51.100.0/24",
          "203.0.113.0/24",
          "224.0.0.0/4",
          "240.0.0.0/4",
          "::/128",
          "::1/128",
          "64:ff9b:1::/48",
          "100::/64",
          "100:0:0:1::/64",
          "2001:2::/48",
          "2001:10::/28",
          "2001:db8::/32",
          "3fff::/20",
          "5f00::/16",
          "fc00::/7",
          "fe80::/10",
          "ff00::/8"
        ],
        "outbound": "block"
      },
      {
        "network": "tcp",
        "port": [25],
        "outbound": "block"
      },
      {
        "protocol": [
          "bittorrent"
        ],
        "outbound": "block"
      },
      {
        "outbound": "direct",
        "network": [
          "udp","tcp"
        ]
      }
    ]
  },
  "experimental": {
    "cache_file": {
      "enabled": true
    }
  }
}
EOF

    # 创建 hy2config.yaml 文件           
    cat <<EOF > /etc/V2bX/hy2config.yaml
quic:
  initStreamReceiveWindow: 1048576
  maxStreamReceiveWindow: 4194304
  initConnReceiveWindow: 4194304
  maxConnReceiveWindow: 16777216
  maxIdleTimeout: 30s
  maxIncomingStreams: 256
  disablePathMTUDiscovery: false
ignoreClientBandwidth: false
disableUDP: false
udpIdleTimeout: 60s
resolver:
  type: system
masquerade:
  type: 404
EOF
    echo -e "${green}V2bX 配置文件生成完成,正在重新启动服务${plain}"
    v2bx restart
}
