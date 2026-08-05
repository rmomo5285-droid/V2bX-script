#!/usr/bin/env bash
set -Eeuo pipefail

mode="check"
assume_yes=0
sysctl_cmd="${V2BX_BBR_SYSCTL_CMD:-sysctl}"
virt_cmd="${V2BX_BBR_VIRT_CMD:-systemd-detect-virt}"
curl_cmd="${V2BX_BBR_CURL_CMD:-curl}"
bash_cmd="${V2BX_BBR_BASH_CMD:-bash}"
tuner_path="${V2BX_BBR_TUNER_PATH:-/usr/local/share/v2bx/network-tune.sh}"

# Keep the reviewed entry script immutable. The third-party installer still
# selects distribution-specific kernel assets interactively at execution time.
installer_commit="420c87c0f4dd43771a68f95cb47413cc50f23ad1"
installer_url="${V2BX_BBR_SCRIPT_URL:-https://raw.githubusercontent.com/ylx2016/Linux-NetSpeed/${installer_commit}/tcpx.sh}"
installer_sha256="${V2BX_BBR_SCRIPT_SHA256:-1245503edf81ec3b8e3d212b6fdb0d78979be644cea084d3a2fefbf33107c38f}"

usage() {
    cat <<'EOF'
Usage: bbr-kernel.sh [check | install] [--yes]

Checks whether the running kernel exposes TCP BBR. If BBR is missing, install
opens the pinned ylx2016/Linux-NetSpeed kernel installer after SHA-256 and Bash
syntax verification. Kernel selection remains interactive and may require a
reboot. This helper never runs automatically during V2bX install or migration.

Commands:
  check       Read-only BBR and virtualization check (default)
  install     Run the verified third-party kernel installer when BBR is absent

Options:
  --yes       Skip this wrapper's confirmation (third-party prompts remain)
  -h, --help  Show this help
EOF
}

while (($# > 0)); do
    case "$1" in
        check|--check)
            mode="check"
            shift
            ;;
        install|--install)
            mode="install"
            shift
            ;;
        --yes|-y)
            assume_yes=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

command_available() {
    [[ -n "$1" ]] && command -v "$1" >/dev/null 2>&1
}

available_algorithms() {
    "$sysctl_cmd" -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true
}

bbr_available() {
    local algorithms
    algorithms=" $(available_algorithms) "
    [[ "$algorithms" == *" bbr "* ]]
}

container_type() {
    local detected=""
    if command_available "$virt_cmd"; then
        detected=$("$virt_cmd" --container 2>/dev/null || true)
    fi
    printf '%s\n' "$detected"
}

show_status() {
    local algorithms container
    algorithms=$(available_algorithms)
    container=$(container_type)
    printf 'Running kernel: %s\n' "$(uname -r)"
    printf 'Available TCP congestion controls: %s\n' "${algorithms:-unknown}"
    if [[ -n "$container" && "$container" != "none" ]]; then
        printf 'Container virtualization: %s\n' "$container"
    else
        echo 'Container virtualization: none detected'
    fi
}

if [[ "$mode" == "check" ]]; then
    show_status
    if bbr_available; then
        echo 'OK: the running kernel exposes BBR; use V2bX tune apply to configure it'
        exit 0
    fi
    if [[ -n "$(container_type)" && "$(container_type)" != "none" ]]; then
        echo 'UNSUPPORTED: a container cannot replace its host kernel' >&2
        exit 4
    fi
    echo 'MISSING: the running kernel does not expose BBR; V2bX bbr install can open the optional kernel installer' >&2
    exit 3
fi

if [[ "${V2BX_BBR_SKIP_ROOT_CHECK:-0}" != "1" && "$(id -u)" -ne 0 ]]; then
    echo 'ERROR: install must run as root' >&2
    exit 1
fi
for required in "$sysctl_cmd" "$curl_cmd" "$bash_cmd" sha256sum; do
    command_available "$required" || { echo "ERROR: required command not found: $required" >&2; exit 1; }
done

show_status
if bbr_available; then
    echo 'ALREADY AVAILABLE: no kernel installer was run'
    if [[ -x "$tuner_path" ]]; then
        echo 'Next step: V2bX tune apply'
    fi
    exit 0
fi

container=$(container_type)
if [[ -n "$container" && "$container" != "none" ]]; then
    echo "ERROR: cannot install a host kernel from container virtualization: $container" >&2
    exit 4
fi

cat <<'EOF'
WARNING: this opens a third-party interactive kernel installer.
- It can install a new kernel and change the boot selection.
- A reboot may be required; keep provider console access available.
- V2bX is not stopped or modified by this helper.
- The reviewed entry script is pinned and hash-verified, while kernel release
  assets are selected and downloaded by the third-party installer at runtime.
EOF
if ((assume_yes == 0)); then
    read -rp 'Type INSTALL BBR KERNEL to continue: ' confirmation
    [[ "$confirmation" == 'INSTALL BBR KERNEL' ]] || {
        echo 'CANCELLED: no change was made'
        exit 1
    }
fi

temp_script=$(mktemp "${TMPDIR:-/tmp}/v2bx-tcpx.XXXXXX.sh")
cleanup() {
    rm -f -- "$temp_script"
}
trap cleanup EXIT

"$curl_cmd" --proto '=https' --tlsv1.2 -fLsS --retry 3 --connect-timeout 15 \
    --max-time 120 -o "$temp_script" "$installer_url"
actual_sha256=$(sha256sum "$temp_script" | awk '{print $1}')
if [[ ! "$installer_sha256" =~ ^[0-9a-fA-F]{64}$ || "${actual_sha256,,}" != "${installer_sha256,,}" ]]; then
    echo 'ERROR: third-party BBR installer SHA-256 mismatch; refusing execution' >&2
    exit 1
fi
"$bash_cmd" -n "$temp_script"

echo "VERIFIED: ylx2016/Linux-NetSpeed tcpx.sh at $installer_commit"
"$bash_cmd" "$temp_script"

if bbr_available; then
    echo 'BBR AVAILABLE: run V2bX tune apply to configure BBR, fq, ECN, and buffers'
else
    echo 'REBOOT MAY BE REQUIRED: after reboot run V2bX bbr check, then V2bX tune apply'
fi
