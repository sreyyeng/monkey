#!/bin/bash

# sing-box 独立管理脚本 v3.1 (1.12+ 终极纯净修复版)
# 核心修正: 彻底删除 dns.servers 中的非法字段 "strategy" (解决 FATAL)
# 逻辑重构: 利用出站 (outbounds) 的 domain_strategy 来控制 IP 分流，符合官方最新最佳实践。
# 特性: 100% 完整交互菜单 / IPv6 自动探测 / 动态路由管理 / 完整增删改查

# 配置路径
SING_BOX_BIN="/usr/local/bin/sing-box"
SING_BOX_CONFIG="/etc/sing-box/config.json"
SING_BOX_CONF_DIR="/etc/sing-box/conf"
SING_BOX_SERVICE="/etc/systemd/system/sing-box.service"
SB_SCRIPT="/usr/local/bin/sb"

# 基础输出函数
info() { echo -e "\033[34m[INFO]\033[0m $1"; }
success() { echo -e "\033[32m[成功]\033[0m $1"; }
warn() { echo -e "\033[33m[警告]\033[0m $1"; }
error() { echo -e "\033[31m[错误]\033[0m $1"; exit 1; }

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
            [[ -f "$SB_SCRIPT" ]] && success "sb 命令已修复"
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

# 检查 IPv6 连通性
check_ipv6() {
    info "正在检测服务器 IPv6 连通性..."
    if ping6 -c 1 -W 3 2404:6800:4008:c13::8a &>/dev/null; then
        HAS_IPV6=true
        success "检测到有效 IPv6 网络，将自动配置智能分流。"
    else
        HAS_IPV6=false
        warn "未检测到有效 IPv6 网络，将使用默认单栈模式。"
    fi
}

# 安装依赖
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

# === v3.1 核心修正：删除 DNS 中的 strategy，回归官方纯净语法 ===
generate_base_config() {
    local enable_ipv6=$1
    
    if [[ "$enable_ipv6" == "true" ]]; then
        cat > "$SING_BOX_CONFIG" << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "type": "https",
        "server": "1.1.1.1",
        "detour": "direct"
      },
      {
        "tag": "dns-local",
        "type": "local",
        "detour": "direct"
      }
    ],
    "final": "dns-remote"
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
      "domain_resolver": "dns-remote",
      "domain_strategy": "ipv4_only"
    },
    {
      "type": "direct",
      "tag": "direct-ipv6",
      "domain_resolver": "dns-remote",
      "domain_strategy": "ipv6_only"
    }
  ],
  "route": {
    "default_domain_resolver": "dns-remote",
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
        cat > "$SING_BOX_CONFIG" << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "type": "https",
        "server": "1.1.1.1",
        "detour": "direct"
      },
      {
        "tag": "dns-local",
        "type": "local",
        "detour": "direct"
      }
    ],
    "final": "dns-remote"
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "default_domain_resolver": "dns-remote",
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

# 安装sing-box
install_singbox() {
    clear
    echo "=========================================="
    echo "   sing-box 安装程序 (v3.1 终极纯净版)"
    echo "=========================================="
    echo ""
    
    check_root
    check_arch
    
    if [[ -f "$SING_BOX_BIN" ]]; then
        warn "sing-box 已安装"
        read -p "是否重新安装覆盖? (y/n): " confirm
        [[ "$confirm" != "y" ]] && exit 0
    fi
    
    install_dependencies
    check_ipv6
    
    info "获取最新版本信息..."
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name' | sed 's/v//')
    [[ -z "$LATEST_VERSION" ]] && error "无法获取最新版本信息"
    
    info "最新版本: v${LATEST_VERSION}"
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${ARCH}.tar.gz"
    
    info "下载 sing-box..."
    TEMP_DIR=$(mktemp -d)
    if ! wget -q --show-progress "$DOWNLOAD_URL" -O "${TEMP_DIR}/sing-box.tar.gz"; then
        error "sing-box 下载失败"
    fi
    
    tar -xzf "${TEMP_DIR}/sing-box.tar.gz" -C "$TEMP_DIR"
    BINARY_FILE=$(find "$TEMP_DIR" -name "sing-box" -type f)
    [[ -z "$BINARY_FILE" ]] && error "未找到二进制文件"
    
    cp "$BINARY_FILE" "$SING_BOX_BIN"
    chmod +x "$SING_BOX_BIN"
    rm -rf "$TEMP_DIR"
    
    mkdir -p /etc/sing-box
    mkdir -p "$SING_BOX_CONF_DIR"

    # 生成配置
    generate_base_config "$HAS_IPV6"
    
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
    else
        warn "无法自动创建 sb 命令"
    fi
    
    if systemctl is-active --quiet sing-box; then
        echo ""
        success "sing-box 安装成功！(1.12+ 适配通过)"
        if [[ "$HAS_IPV6" == "true" ]]; then
            info "智能分流状态: 已开启"
        else
            info "智能分流状态: 未开启 (未检测到 IPv6)"
        fi
        echo ""
    else
        error "sing-box 服务启动失败，请使用 sb log 查看日志"
    fi
}

# 工具函数
generate_uuid() {
    if [[ -f "$SING_BOX_BIN" ]]; then
        "$SING_BOX_BIN" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid
    else
        cat /proc/sys/kernel/random/uuid
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
    
    # 注入前先验证 JSON 合法性
    if ! jq . "$conf_file" >/dev/null 2>&1; then
        error "即将添加的配置非合法 JSON 格式，请检查生成逻辑！"
    fi

    local new_inbound=$(cat "$conf_file")
    jq --argjson inbound "$new_inbound" '.inbounds += [$inbound]' "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"
    
    if [[ $? -eq 0 ]]; then
        mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
    else
        error "合并配置失败，请检查 jq 工具是否正常。"
    fi
}

restart_singbox() {
    info "测试配置文件语法..."
    # 开放报错日志输出，便于排查
    if ! "$SING_BOX_BIN" check -c "$SING_BOX_CONFIG"; then
        echo ""
        error "配置文件语法错误！请根据上方的 Sing-box 报错信息排查。"
    fi
    
    info "重启 sing-box 服务..."
    systemctl restart sing-box
    sleep 2
    
    if systemctl is-active --quiet sing-box; then
        success "服务重启成功"
    else
        error "服务启动失败，请使用 sb log 查看日志"
    fi
}

# === 节点添加区：恢复完整交互菜单 ===

# 添加VLESS-REALITY配置
add_vless_reality() {
    clear
    echo "=========================================="
    echo "   添加 VLESS-REALITY 配置"
    echo "=========================================="
    echo ""
    
    read -p "端口 (默认随机): " PORT
    [[ -z "$PORT" ]] && PORT=$(generate_port)
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -gt 65535 ]; then error "非法端口号"; fi
    
    read -p "UUID (默认随机): " UUID
    [[ -z "$UUID" ]] && UUID=$(generate_uuid)
    
    read -p "SNI (默认 www.apple.com): " SNI
    [[ -z "$SNI" ]] && SNI="www.apple.com"
    
    read -p "目标服务器 (默认 www.apple.com): " DEST_SERVER
    [[ -z "$DEST_SERVER" ]] && DEST_SERVER="www.apple.com"

    read -p "目标端口 (默认 443): " DEST_PORT
    [[ -z "$DEST_PORT" ]] && DEST_PORT=443
    if ! [[ "$DEST_PORT" =~ ^[0-9]+$ ]]; then error "目标端口必须是数字"; fi
    
    info "正在生成 Reality 密钥对..."
    KEYPAIR=$("$SING_BOX_BIN" generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep "PublicKey" | awk '{print $2}')
    SHORT_ID=$(generate_short_id)

    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        error "密钥对生成失败，请检查 sing-box 是否正常。"
    fi
    
    CONF_FILE="${SING_BOX_CONF_DIR}/vless-reality-${PORT}.json"
    
    cat > "$CONF_FILE" << EOF
{
  "type": "vless",
  "tag": "vless-reality-${PORT}",
  "listen": "0.0.0.0",
  "listen_port": ${PORT},
  "sniff": true,
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
  }
}
EOF
    
    # 将公钥单独保存到 .pub 文件中备查，不污染主配置
    echo "$PUBLIC_KEY" > "${CONF_FILE}.pub"

    add_inbound_to_config "$CONF_FILE"
    restart_singbox
    
    SERVER_IP=$(get_server_ip)
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS-${PORT}"
    echo ""
    success "VLESS-REALITY 添加成功！(1.12+ 适配)"
    echo ""
    echo "📱 完整链接："
    echo ""
    echo "${VLESS_LINK}"
    echo ""
    read -p "按回车继续..." dummy
}

# 添加HTTP代理
add_http_proxy() {
    clear
    echo "=========================================="
    echo "   添加 HTTP 代理"
    echo "=========================================="
    echo ""
    
    read -p "端口 (默认3128): " PORT
    [[ -z "$PORT" ]] && PORT=3128
    if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then error "非法端口号"; fi
    
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
  "sniff": true,
  "users": [{"username": "${USER}", "password": "${PASS}"}]
}
EOF
    
    add_inbound_to_config "$CONF_FILE"
    restart_singbox
    
    SERVER_IP=$(get_server_ip)
    
    echo ""
    success "HTTP 代理添加成功！"
    echo ""
    echo "🌐 完整地址："
    echo ""
    echo "http://${USER}:${PASS}@${SERVER_IP}:${PORT}"
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
    
    read -p "端口 (默认1080): " PORT
    [[ -z "$PORT" ]] && PORT=1080
    if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then error "非法端口号"; fi
    
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
  "sniff": true,
  "users": [{"username": "${USER}", "password": "${PASS}"}]
}
EOF
    else
        cat > "$CONF_FILE" << EOF
{
  "type": "socks",
  "tag": "socks-${PORT}",
  "listen": "0.0.0.0",
  "listen_port": ${PORT},
  "sniff": true
}
EOF
    fi
    
    add_inbound_to_config "$CONF_FILE"
    restart_singbox
    
    SERVER_IP=$(get_server_ip)
    
    echo ""
    success "SOCKS5 添加成功！"
    echo ""
    echo "🔌 完整地址："
    echo ""
    if [[ "$AUTH" == "y" ]]; then
        echo "socks5://${USER}:${PASS}@${SERVER_IP}:${PORT}"
    else
        echo "socks5://${SERVER_IP}:${PORT}"
    fi
    echo ""
    read -p "按回车继续..." dummy
}

# 列出配置（交互式）
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
    SERVER_IP=$(get_server_ip)
    
    echo "标签: $tag"
    echo "类型: $type"
    echo "端口: $port"
    echo "服务器: $SERVER_IP"
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
        # 从 .pub 文件读取公钥
        if [[ -f "${conf_file}.pub" ]]; then
            public_key=$(cat "${conf_file}.pub")
        fi
        
        if [[ -n "$public_key" && "$flow" == "xtls-rprx-vision" ]]; then
            local vless_link="vless://${uuid}@${SERVER_IP}:${port}?encryption=none&flow=${flow}&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#VLESS-${port}"
            
            echo "📱 VLESS-REALITY 链接："
            echo ""
            echo "${vless_link}"
            echo ""
        fi
        
    elif [[ "$type" == "http" ]]; then
        local username=$(echo "$config" | jq -r '.users[0].username')
        local password=$(echo "$config" | jq -r '.users[0].password')
        
        echo "🌐 HTTP 代理地址："
        echo ""
        echo "http://${username}:${password}@${SERVER_IP}:${port}"
        echo ""
        
    elif [[ "$type" == "socks" ]]; then
        local username=$(echo "$config" | jq -r '.users[0].username // ""')
        local password=$(echo "$config" | jq -r '.users[0].password // ""')
        
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
    read -p "按回车返回..." dummy
    list_configs
}

# 动态路由管理
manage_route() {
    local action=$1
    local domain=$2
    local target=$3

    [[ ! -f "$SING_BOX_CONFIG" ]] && error "未找到配置文件"

    case $action in
        on)
            info "正在开启 IPv4/v6 智能分流..."
            cp "$SING_BOX_CONFIG" "${SING_BOX_CONFIG}.bak"
            local inbounds=$(jq '.inbounds' "$SING_BOX_CONFIG")
            generate_base_config "true"
            jq --argjson inbounds "$inbounds" '.inbounds = $inbounds' "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"
            mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
            restart_singbox
            success "分流已开启！IPv6 路由已修复完毕。"
            ;;
        off)
            info "正在关闭分流，切换至普通模式..."
            cp "$SING_BOX_CONFIG" "${SING_BOX_CONFIG}.bak"
            local inbounds=$(jq '.inbounds' "$SING_BOX_CONFIG")
            generate_base_config "false"
            jq --argjson inbounds "$inbounds" '.inbounds = $inbounds' "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"
            mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
            restart_singbox
            success "分流已关闭！所有流量将走默认路由。"
            ;;
        add)
            [[ -z "$domain" || -z "$target" ]] && error "用法: sb route add <域名> <v4/v6>"
            [[ "$target" != "v4" && "$target" != "v6" ]] && error "目标只能是 v4 或 v6"
            
            if ! jq -e '.outbounds[] | select(.tag=="direct-ipv6")' "$SING_BOX_CONFIG" &>/dev/null; then
                error "当前未开启分流功能，请先执行 'sb route on' 开启。"
            fi

            info "正在添加规则: 访问 $domain 将走 IPv$target"
            local outbound_tag="direct-ipv4"
            [[ "$target" == "v6" ]] && outbound_tag="direct-ipv6"

            jq --arg domain "$domain" --arg out "$outbound_tag" \
               '.route.rules = [{"domain": [$domain], "outbound": $out}] + .route.rules' \
               "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"
            mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
            
            restart_singbox
            success "已添加临时分流规则: $domain -> IPv$target"
            ;;
        status)
            info "当前路由分流状态："
            if jq -e '.outbounds[] | select(.tag=="direct-ipv6")' "$SING_BOX_CONFIG" &>/dev/null; then
                success "智能分流功能: [已开启]"
            else
                warn "智能分流功能: [已关闭]"
            fi
            ;;
        *)
            echo "=========================================="
            echo "   路由分流管理帮助"
            echo "=========================================="
            echo "命令用法:"
            echo "  sb route status            - 查看当前分流状态"
            echo "  sb route on                - 开启智能分流 (需有 IPv6)"
            echo "  sb route off               - 关闭分流 (单栈模式)"
            echo "  sb route add <域名> <v4/v6> - 指定网站走 v4 或 v6"
            ;;
    esac
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
    find "$SING_BOX_CONF_DIR" -name "*${tag}*.json.pub" -delete 2>/dev/null
    
    restart_singbox
    success "配置已删除: $tag"
}

# 卸载sing-box
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
   sing-box 管理脚本 v3.1 (1.12+ 终极完整版)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📦 安装与卸载:
  sb install          安装 sing-box (含IPv6探测)
  sb uninstall        卸载 sing-box

📋 节点配置管理:
  sb list             列出配置（交互式，可查看详情）
  sb add vless        添加 VLESS-REALITY
  sb add http         添加 HTTP 代理
  sb add socks        添加 SOCKS5 代理
  sb info <tag>       显示配置详情
  sb delete <tag>     删除配置

🌐 路由分流管理:
  sb route status     查看分流状态
  sb route on         开启智能分流 (IPv6 分流完美修复)
  sb route off        关闭分流
  sb route add <域名> <v4/v6>  指定域名走 v4 或 v6

🔧 服务管理:
  sb restart          重启服务
  sb status           查看状态
  sb log              查看日志

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
        route) manage_route "$2" "$3" "$4" ;;
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
