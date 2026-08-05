#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

script_repo="rmomo5285-droid/V2bX-script"
script_branch="master"
script_base_url="https://raw.githubusercontent.com/${script_repo}/${script_branch}"

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误: ${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "alpine"; then
    release="alpine"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "arch"; then
    release="arch"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
    if [[ ${os_version} -eq 7 ]]; then
        echo -e "${red}注意： CentOS 7 无法使用hysteria1/2协议！${plain}\n"
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi

# 检查系统是否有 IPv6 地址
check_ipv6_support() {
    if ip -6 addr | grep -q "inet6"; then
        echo "1"  # 支持 IPv6
    else
        echo "0"  # 不支持 IPv6
    fi
}

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -rp "$1 [默认$2]: " temp
        if [[ x"${temp}" == x"" ]]; then
            temp=$2
        fi
    else
        read -rp "$1 [y/n]: " temp
    fi
    if [[ x"${temp}" == x"y" || x"${temp}" == x"Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "是否重启V2bX" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车返回主菜单: ${plain}" && read temp
    show_menu
}

install() {
    local installer
    installer=$(mktemp)
    if ! curl --proto '=https' --tlsv1.2 -fLsS --retry 3 -o "$installer" "$script_base_url/install.sh" ||
       ! bash -n "$installer"; then
        rm -f -- "$installer"
        echo -e "${red}下载安装脚本失败或脚本语法无效${plain}"
        return 1
    fi
    bash "$installer"
    local result=$?
    rm -f -- "$installer"
    if [[ $result == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    if [[ $# == 0 ]]; then
        echo && echo -n -e "输入指定版本(默认最新版): " && read version
    else
        version=$2
    fi
    local installer
    installer=$(mktemp)
    if ! curl --proto '=https' --tlsv1.2 -fLsS --retry 3 -o "$installer" "$script_base_url/install.sh" ||
       ! bash -n "$installer"; then
        rm -f -- "$installer"
        echo -e "${red}下载安装脚本失败或脚本语法无效${plain}"
        return 1
    fi
    if [[ -n "$version" ]]; then
        bash "$installer" "$version"
    else
        bash "$installer"
    fi
    local result=$?
    rm -f -- "$installer"
    if [[ $result == 0 ]]; then
        echo -e "${green}更新完成，已自动重启 V2bX，请使用 V2bX log 查看运行日志${plain}"
        exit
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

config() {
    local config_path="/etc/V2bX/config.json"
    local edit_path backup_path editor service_was_active=0
    command -v jq >/dev/null 2>&1 || {
        echo -e "${red}缺少 jq，无法安全校验配置。请先安装 jq。${plain}"
        return 1
    }
    [[ -f "$config_path" && ! -L "$config_path" ]] || {
        echo -e "${red}配置文件不存在或不是普通文件: $config_path${plain}"
        return 1
    }
    edit_path=$(mktemp /etc/V2bX/.config.edit.XXXXXX)
    cp -a -- "$config_path" "$edit_path"
    editor="${EDITOR:-vi}"
    "$editor" "$edit_path"
    if cmp -s -- "$edit_path" "$config_path"; then
        rm -f -- "$edit_path"
        echo "配置未改变"
        return 0
    fi
    if ! jq -e '(.Nodes | type) == "array" and (.Nodes | length > 0)' "$edit_path" >/dev/null; then
        rm -f -- "$edit_path"
        echo -e "${red}配置不是有效 JSON，未修改在线文件。${plain}"
        return 1
    fi
    if ! jq -e '
        [.Nodes[] |
          select((.CertConfig.CertMode // "none") == "http" or
                 (.CertConfig.CertMode // "none") == "dns" or
                 (.CertConfig.CertMode // "none") == "self") |
          {path: [(.CertConfig.CertFile // ""), (.CertConfig.KeyFile // "")], domain: (.CertConfig.CertDomain // "")}
        ] | group_by(.path) | all((map(.domain) | unique | length) <= 1)
    ' "$edit_path" >/dev/null; then
        rm -f -- "$edit_path"
        echo -e "${red}多个不同证书域名共用了同一证书路径，拒绝应用。${plain}"
        return 1
    fi
    check_status >/dev/null 2>&1 && service_was_active=1 || true
    backup_path="${config_path}.before-edit.$(date -u +%Y%m%dT%H%M%SZ)"
    cp -a -- "$config_path" "$backup_path"
    chmod --reference="$config_path" "$edit_path" 2>/dev/null || chmod 0600 "$edit_path"
    mv -f -- "$edit_path" "$config_path"
    if ((service_was_active)); then
        restart 0
        if ! check_status >/dev/null 2>&1; then
            cp -a -- "$backup_path" "$config_path"
            restart 0 || true
            echo -e "${red}新配置启动失败，已恢复 $backup_path${plain}"
            return 1
        fi
    fi
    echo -e "${green}配置已校验并应用，备份: $backup_path${plain}"
}

uninstall() {
    confirm "确定要卸载 V2bX 吗?" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        service V2bX stop
        rc-update del V2bX
        rm /etc/init.d/V2bX -f
    else
        systemctl stop V2bX
        systemctl disable V2bX
        rm /etc/systemd/system/V2bX.service -f
        systemctl daemon-reload
        systemctl reset-failed
    fi
    rm /etc/V2bX/ -rf
    rm /usr/local/V2bX/ -rf

    echo ""
    echo -e "卸载成功，如果你想删除此脚本，则退出脚本后运行 ${green}rm /usr/bin/V2bX -f${plain} 进行删除"
    echo ""

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        echo -e "${green}V2bX已运行，无需再次启动，如需重启请选择重启${plain}"
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service V2bX start
        else
            systemctl start V2bX
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            echo -e "${green}V2bX 启动成功，请使用 V2bX log 查看运行日志${plain}"
        else
            echo -e "${red}V2bX可能启动失败，请稍后使用 V2bX log 查看日志信息${plain}"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

stop() {
    if [[ x"${release}" == x"alpine" ]]; then
        service V2bX stop
    else
        systemctl stop V2bX
    fi
    sleep 2
    check_status
    if [[ $? == 1 ]]; then
        echo -e "${green}V2bX 停止成功${plain}"
    else
        echo -e "${red}V2bX停止失败，可能是因为停止时间超过了两秒，请稍后查看日志信息${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart() {
    if [[ x"${release}" == x"alpine" ]]; then
        service V2bX restart
    else
        systemctl restart V2bX
    fi
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        echo -e "${green}V2bX 重启成功，请使用 V2bX log 查看运行日志${plain}"
    else
        echo -e "${red}V2bX可能启动失败，请稍后使用 V2bX log 查看日志信息${plain}"
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

status() {
    if [[ x"${release}" == x"alpine" ]]; then
        service V2bX status
    else
        systemctl status V2bX --no-pager -l
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    if [[ x"${release}" == x"alpine" ]]; then
        rc-update add V2bX
    else
        systemctl enable V2bX
    fi
    if [[ $? == 0 ]]; then
        echo -e "${green}V2bX 设置开机自启成功${plain}"
    else
        echo -e "${red}V2bX 设置开机自启失败${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    if [[ x"${release}" == x"alpine" ]]; then
        rc-update del V2bX
    else
        systemctl disable V2bX
    fi
    if [[ $? == 0 ]]; then
        echo -e "${green}V2bX 取消开机自启成功${plain}"
    else
        echo -e "${red}V2bX 取消开机自启失败${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
    local log_files=()
    while IFS= read -r file; do
        log_files+=("$file")
    done < <(find /var/log/V2bX /etc/V2bX -maxdepth 1 -type f -name '*.log' -print 2>/dev/null | sort -u)
    if ((${#log_files[@]} > 0)); then
        tail -n 200 -F -- "${log_files[@]}"
    elif [[ x"${release}" != x"alpine" ]]; then
        journalctl -u V2bX.service -e --no-pager -f
    else
        echo -e "${red}尚未找到 V2bX 日志文件${plain}\n" && return 1
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_user_log() {
    local uuid="${2:-}" minutes="${3:-60}" pattern max_lines=2000 file
    [[ "$minutes" =~ ^[0-9]+$ ]] && ((minutes >= 1 && minutes <= 10080)) || {
        echo -e "${red}分钟数必须在 1 到 10080 之间${plain}"
        return 2
    }
    if [[ -n "$uuid" ]]; then
        pattern="$uuid"
    else
        pattern='abuse guard rejected|panel (protocol )?rule rejected|policy rejected|node safety rule rejected|connection or device limit rejected|access (domain|protocol).*reject|client_connection_rate|distinct_(destination|ip|port)_scan|outbound_connection_rate|udp_flow_(destination|ip|port)_scan'
    fi
    {
        if [[ x"${release}" != x"alpine" ]]; then
            journalctl -u V2bX.service --since "-$minutes minutes" --no-pager -o short-iso 2>/dev/null || true
        fi
        while IFS= read -r file; do
            echo "===== $file ====="
            tail -n 50000 -- "$file" 2>/dev/null || true
        done < <(find /var/log/V2bX /etc/V2bX -maxdepth 1 -type f -name '*.log' -mmin "-$minutes" -print 2>/dev/null | sort -u)
    } |
        sed -E \
            -e 's/([?&](token|api[_-]?key)=)[^&[:space:]]+/\1REDACTED/Ig' \
            -e 's/(ApiKey["=:[:space:]]+)[^",[:space:]]+/\1REDACTED/Ig' |
        if [[ -n "$uuid" ]]; then grep -Fi -- "$pattern"; else grep -Ei -- "$pattern"; fi |
        tail -n "$max_lines" || true
    echo "最多显示最后 $max_lines 条；文件日志按文件修改时间筛选，完整 URL 不在代理可见范围内。"
}

tune_network() {
    local action="${2:-check}"
    local helper="/usr/local/share/v2bx/network-tune.sh"
    case "$action" in
        check|apply|rollback) ;;
        *) echo -e "${red}用法: V2bX tune [check|apply|rollback]${plain}"; return 2 ;;
    esac
    [[ -x "$helper" ]] || {
        echo -e "${red}网络调优组件不存在: $helper，请先升级安装脚本。${plain}"
        return 1
    }
    "$helper" "$action" "${@:3}"
}

manage_bbr_kernel() {
    local action="${2:-check}"
    local helper="/usr/local/share/v2bx/bbr-kernel.sh"
    case "$action" in
        check|install) ;;
        *) echo -e "${red}用法: V2bX bbr [check|install] [--yes]${plain}"; return 2 ;;
    esac
    [[ -x "$helper" ]] || {
        echo -e "${red}BBR 内核组件不存在: $helper，请先升级安装脚本。${plain}"
        return 1
    }
    "$helper" "$action" "${@:3}"
}

manage_resources() {
    local action="${2:-status}"
    local helper="/usr/local/share/v2bx/resource-guard.sh"
    case "$action" in
        check|apply|status|rollback) ;;
        *) echo -e "${red}用法: V2bX resources [check|apply|status|rollback]${plain}"; return 2 ;;
    esac
    [[ -x "$helper" ]] || {
        echo -e "${red}资源保护组件不存在: $helper，请先升级安装脚本。${plain}"
        return 1
    }
    "$helper" "$action" "${@:3}"
}

run_config_generator() {
    local helper="/usr/local/share/v2bx/initconfig.sh" temp=""
    if [[ ! -f "$helper" ]]; then
        temp=$(mktemp)
        if ! curl --proto '=https' --tlsv1.2 -fLsS --retry 3 -o "$temp" "$script_base_url/initconfig.sh" ||
           ! bash -n "$temp"; then
            rm -f -- "$temp"
            echo -e "${red}配置生成组件下载失败或语法无效${plain}"
            return 1
        fi
        helper="$temp"
    fi
    # The helper defines the maintained generate_config_file implementation.
    source "$helper"
    generate_config_file
    [[ -n "$temp" ]] && rm -f -- "$temp"
}

update_shell() {
    local temp
    temp=$(mktemp /usr/bin/.V2bX.update.XXXXXX)
    if ! curl --proto '=https' --tlsv1.2 -fLsS --retry 3 -o "$temp" "$script_base_url/V2bX.sh" ||
       ! bash -n "$temp"; then
        rm -f -- "$temp"
        echo ""
        echo -e "${red}下载脚本失败，请检查本机能否连接 Github${plain}"
        before_show_menu
    else
        chmod 0755 "$temp"
        mv -f -- "$temp" /usr/bin/V2bX
        echo -e "${green}升级脚本成功，请重新运行脚本${plain}" && exit 0
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /usr/local/V2bX/V2bX ]]; then
        return 2
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(service V2bX status | awk '{print $3}')
        if [[ x"${temp}" == x"started" ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl status V2bX | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ x"${temp}" == x"running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_enabled() {
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(rc-update show | grep V2bX)
        if [[ x"${temp}" == x"" ]]; then
            return 1
        else
            return 0
        fi
    else
        temp=$(systemctl is-enabled V2bX)
        if [[ x"${temp}" == x"enabled" ]]; then
            return 0
        else
            return 1;
        fi
    fi
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        echo -e "${red}V2bX已安装，请不要重复安装${plain}"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        echo -e "${red}请先安装V2bX${plain}"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
        0)
            echo -e "V2bX状态: ${green}已运行${plain}"
            show_enable_status
            ;;
        1)
            echo -e "V2bX状态: ${yellow}未运行${plain}"
            show_enable_status
            ;;
        2)
            echo -e "V2bX状态: ${red}未安装${plain}"
    esac
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "是否开机自启: ${green}是${plain}"
    else
        echo -e "是否开机自启: ${red}否${plain}"
    fi
}

generate_x25519_key() {
    echo -n "正在生成 x25519 密钥："
    /usr/local/V2bX/V2bX x25519
    echo ""
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_V2bX_version() {
    echo -n "V2bX 版本："
    /usr/local/V2bX/V2bX version
    echo ""
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_usage() {
    echo "V2bX 管理脚本使用方法: "
    echo "------------------------------------------"
    echo "V2bX              - 显示管理菜单 (功能更多)"
    echo "V2bX start        - 启动 V2bX"
    echo "V2bX stop         - 停止 V2bX"
    echo "V2bX restart      - 重启 V2bX"
    echo "V2bX status       - 查看 V2bX 状态"
    echo "V2bX enable       - 设置 V2bX 开机自启"
    echo "V2bX disable      - 取消 V2bX 开机自启"
    echo "V2bX log          - 查看 V2bX 日志"
    echo "V2bX userlog [UUID] [分钟] - 查看阻断/滥用日志"
    echo "V2bX tune check|apply|rollback - 管理保守网络调优"
    echo "V2bX resources check|apply|status|rollback - 管理低内存保护"
    echo "V2bX x25519       - 生成 x25519 密钥"
    echo "V2bX generate     - 生成 V2bX 配置文件"
    echo "V2bX update       - 更新 V2bX"
    echo "V2bX update x.x.x - 安装 V2bX 指定版本"
    echo "V2bX install      - 安装 V2bX"
    echo "V2bX uninstall    - 卸载 V2bX"
    echo "V2bX version      - 查看 V2bX 版本"
    echo "------------------------------------------"
}

show_menu() {
    echo -e "
  ${green}V2bX 后端管理脚本，${plain}${red}不适用于docker${plain}
 --- https://github.com/rmomo5285-droid/V2bX ---
  ${green}0.${plain} 修改配置
————————————————
  ${green}1.${plain} 安装 V2bX
  ${green}2.${plain} 更新 V2bX
  ${green}3.${plain} 卸载 V2bX
————————————————
  ${green}4.${plain} 启动 V2bX
  ${green}5.${plain} 停止 V2bX
  ${green}6.${plain} 重启 V2bX
  ${green}7.${plain} 查看 V2bX 状态
  ${green}8.${plain} 查看 V2bX 日志
————————————————
  ${green}9.${plain} 设置 V2bX 开机自启
  ${green}10.${plain} 取消 V2bX 开机自启
————————————————
  ${green}11.${plain} 检查/应用保守网络调优 (不更换内核)
  ${green}12.${plain} 查看 V2bX 版本
  ${green}13.${plain} 生成 X25519 密钥
  ${green}14.${plain} 升级 V2bX 维护脚本
  ${green}15.${plain} 生成 V2bX 配置文件
  ${green}16.${plain} 查看用户阻断/滥用日志
  ${green}17.${plain} 检查/应用低内存原生 Hy2 保护
  ${green}18.${plain} 检测/安装支持 BBR 的内核（第三方，可能需重启）
  ${green}19.${plain} 退出脚本
 "
 #后续更新可加入上方字符串中
    show_status
    echo && read -rp "请输入选择 [0-19]: " num

    case "${num}" in
        0) config ;;
        1) check_uninstall && install ;;
        2) check_install && update ;;
        3) check_install && uninstall ;;
        4) check_install && start ;;
        5) check_install && stop ;;
        6) check_install && restart ;;
        7) check_install && status ;;
        8) check_install && show_log ;;
        9) check_install && enable ;;
        10) check_install && disable ;;
        11) tune_network tune apply ;;
        12) check_install && show_V2bX_version ;;
        13) check_install && generate_x25519_key ;;
        14) update_shell ;;
        15) run_config_generator ;;
        16) show_user_log userlog "" 60 ;;
        17) manage_resources resources apply ;;
        18) manage_bbr_kernel bbr install ;;
        19) exit ;;
        *) echo -e "${red}请输入正确的数字 [0-19]${plain}" ;;
    esac
}


if [[ $# > 0 ]]; then
    case $1 in
        "start") check_install 0 && start 0 ;;
        "stop") check_install 0 && stop 0 ;;
        "restart") check_install 0 && restart 0 ;;
        "status") check_install 0 && status 0 ;;
        "enable") check_install 0 && enable 0 ;;
        "disable") check_install 0 && disable 0 ;;
        "log") check_install 0 && show_log 0 ;;
        "userlog") check_install 0 && show_user_log "$@" ;;
        "tune") tune_network "$@" ;;
        "bbr") manage_bbr_kernel "$@" ;;
        "resources") manage_resources "$@" ;;
        "update") check_install 0 && update 0 $2 ;;
        "config") config $* ;;
        "generate") run_config_generator ;;
        "install") check_uninstall 0 && install 0 ;;
        "uninstall") check_install 0 && uninstall 0 ;;
        "x25519") check_install 0 && generate_x25519_key 0 ;;
        "version") check_install 0 && show_V2bX_version 0 ;;
        "update_shell") update_shell ;;
        *) show_usage
    esac
else
    show_menu
fi
