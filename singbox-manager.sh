#!/bin/bash

# sing-box 独立管理脚本 v2.0
# 支持: VLESS-REALITY + HTTP + SOCKS5
# 功能: install/list/add/delete/info/uninstall
# 作者: 优化版本

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# 配置路径
SING_BOX_BIN="/usr/local/bin/sing-box"
SING_BOX_CONFIG="/etc/sing-box/config.json"
SING_BOX_CONF_DIR="/etc/sing-box/conf"
SING_BOX_SERVICE="/etc/systemd/system/sing-box.service"
SB_SCRIPT="/usr/local/bin/sb"

# 输出函数
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# 检查root权限
check_root() {
    [[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"
}

# 自动修复 sb 命令（如果缺失）
auto_fix_sb_command() {
    # 如果通过 sb 命令调用，则不需要修复
    [[ "$(basename "$0")" == "sb" ]] && return 0
    
    # 如果 sb 命令不存在，尝试创建
    if [[ ! -f "$SB_SCRIPT" ]] && [[ "$1" != "install" ]]; then
        local SCRIPT_PATH="$(readlink -f "$0")"
        if [[ -f "$SCRIPT_PATH" ]]; then
            warn "检测到 sb 命令缺失，正在自动修复..."
            cp "$SCRIPT_PATH" "$SB_SCRIPT" 2>/dev/null && chmod +x "$SB_SCRIPT"
            if [[ -f "$SB_SCRIPT" ]]; then
                success "sb 命令已修复！现在可以使用 'sb' 命令了"
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

# 安装sing-box
install_singbox() {
    clear
    echo -e "${GREEN}=========================================="
    echo -e "   sing-box 安装程序"
    echo -e "==========================================${NC}"
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
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name' | sed 's/v//')
    
    if [[ -z "$LATEST_VERSION" ]]; then
        error "无法获取最新版本信息"
    fi
    
    info "最新版本: v${LATEST_VERSION}"
    
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${ARCH}.tar.gz"
    
    info "下载 sing-box..."
    TEMP_DIR=$(mktemp -d)
    
    if ! wget -q --show-progress "$DOWNLOAD_URL" -O "${TEMP_DIR}/sing-box.tar.gz"; then
        error "下载失败"
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
      "tag": "direct"
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
    
    # 创建 sb 快捷命令
    SCRIPT_PATH="$(readlink -f "$0")"
    if [[ -f "$SCRIPT_PATH" ]]; then
        cp "$SCRIPT_PATH" "$SB_SCRIPT"
        chmod +x "$SB_SCRIPT"
    else
        # 如果无法获取脚本路径，提示用户手动创建
        warn "无法自动创建 sb 命令"
        echo "请手动运行: ln -sf $(pwd)/singbox-manager.sh /usr/local/bin/sb"
    fi
    
    if systemctl is-active --quiet sing-box; then
        echo ""
        success "sing-box 安装成功！"
        success "版本: v${LATEST_VERSION}"
        success "已创建快捷命令: ${GREEN}sb${NC}"
        echo ""
        info "现在可以使用以下命令:"
        echo -e "  ${GREEN}sb add vless${NC}   - 添加 VLESS-REALITY"
        echo -e "  ${GREEN}sb add http${NC}    - 添加 HTTP 代理"
        echo -e "  ${GREEN}sb add socks${NC}   - 添加 SOCKS5 代理"
        echo -e "  ${GREEN}sb list${NC}        - 查看配置"
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

get_server_ip() {
    SERVER_IP=$(curl -s ip.sb 2>/dev/null || curl -s ifconfig.me 2>/dev/null)
    [[ -z "$SERVER_IP" ]] && SERVER_IP="YOUR_SERVER_IP"
    echo "$SERVER_IP"
}

add_inbound_to_config() {
    local conf_file=$1
    [[ ! -f "$conf_file" ]] && error "配置文件不存在: $conf_file"
    
    local new_inbound=$(cat "$conf_file")
    jq --argjson inbound "$new_inbound" '.inbounds += [$inbound]' "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"
    
    if [[ $? -eq 0 ]]; then
        mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
    else
        error "更新配置失败"
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

# 添加VLESS-REALITY配置
add_vless_reality() {
    clear
    echo -e "${GREEN}=========================================="
    echo -e "   添加 VLESS-REALITY 配置"
    echo -e "==========================================${NC}"
    echo ""
    
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
    
    CONF_FILE="${SING_BOX_CONF_DIR}/vless-reality-${PORT}.json"
    cat > "$CONF_FILE" << EOF
{
  "type": "vless",
  "tag": "vless-reality-${PORT}",
  "listen": "0.0.0.0",
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
    add_inbound_to_config "${CONF_FILE}.tmp"
    rm -f "${CONF_FILE}.tmp"
    
    restart_singbox
    
    SERVER_IP=$(get_server_ip)
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS-${PORT}"
    echo ""
    success "VLESS-REALITY 添加成功！"
    echo ""
    echo -e "${YELLOW}📱 完整链接：${NC}"
    echo ""
    echo -e "${CYAN}${VLESS_LINK}${NC}"
    echo ""
    echo -e "${YELLOW}配置详情：${NC}"
    echo -e "  目标服务器: ${GREEN}${DEST_SERVER}${NC}"
    echo -e "  目标端口: ${GREEN}${DEST_PORT}${NC}"
    echo -e "  SNI: ${GREEN}${SNI}${NC}"
    echo ""
    read -p "按回车继续..." dummy
}

# 添加HTTP代理
add_http_proxy() {
    clear
    echo -e "${GREEN}=========================================="
    echo -e "   添加 HTTP 代理"
    echo -e "==========================================${NC}"
    echo ""
    
    read -p "端口 (默认3128): " PORT
    [[ -z "$PORT" ]] && PORT=3128
    
    read -p "用户名 (默认httpuser): " USER
    [[ -z "$USER" ]] && USER="httpuser"
    
    read -p "密码 (默认随机): " PASS
    if [[ -z "$PASS" ]]; then
        PASS=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
        info "密码: ${PASS}"
    fi
    
    CONF_FILE="${SING_BOX_CONF_DIR}/http-${PORT}.json"
    
    cat > "$CONF_FILE" << EOF
{
  "type": "http",
  "tag": "http-${PORT}",
  "listen": "0.0.0.0",
  "listen_port": ${PORT},
  "users": [{"username": "${USER}", "password": "${PASS}"}]
}
EOF
    
    add_inbound_to_config "$CONF_FILE"
    restart_singbox
    
    SERVER_IP=$(get_server_ip)
    
    echo ""
    success "HTTP 代理添加成功！"
    echo ""
    echo -e "${YELLOW}🌐 完整地址：${NC}"
    echo ""
    echo -e "${CYAN}http://${USER}:${PASS}@${SERVER_IP}:${PORT}${NC}"
    echo ""
    read -p "按回车继续..." dummy
}

# 添加SOCKS5代理
add_socks5_proxy() {
    clear
    echo -e "${GREEN}=========================================="
    echo -e "   添加 SOCKS5 代理"
    echo -e "==========================================${NC}"
    echo ""
    
    read -p "端口 (默认1080): " PORT
    [[ -z "$PORT" ]] && PORT=1080
    
    read -p "需要认证? (y/n, 默认n): " AUTH
    
    CONF_FILE="${SING_BOX_CONF_DIR}/socks-${PORT}.json"
    
    if [[ "$AUTH" == "y" ]]; then
        read -p "用户名 (默认socksuser): " USER
        [[ -z "$USER" ]] && USER="socksuser"
        
        read -p "密码 (默认随机): " PASS
        if [[ -z "$PASS" ]]; then
            PASS=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
            info "密码: ${PASS}"
        fi
        
        cat > "$CONF_FILE" << EOF
{
  "type": "socks",
  "tag": "socks-${PORT}",
  "listen": "0.0.0.0",
  "listen_port": ${PORT},
  "users": [{"username": "${USER}", "password": "${PASS}"}]
}
EOF
    else
        cat > "$CONF_FILE" << EOF
{
  "type": "socks",
  "tag": "socks-${PORT}",
  "listen": "0.0.0.0",
  "listen_port": ${PORT}
}
EOF
    fi
    
    add_inbound_to_config "$CONF_FILE"
    restart_singbox
    
    SERVER_IP=$(get_server_ip)
    
    echo ""
    success "SOCKS5 添加成功！"
    echo ""
    echo -e "${YELLOW}🔌 完整地址：${NC}"
    echo ""
    if [[ "$AUTH" == "y" ]]; then
        echo -e "${CYAN}socks5://${USER}:${PASS}@${SERVER_IP}:${PORT}${NC}"
    else
        echo -e "${CYAN}socks5://${SERVER_IP}:${PORT}${NC}"
    fi
    echo ""
    read -p "按回车继续..." dummy
}

# 列出配置（交互式）
list_configs() {
    clear
    echo -e "${GREEN}=========================================="
    echo -e "   配置列表"
    echo -e "==========================================${NC}"
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
    
    echo -e "${CYAN}序号  类型          端口      标签${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    for i in "${!tags[@]}"; do
        local num=$((i + 1))
        printf "${GREEN}%-4s${NC}  ${YELLOW}%-12s${NC}  ${MAGENTA}%-8s${NC}  %s\n" "$num" "${types[$i]}" "${ports[$i]}" "${tags[$i]}"
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

# 显示配置详情
show_config_info() {
    local tag=$1
    [[ -z "$tag" ]] && error "请指定配置标签"
    
    clear
    echo -e "${GREEN}=========================================="
    echo -e "   配置详情"
    echo -e "==========================================${NC}"
    echo ""
    
    local config=$(jq -r ".inbounds[] | select(.tag == \"$tag\")" "$SING_BOX_CONFIG" 2>/dev/null)
    [[ -z "$config" ]] && error "配置不存在: $tag"
    
    local type=$(echo "$config" | jq -r '.type')
    local port=$(echo "$config" | jq -r '.listen_port')
    SERVER_IP=$(get_server_ip)
    
    echo -e "${CYAN}标签:${NC} ${YELLOW}$tag${NC}"
    echo -e "${CYAN}类型:${NC} ${YELLOW}$type${NC}"
    echo -e "${CYAN}端口:${NC} ${YELLOW}$port${NC}"
    echo -e "${CYAN}服务器:${NC} ${YELLOW}$SERVER_IP${NC}"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
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
            local vless_link="vless://${uuid}@${SERVER_IP}:${port}?encryption=none&flow=${flow}&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#VLESS-${port}"
            
            echo -e "${YELLOW}📱 VLESS-REALITY 链接：${NC}"
            echo ""
            echo -e "${CYAN}${vless_link}${NC}"
            echo ""
        fi
        
    elif [[ "$type" == "http" ]]; then
        local username=$(echo "$config" | jq -r '.users[0].username')
        local password=$(echo "$config" | jq -r '.users[0].password')
        
        echo -e "${YELLOW}🌐 HTTP 代理地址：${NC}"
        echo ""
        echo -e "${CYAN}http://${username}:${password}@${SERVER_IP}:${port}${NC}"
        echo ""
        
    elif [[ "$type" == "socks" ]]; then
        local username=$(echo "$config" | jq -r '.users[0].username // ""')
        local password=$(echo "$config" | jq -r '.users[0].password // ""')
        
        echo -e "${YELLOW}🔌 SOCKS5 代理地址：${NC}"
        echo ""
        if [[ -n "$username" ]]; then
            echo -e "${CYAN}socks5://${username}:${password}@${SERVER_IP}:${port}${NC}"
        else
            echo -e "${CYAN}socks5://${SERVER_IP}:${port}${NC}"
        fi
        echo ""
    fi
    
    echo ""
    read -p "按回车返回..." dummy
    list_configs
}

# 删除配置
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
    
    warn "即将删除配置: $tag"
    read -p "确认删除? (y/n): " confirm
    
    [[ "$confirm" != "y" ]] && { info "已取消"; exit 0; }
    
    cp "$SING_BOX_CONFIG" "${SING_BOX_CONFIG}.backup.$(date +%s)"
    
    jq "del(.inbounds[] | select(.tag == \"$tag\"))" "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"
    mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
    
    find "$SING_BOX_CONF_DIR" -name "*${tag}*.json" -delete 2>/dev/null
    
    restart_singbox
    success "配置已删除: $tag"
}

# 卸载sing-box
uninstall_singbox() {
    clear
    echo -e "${RED}=========================================="
    echo -e "   卸载 sing-box"
    echo -e "==========================================${NC}"
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
${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${GREEN}      sing-box 管理脚本 v2.0${NC}
${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

${YELLOW}📦 安装与卸载:${NC}
  ${GREEN}sb install${NC}          安装 sing-box
  ${GREEN}sb uninstall${NC}        卸载 sing-box

${YELLOW}📋 配置管理:${NC}
  ${GREEN}sb list${NC}             列出配置（交互式）
  ${GREEN}sb add vless${NC}        添加 VLESS-REALITY
  ${GREEN}sb add http${NC}         添加 HTTP 代理
  ${GREEN}sb add socks${NC}        添加 SOCKS5 代理
  ${GREEN}sb info <tag>${NC}       显示配置详情
  ${GREEN}sb delete <tag>${NC}     删除配置

${YELLOW}🔧 服务管理:${NC}
  ${GREEN}sb restart${NC}          重启服务
  ${GREEN}sb status${NC}           查看状态
  ${GREEN}sb log${NC}              查看日志

${YELLOW}💡 使用技巧:${NC}
  • ${GREEN}sb list${NC} 后输入序号快速查看
  • VLESS-REALITY 最安全，推荐使用
  • 支持指定端口，适配 NAT VPS

${YELLOW}🌐 支持协议:${NC}
  ${GREEN}✓${NC} VLESS-REALITY  - 最安全
  ${GREEN}✓${NC} HTTP Proxy     - 广泛支持
  ${GREEN}✓${NC} SOCKS5         - 通用代理

${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
EOF
}

show_log() {
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}   实时日志 (Ctrl+C 退出)${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    journalctl -u sing-box -f --no-pager
}

# 主函数
main() {
    # 自动修复 sb 命令（如果需要）
    auto_fix_sb_command "$1"
    
    case ${1,,} in
        install) install_singbox ;;
        uninstall) uninstall_singbox ;;
        list|ls) list_configs ;;
        add)
            case ${2,,} in
                vless|reality) add_vless_reality ;;
                http|proxy) add_http_proxy ;;
                socks|socks5) add_socks5_proxy ;;
                *) error "未知类型: $2\n使用: vless | http | socks" ;;
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
