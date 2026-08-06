#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_VERSION="1.1.0"
DEFAULT_CERT_DIR="/etc/ssl/ip-cert"
DEFAULT_RENEW_DAYS="4"
STATE_FILE="/etc/ip-cert-acme.conf"
CONFIG_DIR="/etc/ip-cert-acme"
TARGETS_FILE="${CONFIG_DIR}/targets.conf"
BACKUP_DIR="/var/lib/ip-cert-acme/backups"
RUNTIME_SCRIPT="/usr/local/sbin/ip-cert-acme"
DEPLOY_COMMAND="${RUNTIME_SCRIPT} --deploy"

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
}

require_tty() {
    test -t 0 || die "此脚本需要交互式终端。请先下载，再使用 bash 执行；不要使用 curl | bash。"
}

ROOT_HOME="$(getent passwd 0 2>/dev/null | awk -F: '{print $6}' || true)"
ROOT_HOME="${ROOT_HOME:-/root}"
ACME_HOME="${ROOT_HOME}/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"

TARGET_TYPES=()
TARGET_NAMES=()
TARGET_CERT_PATHS=()
TARGET_KEY_PATHS=()
TARGET_RELOAD_COMMANDS=()

add_target() {
    [[ $# -eq 5 ]] || return 1
    TARGET_TYPES+=("$1")
    TARGET_NAMES+=("$2")
    TARGET_CERT_PATHS+=("$3")
    TARGET_KEY_PATHS+=("$4")
    TARGET_RELOAD_COMMANDS+=("$5")
}

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
    info "证书主标识：${SELECTED_IPV4}"
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

reset_target_arrays() {
    TARGET_TYPES=()
    TARGET_NAMES=()
    TARGET_CERT_PATHS=()
    TARGET_KEY_PATHS=()
    TARGET_RELOAD_COMMANDS=()
}

ensure_deploy_layout() {
    install -d -m 700 "$CONFIG_DIR" "$BACKUP_DIR"
}

install_runtime_script() {
    local source_script="${BASH_SOURCE[0]}"
    [[ -r "$source_script" ]] || { error "无法读取当前脚本：$source_script"; return 1; }
    if [[ -e "$RUNTIME_SCRIPT" ]] \
        && [[ "$(readlink -f "$source_script")" == "$(readlink -f "$RUNTIME_SCRIPT")" ]]; then
        chmod 700 "$RUNTIME_SCRIPT"
        return 0
    fi
    install -D -m 700 "$source_script" "$RUNTIME_SCRIPT"
    info "部署分发器已安装：$RUNTIME_SCRIPT"
}

load_targets() {
    local owner=""
    local mode=""
    reset_target_arrays
    [[ -s "$TARGETS_FILE" ]] || return 0

    owner="$(stat -c '%u' "$TARGETS_FILE" 2>/dev/null || true)"
    mode="$(stat -c '%a' "$TARGETS_FILE" 2>/dev/null || true)"
    [[ "$owner" == "0" ]] || { error "$TARGETS_FILE 必须归 root 所有。"; return 1; }
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || { error "无法确认 $TARGETS_FILE 的权限。"; return 1; }
    (( (8#$mode & 022) == 0 )) || { error "$TARGETS_FILE 不能允许组或其他用户写入。"; return 1; }

    # 配置文件仅由本脚本以 root:root 0600 和 shell 转义后的参数生成。
    # shellcheck disable=SC1090
    . "$TARGETS_FILE"
}

show_deploy_targets() {
    local i=0
    load_targets || return 1
    printf '\n已配置的部署目标：\n'
    if ((${#TARGET_TYPES[@]} == 0)); then
        printf '  （无）\n'
        return 0
    fi
    for i in "${!TARGET_TYPES[@]}"; do
        printf '  %d) %s [%s]\n' "$((i + 1))" "${TARGET_NAMES[$i]}" "${TARGET_TYPES[$i]}"
        if [[ "${TARGET_TYPES[$i]}" == "copy" ]]; then
            printf '     证书：%s\n' "${TARGET_CERT_PATHS[$i]}"
            printf '     私钥：%s\n' "${TARGET_KEY_PATHS[$i]}"
        fi
        printf '     命令：%s\n' "${TARGET_RELOAD_COMMANDS[$i]}"
    done
}

validate_certificate_pair() {
    local cert_file="$1"
    local key_file="$2"
    local cert_pub=""
    local key_pub=""

    [[ -s "$cert_file" && -s "$key_file" ]] || return 1
    openssl x509 -in "$cert_file" -noout >/dev/null 2>&1 || return 1
    openssl pkey -in "$key_file" -noout >/dev/null 2>&1 || return 1
    cert_pub="$(openssl x509 -in "$cert_file" -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | sha256sum | awk '{print $1}')"
    key_pub="$(openssl pkey -in "$key_file" -pubout -outform DER 2>/dev/null \
        | sha256sum | awk '{print $1}')"
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

run_target_command() {
    local name="$1"
    local command_text="$2"
    info "执行部署目标命令 [${name}]：${command_text}"
    bash -c "$command_text"
}

deploy_copy_target() {
    local name="$1"
    local cert_path="$2"
    local key_path="$3"
    local reload_command="$4"
    local source_cert="${CERT_DIR}/fullchain.pem"
    local source_key="${CERT_DIR}/privkey.pem"
    local cert_dir=""
    local key_dir=""
    local cert_tmp=""
    local key_tmp=""
    local cert_mode="600"
    local key_mode="600"
    local cert_owner="0:0"
    local key_owner="0:0"
    local safe_name=""
    local target_backup_dir=""
    local had_backup=0

    [[ "$cert_path" == /* && "$key_path" == /* && "$cert_path" != "/" && "$key_path" != "/" ]] || {
        error "部署目标路径必须是非根目录的绝对路径：$name"
        return 1
    }
    cert_dir="$(dirname -- "$cert_path")"
    key_dir="$(dirname -- "$key_path")"
    [[ -d "$cert_dir" && -d "$key_dir" ]] || {
        error "部署目标目录不存在：$name"
        return 1
    }

    [[ -e "$cert_path" ]] && cert_mode="$(stat -c '%a' "$cert_path")" cert_owner="$(stat -c '%u:%g' "$cert_path")"
    [[ -e "$key_path" ]] && key_mode="$(stat -c '%a' "$key_path")" key_owner="$(stat -c '%u:%g' "$key_path")"

    safe_name="$(printf '%s' "$name" | tr -cs 'A-Za-z0-9._-' '_')"
    target_backup_dir="${BACKUP_DIR}/${safe_name}/$(date '+%Y%m%d-%H%M%S')"
    if [[ -s "$cert_path" && -s "$key_path" ]]; then
        install -d -m 700 "$target_backup_dir"
        cp -a -- "$cert_path" "${target_backup_dir}/certificate"
        cp -a -- "$key_path" "${target_backup_dir}/private-key"
        had_backup=1
    fi

    cert_tmp="$(mktemp "${cert_path}.tmp.XXXXXX")"
    key_tmp="$(mktemp "${key_path}.tmp.XXXXXX")"
    if ! install -m "$cert_mode" "$source_cert" "$cert_tmp" \
        || ! install -m "$key_mode" "$source_key" "$key_tmp" \
        || ! chown "$cert_owner" "$cert_tmp" \
        || ! chown "$key_owner" "$key_tmp" \
        || ! validate_certificate_pair "$cert_tmp" "$key_tmp"; then
        rm -f -- "$cert_tmp" "$key_tmp"
        error "准备部署文件失败：$name"
        return 1
    fi

    mv -f -- "$cert_tmp" "$cert_path"
    mv -f -- "$key_tmp" "$key_path"
    if run_target_command "$name" "$reload_command"; then
        info "部署成功：$name"
        return 0
    fi

    error "重载失败，开始回滚：$name"
    if ((had_backup)); then
        cp -a -- "${target_backup_dir}/certificate" "$cert_path"
        cp -a -- "${target_backup_dir}/private-key" "$key_path"
        run_target_command "${name}（回滚后）" "$reload_command" || true
    else
        rm -f -- "$cert_path" "$key_path"
    fi
    return 1
}

deploy_targets() {
    local i=0
    local failures=0
    load_state
    ensure_deploy_layout
    validate_certificate_pair "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/privkey.pem" || {
        error "统一证书源不存在、格式无效或证书与私钥不匹配。"
        return 1
    }
    load_targets || return 1

    if ((${#TARGET_TYPES[@]} == 0)); then
        warn "没有配置部署目标；统一证书源已更新，但没有服务被重载。"
        return 0
    fi

    for i in "${!TARGET_TYPES[@]}"; do
        case "${TARGET_TYPES[$i]}" in
            copy)
                deploy_copy_target \
                    "${TARGET_NAMES[$i]}" \
                    "${TARGET_CERT_PATHS[$i]}" \
                    "${TARGET_KEY_PATHS[$i]}" \
                    "${TARGET_RELOAD_COMMANDS[$i]}" || failures=$((failures + 1))
                ;;
            reload)
                run_target_command "${TARGET_NAMES[$i]}" "${TARGET_RELOAD_COMMANDS[$i]}" \
                    || failures=$((failures + 1))
                ;;
            *)
                error "未知部署目标类型：${TARGET_TYPES[$i]}"
                failures=$((failures + 1))
                ;;
        esac
    done

    if ((failures > 0)); then
        error "${failures} 个部署目标失败。"
        return 1
    fi
    info "全部部署目标处理完成。"
}

append_target_config() {
    local file="$1"
    shift
    printf 'add_target %q %q %q %q %q\n' "$@" >>"$file"
    add_target "$@"
}

discover_1panel_panel_dirs() {
    local root=""
    local cert=""
    for root in /opt/1panel /usr/local/1panel /data/1panel; do
        [[ -d "$root" ]] || continue
        while IFS= read -r cert; do
            [[ -f "${cert%/server.crt}/server.key" ]] && dirname -- "$cert"
        done < <(find "$root" -maxdepth 4 -type f -path '*/secret/server.crt' -print 2>/dev/null)
    done | sort -u
}

add_1panel_panel_target() {
    local config_file="$1"
    local panel_dir=""
    local input=""
    local dirs=()
    local i=0

    command -v 1pctl >/dev/null 2>&1 || {
        warn "未找到 1pctl；可改用自定义文件目标。"
        return 1
    }
    mapfile -t dirs < <(discover_1panel_panel_dirs)
    if ((${#dirs[@]} == 1)); then
        panel_dir="${dirs[0]}"
        info "检测到 1Panel 面板证书目录：$panel_dir"
    elif ((${#dirs[@]} > 1)); then
        printf '检测到多个 1Panel 面板证书目录：\n'
        for i in "${!dirs[@]}"; do printf '  %d) %s\n' "$((i + 1))" "${dirs[$i]}"; done
        read -r -p "请选择编号：" input
        [[ "$input" =~ ^[0-9]+$ ]] && ((input >= 1 && input <= ${#dirs[@]})) || return 1
        panel_dir="${dirs[$((input - 1))]}"
    else
        read -r -p "未自动发现，请输入 1Panel secret 目录（留空取消）：" panel_dir
        [[ -n "$panel_dir" ]] || return 1
    fi

    [[ -f "${panel_dir}/server.crt" && -f "${panel_dir}/server.key" ]] || {
        error "目录中缺少 server.crt 或 server.key：$panel_dir"
        return 1
    }
    append_target_config "$config_file" copy "1Panel 面板" \
        "${panel_dir}/server.crt" "${panel_dir}/server.key" "1pctl restart"
}

discover_1panel_site_certs() {
    local root=""
    local cert=""
    for root in /opt/1panel /usr/local/1panel /data/1panel; do
        [[ -d "$root" ]] || continue
        while IFS= read -r cert; do
            [[ -f "${cert%/fullchain.pem}/privkey.pem" ]] && printf '%s\n' "$cert"
        done < <(find "$root" -maxdepth 8 -type f -path '*/www/sites/*/ssl/fullchain.pem' -print 2>/dev/null)
    done | sort -u
}

detect_openresty_containers() {
    command -v docker >/dev/null 2>&1 || return 0
    docker ps --format '{{.Names}}|{{.Image}}' 2>/dev/null \
        | awk -F'|' 'tolower($0) ~ /(openresty|nginx)/ {print $1}'
}

add_1panel_site_targets() {
    local config_file="$1"
    local cert=""
    local site_name=""
    local selected=0
    local container=""
    local input=""
    local reload_command=""
    local certs=()
    local containers=()
    local i=0

    mapfile -t certs < <(discover_1panel_site_certs)
    if ((${#certs[@]} == 0)); then
        warn "未发现 1Panel 网站证书目录。"
        return 1
    fi

    warn "只有通过该公网 IP 访问并且确实需要 IP 证书的网站才应选择。"
    for cert in "${certs[@]}"; do
        site_name="$(basename "$(dirname "$(dirname "$cert")")")"
        if confirm "把 IP 证书同步到网站 ${site_name}？" "n"; then
            append_target_config "$config_file" copy "1Panel 网站 ${site_name}" \
                "$cert" "${cert%/fullchain.pem}/privkey.pem" ":"
            selected=$((selected + 1))
        fi
    done
    ((selected > 0)) || return 0

    mapfile -t containers < <(detect_openresty_containers)
    if ((${#containers[@]} == 1)); then
        container="${containers[0]}"
        info "检测到 OpenResty/Nginx 容器：$container"
    elif ((${#containers[@]} > 1)); then
        printf '检测到多个 OpenResty/Nginx 容器：\n'
        for i in "${!containers[@]}"; do printf '  %d) %s\n' "$((i + 1))" "${containers[$i]}"; done
        read -r -p "请选择编号：" input
        [[ "$input" =~ ^[0-9]+$ ]] && ((input >= 1 && input <= ${#containers[@]})) || return 1
        container="${containers[$((input - 1))]}"
    else
        read -r -p "未检测到容器，请输入 OpenResty/Nginx 容器名（留空改用自定义命令）：" container
    fi

    if [[ -n "$container" ]]; then
        printf -v reload_command 'docker exec -i %q nginx -t && docker exec -i %q nginx -s reload' \
            "$container" "$container"
    else
        read -r -p "请输入网站服务检查并重载命令：" reload_command
        [[ -n "$reload_command" ]] || return 1
    fi
    append_target_config "$config_file" reload "1Panel 网站服务" "" "" "$reload_command"
}

add_common_service_target() {
    local config_file="$1"
    local service_name="$2"
    local action="$3"
    command -v systemctl >/dev/null 2>&1 || { error "当前系统没有 systemctl。"; return 1; }
    systemctl cat "$service_name" >/dev/null 2>&1 || {
        error "未找到 systemd 服务：$service_name"
        return 1
    }
    append_target_config "$config_file" reload "$service_name" "" "" \
        "systemctl ${action} ${service_name}"
}

add_custom_copy_target() {
    local config_file="$1"
    local name=""
    local cert_path=""
    local key_path=""
    local command_text=""
    read -r -p "目标名称：" name
    read -r -p "目标完整证书路径：" cert_path
    read -r -p "目标私钥路径：" key_path
    read -r -p "复制后执行的命令（不需要则填 :）：" command_text
    [[ -n "$name" && "$cert_path" == /* && "$key_path" == /* && -n "$command_text" ]] || {
        error "输入不完整或路径不是绝对路径。"
        return 1
    }
    append_target_config "$config_file" copy "$name" "$cert_path" "$key_path" "$command_text"
}

add_custom_reload_target() {
    local config_file="$1"
    local name=""
    local command_text=""
    read -r -p "目标名称：" name
    read -r -p "续期后执行的完整命令：" command_text
    [[ -n "$name" && -n "$command_text" ]] || return 1
    append_target_config "$config_file" reload "$name" "" "" "$command_text"
}

configure_deploy_targets() {
    local choice=""
    local temp_file=""
    ensure_deploy_layout
    install_runtime_script || return 1
    temp_file="$(mktemp "${CONFIG_DIR}/targets.conf.XXXXXX")"
    chmod 600 "$temp_file"
    reset_target_arrays

    if [[ -s "$TARGETS_FILE" ]] && confirm "保留现有部署目标并继续添加？" "y"; then
        cp -- "$TARGETS_FILE" "$temp_file"
        chmod 600 "$temp_file"
        # 临时加载现有配置以便显示。
        local saved_targets_file="$TARGETS_FILE"
        TARGETS_FILE="$temp_file"
        load_targets || { TARGETS_FILE="$saved_targets_file"; rm -f -- "$temp_file"; return 1; }
        TARGETS_FILE="$saved_targets_file"
    fi

    while true; do
        printf '\n配置证书部署目标（可添加多个）：\n'
        printf '  1) 自动添加 1Panel 面板\n'
        printf '  2) 选择 1Panel 网站\n'
        printf '  3) 添加 x-ui\n'
        printf '  4) 添加 Nginx\n'
        printf '  5) 添加 Caddy\n'
        printf '  6) 添加 Apache2\n'
        printf '  7) 添加自定义文件目标\n'
        printf '  8) 添加自定义重载命令\n'
        printf '  9) 查看当前目标\n'
        printf '  0) 保存并结束\n'
        read -r -p "请选择 [0-9]：" choice
        case "$choice" in
            1) add_1panel_panel_target "$temp_file" || warn "未添加 1Panel 面板。" ;;
            2) add_1panel_site_targets "$temp_file" || warn "未添加 1Panel 网站。" ;;
            3) add_common_service_target "$temp_file" x-ui restart || true ;;
            4) add_common_service_target "$temp_file" nginx reload || true ;;
            5) add_common_service_target "$temp_file" caddy reload || true ;;
            6) add_common_service_target "$temp_file" apache2 reload || true ;;
            7) add_custom_copy_target "$temp_file" || warn "未添加自定义文件目标。" ;;
            8) add_custom_reload_target "$temp_file" || warn "未添加自定义命令。" ;;
            9)
                printf '\n当前待保存目标：\n'
                local i=0
                for i in "${!TARGET_TYPES[@]}"; do
                    printf '  %d) %s [%s]\n' "$((i + 1))" "${TARGET_NAMES[$i]}" "${TARGET_TYPES[$i]}"
                done
                ;;
            0) break ;;
            *) warn "无效选项。" ;;
        esac
    done

    if ((${#TARGET_TYPES[@]} == 0)) && ! confirm "没有部署目标，仍然保存？" "n"; then
        rm -f -- "$temp_file"
        return 1
    fi
    mv -f -- "$temp_file" "$TARGETS_FILE"
    chmod 600 "$TARGETS_FILE"
    info "部署目标已保存：$TARGETS_FILE"
    show_deploy_targets
}

write_state() {
    local cert_dir="$1"
    local reload_command="$2"
    umask 077
    {
        printf 'PRIMARY_IP=%q\n' "$SELECTED_IPV4"
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

    if [[ -s "$TARGETS_FILE" ]]; then
        show_deploy_targets || return 1
        if confirm "继续使用以上部署目标？" "y"; then
            install_runtime_script || return 1
        else
            configure_deploy_targets || return 1
        fi
    else
        configure_deploy_targets || return 1
    fi
    RELOAD_COMMAND="$DEPLOY_COMMAND"

    install -d -m 700 "$cert_dir"
    [[ -e "${cert_dir}/privkey.pem" ]] || install -m 600 /dev/null "${cert_dir}/privkey.pem"
    [[ -e "${cert_dir}/fullchain.pem" ]] || install -m 644 /dev/null "${cert_dir}/fullchain.pem"
    # 部署钩子在 acme.sh 写入证书后立即执行，因此必须先记录统一证书源路径。
    write_state "$cert_dir" "$RELOAD_COMMAND"

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

rebind_deploy_hook() {
    local output=""
    local rc=0
    load_state
    [[ -x "$ACME_BIN" ]] || { error "尚未安装 acme.sh。"; return 1; }
    [[ -n "$PRIMARY_IP" ]] || { error "未找到已保存的证书 IP。"; return 1; }
    [[ -s "${CERT_DIR}/fullchain.pem" && -s "${CERT_DIR}/privkey.pem" ]] || {
        error "固定证书路径不存在，请先完成正式签发。"
        return 1
    }
    install_runtime_script || return 1

    set +e
    output="$("$ACME_BIN" --install-cert \
        -d "$PRIMARY_IP" \
        --ecc \
        --force \
        --key-file "${CERT_DIR}/privkey.pem" \
        --fullchain-file "${CERT_DIR}/fullchain.pem" \
        --reloadcmd "$DEPLOY_COMMAND" 2>&1)"
    rc=$?
    set -e
    printf '%s\n' "$output"
    if ((rc != 0)); then
        error "重新绑定部署钩子或立即部署失败。"
        return "$rc"
    fi

    RELOAD_COMMAND="$DEPLOY_COMMAND"
    write_state "$CERT_DIR" "$RELOAD_COMMAND"
    info "acme.sh 已绑定多目标部署钩子。"
}

configure_and_rebind_targets() {
    configure_deploy_targets || return 1
    rebind_deploy_hook
}

load_state() {
    local owner=""
    local mode=""
    PRIMARY_IP=""
    CERT_DIR="$DEFAULT_CERT_DIR"
    RELOAD_COMMAND=""
    if [[ -r "$STATE_FILE" ]]; then
        owner="$(stat -c '%u' "$STATE_FILE" 2>/dev/null || true)"
        mode="$(stat -c '%a' "$STATE_FILE" 2>/dev/null || true)"
        [[ "$owner" == "0" ]] || { error "$STATE_FILE 必须归 root 所有。"; return 1; }
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] || { error "无法确认 $STATE_FILE 的权限。"; return 1; }
        (( (8#$mode & 022) == 0 )) || { error "$STATE_FILE 不能允许组或其他用户写入。"; return 1; }
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
        printf '已保存的证书 IP：%s\n' "$PRIMARY_IP"
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

    printf '\n部署分发器：%s\n' "$RUNTIME_SCRIPT"
    [[ -x "$RUNTIME_SCRIPT" ]] || warn "部署分发器尚未安装或不可执行。"
    show_deploy_targets || warn "无法读取部署目标。"

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
    printf '  8) 配置/重配多目标部署与自动重载\n'
    printf '  0) 退出\n\n'
}

main() {
    require_root
    require_tty

    while true; do
        local choice=""
        show_menu
        read -r -p "请选择 [0-8]：" choice
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
            8) configure_and_rebind_targets || warn "部署目标配置或绑定未完成。"; pause ;;
            0) exit 0 ;;
            *) warn "无效选项。"; sleep 1 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ "${1:-}" == "--deploy" ]]; then
        require_root
        deploy_targets
        exit $?
    fi
    main "$@"
fi
