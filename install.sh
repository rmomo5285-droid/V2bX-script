#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

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

arch=$(uname -m)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi

echo "架构: ${arch}"

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
    exit 2
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

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release wget curl unzip tar crontabs socat ca-certificates jq openssl logrotate iproute procps-ng kmod -y >/dev/null 2>&1
        update-ca-trust force-enable >/dev/null 2>&1
    elif [[ x"${release}" == x"alpine" ]]; then
        apk add wget curl unzip tar socat ca-certificates jq openssl logrotate iproute2 procps kmod >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"debian" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat ca-certificates jq openssl logrotate iproute2 procps kmod -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"ubuntu" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat jq openssl logrotate iproute2 procps kmod -y >/dev/null 2>&1
        apt-get install ca-certificates wget -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"arch" ]]; then
        pacman -Sy --noconfirm >/dev/null 2>&1
        pacman -S --noconfirm --needed wget curl unzip tar cron socat jq openssl logrotate iproute2 procps-ng kmod >/dev/null 2>&1
        pacman -S --noconfirm --needed ca-certificates wget >/dev/null 2>&1
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

install_V2bX_safe() {
    local requested_version="${1:-}" script_ref="${V2BX_SCRIPT_REF:-v0.1.3}"
    local script_base="https://raw.githubusercontent.com/rmomo5285-droid/V2bX-script/${script_ref}"
    local migration migration_manifest temp_dir release_tag asset archive checksum expected actual helper name manifest

    # Existing production installs use the transactional migrator. It keeps the
    # old service running while downloads and validation are performed.
    if [[ -x /usr/local/V2bX/V2bX && -f /etc/V2bX/config.json ]]; then
        migration=$(mktemp)
        migration_manifest=$(mktemp)
        if ! curl --proto '=https' --tlsv1.2 -fLsS --retry 3 \
            -o "$migration" "$script_base/migrate-to-rmomo-v2bx.sh" ||
           ! curl --proto '=https' --tlsv1.2 -fLsS --retry 3 \
            -o "$migration_manifest" "$script_base/components.sha256"; then
            rm -f -- "$migration" "$migration_manifest"
            echo -e "${red}无法下载或校验事务式迁移脚本${plain}"
            return 1
        fi
        expected=$(awk '$2 == "migrate-to-rmomo-v2bx.sh" || $2 == "*migrate-to-rmomo-v2bx.sh" { print $1; exit }' "$migration_manifest")
        actual=$(sha256sum "$migration" | awk '{print $1}')
        if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ || "${actual,,}" != "${expected,,}" ]] || ! bash -n "$migration"; then
            rm -f -- "$migration" "$migration_manifest"
            echo -e "${red}事务式迁移脚本 SHA-256 或语法校验失败${plain}"
            return 1
        fi
        if [[ -n "$requested_version" ]]; then
            V2BX_SCRIPT_REF="$script_ref" bash "$migration" apply --version "$requested_version"
        else
            V2BX_SCRIPT_REF="$script_ref" bash "$migration" apply
        fi
        local result=$?
        rm -f -- "$migration" "$migration_manifest"
        return "$result"
    fi

    if [[ -n "$requested_version" ]]; then
        release_tag="$requested_version"
    else
        release_tag=$(curl --proto '=https' --tlsv1.2 -fLsS --retry 3 \
            "https://api.github.com/repos/rmomo5285-droid/V2bX/releases/latest" |
            sed -nE 's/^[[:space:]]*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' | head -n1)
    fi
    [[ "$release_tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
        echo -e "${red}无法解析有效的 V2bX release 版本${plain}"
        return 1
    }

    asset="V2bX-linux-${arch}.zip"
    temp_dir=$(mktemp -d /usr/local/.v2bx-install.XXXXXX)
    archive="$temp_dir/$asset"
    checksum="$archive.sha256"
    mkdir "$temp_dir/unpack" "$temp_dir/scripts"
    echo -e "下载并校验 rmomo5285-droid/V2bX ${green}${release_tag}${plain}"
    if ! curl --proto '=https' --tlsv1.2 -fL --retry 3 --connect-timeout 15 --max-time 600 \
            -o "$archive" "https://github.com/rmomo5285-droid/V2bX/releases/download/$release_tag/$asset" ||
       ! curl --proto '=https' --tlsv1.2 -fL --retry 3 --connect-timeout 15 --max-time 120 \
            -o "$checksum" "https://github.com/rmomo5285-droid/V2bX/releases/download/$release_tag/$asset.sha256"; then
        rm -rf -- "$temp_dir"
        echo -e "${red}release 或 SHA-256 下载失败，未修改安装目录${plain}"
        return 1
    fi
    expected=$(awk -v asset="$asset" '$2 == asset || $2 == "*" asset { print $1; exit }' "$checksum")
    actual=$(sha256sum "$archive" | awk '{print $1}')
    if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ || "${actual,,}" != "${expected,,}" ]] ||
       ! unzip -tq "$archive" >/dev/null ||
       ! unzip -q "$archive" -d "$temp_dir/unpack" ||
       [[ ! -f "$temp_dir/unpack/V2bX" ]]; then
        rm -rf -- "$temp_dir"
        echo -e "${red}release 校验或解压失败，未修改安装目录${plain}"
        return 1
    fi
    chmod 0755 "$temp_dir/unpack/V2bX"
    if ! "$temp_dir/unpack/V2bX" version >/dev/null 2>&1; then
        rm -rf -- "$temp_dir"
        echo -e "${red}release 中的 V2bX 无法执行${plain}"
        return 1
    fi

    manifest="$temp_dir/components.sha256"
    if ! curl --proto '=https' --tlsv1.2 -fLsS --retry 3 -o "$manifest" "$script_base/components.sha256"; then
        rm -rf -- "$temp_dir"
        echo -e "${red}组件校验清单下载失败，未安装${plain}"
        return 1
    fi
    for name in V2bX.sh initconfig.sh bbr-kernel.sh network-tune.sh resource-guard.sh fix-legacy-hy2-config.sh migrate-to-rmomo-v2bx.sh V2bX.service v2bx.logrotate; do
        helper="$temp_dir/scripts/$name"
        if ! curl --proto '=https' --tlsv1.2 -fLsS --retry 3 -o "$helper" "$script_base/$name"; then
            rm -rf -- "$temp_dir"
            echo -e "${red}组件 $name 下载失败，未安装${plain}"
            return 1
        fi
        expected=$(awk -v component="$name" '$2 == component || $2 == "*" component { print $1; exit }' "$manifest")
        actual=$(sha256sum "$helper" | awk '{print $1}')
        if [[ ! "$expected" =~ ^[0-9a-fA-F]{64}$ || "${actual,,}" != "${expected,,}" ]] ||
           { [[ "$name" == *.sh ]] && ! bash -n "$helper"; }; then
            rm -rf -- "$temp_dir"
            echo -e "${red}组件 $name 的 SHA-256 或语法无效，未安装${plain}"
            return 1
        fi
        chmod 0755 "$helper"
    done

    mkdir -p /usr/local/V2bX /etc/V2bX /usr/local/share/v2bx /var/log/V2bX
    install -m 0755 "$temp_dir/unpack/V2bX" /usr/local/V2bX/.V2bX.new
    mv -f /usr/local/V2bX/.V2bX.new /usr/local/V2bX/V2bX
    for name in geoip.dat geosite.dat dns.json route.json custom_outbound.json custom_inbound.json; do
        if [[ -f "$temp_dir/unpack/$name" ]]; then
            if [[ "$name" == *.dat ]]; then
                install -m 0644 "$temp_dir/unpack/$name" "/etc/V2bX/$name"
            elif [[ ! -f "/etc/V2bX/$name" ]]; then
                install -m 0644 "$temp_dir/unpack/$name" "/etc/V2bX/$name"
            fi
        fi
    done
    if [[ ! -f /etc/V2bX/config.json ]]; then
        install -m 0600 "$temp_dir/unpack/config.json" /etc/V2bX/config.json
    fi
    install -m 0755 "$temp_dir/scripts/V2bX.sh" /usr/bin/V2bX
    for name in initconfig.sh bbr-kernel.sh network-tune.sh resource-guard.sh fix-legacy-hy2-config.sh migrate-to-rmomo-v2bx.sh; do
        install -m 0755 "$temp_dir/scripts/$name" "/usr/local/share/v2bx/$name"
    done
    ln -sfn /usr/bin/V2bX /usr/bin/v2bx

    install -m 0644 "$temp_dir/scripts/v2bx.logrotate" /etc/logrotate.d/v2bx

    if [[ x"${release}" == x"alpine" ]]; then
        cat > /etc/init.d/V2bX <<'EOF'
#!/sbin/openrc-run
name="V2bX"
description="V2bX"
command="/usr/local/V2bX/V2bX"
command_args="server"
command_user="root"
pidfile="/run/V2bX.pid"
command_background="yes"
depend() { need net; }
EOF
        chmod 0755 /etc/init.d/V2bX
        rc-update add V2bX default
    else
        install -m 0644 "$temp_dir/scripts/V2bX.service" /etc/systemd/system/V2bX.service
        systemctl daemon-reload
        systemctl enable V2bX
    fi

    rm -rf -- "$temp_dir"
    echo -e "${green}V2bX ${release_tag} 已安装，release 已通过 SHA-256 校验${plain}"
    echo "阻断日志按用户和原因限频；每个文件按 10 MiB x 5、最长 7 天轮转。"

    read -rp "是否现在运行安全配置生成向导？(y/n): " if_generate
    if [[ "$if_generate" == [Yy] ]]; then
        source /usr/local/share/v2bx/initconfig.sh
        generate_config_file
    else
        echo "请修改 /etc/V2bX/config.json 后执行: V2bX restart"
    fi

    if [[ "${V2BX_ENABLE_RESOURCE_GUARD:-0}" == "1" ]]; then
        /usr/local/share/v2bx/resource-guard.sh apply ||
            echo -e "${yellow}低内存保护不适用或未能应用，V2bX 安装不受影响${plain}"
    else
        echo "内存硬限制默认不启用；仅在实测业务峰值后手工执行 V2bX resources apply。"
    fi
    if [[ "${V2BX_SKIP_NETWORK_TUNING:-0}" != "1" ]]; then
        /usr/local/share/v2bx/network-tune.sh apply ||
            echo -e "${yellow}当前内核不支持全部保守网络调优；可执行 V2bX bbr check，确认缺失后再运行 V2bX bbr install${plain}"
    fi
}

echo -e "${green}开始安装${plain}"
install_base
install_V2bX_safe "${1:-}"
