#!/bin/bash

# sing-box 双栈管理脚本 v3.1 (无色纯净/完整版)
# 特性: 
# 1. 移除所有颜色代码，兼容所有终端
# 2. 彻底移除 HTTP 代理，精简为 VLESS 和 SOCKS5
# 3. 新增网络出口模式选择（IPv4专用 / IPv6专用 / 双栈自动）
# 4. 保留完整的列表、详情、删除、卸载和日志管理功能

# 配置路径
SING_BOX_BIN="/usr/local/bin/sing-box"
SING_BOX_CONFIG="/etc/sing-box/config.json"
SING_BOX_CONF_DIR="/etc/sing-box/conf"
SING_BOX_SERVICE="/etc/systemd/system/sing-box.service"
SB_SCRIPT="/usr/local/bin/sb"

# 输出函数 (已移除颜色)
info() { echo "[INFO] $1"; }
success() { echo "[✓] $1"; }
warn() { echo "[!] $1"; }
error() { echo "[✗] $1"; exit 1; }

# 检查root权限
check_root() {
    [[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"
}

# 自动修复 sb 命令
auto_fix_sb_command() {
    [[ "$(basename "$0")" == "sb" ]] && return 0
    if [[ ! -f "$SB_SCRIPT" ]] && [[ "$1" != "install" ]]; then
        local SCRIPT_PATH="$(readlink -f "$0")"
        if [[ -f "$SCRIPT_PATH" ]]; then
            warn "检测到 sb 命令缺失，正在自动修复..."
            cp "$SCRIPT_PATH" "$SB_SCRIPT" 2>/dev/null && chmod +x "$SB_SCRIPT"
            if [[ -f "$SB_SCRIPT" ]]; then
                success "sb 命令已修复！"
                echo ""
            fi
        fi
    fi
}

# 检查系统架构
check_arch() {
    case $(uname -m) in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7*) ARCH="armv7" ;;
        *) error "不支持的系统架构: $(uname -m)" ;;
    esac
}

# 安装依赖
install_dependencies() {
    info "安装依赖包..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y curl wget jq tar gzip &>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y curl wget jq tar gzip &>/dev/null
    else
        error "不支持的包管理器"
    fi
}

# 获取IPv4地址
get_server_ipv4() {
    local ip=$(curl -s -4 ip.sb 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s -4 ifconfig.me 2>/dev/null)
    echo "$ip"
}

# 获取IPv6地址
get_server_ipv6() {
    local ip=$(curl -s -6 ip.sb 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s -6 ifconfig.me 2>/dev/null)
    echo "[$ip]"
}

# 安装sing-box核心
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
        read -p "是否重新安装? (y/n): " confirm
        [[ "$confirm" != "y" ]] && exit 0
    fi
    
    install_dependencies
    
    info "获取最新版本信息..."
    LATEST_VERSION=$(curl -s -6 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name' | sed 's/v//')
    if [[ -z "$LATEST_VERSION" ]] || [[ "$LATEST_VERSION" == "null" ]]; then
        LATEST_VERSION="1.11.4"
        warn "API 连接失败，使用默认版本: v${LATEST_VERSION}"
    else
        info "最新版本: v${LATEST_VERSION}"
    fi
    
    FILENAME="sing-box-${LATEST_VERSION}-linux-${ARCH}.tar.gz"
    ORIGIN_URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/${FILENAME}"
    MIRROR_URL="https://ghp.ci/${ORIGIN_URL}"
    
    info "正在下载 (使用高速镜像)..."
    TEMP_DIR=$(mktemp -d)
    
    if ! wget -q --show-progress "$MIRROR_URL" -O "${TEMP_DIR}/sing-box.tar.gz"; then
        echo ""
        error "镜像下载失败！请检查 VPS 网络连接"
    fi
    
    info "安装 sing-box..."
    tar -xzf "${TEMP_DIR}/sing-box.tar.gz" -C "$TEMP_DIR"
    BINARY_FILE=$(find "$TEMP_DIR" -name "sing-box" -type f)
    
    if [[ -z "$BINARY_FILE" ]]; then
        error "未找到 sing-box 二进制文件"
    fi
    
    cp "$BINARY_FILE" "$SING_BOX_BIN"
    chmod +x "$SING_BOX_BIN"
    rm -rf "$TEMP_DIR"
    
    mkdir -p /etc/sing-box
    mkdir -p "$SING_BOX_CONF_DIR"
    
    # 初始化基础配置 (预设直接、v4专用、v6专用三个出站)
    cat > "$SING_BOX_CONFIG" << 'EOF'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct",
      "domain_strategy": "ipv6_only"
    },
    {
      "type": "direct",
      "tag": "direct-v4",
      "domain_strategy": "ipv4_only"
    },
    {
      "type": "direct",
      "tag": "direct-v6",
      "domain_strategy": "ipv6_only"
    }
  ],
  "route": {
    "rules": []
  }
}
EOF
    
    cat > "$SING_BOX_SERVICE" << 'EOF'
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
EOF
    
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
        success "sing-box (双栈版) 安装成功！"
        success "已创建快捷命令: sb"
        echo ""
        info "现在可以使用以下命令:"
        echo "  sb add vless    - 添加 VLESS-REALITY"
        echo "  sb add socks    - 添加 SOCKS5 代理"
        echo ""
    else
        error "sing-box 服务启动失败"
    fi
}

# 工具函数
generate_uuid() {
    if [[ -f "$SING_BOX_BIN" ]]; then
        "$SING_BOX_BIN" generate uuid
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

generate_reality_keypair() {
    if [[ -f "$SING_BOX_BIN" ]]; then
        "$SING_BOX_BIN" generate reality-keypair
    else
        error "sing-box 未安装"
    fi
}

generate_port() {
    local min=${1:-10000}
    local max=${2:-65535}
    while true; do
        port=$((RANDOM % (max - min + 1) + min))
        if ! ss -tuln | grep -q ":$port "; then
            echo "$port"
            return
        fi
    done
}

generate_short_id() {
    openssl rand -hex 8
}

# 配置文件写入：包含入站与路由规则
add_inbound_with_route() {
    local conf_file=$1
    local tag=$2
    local out_tag=$3
    
    [[ ! -f "$conf_file" ]] && error "配置文件不存在: $conf_file"
    
    local new_inbound=$(cat "$conf_file")
    
    # 写入入站配置
    jq --argjson inbound "$new_inbound" '.inbounds += [$inbound]' "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"
    mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
    
    # 写入路由规则 (如果不是direct，则绑定强制出站)
    if [[ "$out_tag" != "direct" ]]; then
        jq --arg tag "$tag" --arg out "$out_tag" \
        '.route.rules += [{"inbound": [$tag], "outbound": $out}]' \
        "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"
        mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
    fi
}

restart_singbox() {
    info "测试配置文件..."
    if ! "$SING_BOX_BIN" check -c "$SING_BOX_CONFIG" &>/dev/null; then
        error "配置文件语法错误"
    fi
    
    info "重启 sing-box 服务..."
    systemctl restart sing-box
    sleep 2
    
    if systemctl is-active --quiet sing-box; then
        success "服务重启成功"
    else
        error "服务启动失败"
    fi
}

# 选择IP出口类型
select_ip_type() {
    echo "请选择此节点的网络出口模式:"
    echo "  1) 仅 IPv4 (适用于跨区锁定香港等纯v4出口)"
    echo "  2) 仅 IPv6 (适用于跨区锁定日本等纯v6出口)"
    echo "  3) IPv4+IPv6 自动分流 (适用于v4/v6同区，由VPS自动判断出站)"
    read -p "请输入 [1/2/3]: " ip_choice
    
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

# 添加VLESS-REALITY配置
add_vless_reality() {
    clear
    echo "=========================================="
    echo "   添加 VLESS-REALITY"
    echo "=========================================="
    echo ""
    
    select_ip_type
    
    read -p "端口 (默认随机): " PORT
    [[ -z "$PORT" ]] && PORT=$(generate_port)
    
    read -p "UUID (默认随机): " UUID
    [[ -z "$UUID" ]] && UUID=$(generate_uuid)
    
    read -p "SNI (默认 www.apple.com): " SNI
    [[ -z "$SNI" ]] && SNI="www.apple.com"
    
    read -p "目标服务器 (默认 www.apple.com): " DEST_SERVER
    [[ -z "$DEST_SERVER" ]] && DEST_SERVER="www.apple.com"

    read -p "目标端口 (默认 443): " DEST_PORT
    [[ -z "$DEST_PORT" ]] && DEST_PORT=443
    
    info "生成密钥..."
    KEYPAIR=$(generate_reality_keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep "PublicKey" | awk '{print $2}')
    SHORT_ID=$(generate_short_id)
    
    TAG="vless-${IP_TYPE}-${PORT}"
    CONF_FILE="${SING_BOX_CONF_DIR}/${TAG}.json"
    
    cat > "$CONF_FILE" << EOF
{
  "type": "vless",
  "tag": "${TAG}",
  "listen": "${LISTEN_IP}",
  "listen_port": ${PORT},
  "users": [{"uuid": "${UUID}", "flow": "xtls-rprx-vision"}],
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "reality": {
      "enabled": true,
      "handshake": {
        "server": "${DEST_SERVER}",
        "server_port": ${DEST_PORT}
      },
      "private_key": "${PRIVATE_KEY}",
      "short_id": ["${SHORT_ID}"]
    }
  },
  "public_key": "${PUBLIC_KEY}"
}
EOF
    
    local temp_config=$(jq 'del(.public_key)' "$CONF_FILE")
    echo "$temp_config" > "${CONF_FILE}.tmp"
    add_inbound_with_route "${CONF_FILE}.tmp" "$TAG" "$OUT_TAG"
    rm -f "${CONF_FILE}.tmp"
    
    restart_singbox
    
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS-${IP_TYPE}-${PORT}"
    
    echo ""
    success "VLESS-REALITY 添加成功！(模式: ${IP_TYPE})"
    echo ""
    echo "完整链接："
    echo ""
    echo "${VLESS_LINK}"
    echo ""
    read -p "按回车继续..." dummy
}

# 添加SOCKS5代理
add_socks5_proxy() {
    clear
    echo "=========================================="
    echo "   添加 SOCKS5 代理"
    echo "=========================================="
    echo ""
    
    select_ip_type
    
    read -p "端口 (默认1080): " PORT
    [[ -z "$PORT" ]] && PORT=1080
    
    read -p "需要认证? (y/n, 默认n): " AUTH
    
    TAG="socks-${IP_TYPE}-${PORT}"
    CONF_FILE="${SING_BOX_CONF_DIR}/${TAG}.json"
    
    if [[ "$AUTH" == "y" ]]; then
        read -p "用户名 (默认socksuser): " USER
        [[ -z "$USER" ]] && USER="socksuser"
        
        read -p "密码 (默认随机): " PASS
        if [[ -z "$PASS" ]]; then
            PASS=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
            info "随机密码: ${PASS}"
        fi
        
        cat > "$CONF_FILE" << EOF
{
  "type": "socks",
  "tag": "${TAG}",
  "listen": "${LISTEN_IP}",
  "listen_port": ${PORT},
  "users": [{"username": "${USER}", "password": "${PASS}"}]
}
EOF
    else
        cat > "$CONF_FILE" << EOF
{
  "type": "socks",
  "tag": "${TAG}",
  "listen": "${LISTEN_IP}",
  "listen_port": ${PORT}
}
EOF
    fi
    
    add_inbound_with_route "$CONF_FILE" "$TAG" "$OUT_TAG"
    restart_singbox
    
    echo ""
    success "SOCKS5 添加成功！(模式: ${IP_TYPE})"
    echo ""
    echo "完整地址："
    echo ""
    if [[ "$AUTH" == "y" ]]; then
        echo "socks5://${USER}:${PASS}@${SERVER_IP}:${PORT}"
    else
        echo "socks5://${SERVER_IP}:${PORT}"
    fi
    echo ""
    read -p "按回车继续..." dummy
}

# 列出配置
list_configs() {
    clear
    echo "=========================================="
    echo "   配置列表"
    echo "=========================================="
    echo ""
    
    [[ ! -f "$SING_BOX_CONFIG" ]] && { warn "配置文件不存在"; return; }
    
    local inbounds=$(jq -r '.inbounds[] | "\(.tag)|\(.type)|\(.listen_port // "N/A")"' "$SING_BOX_CONFIG" 2>/dev/null)
    
    if [[ -z "$inbounds" ]]; then
        warn "当前没有配置"
        return
    fi
    
    declare -a tags=()
    declare -a types=()
    declare -a ports=()
    
    while IFS='|' read -r tag type port; do
        tags+=("$tag")
        types+=("$type")
        ports+=("$port")
    done <<< "$inbounds"
    
    echo "序号  类型          端口      标签(含出口模式)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    for i in "${!tags[@]}"; do
        local num=$((i + 1))
        printf "%-4s  %-12s  %-8s  %s\n" "$num" "${types[$i]}" "${ports[$i]}" "${tags[$i]}"
    done
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    read -p "输入序号查看详情（回车退出）: " choice
    
    if [[ -z "$choice" ]]; then
        return
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#tags[@]}" ]; then
        error "无效序号"
    fi
    
    local index=$((choice - 1))
    show_config_info "${tags[$index]}"
}

# 显示配置详情 (完整恢复版)
show_config_info() {
    local tag=$1
    [[ -z "$tag" ]] && error "请指定配置标签"
    
    clear
    echo "=========================================="
    echo "   配置详情"
    echo "=========================================="
    echo ""
    
    local config=$(jq -r ".inbounds[] | select(.tag == \"$tag\")" "$SING_BOX_CONFIG" 2>/dev/null)
    [[ -z "$config" ]] && error "配置不存在: $tag"
    
    local type=$(echo "$config" | jq -r '.type')
    local port=$(echo "$config" | jq -r '.listen_port')
    
    # 智能判断该显示哪个IP
    local display_ip=""
    if [[ "$tag" == *"-v4-"* ]]; then
        display_ip=$(get_server_ipv4)
    elif [[ "$tag" == *"-v6-"* ]]; then
        display_ip=$(get_server_ipv6)
    else
        display_ip=$(get_server_ipv4)
        [[ -z "$display_ip" ]] && display_ip=$(get_server_ipv6)
    fi
    
    echo "标签: $tag"
    echo "类型: $type"
    echo "端口: $port"
    echo "建议IP: $display_ip"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    if [[ "$type" == "vless" ]]; then
        local uuid=$(echo "$config" | jq -r '.users[0].uuid')
        local flow=$(echo "$config" | jq -r '.users[0].flow // "none"')
        local sni=$(echo "$config" | jq -r '.tls.server_name // "N/A"')
        local short_id=$(echo "$config" | jq -r '.tls.reality.short_id[0] // ""')
        
        local conf_file="${SING_BOX_CONF_DIR}/${tag}.json"
        local public_key=""
        if [[ -f "$conf_file" ]]; then
            public_key=$(jq -r '.public_key // ""' "$conf_file")
        fi
        
        if [[ -n "$public_key" && "$flow" == "xtls-rprx-vision" ]]; then
            local vless_link="vless://${uuid}@${display_ip}:${port}?encryption=none&flow=${flow}&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#VLESS-${port}"
            
            echo "VLESS-REALITY 链接："
            echo ""
            echo "${vless_link}"
            echo ""
        fi
        
    elif [[ "$type" == "socks" ]]; then
        local username=$(echo "$config" | jq -r '.users[0].username // ""')
        local password=$(echo "$config" | jq -r '.users[0].password // ""')
        
        echo "SOCKS5 代理地址："
        echo ""
        if [[ -n "$username" ]]; then
            echo "socks5://${username}:${password}@${display_ip}:${port}"
        else
            echo "socks5://${display_ip}:${port}"
        fi
        echo ""
    fi
    
    echo ""
    read -p "按回车返回..." dummy
    list_configs
}

# 删除配置 (同步删除路由规则)
delete_config() {
    local tag=$1
    
    if [[ -z "$tag" ]]; then
        list_configs
        echo ""
        read -p "请输入要删除的配置标签: " tag
    fi
    
    [[ -z "$tag" ]] && error "配置标签不能为空"
    
    local exists=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .tag" "$SING_BOX_CONFIG" 2>/dev/null)
    [[ -z "$exists" ]] && error "配置不存在: $tag"
    
    warn "即将删除配置及相关路由: $tag"
    read -p "确认删除? (y/n): " confirm
    
    [[ "$confirm" != "y" ]] && { info "已取消"; exit 0; }
    
    cp "$SING_BOX_CONFIG" "${SING_BOX_CONFIG}.backup.$(date +%s)"
    
    # 核心修改：同时删除inbounds块和route.rules块中对应的记录
    jq "del(.inbounds[] | select(.tag == \"$tag\")) | del(.route.rules[] | select(.inbound[]? == \"$tag\"))" "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"
    mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
    
    find "$SING_BOX_CONF_DIR" -name "*${tag}*.json" -delete 2>/dev/null
    
    restart_singbox
    success "配置已删除: $tag"
}

# 卸载sing-box (完整恢复版)
uninstall_singbox() {
    clear
    echo "=========================================="
    echo "   卸载 sing-box"
    echo "=========================================="
    echo ""
    
    warn "此操作将完全卸载 sing-box 并删除所有配置！"
    warn "这是不可逆的操作！"
    echo ""
    read -p "确认卸载? 输入 'YES' 继续: " confirm
    
    [[ "$confirm" != "YES" ]] && { info "已取消"; exit 0; }
    
    echo ""
    info "开始卸载..."
    
    systemctl is-active --quiet sing-box && systemctl stop sing-box
    systemctl is-enabled --quiet sing-box &>/dev/null && systemctl disable sing-box &>/dev/null
    
    [[ -f "$SING_BOX_SERVICE" ]] && rm -f "$SING_BOX_SERVICE"
    systemctl daemon-reload
    
    [[ -f "$SING_BOX_BIN" ]] && rm -f "$SING_BOX_BIN"
    
    if [[ -d "/etc/sing-box" ]]; then
        read -p "备份配置? (y/n): " backup
        if [[ "$backup" == "y" ]]; then
            BACKUP_DIR="/root/sing-box-backup-$(date +%Y%m%d-%H%M%S)"
            mkdir -p "$BACKUP_DIR"
            cp -r /etc/sing-box/* "$BACKUP_DIR/" 2>/dev/null
            success "配置已备份到: $BACKUP_DIR"
        fi
        rm -rf /etc/sing-box
    fi
    
    [[ -f "$SB_SCRIPT" ]] && rm -f "$SB_SCRIPT"
    [[ -d "/var/log/sing-box" ]] && rm -rf /var/log/sing-box
    
    echo ""
    success "sing-box 已完全卸载！"
    echo ""
}

# 帮助信息
show_help() {
    cat << EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      sing-box 管理脚本 (纯净双栈版)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📦 安装与卸载:
  sb install           安装 sing-box
  sb uninstall         卸载 sing-box

📋 配置管理:
  sb list              列出配置（交互式）
  sb add vless         添加 VLESS-REALITY
  sb add socks         添加 SOCKS5 代理
  sb info <tag>        显示配置详情
  sb delete <tag>      删除配置

🔧 服务管理:
  sb restart           重启服务
  sb status            查看状态
  sb log               查看日志

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

# 查看日志
show_log() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   实时日志 (Ctrl+C 退出)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    journalctl -u sing-box -f --no-pager
}

# 主函数
main() {
    auto_fix_sb_command "$1"
    
    case ${1,,} in
        install) install_singbox ;;
        uninstall) uninstall_singbox ;;
        list|ls) list_configs ;;
        add)
            case ${2,,} in
                vless|reality) add_vless_reality ;;
                socks|socks5) add_socks5_proxy ;;
                *) error "未知类型: $2\n使用: vless | socks" ;;
            esac
            ;;
        info|show) show_config_info "$2" ;;
        delete|del|rm) delete_config "$2" ;;
        restart) restart_singbox ;;
        status) systemctl status sing-box ;;
        log) show_log ;;
        help|--help|-h|"") show_help ;;
        *) error "未知命令: $1\n使用 'sb help' 查看帮助" ;;
    esac
}

main "$@"
