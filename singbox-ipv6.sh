#!/bin/bash

# sing-box 双栈管理脚本 v3.4
# 修复: outbound 改用 inet4/inet6_bind_address 控制出口，完全兼容 v1.12+/v1.13+

SING_BOX_BIN="/usr/local/bin/sing-box"
SING_BOX_CONFIG="/etc/sing-box/config.json"
SING_BOX_CONF_DIR="/etc/sing-box/conf"
SING_BOX_SERVICE="/etc/systemd/system/sing-box.service"
SB_SCRIPT="/usr/local/bin/sb"

info()    { echo "[INFO] $1"; }
success() { echo "[✓] $1"; }
warn()    { echo "[!] $1"; }
error()   { echo "[✗] $1"; exit 1; }

check_root() {
    [[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"
}

auto_fix_sb_command() {
    [[ "$(basename "$0")" == "sb" ]] && return 0
    if [[ ! -f "$SB_SCRIPT" ]] && [[ "$1" != "install" ]]; then
        local SCRIPT_PATH
        SCRIPT_PATH="$(readlink -f "$0")"
        if [[ -f "$SCRIPT_PATH" ]]; then
            warn "检测到 sb 命令缺失，正在自动修复..."
            cp "$SCRIPT_PATH" "$SB_SCRIPT" 2>/dev/null && chmod +x "$SB_SCRIPT"
            [[ -f "$SB_SCRIPT" ]] && { success "sb 命令已修复！"; echo ""; }
        fi
    fi
}

check_arch() {
    case $(uname -m) in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7*)        ARCH="armv7" ;;
        *) error "不支持的系统架构: $(uname -m)" ;;
    esac
}

install_dependencies() {
    info "安装依赖包..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y curl wget jq tar gzip openssl &>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y curl wget jq tar gzip openssl &>/dev/null
    else
        error "不支持的包管理器"
    fi
}

get_server_ipv4() {
    local ip
    ip=$(curl -s -4 --max-time 5 ip.sb 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s -4 --max-time 5 ifconfig.me 2>/dev/null)
    echo "$ip"
}

get_server_ipv6() {
    local ip
    ip=$(curl -s -6 --max-time 5 ip.sb 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s -6 --max-time 5 ifconfig.me 2>/dev/null)
    echo "[$ip]"
}

install_singbox() {
    clear
    echo "=========================================="
    echo "   sing-box 双栈分流版 安装程序"
    echo "=========================================="
    echo ""

    check_root
    check_arch

    if [[ -f "$SING_BOX_BIN" ]]; then
        warn "sing-box 已安装"
        read -rp "是否重新安装? (y/n): " confirm
        [[ "$confirm" != "y" ]] && exit 0
    fi

    install_dependencies

    info "获取最新稳定版本信息..."
    LATEST_VERSION=$(curl -s --max-time 10 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
        | jq -r '.tag_name' | sed 's/v//')

    if [[ -z "$LATEST_VERSION" ]] || [[ "$LATEST_VERSION" == "null" ]]; then
        LATEST_VERSION="1.13.13"
        warn "无法动态获取版本，使用内置版本: v${LATEST_VERSION}"
    fi

    info "最新版本: v${LATEST_VERSION}"
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${ARCH}.tar.gz"
    info "下载地址: $DOWNLOAD_URL"

    TEMP_DIR=$(mktemp -d)
    if ! wget -q --show-progress "$DOWNLOAD_URL" -O "${TEMP_DIR}/sing-box.tar.gz"; then
        rm -rf "$TEMP_DIR"
        error "下载失败，请检查网络或 GitHub 连通性"
    fi

    info "安装 sing-box..."
    tar -xzf "${TEMP_DIR}/sing-box.tar.gz" -C "$TEMP_DIR"
    BINARY_FILE=$(find "$TEMP_DIR" -name "sing-box" -type f | head -1)
    if [[ -z "$BINARY_FILE" ]]; then
        rm -rf "$TEMP_DIR"
        error "未找到 sing-box 二进制文件"
    fi

    cp "$BINARY_FILE" "$SING_BOX_BIN"
    chmod +x "$SING_BOX_BIN"
    rm -rf "$TEMP_DIR"

    mkdir -p /etc/sing-box "$SING_BOX_CONF_DIR"

    # 基础配置：使用 inet4/inet6_bind_address 控制出口，兼容 v1.12+
    cat > "$SING_BOX_CONFIG" << 'BASECFG'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "direct",
      "tag": "direct-v4",
      "inet4_bind_address": "0.0.0.0"
    },
    {
      "type": "direct",
      "tag": "direct-v6",
      "inet6_bind_address": "::"
    }
  ],
  "route": {
    "rules": []
  }
}
BASECFG

    cat > "$SING_BOX_SERVICE" << 'SVCCFG'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SVCCFG

    systemctl daemon-reload
    systemctl enable sing-box &>/dev/null
    systemctl start sing-box

    SCRIPT_PATH="$(readlink -f "$0")"
    if [[ -f "$SCRIPT_PATH" ]]; then
        cp "$SCRIPT_PATH" "$SB_SCRIPT"
        chmod +x "$SB_SCRIPT"
    fi

    if systemctl is-active --quiet sing-box; then
        echo ""
        success "sing-box v${LATEST_VERSION} 安装成功！"
        echo ""
        echo "  sb add vless    - 添加 VLESS-REALITY"
        echo "  sb add socks    - 添加 SOCKS5 代理"
        echo "  sb list         - 查看配置"
        echo ""
    else
        journalctl -u sing-box -n 20 --no-pager
        error "sing-box 服务启动失败"
    fi
}

generate_uuid() {
    if [[ -f "$SING_BOX_BIN" ]]; then
        "$SING_BOX_BIN" generate uuid
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

generate_reality_keypair() {
    [[ ! -f "$SING_BOX_BIN" ]] && error "sing-box 未安装"
    "$SING_BOX_BIN" generate reality-keypair
}

generate_port() {
    local min=${1:-10000}
    local max=${2:-65535}
    local port
    while true; do
        port=$((RANDOM % (max - min + 1) + min))
        if ! ss -tuln 2>/dev/null | grep -q ":$port "; then
            echo "$port"
            return
        fi
    done
}

generate_short_id() {
    openssl rand -hex 8
}

add_inbound_to_config() {
    local inbound_json="$1"
    local tag="$2"
    local out_tag="$3"

    if ! echo "$inbound_json" | jq . >/dev/null 2>&1; then
        error "构造的 inbound JSON 非法"
    fi

    jq --argjson ib "$inbound_json" '.inbounds += [$ib]' \
        "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp" \
        && mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"

    if [[ "$out_tag" != "direct" ]]; then
        jq --arg tag "$tag" --arg out "$out_tag" \
            '.route.rules += [{"inbound": [$tag], "outbound": $out}]' \
            "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp" \
            && mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
    fi
}

restart_singbox() {
    info "验证配置文件..."
    local check_out
    check_out=$("$SING_BOX_BIN" check -c "$SING_BOX_CONFIG" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "$check_out"
        error "配置文件验证失败，已终止"
    fi

    info "重启 sing-box 服务..."
    systemctl restart sing-box
    sleep 2

    if systemctl is-active --quiet sing-box; then
        success "服务重启成功"
    else
        journalctl -u sing-box -n 20 --no-pager
        error "服务启动失败"
    fi
}

select_ip_type() {
    echo "请选择此节点的网络出口模式:"
    echo "  1) 仅 IPv4"
    echo "  2) 仅 IPv6"
    echo "  3) IPv4+IPv6 双栈（系统默认）"
    read -rp "请输入 [1/2/3]: " ip_choice

    case "$ip_choice" in
        1)
            LISTEN_IP="0.0.0.0"
            IP_TYPE="v4"
            OUT_TAG="direct-v4"
            SERVER_IP=$(get_server_ipv4)
            [[ -z "$SERVER_IP" ]] && error "无法获取 IPv4 地址"
            ;;
        2)
            LISTEN_IP="::"
            IP_TYPE="v6"
            OUT_TAG="direct-v6"
            SERVER_IP=$(get_server_ipv6)
            [[ -z "$SERVER_IP" || "$SERVER_IP" == "[]" ]] && error "无法获取 IPv6 地址"
            ;;
        3)
            LISTEN_IP="::"
            IP_TYPE="dual"
            OUT_TAG="direct"
            SERVER_IP=$(get_server_ipv4)
            [[ -z "$SERVER_IP" ]] && SERVER_IP=$(get_server_ipv6)
            ;;
        *)
            error "无效选择"
            ;;
    esac
}

add_vless_reality() {
    clear
    echo "=========================================="
    echo "   添加 VLESS-REALITY"
    echo "=========================================="
    echo ""

    check_root
    select_ip_type

    read -rp "端口 (默认随机): " PORT
    [[ -z "$PORT" ]] && PORT=$(generate_port)

    read -rp "UUID (默认随机): " UUID
    [[ -z "$UUID" ]] && UUID=$(generate_uuid)

    read -rp "SNI (默认 www.apple.com): " SNI
    [[ -z "$SNI" ]] && SNI="www.apple.com"

    read -rp "目标服务器 (默认 www.apple.com): " DEST_SERVER
    [[ -z "$DEST_SERVER" ]] && DEST_SERVER="www.apple.com"

    read -rp "目标端口 (默认 443): " DEST_PORT
    [[ -z "$DEST_PORT" ]] && DEST_PORT=443

    info "生成 Reality 密钥对..."
    KEYPAIR=$(generate_reality_keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR"  | grep "PublicKey"  | awk '{print $2}')
    SHORT_ID=$(generate_short_id)

    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        error "密钥对生成失败，请检查 sing-box 安装"
    fi

    TAG="vless-${IP_TYPE}-${PORT}"
    CONF_FILE="${SING_BOX_CONF_DIR}/${TAG}.json"

    INBOUND_JSON=$(jq -n \
        --arg     tag         "$TAG" \
        --arg     listen      "$LISTEN_IP" \
        --argjson port        "$PORT" \
        --arg     uuid        "$UUID" \
        --arg     sni         "$SNI" \
        --arg     dest_server "$DEST_SERVER" \
        --argjson dest_port   "$DEST_PORT" \
        --arg     priv_key    "$PRIVATE_KEY" \
        --arg     short_id    "$SHORT_ID" \
        '{
          "type": "vless",
          "tag": $tag,
          "listen": $listen,
          "listen_port": $port,
          "users": [{"uuid": $uuid, "flow": "xtls-rprx-vision"}],
          "tls": {
            "enabled": true,
            "server_name": $sni,
            "reality": {
              "enabled": true,
              "handshake": {
                "server": $dest_server,
                "server_port": $dest_port
              },
              "private_key": $priv_key,
              "short_id": [$short_id]
            }
          }
        }')

    [[ -z "$INBOUND_JSON" ]] && error "jq 构造 inbound JSON 失败"

    # 备份文件含 public_key，供 show_config_info 使用
    echo "$INBOUND_JSON" | jq --arg pk "$PUBLIC_KEY" '. + {"public_key": $pk}' > "$CONF_FILE"

    add_inbound_to_config "$INBOUND_JSON" "$TAG" "$OUT_TAG"
    restart_singbox

    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS-${IP_TYPE}-${PORT}"

    echo ""
    success "VLESS-REALITY 添加成功！(模式: ${IP_TYPE})"
    echo ""
    echo "完整链接："
    echo ""
    echo "${VLESS_LINK}"
    echo ""
    read -rp "按回车继续..." _
}

add_socks5_proxy() {
    clear
    echo "=========================================="
    echo "   添加 SOCKS5 代理"
    echo "=========================================="
    echo ""

    check_root
    select_ip_type

    read -rp "端口 (默认1080): " PORT
    [[ -z "$PORT" ]] && PORT=1080

    read -rp "需要认证? (y/n, 默认n): " AUTH

    TAG="socks-${IP_TYPE}-${PORT}"
    CONF_FILE="${SING_BOX_CONF_DIR}/${TAG}.json"

    if [[ "$AUTH" == "y" ]]; then
        read -rp "用户名 (默认 socksuser): " USER
        [[ -z "$USER" ]] && USER="socksuser"
        read -rp "密码 (默认随机): " PASS
        if [[ -z "$PASS" ]]; then
            PASS=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)
            info "随机密码: ${PASS}"
        fi
        INBOUND_JSON=$(jq -n \
            --arg     tag    "$TAG" \
            --arg     listen "$LISTEN_IP" \
            --argjson port   "$PORT" \
            --arg     user   "$USER" \
            --arg     pass   "$PASS" \
            '{"type":"socks","tag":$tag,"listen":$listen,"listen_port":$port,"users":[{"username":$user,"password":$pass}]}')
    else
        INBOUND_JSON=$(jq -n \
            --arg     tag    "$TAG" \
            --arg     listen "$LISTEN_IP" \
            --argjson port   "$PORT" \
            '{"type":"socks","tag":$tag,"listen":$listen,"listen_port":$port}')
    fi

    echo "$INBOUND_JSON" > "$CONF_FILE"
    add_inbound_to_config "$INBOUND_JSON" "$TAG" "$OUT_TAG"
    restart_singbox

    echo ""
    success "SOCKS5 添加成功！(模式: ${IP_TYPE})"
    echo ""
    if [[ "$AUTH" == "y" ]]; then
        echo "socks5://${USER}:${PASS}@${SERVER_IP}:${PORT}"
    else
        echo "socks5://${SERVER_IP}:${PORT}"
    fi
    echo ""
    read -rp "按回车继续..." _
}

list_configs() {
    clear
    echo "=========================================="
    echo "   配置列表"
    echo "=========================================="
    echo ""

    [[ ! -f "$SING_BOX_CONFIG" ]] && { warn "配置文件不存在"; return; }

    local inbounds
    inbounds=$(jq -r '.inbounds[] | "\(.tag)|\(.type)|\(.listen_port // "N/A")"' "$SING_BOX_CONFIG" 2>/dev/null)

    if [[ -z "$inbounds" ]]; then
        warn "当前没有配置"
        return
    fi

    declare -a tags=() types=() ports=()
    while IFS='|' read -r tag type port; do
        tags+=("$tag"); types+=("$type"); ports+=("$port")
    done <<< "$inbounds"

    printf "%-4s  %-12s  %-8s  %s\n" "序号" "类型" "端口" "标签"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for i in "${!tags[@]}"; do
        printf "%-4s  %-12s  %-8s  %s\n" "$((i+1))" "${types[$i]}" "${ports[$i]}" "${tags[$i]}"
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    read -rp "输入序号查看详情（回车退出）: " choice
    [[ -z "$choice" ]] && return

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#tags[@]} )); then
        error "无效序号"
    fi
    show_config_info "${tags[$((choice-1))]}"
}

show_config_info() {
    local tag="$1"
    [[ -z "$tag" ]] && error "请指定配置标签"

    clear
    echo "=========================================="
    echo "   配置详情"
    echo "=========================================="
    echo ""

    local config
    config=$(jq -r ".inbounds[] | select(.tag == \"$tag\")" "$SING_BOX_CONFIG" 2>/dev/null)
    [[ -z "$config" ]] && error "配置不存在: $tag"

    local type port
    type=$(echo "$config" | jq -r '.type')
    port=$(echo "$config" | jq -r '.listen_port')

    local display_ip=""
    if [[ "$tag" == *"-v4-"* ]]; then
        display_ip=$(get_server_ipv4)
    elif [[ "$tag" == *"-v6-"* ]]; then
        display_ip=$(get_server_ipv6)
    else
        display_ip=$(get_server_ipv4)
        [[ -z "$display_ip" ]] && display_ip=$(get_server_ipv6)
    fi

    echo "标签: $tag  |  类型: $type  |  端口: $port  |  IP: $display_ip"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [[ "$type" == "vless" ]]; then
        local uuid flow sni short_id public_key
        uuid=$(echo "$config"     | jq -r '.users[0].uuid')
        flow=$(echo "$config"     | jq -r '.users[0].flow // "none"')
        sni=$(echo "$config"      | jq -r '.tls.server_name // "N/A"')
        short_id=$(echo "$config" | jq -r '.tls.reality.short_id[0] // ""')
        public_key=""
        [[ -f "${SING_BOX_CONF_DIR}/${tag}.json" ]] && \
            public_key=$(jq -r '.public_key // ""' "${SING_BOX_CONF_DIR}/${tag}.json")

        if [[ -n "$public_key" ]]; then
            echo "vless://${uuid}@${display_ip}:${port}?encryption=none&flow=${flow}&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#VLESS-${port}"
            echo ""
        fi

    elif [[ "$type" == "socks" ]]; then
        local username password
        username=$(echo "$config" | jq -r '.users[0].username // ""')
        password=$(echo "$config" | jq -r '.users[0].password // ""')
        if [[ -n "$username" ]]; then
            echo "socks5://${username}:${password}@${display_ip}:${port}"
        else
            echo "socks5://${display_ip}:${port}"
        fi
        echo ""
    fi

    read -rp "按回车返回..." _
    list_configs
}

delete_config() {
    local tag="$1"

    if [[ -z "$tag" ]]; then
        list_configs
        echo ""
        read -rp "请输入要删除的配置标签: " tag
    fi

    [[ -z "$tag" ]] && error "配置标签不能为空"

    local exists
    exists=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .tag" "$SING_BOX_CONFIG" 2>/dev/null)
    [[ -z "$exists" ]] && error "配置不存在: $tag"

    warn "即将删除配置及相关路由: $tag"
    read -rp "确认删除? (y/n): " confirm
    [[ "$confirm" != "y" ]] && { info "已取消"; exit 0; }

    cp "$SING_BOX_CONFIG" "${SING_BOX_CONFIG}.backup.$(date +%s)"
    jq "del(.inbounds[] | select(.tag == \"$tag\")) \
      | del(.route.rules[] | select(.inbound[]? == \"$tag\"))" \
        "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp" \
        && mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
    find "$SING_BOX_CONF_DIR" -name "*${tag}*.json" -delete 2>/dev/null
    restart_singbox
    success "配置已删除: $tag"
}

uninstall_singbox() {
    clear
    echo "=========================================="
    echo "   卸载 sing-box"
    echo "=========================================="
    echo ""
    warn "此操作将完全卸载 sing-box 并删除所有配置！"
    echo ""
    read -rp "确认卸载? 输入 'YES' 继续: " confirm
    [[ "$confirm" != "YES" ]] && { info "已取消"; exit 0; }

    systemctl is-active  --quiet sing-box && systemctl stop    sing-box
    systemctl is-enabled --quiet sing-box && systemctl disable sing-box &>/dev/null
    [[ -f "$SING_BOX_SERVICE" ]] && rm -f "$SING_BOX_SERVICE"
    systemctl daemon-reload
    [[ -f "$SING_BOX_BIN" ]] && rm -f "$SING_BOX_BIN"

    if [[ -d "/etc/sing-box" ]]; then
        read -rp "备份配置到 /root? (y/n): " backup
        if [[ "$backup" == "y" ]]; then
            local BACKUP_DIR="/root/sing-box-backup-$(date +%Y%m%d-%H%M%S)"
            mkdir -p "$BACKUP_DIR"
            cp -r /etc/sing-box/* "$BACKUP_DIR/" 2>/dev/null
            success "配置已备份到: $BACKUP_DIR"
        fi
        rm -rf /etc/sing-box
    fi

    [[ -f "$SB_SCRIPT" ]] && rm -f "$SB_SCRIPT"
    echo ""
    success "sing-box 已完全卸载！"
}

show_log() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   实时日志 (Ctrl+C 退出)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    journalctl -u sing-box -f --no-pager
}

show_help() {
    cat << 'HELP'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      sing-box 管理脚本 v3.4 (双栈版)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
安装与卸载:
  sb install           安装 sing-box
  sb uninstall         卸载 sing-box

配置管理:
  sb add vless         添加 VLESS-REALITY
  sb add socks         添加 SOCKS5 代理
  sb list              列出所有配置
  sb info <tag>        显示配置详情及链接
  sb delete <tag>      删除配置

服务管理:
  sb restart           重启服务
  sb status            查看服务状态
  sb log               实时日志
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HELP
}

main() {
    auto_fix_sb_command "$1"
    case "${1,,}" in
        install)   install_singbox ;;
        uninstall) uninstall_singbox ;;
        list|ls)   list_configs ;;
        add)
            case "${2,,}" in
                vless|reality) add_vless_reality ;;
                socks|socks5)  add_socks5_proxy ;;
                *) error "未知类型: $2  用法: sb add vless | sb add socks" ;;
            esac ;;
        info|show)     show_config_info "$2" ;;
        delete|del|rm) delete_config "$2" ;;
        restart)       restart_singbox ;;
        status)        systemctl status sing-box ;;
        log)           show_log ;;
        help|--help|-h|"") show_help ;;
        *) error "未知命令: $1  使用 'sb help' 查看帮助" ;;
    esac
}

main "$@"
