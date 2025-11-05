#!/bin/bash

# sing-box 独立管理脚本
# 支持: VLESS-REALITY + HTTP代理
# 功能: install/list/add/delete/info

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置路径
SING_BOX_BIN="/usr/local/bin/sing-box"
SING_BOX_CONFIG="/etc/sing-box/config.json"
SING_BOX_CONF_DIR="/etc/sing-box/conf"
SING_BOX_SERVICE="/etc/systemd/system/sing-box.service"

# 输出函数
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 检查root权限
check_root() {
    [[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"
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
    
    # 检查是否已安装
    if [[ -f "$SING_BOX_BIN" ]]; then
        warn "sing-box 已安装"
        read -p "是否重新安装? (y/n): " confirm
        [[ "$confirm" != "y" ]] && exit 0
    fi
    
    install_dependencies
    
    # 获取最新版本
    info "获取最新版本信息..."
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name' | sed 's/v//')
    
    if [[ -z "$LATEST_VERSION" ]]; then
        error "无法获取最新版本信息"
    fi
    
    info "最新版本: v${LATEST_VERSION}"
    
    # 下载sing-box
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${ARCH}.tar.gz"
    
    info "下载 sing-box..."
    TEMP_DIR=$(mktemp -d)
    
    if ! wget -q --show-progress "$DOWNLOAD_URL" -O "${TEMP_DIR}/sing-box.tar.gz"; then
        error "下载失败"
    fi
    
    # 解压安装
    info "安装 sing-box..."
    tar -xzf "${TEMP_DIR}/sing-box.tar.gz" -C "$TEMP_DIR"
    
    # 查找sing-box二进制文件
    BINARY_FILE=$(find "$TEMP_DIR" -name "sing-box" -type f)
    
    if [[ -z "$BINARY_FILE" ]]; then
        error "未找到 sing-box 二进制文件"
    fi
    
    cp "$BINARY_FILE" "$SING_BOX_BIN"
    chmod +x "$SING_BOX_BIN"
    
    # 清理临时文件
    rm -rf "$TEMP_DIR"
    
    # 创建配置目录
    mkdir -p /etc/sing-box
    mkdir -p "$SING_BOX_CONF_DIR"
    
    # 创建基础配置文件
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
    
    # 创建systemd服务
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
    
    # 启用并启动服务
    systemctl daemon-reload
    systemctl enable sing-box &>/dev/null
    systemctl start sing-box
    
    # 检查服务状态
    if systemctl is-active --quiet sing-box; then
        success "sing-box 安装成功！"
        success "版本: v${LATEST_VERSION}"
        success "配置文件: $SING_BOX_CONFIG"
        echo ""
        info "使用以下命令管理配置:"
        echo -e "  ${CYAN}$0 add vless${NC}   - 添加 VLESS-REALITY 配置"
        echo -e "  ${CYAN}$0 add http${NC}    - 添加 HTTP 代理配置"
        echo -e "  ${CYAN}$0 list${NC}        - 查看所有配置"
    else
        error "sing-box 服务启动失败"
    fi
}

# 生成UUID
generate_uuid() {
    if [[ -f "$SING_BOX_BIN" ]]; then
        "$SING_BOX_BIN" generate uuid
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

# 生成REALITY密钥对
generate_reality_keypair() {
    if [[ -f "$SING_BOX_BIN" ]]; then
        "$SING_BOX_BIN" generate reality-keypair
    else
        error "sing-box 未安装"
    fi
}

# 生成随机端口
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

# 生成short_id
generate_short_id() {
    openssl rand -hex 8
}

# 获取服务器IP
get_server_ip() {
    SERVER_IP=$(curl -s ip.sb 2>/dev/null || curl -s ifconfig.me 2>/dev/null)
    [[ -z "$SERVER_IP" ]] && SERVER_IP="YOUR_SERVER_IP"
    echo "$SERVER_IP"
}

# 添加VLESS-REALITY配置
add_vless_reality() {
    clear
    echo -e "${GREEN}=========================================="
    echo -e "   添加 VLESS-REALITY 配置"
    echo -e "==========================================${NC}"
    echo ""
    
    # 获取用户输入
    read -p "端口 (默认随机): " PORT
    [[ -z "$PORT" ]] && PORT=$(generate_port)
    
    read -p "UUID (默认随机生成): " UUID
    [[ -z "$UUID" ]] && UUID=$(generate_uuid)
    
    read -p "服务器名称/SNI (默认 www.apple.com): " SERVER_NAME
    [[ -z "$SERVER_NAME" ]] && SERVER_NAME="www.apple.com"
    
    read -p "目标地址 (默认 www.apple.com:443): " DEST
    [[ -z "$DEST" ]] && DEST="www.apple.com:443"
    
    # 生成密钥对
    info "生成 REALITY 密钥对..."
    KEYPAIR=$(generate_reality_keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep "PublicKey" | awk '{print $2}')
    
    # 生成short_id
    SHORT_ID=$(generate_short_id)
    
    # 创建配置文件
    CONF_FILE="${SING_BOX_CONF_DIR}/vless-reality-${PORT}.json"
    
    cat > "$CONF_FILE" << EOF
{
  "type": "vless",
  "tag": "vless-reality-${PORT}",
  "listen": "0.0.0.0",
  "listen_port": ${PORT},
  "users": [
    {
      "uuid": "${UUID}",
      "flow": "xtls-rprx-vision"
    }
  ],
  "tls": {
    "enabled": true,
    "server_name": "${SERVER_NAME}",
    "reality": {
      "enabled": true,
      "handshake": {
        "server": "${DEST}",
        "server_port": 443
      },
      "private_key": "${PRIVATE_KEY}",
      "short_id": ["${SHORT_ID}"]
    }
  }
}
EOF
    
    # 添加到主配置
    add_inbound_to_config "$CONF_FILE"
    
    # 重启服务
    restart_singbox
    
    # 获取服务器IP
    SERVER_IP=$(get_server_ip)
    
    # 显示配置信息
    echo ""
    success "VLESS-REALITY 配置添加成功！"
    echo ""
    echo -e "${YELLOW}配置信息：${NC}"
    echo -e "  服务器: ${GREEN}${SERVER_IP}${NC}"
    echo -e "  端口: ${GREEN}${PORT}${NC}"
    echo -e "  UUID: ${GREEN}${UUID}${NC}"
    echo -e "  Flow: ${GREEN}xtls-rprx-vision${NC}"
    echo -e "  SNI: ${GREEN}${SERVER_NAME}${NC}"
    echo -e "  Public Key: ${GREEN}${PUBLIC_KEY}${NC}"
    echo -e "  Short ID: ${GREEN}${SHORT_ID}${NC}"
    echo ""
    echo -e "${YELLOW}VLESS 链接：${NC}"
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS-REALITY-${PORT}"
    echo -e "${GREEN}${VLESS_LINK}${NC}"
    echo ""
    info "配置文件: ${CONF_FILE}"
}

# 添加HTTP代理配置
add_http_proxy() {
    clear
    echo -e "${GREEN}=========================================="
    echo -e "   添加 HTTP 代理配置"
    echo -e "==========================================${NC}"
    echo ""
    
    # 获取用户输入
    read -p "端口 (默认3128): " PORT
    [[ -z "$PORT" ]] && PORT=3128
    
    read -p "用户名 (默认httpuser): " USERNAME
    [[ -z "$USERNAME" ]] && USERNAME="httpuser"
    
    read -p "密码 (默认随机生成): " PASSWORD
    if [[ -z "$PASSWORD" ]]; then
        PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
        info "随机生成密码: ${PASSWORD}"
    fi
    
    # 创建配置文件
    CONF_FILE="${SING_BOX_CONF_DIR}/http-${PORT}.json"
    
    cat > "$CONF_FILE" << EOF
{
  "type": "http",
  "tag": "http-${PORT}",
  "listen": "0.0.0.0",
  "listen_port": ${PORT},
  "users": [
    {
      "username": "${USERNAME}",
      "password": "${PASSWORD}"
    }
  ]
}
EOF
    
    # 添加到主配置
    add_inbound_to_config "$CONF_FILE"
    
    # 重启服务
    restart_singbox
    
    # 获取服务器IP
    SERVER_IP=$(get_server_ip)
    
    # 显示配置信息
    echo ""
    success "HTTP 代理配置添加成功！"
    echo ""
    echo -e "${YELLOW}代理信息：${NC}"
    echo -e "  地址: ${GREEN}http://${USERNAME}:${PASSWORD}@${SERVER_IP}:${PORT}${NC}"
    echo ""
    echo -e "${YELLOW}测试命令：${NC}"
    echo -e "  curl -x http://${USERNAME}:${PASSWORD}@127.0.0.1:${PORT} http://ip-api.com/json"
    echo ""
    info "配置文件: ${CONF_FILE}"
}

# 添加inbound到主配置
add_inbound_to_config() {
    local conf_file=$1
    
    if [[ ! -f "$conf_file" ]]; then
        error "配置文件不存在: $conf_file"
    fi
    
    # 读取新配置
    local new_inbound=$(cat "$conf_file")
    
    # 添加到主配置的inbounds数组
    jq --argjson inbound "$new_inbound" '.inbounds += [$inbound]' "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"
    
    if [[ $? -eq 0 ]]; then
        mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
    else
        error "更新配置失败"
    fi
}

# 重启sing-box服务
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
        error "服务启动失败，请检查配置"
    fi
}

# 列出所有配置
list_configs() {
    clear
    echo -e "${GREEN}=========================================="
    echo -e "   当前配置列表"
    echo -e "==========================================${NC}"
    echo ""
    
    if [[ ! -f "$SING_BOX_CONFIG" ]]; then
        warn "配置文件不存在"
        return
    fi
    
    # 解析并显示配置
    local inbounds=$(jq -r '.inbounds[] | "\(.tag)|\(.type)|\(.listen_port // "N/A")"' "$SING_BOX_CONFIG" 2>/dev/null)
    
    if [[ -z "$inbounds" ]]; then
        warn "当前没有配置"
        return
    fi
    
    echo -e "${CYAN}序号  类型      端口      标签${NC}"
    echo "----------------------------------------"
    
    local index=1
    while IFS='|' read -r tag type port; do
        printf "%-6s %-10s %-10s %s\n" "$index" "$type" "$port" "$tag"
        ((index++))
    done <<< "$inbounds"
    
    echo ""
}

# 显示配置详情
show_config_info() {
    local tag=$1
    
    if [[ -z "$tag" ]]; then
        error "请指定配置标签"
    fi
    
    clear
    echo -e "${GREEN}=========================================="
    echo -e "   配置详情"
    echo -e "==========================================${NC}"
    echo ""
    
    # 获取配置
    local config=$(jq -r ".inbounds[] | select(.tag == \"$tag\")" "$SING_BOX_CONFIG" 2>/dev/null)
    
    if [[ -z "$config" ]]; then
        error "配置不存在: $tag"
    fi
    
    local type=$(echo "$config" | jq -r '.type')
    local port=$(echo "$config" | jq -r '.listen_port')
    
    echo -e "${YELLOW}标签:${NC} $tag"
    echo -e "${YELLOW}类型:${NC} $type"
    echo -e "${YELLOW}端口:${NC} $port"
    echo ""
    
    SERVER_IP=$(get_server_ip)
    
    if [[ "$type" == "vless" ]]; then
        local uuid=$(echo "$config" | jq -r '.users[0].uuid')
        local flow=$(echo "$config" | jq -r '.users[0].flow // "none"')
        local sni=$(echo "$config" | jq -r '.tls.server_name // "N/A"')
        local public_key=$(echo "$config" | jq -r '.tls.reality.private_key // "N/A"')
        local short_id=$(echo "$config" | jq -r '.tls.reality.short_id[0] // "N/A"')
        
        echo -e "${YELLOW}配置信息：${NC}"
        echo -e "  服务器: ${GREEN}${SERVER_IP}${NC}"
        echo -e "  UUID: ${GREEN}${uuid}${NC}"
        echo -e "  Flow: ${GREEN}${flow}${NC}"
        echo -e "  SNI: ${GREEN}${sni}${NC}"
        
        if [[ "$public_key" != "N/A" ]]; then
            # 从private_key生成public_key (实际应该从配置存储)
            echo -e "  Short ID: ${GREEN}${short_id}${NC}"
        fi
        
    elif [[ "$type" == "http" ]]; then
        local username=$(echo "$config" | jq -r '.users[0].username')
        local password=$(echo "$config" | jq -r '.users[0].password')
        
        echo -e "${YELLOW}代理信息：${NC}"
        echo -e "  地址: ${GREEN}http://${username}:${password}@${SERVER_IP}:${port}${NC}"
        echo ""
        echo -e "${YELLOW}测试命令：${NC}"
        echo -e "  curl -x http://${username}:${password}@127.0.0.1:${port} http://ip-api.com/json"
    fi
    
    echo ""
}

# 删除配置
delete_config() {
    local tag=$1
    
    if [[ -z "$tag" ]]; then
        list_configs
        echo ""
        read -p "请输入要删除的配置标签: " tag
    fi
    
    if [[ -z "$tag" ]]; then
        error "配置标签不能为空"
    fi
    
    # 检查配置是否存在
    local exists=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .tag" "$SING_BOX_CONFIG" 2>/dev/null)
    
    if [[ -z "$exists" ]]; then
        error "配置不存在: $tag"
    fi
    
    # 确认删除
    warn "即将删除配置: $tag"
    read -p "确认删除? (y/n): " confirm
    
    if [[ "$confirm" != "y" ]]; then
        info "已取消删除"
        exit 0
    fi
    
    # 备份配置
    cp "$SING_BOX_CONFIG" "${SING_BOX_CONFIG}.backup.$(date +%s)"
    
    # 删除配置
    jq "del(.inbounds[] | select(.tag == \"$tag\"))" "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"
    mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
    
    # 删除对应的配置文件
    local conf_files=$(find "$SING_BOX_CONF_DIR" -name "*${tag}*.json" 2>/dev/null)
    if [[ -n "$conf_files" ]]; then
        rm -f $conf_files
    fi
    
    # 重启服务
    restart_singbox
    
    success "配置已删除: $tag"
}

# 显示帮助信息
show_help() {
    cat << EOF
${GREEN}sing-box 管理脚本${NC}

用法: $0 [命令] [选项]

${YELLOW}命令:${NC}
  ${CYAN}install${NC}              安装 sing-box
  ${CYAN}list${NC}                 列出所有配置
  ${CYAN}add vless${NC}            添加 VLESS-REALITY 配置
  ${CYAN}add http${NC}             添加 HTTP 代理配置
  ${CYAN}info <tag>${NC}           显示配置详情
  ${CYAN}delete <tag>${NC}         删除指定配置
  ${CYAN}restart${NC}              重启 sing-box 服务
  ${CYAN}status${NC}               查看服务状态
  ${CYAN}help${NC}                 显示此帮助信息

${YELLOW}示例:${NC}
  $0 install                    # 安装 sing-box
  $0 add vless                  # 添加 VLESS-REALITY 配置
  $0 add http                   # 添加 HTTP 代理
  $0 list                       # 查看所有配置
  $0 info vless-reality-443     # 查看配置详情
  $0 delete http-3128           # 删除 HTTP 配置

EOF
}

# 主函数
main() {
    case ${1,,} in
        install)
            install_singbox
            ;;
        list|ls)
            list_configs
            ;;
        add)
            case ${2,,} in
                vless|reality)
                    add_vless_reality
                    ;;
                http|proxy)
                    add_http_proxy
                    ;;
                *)
                    error "未知类型: $2\n使用 'vless' 或 'http'"
                    ;;
            esac
            ;;
        info|show)
            show_config_info "$2"
            ;;
        delete|del|rm)
            delete_config "$2"
            ;;
        restart)
            restart_singbox
            ;;
        status)
            systemctl status sing-box
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            show_help
            ;;
    esac
}

# 运行主函数
main "$@"
