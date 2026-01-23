#!/bin/bash

# sing-box 独立管理脚本 v2.6 (完全展开·终极版)
# 适配: Sing-box v1.10.1 (稳定版，适配 Rule Set 格式)
# 特色: 无色防乱码 / 完整交互UI / IPv6+WARP自动探测 / 动态路由管理

set -euo pipefail  # 严格模式

# ==============================================================================
# 全局配置与变量
# ==============================================================================
SING_BOX_BIN="/usr/local/bin/sing-box"
SING_BOX_CONFIG="/etc/sing-box/config.json"
SING_BOX_CONF_DIR="/etc/sing-box/conf"
SING_BOX_SERVICE="/etc/systemd/system/sing-box.service"
SB_SCRIPT="/usr/local/bin/sb"
MAX_BACKUPS=5
TEMP_DIR=""

HAS_IPV6=false
IS_WARP_IPV6=false

# 推荐固定的稳定版本
TARGET_VERSION="1.10.1"

# ==============================================================================
# 基础工具与清理函数
# ==============================================================================

# 退出时清理临时文件
cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# 基础输出函数 (无色，防乱码)
info() { echo "[INFO] $1"; }
success() { echo "[成功] $1"; }
warn() { echo "[警告] $1"; }
error() { 
    echo "[错误] $1" >&2
    exit 1
}

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用 root 用户运行此脚本"
    fi
}

# 自动修复 sb 命令
auto_fix_sb_command() {
    if [[ "$(basename "$0")" == "sb" ]]; then
        return 0
    fi
    
    if [[ ! -f "$SB_SCRIPT" ]] && [[ "$1" != "install" ]]; then
        local SCRIPT_PATH
        SCRIPT_PATH="$(readlink -f "$0")"
        if [[ -f "$SCRIPT_PATH" ]]; then
            warn "检测到 sb 命令缺失，正在自动修复..."
            if cp "$SCRIPT_PATH" "$SB_SCRIPT" 2>/dev/null && chmod +x "$SB_SCRIPT"; then
                success "sb 命令已修复"
            fi
        fi
    fi
}

# ==============================================================================
# 系统环境检查
# ==============================================================================

# 检查系统架构
check_arch() {
    case $(uname -m) in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7*) ARCH="armv7" ;;
        *) error "不支持的系统架构: $(uname -m)" ;;
    esac
}

# 检查 WARP 状态
check_warp() {
    # 检查 warp-cli
    if command -v warp-cli &>/dev/null; then
        if warp-cli status 2>/dev/null | grep -qi "connected"; then
            IS_WARP_IPV6=true
            return 0
        fi
    fi
    
    # 检查 wg 接口
    if command -v wg &>/dev/null; then
        if wg show 2>/dev/null | grep -q "interface:.*wgcf\|cloudflare"; then
            IS_WARP_IPV6=true
            return 0
        fi
    fi
    
    # 检查路由表
    if ip -6 route 2>/dev/null | grep -q "2606:4700::/32"; then
        IS_WARP_IPV6=true
        return 0
    fi
    
    IS_WARP_IPV6=false
    return 1
}

# 增强的 IPv6 连通性检测 (完整测试逻辑)
check_ipv6() {
    info "正在检测服务器 IPv6 连通性..."
    
    # 1. 检查是否有 IPv6 地址
    if ! ip -6 addr show 2>/dev/null | grep -q "inet6.*global"; then
        HAS_IPV6=false
        warn "未检测到全局 IPv6 地址"
        return 1
    fi
    
    # 2. 检查是否为 WARP
    if check_warp; then
        HAS_IPV6=true
        success "检测到 Cloudflare WARP 虚拟 IPv6 网络"
        info "注意: WARP IPv6 流量将通过 Cloudflare 节点转发"
        return 0
    fi
    
    # 3. 检查 ping6 工具
    if ! command -v ping6 &>/dev/null && ! command -v ping &>/dev/null; then
        warn "ping6 命令不可用，跳过连通性测试"
        HAS_IPV6=false
        return 1
    fi
    
    # 4. 多目标测试（Google、Cloudflare、OpenDNS）
    local test_targets=(
        "2404:6800:4008:c13::8a"  # Google
        "2606:4700:4700::1111"     # Cloudflare
        "2001:4860:4860::8888"     # Google DNS
    )
    
    local ping_cmd="ping6"
    command -v ping6 &>/dev/null || ping_cmd="ping -6"
    
    for target in "${test_targets[@]}"; do
        if timeout 5 $ping_cmd -c 1 -W 3 "$target" &>/dev/null; then
            HAS_IPV6=true
            success "检测到有效原生 IPv6 网络（测试目标: $target）"
            return 0
        fi
    done
    
    HAS_IPV6=false
    warn "未检测到有效 IPv6 网络连通性"
    return 1
}

# 安装依赖包
install_dependencies() {
    info "检查并安装依赖包..."
    
    local packages=("curl" "wget" "jq" "tar" "gzip" "openssl")
    local missing_packages=()
    
    for pkg in "${packages[@]}"; do
        if ! command -v "$pkg" &>/dev/null; then
            missing_packages+=("$pkg")
        fi
    done
    
    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        success "所有依赖已安装"
        return 0
    fi
    
    info "需要安装: ${missing_packages[*]}"
    
    if command -v apt-get &>/dev/null; then
        apt-get update -qq || warn "apt-get update 失败"
        apt-get install -y "${missing_packages[@]}" || error "依赖安装失败"
    elif command -v yum &>/dev/null; then
        yum install -y "${missing_packages[@]}" || error "依赖安装失败"
    elif command -v dnf &>/dev/null; then
        dnf install -y "${missing_packages[@]}" || error "依赖安装失败"
    else
        error "不支持的包管理器，请手动安装: ${missing_packages[*]}"
    fi
    
    success "依赖安装完成"
}

# ==============================================================================
# 配置与服务管理
# ==============================================================================

# 生成基础配置文件 (分流 vs 不分流)
generate_base_config() {
    local enable_ipv6=$1

    if [[ "$enable_ipv6" == "true" ]]; then
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
    },
    {
      "type": "direct",
      "tag": "direct-ipv4",
      "domain_strategy": "ipv4_only"
    },
    {
      "type": "direct",
      "tag": "direct-ipv6",
      "domain_strategy": "ipv6_only"
    }
  ],
  "route": {
    "rules": [
      {
        "rule_set": ["geosite-google", "geosite-youtube", "geosite-netflix", "geosite-telegram"],
        "outbound": "direct-ipv6"
      },
      {
        "rule_set": ["geosite-cn", "geoip-cn"],
        "outbound": "direct-ipv4"
      },
      {
        "ip_is_private": true,
        "outbound": "direct"
      }
    ],
    "rule_set": [
      {
        "tag": "geosite-google",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-google.srs",
        "download_detour": "direct-ipv4"
      },
      {
        "tag": "geosite-youtube",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-youtube.srs",
        "download_detour": "direct-ipv4"
      },
      {
        "tag": "geosite-netflix",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-netflix.srs",
        "download_detour": "direct-ipv4"
      },
      {
        "tag": "geosite-telegram",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-telegram.srs",
        "download_detour": "direct-ipv4"
      },
      {
        "tag": "geosite-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
        "download_detour": "direct-ipv4"
      },
      {
        "tag": "geoip-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
        "download_detour": "direct-ipv4"
      }
    ]
  }
}
EOF
    else
        # 纯 IPv4 / 无分流配置
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
    "rules": [
      {
        "ip_is_private": true,
        "outbound": "direct"
      }
    ]
  }
}
EOF
    fi
}

# 验证配置文件
validate_config() {
    local config_file=${1:-$SING_BOX_CONFIG}
    
    if [[ ! -f "$config_file" ]]; then
        error "配置文件不存在: $config_file"
    fi
    
    if ! jq empty "$config_file" 2>/dev/null; then
        error "配置文件 JSON 格式错误: $config_file"
    fi
    
    if [[ -f "$SING_BOX_BIN" ]]; then
        if ! "$SING_BOX_BIN" check -c "$config_file" 2>/dev/null; then
            error "sing-box 配置验证失败，请检查配置"
        fi
    fi
}

# 备份配置文件
backup_config() {
    local backup_dir="/etc/sing-box/backups"
    mkdir -p "$backup_dir"
    
    local backup_file="${backup_dir}/config.$(date +%Y%m%d_%H%M%S).json"
    cp "$SING_BOX_CONFIG" "$backup_file" || error "备份失败"
    
    # 限制备份数量
    local backup_count
    backup_count=$(find "$backup_dir" -name "config.*.json" | wc -l)
    if [[ $backup_count -gt $MAX_BACKUPS ]]; then
        find "$backup_dir" -name "config.*.json" -type f -printf '%T+ %p\n' | \
            sort | head -n -"$MAX_BACKUPS" | cut -d' ' -f2- | xargs rm -f
    fi
    info "配置已备份: $backup_file"
}

# 添加 Inbound 到主配置
add_inbound_to_config() {
    local conf_file=$1
    if [[ ! -f "$conf_file" ]]; then
        error "配置文件不存在: $conf_file"
    fi
    
    backup_config
    
    local new_inbound
    new_inbound=$(cat "$conf_file")
    
    if ! jq --argjson inbound "$new_inbound" '.inbounds += [$inbound]' "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"; then
        error "更新配置失败"
    fi
    
    validate_config "${SING_BOX_CONFIG}.tmp"
    mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
}

# 重启 sing-box
restart_singbox() {
    info "验证配置文件..."
    validate_config
    
    info "重启 sing-box 服务..."
    if ! systemctl restart sing-box; then
        error "服务重启失败"
    fi
    
    sleep 2
    
    if systemctl is-active --quiet sing-box; then
        success "服务重启成功"
    else
        error "服务启动失败，请检查日志: journalctl -u sing-box -n 50"
    fi
}

# ==============================================================================
# 安装与卸载逻辑
# ==============================================================================

# 安装 sing-box (锁定 v1.10.1 稳定版)
install_singbox() {
    clear
    echo "=========================================="
    echo "   sing-box 安装程序 (锁定稳定版)"
    echo "=========================================="
    echo ""
    
    check_root
    check_arch
    
    if [[ -f "$SING_BOX_BIN" ]]; then
        warn "sing-box 已安装"
        read -p "是否重新安装? (y/n): " confirm
        if [[ "$confirm" != "y" ]]; then
            exit 0
        fi
    fi
    
    install_dependencies
    check_ipv6
    
    info "锁定安装稳定版本: v${TARGET_VERSION}"
    local DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${TARGET_VERSION}/sing-box-${TARGET_VERSION}-linux-${ARCH}.tar.gz"
    
    info "下载 sing-box v${TARGET_VERSION}..."
    TEMP_DIR=$(mktemp -d)
    
    # 完整重试逻辑
    local retry_count=0
    local max_retries=3
    while [[ $retry_count -lt $max_retries ]]; do
        if wget --timeout=30 --tries=3 -q --show-progress "$DOWNLOAD_URL" -O "${TEMP_DIR}/sing-box.tar.gz"; then
            break
        fi
        retry_count=$((retry_count + 1))
        if [[ $retry_count -lt $max_retries ]]; then
            warn "下载失败，重试 ($retry_count/$max_retries)..."
            sleep 2
        else
            error "sing-box 下载失败，请检查网络或稍后重试"
        fi
    done
    
    info "解压文件..."
    tar -xzf "${TEMP_DIR}/sing-box.tar.gz" -C "$TEMP_DIR" || error "解压失败"
    
    local BINARY_FILE
    BINARY_FILE=$(find "$TEMP_DIR" -name "sing-box" -type f | head -n1)
    if [[ -z "$BINARY_FILE" ]]; then
        error "未找到二进制文件"
    fi
    
    cp "$BINARY_FILE" "$SING_BOX_BIN" || error "复制失败"
    chmod +x "$SING_BOX_BIN"
    
    mkdir -p /etc/sing-box
    mkdir -p "$SING_BOX_CONF_DIR"
    mkdir -p /etc/sing-box/backups

    generate_base_config "$HAS_IPV6"
    validate_config
    
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
    systemctl enable sing-box &>/dev/null || warn "设置开机自启失败"
    systemctl start sing-box || error "服务启动失败"
    
    local SCRIPT_PATH="$(readlink -f "$0")"
    if [[ -f "$SCRIPT_PATH" ]]; then
        cp "$SCRIPT_PATH" "$SB_SCRIPT"
        chmod +x "$SB_SCRIPT"
    fi
    
    sleep 2
    if systemctl is-active --quiet sing-box; then
        echo ""
        success "sing-box 安装成功！版本: v${TARGET_VERSION}"
        if [[ "$HAS_IPV6" == "true" ]]; then
            info "智能分流状态: 已开启"
        else
            info "智能分流状态: 未开启"
        fi
        echo ""
        info "使用 'sb help' 查看所有命令"
    else
        error "sing-box 服务启动失败，请使用 'sb log' 查看日志"
    fi
}

# 卸载 sing-box
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
    
    if [[ "$confirm" != "YES" ]]; then
        info "已取消"
        exit 0
    fi
    
    echo ""
    info "开始卸载..."
    
    if systemctl is-active --quiet sing-box; then
        systemctl stop sing-box
    fi
    
    if systemctl is-enabled --quiet sing-box &>/dev/null; then
        systemctl disable sing-box &>/dev/null
    fi
    
    [[ -f "$SING_BOX_SERVICE" ]] && rm -f "$SING_BOX_SERVICE"
    systemctl daemon-reload
    
    [[ -f "$SING_BOX_BIN" ]] && rm -f "$SING_BOX_BIN"
    
    if [[ -d "/etc/sing-box" ]]; then
        read -p "备份配置? (y/n): " backup
        if [[ "$backup" == "y" ]]; then
            local BACKUP_DIR="/root/sing-box-backup-$(date +%Y%m%d-%H%M%S)"
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

# ==============================================================================
# 工具与生成器
# ==============================================================================

generate_uuid() {
    if [[ -f "$SING_BOX_BIN" ]]; then
        "$SING_BOX_BIN" generate uuid
    elif command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        error "无法生成 UUID"
    fi
}

generate_reality_keypair() {
    if [[ -f "$SING_BOX_BIN" ]]; then
        "$SING_BOX_BIN" generate reality-keypair
    else
        error "sing-box 未安装"
    fi
}

generate_short_id() {
    openssl rand -hex 8 2>/dev/null || error "openssl 不可用"
}

get_server_ip() {
    local ip
    ip=$(curl -sSL --connect-timeout 5 --max-time 10 ip.sb 2>/dev/null || \
         curl -sSL --connect-timeout 5 --max-time 10 ifconfig.me 2>/dev/null || \
         curl -sSL --connect-timeout 5 --max-time 10 icanhazip.com 2>/dev/null)
    
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I | awk '{print $1}')
    fi
    
    if [[ -z "$ip" ]]; then
        ip="YOUR_SERVER_IP"
    fi
    
    echo "$ip"
}

# 改进的端口生成函数
generate_port() {
    local min=${1:-10000}
    local max=${2:-65535}
    local max_attempts=100
    
    for ((i=0; i<max_attempts; i++)); do
        local port=$((RANDOM % (max - min + 1) + min))
        
        if command -v ss &>/dev/null; then
            if ! ss -tuln | awk '{print $5}' | grep -qw ":$port$"; then
                echo "$port"
                return 0
            fi
        elif command -v netstat &>/dev/null; then
            if ! netstat -tuln | awk '{print $4}' | grep -qw ":$port$"; then
                echo "$port"
                return 0
            fi
        else
            echo "$port"
            return 0
        fi
    done
    
    error "无法找到可用端口"
}

# 验证端口输入
validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        error "端口必须是数字"
    fi
    
    if [[ $port -lt 1 || $port -gt 65535 ]]; then
        error "端口范围必须在 1-65535 之间"
    fi
    
    if command -v ss &>/dev/null; then
        if ss -tuln | awk '{print $5}' | grep -qw ":$port$"; then
            error "端口 $port 已被占用"
        fi
    fi
}

# ==============================================================================
# 节点管理与交互UI
# ==============================================================================

# 添加 VLESS-REALITY 配置
add_vless_reality() {
    clear
    echo "=========================================="
    echo "   添加 VLESS-REALITY 配置"
    echo "=========================================="
    echo ""
    
    # 获取参数
    local PORT
    read -p "端口 (默认随机): " PORT
    if [[ -z "$PORT" ]]; then
        PORT=$(generate_port)
    else
        validate_port "$PORT"
    fi
    
    local UUID
    read -p "UUID (默认随机): " UUID
    if [[ -z "$UUID" ]]; then
        UUID=$(generate_uuid)
    fi
    
    local SNI
    read -p "SNI (默认 www.apple.com): " SNI
    if [[ -z "$SNI" ]]; then
        SNI="www.apple.com"
    fi
    
    local DEST_SERVER
    read -p "目标服务器 (默认 $SNI): " DEST_SERVER
    if [[ -z "$DEST_SERVER" ]]; then
        DEST_SERVER="$SNI"
    fi

    local DEST_PORT
    read -p "目标端口 (默认 443): " DEST_PORT
    if [[ -z "$DEST_PORT" ]]; then
        DEST_PORT=443
    else
        validate_port "$DEST_PORT"
    fi
    
    info "生成密钥对..."
    local KEYPAIR PRIVATE_KEY PUBLIC_KEY SHORT_ID
    KEYPAIR=$(generate_reality_keypair) || error "密钥生成失败"
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep "PublicKey" | awk '{print $2}')
    SHORT_ID=$(generate_short_id)
    
    local CONF_FILE="${SING_BOX_CONF_DIR}/vless-reality-${PORT}.json"
    
    # 写入配置文件
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
    
    # 去除 public_key 后导入主配置
    local temp_config
    temp_config=$(jq 'del(.public_key)' "$CONF_FILE")
    echo "$temp_config" > "${CONF_FILE}.tmp"
    
    add_inbound_to_config "${CONF_FILE}.tmp"
    rm -f "${CONF_FILE}.tmp"
    
    restart_singbox
    
    # 生成链接信息
    local SERVER_IP
    SERVER_IP=$(get_server_ip)
    local VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS-${PORT}"
    
    echo ""
    success "VLESS-REALITY 添加成功！"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📱 完整链接（可直接导入客户端）："
    echo ""
    echo "${VLESS_LINK}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "配置详情："
    echo "  服务器: ${SERVER_IP}"
    echo "  端口: ${PORT}"
    echo "  UUID: ${UUID}"
    echo "  目标服务器: ${DEST_SERVER}:${DEST_PORT}"
    echo "  SNI: ${SNI}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    read -p "按回车继续..." dummy
}

# 添加 HTTP 代理
add_http_proxy() {
    clear
    echo "=========================================="
    echo "   添加 HTTP 代理"
    echo "=========================================="
    echo ""
    
    local PORT USER PASS
    
    read -p "端口 (默认3128): " PORT
    if [[ -z "$PORT" ]]; then
        PORT=3128
    else
        validate_port "$PORT"
    fi
    
    read -p "用户名 (默认httpuser): " USER
    if [[ -z "$USER" ]]; then
        USER="httpuser"
    fi
    
    read -p "密码 (默认随机生成): " PASS
    if [[ -z "$PASS" ]]; then
        PASS=$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-16)
        info "已生成密码: ${PASS}"
    fi
    
    local CONF_FILE="${SING_BOX_CONF_DIR}/http-${PORT}.json"
    
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
    
    local SERVER_IP
    SERVER_IP=$(get_server_ip)
    
    echo ""
    success "HTTP 代理添加成功！"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🌐 代理地址："
    echo ""
    echo "http://${USER}:${PASS}@${SERVER_IP}:${PORT}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    read -p "按回车继续..." dummy
}

# 添加 SOCKS5 代理
add_socks5_proxy() {
    clear
    echo "=========================================="
    echo "   添加 SOCKS5 代理"
    echo "=========================================="
    echo ""
    
    local PORT AUTH USER PASS
    
    read -p "端口 (默认1080): " PORT
    if [[ -z "$PORT" ]]; then
        PORT=1080
    else
        validate_port "$PORT"
    fi
    
    read -p "需要认证? (y/n, 默认n): " AUTH
    
    local CONF_FILE="${SING_BOX_CONF_DIR}/socks-${PORT}.json"
    
    if [[ "$AUTH" == "y" ]]; then
        read -p "用户名 (默认socksuser): " USER
        if [[ -z "$USER" ]]; then
            USER="socksuser"
        fi
        
        read -p "密码 (默认随机生成): " PASS
        if [[ -z "$PASS" ]]; then
            PASS=$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-16)
            info "已生成密码: ${PASS}"
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
    
    local SERVER_IP
    SERVER_IP=$(get_server_ip)
    
    echo ""
    success "SOCKS5 代理添加成功！"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔌 代理地址："
    echo ""
    if [[ "$AUTH" == "y" ]]; then
        echo "socks5://${USER}:${PASS}@${SERVER_IP}:${PORT}"
    else
        echo "socks5://${SERVER_IP}:${PORT}"
    fi
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    read -p "按回车继续..." dummy
}

# 交互式列出配置
list_configs() {
    clear
    echo "=========================================="
    echo "   配置列表"
    echo "=========================================="
    echo ""
    
    if [[ ! -f "$SING_BOX_CONFIG" ]]; then
        warn "配置文件不存在"
        return
    fi
    
    local inbounds
    inbounds=$(jq -r '.inbounds[] | "\(.tag)|\(.type)|\(.listen_port // "N/A")"' "$SING_BOX_CONFIG" 2>/dev/null)
    
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
    
    echo "序号  类型          端口      标签"
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

# 显示配置详情
show_config_info() {
    local tag=$1
    if [[ -z "$tag" ]]; then
        error "请指定配置标签"
    fi
    
    clear
    echo "=========================================="
    echo "   配置详情"
    echo "=========================================="
    echo ""
    
    local config
    config=$(jq -r ".inbounds[] | select(.tag == \"$tag\")" "$SING_BOX_CONFIG" 2>/dev/null)
    if [[ -z "$config" ]]; then
        error "配置不存在: $tag"
    fi
    
    local type port SERVER_IP
    type=$(echo "$config" | jq -r '.type')
    port=$(echo "$config" | jq -r '.listen_port')
    SERVER_IP=$(get_server_ip)
    
    echo "标签: $tag"
    echo "类型: $type"
    echo "端口: $port"
    echo "服务器: $SERVER_IP"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    if [[ "$type" == "vless" ]]; then
        local uuid flow sni short_id public_key
        uuid=$(echo "$config" | jq -r '.users[0].uuid')
        flow=$(echo "$config" | jq -r '.users[0].flow // "none"')
        sni=$(echo "$config" | jq -r '.tls.server_name // "N/A"')
        short_id=$(echo "$config" | jq -r '.tls.reality.short_id[0] // ""')
        
        local conf_file="${SING_BOX_CONF_DIR}/${tag}.json"
        if [[ -f "$conf_file" ]]; then
            public_key=$(jq -r '.public_key // ""' "$conf_file")
        fi
        
        if [[ -n "$public_key" && "$flow" == "xtls-rprx-vision" ]]; then
            local vless_link="vless://${uuid}@${SERVER_IP}:${port}?encryption=none&flow=${flow}&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#VLESS-${port}"
            
            echo "📱 VLESS-REALITY 链接："
            echo ""
            echo "${vless_link}"
            echo ""
        fi
        
    elif [[ "$type" == "http" ]]; then
        local username password
        username=$(echo "$config" | jq -r '.users[0].username')
        password=$(echo "$config" | jq -r '.users[0].password')
        
        echo "🌐 HTTP 代理地址："
        echo ""
        echo "http://${username}:${password}@${SERVER_IP}:${port}"
        echo ""
        
    elif [[ "$type" == "socks" ]]; then
        local username password
        username=$(echo "$config" | jq -r '.users[0].username // ""')
        password=$(echo "$config" | jq -r '.users[0].password // ""')
        
        echo "🔌 SOCKS5 代理地址："
        echo ""
        if [[ -n "$username" ]]; then
            echo "socks5://${username}:${password}@${SERVER_IP}:${port}"
        else
            echo "socks5://${SERVER_IP}:${port}"
        fi
        echo ""
    fi
    
    echo ""
    read -p "按回车返回列表..." dummy
    list_configs
}

# 交互式删除配置
delete_config() {
    local tag=$1
    
    if [[ -z "$tag" ]]; then
        list_configs
        echo ""
        read -p "请输入要删除的配置标签: " tag
    fi
    
    if [[ -z "$tag" ]]; then
        return
    fi
    
    local exists
    exists=$(jq -r ".inbounds[] | select(.tag == \"$tag\") | .tag" "$SING_BOX_CONFIG" 2>/dev/null)
    if [[ -z "$exists" ]]; then
        error "配置不存在: $tag"
    fi
    
    warn "即将删除配置: $tag"
    read -p "确认删除? (y/n): " confirm
    
    if [[ "$confirm" != "y" ]]; then
        info "已取消"
        return 0
    fi
    
    backup_config
    
    if ! jq "del(.inbounds[] | select(.tag == \"$tag\"))" "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"; then
        error "删除配置失败"
    fi
    
    validate_config "${SING_BOX_CONFIG}.tmp"
    mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
    
    find "$SING_BOX_CONF_DIR" -name "*${tag}*.json" -delete 2>/dev/null
    
    restart_singbox
    success "配置已删除: $tag"
}

# ==============================================================================
# 动态路由管理
# ==============================================================================

manage_route() {
    local action=$1
    local domain=$2
    local target=$3

    if [[ ! -f "$SING_BOX_CONFIG" ]]; then
        error "未找到配置文件"
    fi

    case $action in
        on)
            info "正在开启 IPv4/v6 智能分流..."
            backup_config
            
            local inbounds
            inbounds=$(jq '.inbounds' "$SING_BOX_CONFIG")
            generate_base_config "true"
            
            if ! jq --argjson inbounds "$inbounds" '.inbounds = $inbounds' "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"; then
                error "配置更新失败"
            fi
            
            validate_config "${SING_BOX_CONFIG}.tmp"
            mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
            
            restart_singbox
            success "分流已开启！Google/Youtube/Netflix/TG 将优先走 IPv6。"
            ;;
            
        off)
            info "正在关闭分流，切换至普通模式..."
            backup_config
            
            local inbounds
            inbounds=$(jq '.inbounds' "$SING_BOX_CONFIG")
            generate_base_config "false"
            
            if ! jq --argjson inbounds "$inbounds" '.inbounds = $inbounds' "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"; then
                error "配置更新失败"
            fi
            
            validate_config "${SING_BOX_CONFIG}.tmp"
            mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
            
            restart_singbox
            success "分流已关闭！所有流量将走默认路由。"
            ;;
            
        add)
            if [[ -z "$domain" || -z "$target" ]]; then
                error "用法: sb route add <域名> <v4/v6>"
            fi
            if [[ "$target" != "v4" && "$target" != "v6" ]]; then
                error "目标只能是 v4 或 v6"
            fi
            
            if ! jq -e '.outbounds[] | select(.tag=="direct-ipv6")' "$SING_BOX_CONFIG" &>/dev/null; then
                error "当前未开启分流功能，请先执行 'sb route on' 开启。"
            fi

            if jq -e ".route.rules[] | select(.domain[]? == \"$domain\")" "$SING_BOX_CONFIG" &>/dev/null; then
                warn "域名 $domain 的规则已存在"
                read -p "是否覆盖? (y/n): " confirm
                if [[ "$confirm" != "y" ]]; then
                    return 0
                fi
                
                if ! jq "del(.route.rules[] | select(.domain[]? == \"$domain\"))" "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"; then
                    error "删除旧规则失败"
                fi
                mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
            fi

            info "正在添加规则: 访问 $domain 将走 IPv$target"
            backup_config
            
            local outbound_tag="direct-ipv4"
            if [[ "$target" == "v6" ]]; then
                outbound_tag="direct-ipv6"
            fi

            if ! jq --arg domain "$domain" --arg out "$outbound_tag" \
               '.route.rules = [{"domain": [$domain], "outbound": $out}] + .route.rules' \
               "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"; then
                error "添加规则失败"
            fi
            
            validate_config "${SING_BOX_CONFIG}.tmp"
            mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
            restart_singbox
            success "已添加分流规则: $domain -> IPv$target"
            ;;
            
        status)
            info "当前路由分流状态："
            echo ""
            if jq -e '.outbounds[] | select(.tag=="direct-ipv6")' "$SING_BOX_CONFIG" &>/dev/null; then
                success "智能分流功能: [已开启]"
                echo ""
                echo "默认分流规则:"
                echo "  • Google/Youtube/Netflix/Telegram → IPv6"
                echo "  • 国内网站 (CN) → IPv4"
                echo "  • 内网地址 → 直连"
                echo ""
                local custom_rules
                custom_rules=$(jq -r '.route.rules[] | select(.domain != null and (.rule_set == null)) | "  • \(.domain[]) → \(.outbound)"' "$SING_BOX_CONFIG" 2>/dev/null)
                if [[ -n "$custom_rules" ]]; then
                    echo "自定义规则:"
                    echo "$custom_rules"
                fi
            else
                warn "智能分流功能: [已关闭]"
                echo "所有流量走系统默认路由。"
            fi
            ;;
            
        *)
            echo "=========================================="
            echo "   路由分流管理帮助"
            echo "=========================================="
            echo "命令用法:"
            echo "  sb route status            - 查看当前分流状态"
            echo "  sb route on                - 开启智能分流"
            echo "  sb route off               - 关闭分流 (单栈模式)"
            echo "  sb route add <域名> <v4/v6> - 指定网站走 v4 或 v6"
            ;;
    esac
}

# ==============================================================================
# 帮助信息与日志
# ==============================================================================

show_help() {
    cat << 'EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      sing-box 管理脚本 v2.6 (终极版)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📦 安装与卸载:
  sb install          安装 sing-box (固定 v1.10.1 稳定版)
  sb uninstall        卸载 sing-box

📋 节点配置管理:
  sb list             查看配置列表 (交互式)
  sb add vless        添加 VLESS-REALITY
  sb add http         添加 HTTP 代理
  sb add socks        添加 SOCKS5 代理
  sb delete           删除配置 (交互式)

🌐 路由分流管理:
  sb route status     查看分流状态
  sb route on         开启智能分流
  sb route off        关闭分流
  sb route add <域名> <v4/v6>  指定域名走 v4 或 v6

🔧 服务管理:
  sb restart          重启服务
  sb status           查看状态
  sb log              查看实时日志

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

show_log() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   实时日志 (Ctrl+C 退出)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    journalctl -u sing-box -f --no-pager
}

# ==============================================================================
# 主函数入口
# ==============================================================================

main() {
    # 自动修复命令
    auto_fix_sb_command "$1"
    
    case ${1,,} in
        install) 
            install_singbox 
            ;;
        uninstall) 
            uninstall_singbox 
            ;;
        route) 
            manage_route "$2" "$3" "$4" 
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
                socks|socks5) 
                    add_socks5_proxy 
                    ;;
                *) 
                    error "未知类型: $2\n使用: vless | http | socks" 
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
        log|logs) 
            show_log 
            ;;
        help|--help|-h|"") 
            show_help 
            ;;
        *) 
            error "未知命令: $1\n使用 'sb help' 查看帮助" 
            ;;
    esac
}

main "$@"
