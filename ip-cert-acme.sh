#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
DEFAULT_CERT_DIR="/etc/ssl/ip-cert"
DEFAULT_RENEW_DAYS="4"
STATE_FILE="/etc/ip-cert-acme.conf"

if test -t 1; then
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_RESET='\033[0m'
else
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_RESET=''
fi

info() { printf '%b[信息]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%b[警告]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%b[错误]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() { error "$*"; exit 1; }

pause() {
    printf '\n'
    read -r -p "按 Enter 返回菜单..." _
}

confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local answer=""
    local suffix="[y/N]"
    [[ "$default" == "y" ]] && suffix="[Y/n]"
    read -r -p "$prompt $suffix " answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy]$ ]]
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行此脚本。"
    test -t 0 || die "此脚本需要交互式终端。请先下载，再使用 bash 执行；不要使用 curl | bash。"
}

ROOT_HOME="$(getent passwd 0 2>/dev/null | awk -F: '{print $6}' || true)"
ROOT_HOME="${ROOT_HOME:-/root}"
ACME_HOME="${ROOT_HOME}/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"

detect_os() {
    [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。当前仅支持 Debian/Ubuntu。"
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        debian | ubuntu) ;;
        *) die "当前系统为 ${ID:-unknown}，此版本仅支持 Debian/Ubuntu。" ;;
    esac
    info "检测到系统：${PRETTY_NAME:-${ID}}"
}

install_dependencies() {
    info "安装依赖：curl、socat、cron、openssl、ca-certificates..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl socat cron openssl ca-certificates

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now cron
    else
        service cron start
    fi

    for command_name in curl socat crontab openssl; do
        command -v "$command_name" >/dev/null 2>&1 || die "依赖安装后仍找不到：${command_name}"
    done
    info "依赖安装完成。"
}

install_acme() {
    if [[ -x "$ACME_BIN" ]]; then
        info "检测到已安装的 acme.sh：$ACME_BIN"
    else
        local email=""
        local temp_dir=""
        local installer=""

        read -r -p "请输入联系邮箱（可留空）：" email
        temp_dir="$(mktemp -d /tmp/ip-cert-acme-install.XXXXXX)"
        installer="${temp_dir}/get-acme.sh"

        info "从 acme.sh 官方安装地址下载安装器..."
        if ! curl -fsSL --proto '=https' --tlsv1.2 https://get.acme.sh -o "$installer"; then
            rm -rf -- "$temp_dir"
            die "下载安装器失败。"
        fi

        if [[ -n "$email" ]]; then
            HOME="$ROOT_HOME" sh "$installer" "email=${email}"
        else
            HOME="$ROOT_HOME" sh "$installer"
        fi
        rm -rf -- "$temp_dir"
    fi

    [[ -x "$ACME_BIN" ]] || die "acme.sh 安装失败：$ACME_BIN 不存在。"
    "$ACME_BIN" --set-default-ca --server letsencrypt
    "$ACME_BIN" --upgrade --auto-upgrade 1

    if ! crontab -l 2>/dev/null | grep -Fq "$ACME_BIN"; then
        "$ACME_BIN" --install-cronjob
    fi

    if ! "$ACME_BIN" --help 2>&1 | grep -q -- '--certificate-profile'; then
        die "当前 acme.sh 不支持 ACME certificate profile，请稍后更新后重试。"
    fi

    "$ACME_BIN" --version
    info "acme.sh 与每日自动续期 cron 已准备完成。"
}

is_ipv4() {
    local ip="$1"
    local a b c d extra
    IFS=. read -r a b c d extra <<<"$ip"
    [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
    done
}

is_ipv6() {
    local ip="$1"
    [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ ]]
}

detect_public_ipv4() {
    local url=""
    local result=""
    local urls=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.ident.me"
    )

    for url in "${urls[@]}"; do
        result="$(curl -4fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
        if is_ipv4 "$result"; then
            printf '%s\n' "$result"
            return 0
        fi
    done
    return 1
}

SELECTED_IPV4=""
SELECTED_IPV6=""

select_ips() {
    local detected=""
    local input=""

    detected="$(detect_public_ipv4 || true)"
    if [[ -n "$detected" ]]; then
        read -r -p "公网 IPv4 [${detected}]：" input
        input="${input:-$detected}"
    else
        read -r -p "请输入公网 IPv4：" input
    fi
    is_ipv4 "$input" || { error "IPv4 格式无效：$input"; return 1; }
    SELECTED_IPV4="$input"

    read -r -p "可选：请输入需要加入同一证书的公网 IPv6（没有则留空）：" input
    if [[ -n "$input" ]]; then
        is_ipv6 "$input" || { error "IPv6 格式无效：$input"; return 1; }
        SELECTED_IPV6="$input"
    else
        SELECTED_IPV6=""
    fi

    info "证书主标识：${SELECTED_IPV4}"
    [[ -n "$SELECTED_IPV6" ]] && info "附加标识：${SELECTED_IPV6}"
}

port_80_in_use() {
    if command -v ss >/dev/null 2>&1; then
        ss -H -lntp 2>/dev/null | awk '$4 ~ /:80$/ {found=1} END {exit !found}'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lntp 2>/dev/null | awk '$4 ~ /:80$/ {found=1} END {exit !found}'
    elif command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:80 -sTCP:LISTEN >/dev/null 2>&1
    else
        return 1
    fi
}

show_port_80_owner() {
    if command -v ss >/dev/null 2>&1; then
        ss -lntp 2>/dev/null | awk 'NR==1 || $4 ~ /:80$/'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lntp 2>/dev/null | awk 'NR==1 || $4 ~ /:80$/'
    elif command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:80 -sTCP:LISTEN || true
    fi
}

ensure_port_80_free() {
    if port_80_in_use; then
        error "TCP 80 当前被占用，standalone 验证和以后自动续期都会失败。"
        show_port_80_owner
        warn "请先调整占用端口的服务，或改用能够长期处理 HTTP-01 的其他方案。"
        return 1
    fi
    info "本机 TCP 80 当前空闲。请同时确认云安全组和系统防火墙允许公网访问 TCP 80。"
}

build_domain_args() {
    DOMAIN_ARGS=(-d "$SELECTED_IPV4")
    [[ -n "$SELECTED_IPV6" ]] && DOMAIN_ARGS+=(-d "$SELECTED_IPV6")
}

run_staging_test() {
    local test_root=""
    build_domain_args
    ensure_port_80_free || return 1

    test_root="$(mktemp -d /tmp/ip-cert-acme-staging.XXXXXX)"
    info "开始 Let's Encrypt staging 测试；测试证书不会写入正式配置。"

    if "$ACME_BIN" --issue \
        --staging \
        --server letsencrypt \
        "${DOMAIN_ARGS[@]}" \
        --standalone \
        --certificate-profile shortlived \
        --days "$DEFAULT_RENEW_DAYS" \
        --keylength ec-256 \
        --config-home "${test_root}/config" \
        --cert-home "${test_root}/certs"; then
        rm -rf -- "$test_root"
        info "staging 测试签发成功：公网 TCP 80 与 IP 验证正常。"
        return 0
    fi

    rm -rf -- "$test_root"
    error "staging 测试失败。请检查公网 TCP 80、防火墙、安全组和 NAT 转发。"
    return 1
}

acme_tracks_ip() {
    "$ACME_BIN" --list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$SELECTED_IPV4"
}

issue_production() {
    local issue_args=()
    build_domain_args
    ensure_port_80_free || return 1

    if acme_tracks_ip; then
        warn "acme.sh 已存在 ${SELECTED_IPV4} 的证书记录。"
        if confirm "是否强制重新签发？这会消耗 CA 速率限额" "n"; then
            issue_args+=(--force)
        else
            info "跳过重新签发，继续部署已有证书。"
            return 0
        fi
    fi

    info "开始申请正式 IP 证书..."
    "$ACME_BIN" --issue \
        --server letsencrypt \
        "${DOMAIN_ARGS[@]}" \
        --standalone \
        --certificate-profile shortlived \
        --days "$DEFAULT_RENEW_DAYS" \
        --keylength ec-256 \
        "${issue_args[@]}"

    info "正式证书签发成功。"
}

choose_reload_command() {
    local choice=""
    local custom=""

    printf '\n续期成功后，需要让使用证书的软件重新加载文件：\n'
    printf '  1) 重启 x-ui\n'
    printf '  2) 重载 Nginx\n'
    printf '  3) 重载 Caddy\n'
    printf '  4) 重载 Apache2\n'
    printf '  5) 输入自定义命令\n'
    printf '  6) 暂不重载（仅复制证书）\n'
    read -r -p "请选择 [1-6]：" choice

    case "$choice" in
        1) RELOAD_COMMAND="systemctl restart x-ui" ;;
        2) RELOAD_COMMAND="systemctl reload nginx" ;;
        3) RELOAD_COMMAND="systemctl reload caddy" ;;
        4) RELOAD_COMMAND="systemctl reload apache2" ;;
        5)
            read -r -p "请输入完整命令（将以 root 身份在每次续期后执行）：" custom
            [[ -n "$custom" ]] || { error "自定义命令不能为空。"; return 1; }
            RELOAD_COMMAND="$custom"
            ;;
        6)
            RELOAD_COMMAND=":"
            warn "未设置服务重载。以后必须补充，否则服务可能继续使用旧证书。"
            ;;
        *)
            error "选项无效。"
            return 1
            ;;
    esac

    info "续期后执行：${RELOAD_COMMAND}"
    confirm "确认使用该命令？" "y"
}

write_state() {
    local cert_dir="$1"
    local reload_command="$2"
    umask 077
    {
        printf 'PRIMARY_IP=%q\n' "$SELECTED_IPV4"
        printf 'SECONDARY_IPV6=%q\n' "$SELECTED_IPV6"
        printf 'CERT_DIR=%q\n' "$cert_dir"
        printf 'RELOAD_COMMAND=%q\n' "$reload_command"
    } >"$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

install_certificate_files() {
    local cert_dir=""
    local install_output=""
    local install_rc=0

    read -r -p "证书固定目录 [${DEFAULT_CERT_DIR}]：" cert_dir
    cert_dir="${cert_dir:-$DEFAULT_CERT_DIR}"
    [[ "$cert_dir" == /* && "$cert_dir" != "/" ]] || {
        error "证书目录必须是非根目录的绝对路径。"
        return 1
    }

    choose_reload_command || return 1

    install -d -m 700 "$cert_dir"
    [[ -e "${cert_dir}/privkey.pem" ]] || install -m 600 /dev/null "${cert_dir}/privkey.pem"
    [[ -e "${cert_dir}/fullchain.pem" ]] || install -m 644 /dev/null "${cert_dir}/fullchain.pem"

    set +e
    install_output="$("$ACME_BIN" --install-cert \
        -d "$SELECTED_IPV4" \
        --ecc \
        --force \
        --key-file "${cert_dir}/privkey.pem" \
        --fullchain-file "${cert_dir}/fullchain.pem" \
        --reloadcmd "$RELOAD_COMMAND" 2>&1)"
    install_rc=$?
    set -e
    printf '%s\n' "$install_output"

    [[ -s "${cert_dir}/privkey.pem" && -s "${cert_dir}/fullchain.pem" ]] || {
        error "固定路径中的证书文件不存在或为空。"
        return 1
    }

    chmod 700 "$cert_dir"
    chmod 600 "${cert_dir}/privkey.pem"
    chmod 644 "${cert_dir}/fullchain.pem"
    write_state "$cert_dir" "$RELOAD_COMMAND"

    if ((install_rc != 0)); then
        warn "证书已写入，但重载命令返回非零状态。请检查上方输出和服务状态。"
    else
        info "证书已部署，重载命令执行成功。"
    fi

    openssl x509 -in "${cert_dir}/fullchain.pem" -noout -subject -issuer -dates -ext subjectAltName
}

load_state() {
    PRIMARY_IP=""
    SECONDARY_IPV6=""
    CERT_DIR="$DEFAULT_CERT_DIR"
    RELOAD_COMMAND=""
    if [[ -r "$STATE_FILE" ]]; then
        # 文件由本脚本以 root:root 0600 创建。
        # shellcheck disable=SC1090
        . "$STATE_FILE"
    fi
}

show_status() {
    load_state
    printf '\n%b程序状态%b\n' "$C_BLUE" "$C_RESET"
    printf '脚本版本：%s\n' "$SCRIPT_VERSION"
    printf 'acme.sh：%s\n' "$ACME_BIN"
    if [[ -n "$PRIMARY_IP" ]]; then
        printf '已保存的证书 IP：%s' "$PRIMARY_IP"
        [[ -n "$SECONDARY_IPV6" ]] && printf '，%s' "$SECONDARY_IPV6"
        printf '\n'
    fi

    if [[ -x "$ACME_BIN" ]]; then
        "$ACME_BIN" --version
        printf '\nacme.sh 证书列表：\n'
        "$ACME_BIN" --list || true
    else
        warn "尚未安装 acme.sh。"
    fi

    printf '\nroot 的自动续期任务：\n'
    if ! crontab -l 2>/dev/null | grep -F 'acme.sh'; then
        warn "未找到 acme.sh cron。"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        printf '\ncron 服务：'
        systemctl is-active cron 2>/dev/null || true
    fi

    if [[ -n "$PRIMARY_IP" && -x "$ACME_BIN" ]]; then
        printf '\n续期信息：\n'
        "$ACME_BIN" --info -d "$PRIMARY_IP" --ecc 2>/dev/null \
            | grep -E 'Le_Domain=|Le_Alt=|Le_NextRenewTime=|Le_NextRenewTimeStr=|Le_ReloadCmd=|Le_RealFullChainPath=|Le_RealKeyPath=' || true
    fi

    if [[ -s "${CERT_DIR}/fullchain.pem" ]]; then
        printf '\n固定路径证书：%s\n' "${CERT_DIR}/fullchain.pem"
        openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -subject -issuer -dates -ext subjectAltName
    fi

    if port_80_in_use; then
        printf '\n'
        warn "TCP 80 当前被占用；到期续期时 standalone 验证可能失败。"
        show_port_80_owner
    else
        info "TCP 80 当前空闲。"
    fi
}

run_renewal_check() {
    [[ -x "$ACME_BIN" ]] || { error "尚未安装 acme.sh。"; return 1; }
    info "执行一次正常 cron 检查；未到续期时间的证书会被跳过。"
    "$ACME_BIN" --cron --home "$ACME_HOME"
}

force_renew() {
    load_state
    [[ -x "$ACME_BIN" ]] || { error "尚未安装 acme.sh。"; return 1; }
    [[ -n "$PRIMARY_IP" ]] || { error "未找到 $STATE_FILE，请先完成正式签发。"; return 1; }
    ensure_port_80_free || return 1

    warn "强制续期会立即向 Let's Encrypt 创建新订单并消耗速率限额。"
    local typed=""
    read -r -p "如确定继续，请输入 RENEW：" typed
    [[ "$typed" == "RENEW" ]] || { info "已取消。"; return 0; }
    "$ACME_BIN" --renew -d "$PRIMARY_IP" --ecc --force
}

update_acme() {
    [[ -x "$ACME_BIN" ]] || { error "尚未安装 acme.sh。"; return 1; }
    "$ACME_BIN" --upgrade --auto-upgrade 1
    "$ACME_BIN" --version
}

full_wizard() {
    detect_os
    install_dependencies
    install_acme
    select_ips || return 1
    ensure_port_80_free || return 1

    if confirm "是否先使用 staging 测试公网验证？推荐执行" "y"; then
        run_staging_test || return 1
    fi

    issue_production || return 1
    install_certificate_files || return 1

    printf '\n'
    info "配置完成。"
    show_status
    warn "IP 证书有效期约 6 天，请保持公网 TCP 80 可达，并定期检查续期状态。"
}

show_menu() {
    clear 2>/dev/null || true
    printf '%bIP Certificate ACME%b  v%s\n' "$C_BLUE" "$C_RESET" "$SCRIPT_VERSION"
    printf '使用 acme.sh 为公网 IP 申请并自动续期 Let\x27s Encrypt 短期证书\n\n'
    printf '  1) 一键安装、测试、正式签发并配置自动续期\n'
    printf '  2) 仅执行 staging 验证测试\n'
    printf '  3) 正式签发并部署证书\n'
    printf '  4) 查看证书与自动续期状态\n'
    printf '  5) 立即运行一次正常续期检查\n'
    printf '  6) 强制续期（谨慎）\n'
    printf '  7) 更新 acme.sh\n'
    printf '  0) 退出\n\n'
}

main() {
    require_root

    while true; do
        local choice=""
        show_menu
        read -r -p "请选择 [0-7]：" choice
        case "$choice" in
            1) full_wizard || warn "流程未完成，请根据上方提示处理后重试。"; pause ;;
            2)
                [[ -x "$ACME_BIN" ]] || { error "请先运行选项 1 安装 acme.sh。"; pause; continue; }
                if select_ips; then
                    run_staging_test || warn "staging 测试未通过。"
                else
                    warn "IP 输入未完成。"
                fi
                pause
                ;;
            3)
                [[ -x "$ACME_BIN" ]] || { error "请先运行选项 1 安装 acme.sh。"; pause; continue; }
                if select_ips && issue_production; then
                    install_certificate_files || warn "证书部署未完成。"
                else
                    warn "正式签发未完成。"
                fi
                pause
                ;;
            4) show_status; pause ;;
            5) run_renewal_check || true; pause ;;
            6) force_renew || true; pause ;;
            7) update_acme || true; pause ;;
            0) exit 0 ;;
            *) warn "无效选项。"; sleep 1 ;;
        esac
    done
}

main "$@"
