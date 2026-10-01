#!/bin/bash

# ====================================================
# Xray-core NAT 终极全功能管理脚本 (Final Version)
# ====================================================

CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_CMD="/usr/local/bin/xray"

# ================== 基础检查与安装 ==================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "[错误] 请使用 root 用户运行此脚本！"
        exit 1
    fi
}

install_base() {
    echo "--- 开始安装基础组件与 Xray-core ---"
    apt update -y
    apt install -y curl jq openssl qrencode wireguard-tools
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
}

generate_warp() {
    echo "--- 正在申请 Cloudflare WARP 双栈账户 ---"
    curl -fsSL git.io/wgcf.sh | bash
    wgcf register --accept-tos
    wgcf generate
    WARP_PRIV_KEY=$(grep PrivateKey wgcf-profile.conf | awk '{print $3}')
    WARP_IPV6=$(grep Address wgcf-profile.conf | grep : | awk '{print $3}' | cut -d/ -f1)
    if [ -n "$WARP_PRIV_KEY" ]; then echo "[成功] WARP 账户生成成功！IPv6: $WARP_IPV6"; fi
}

install_argo() {
    echo "--------------------------------"
    read -p "请输入 Cloudflare Argo Tunnel Token: " ARGO_TOKEN
    if [[ -n "$ARGO_TOKEN" ]]; then
        curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
        dpkg -i cloudflared.deb
        cloudflared service install "$ARGO_TOKEN"
        echo "[成功] Argo Tunnel 已安装并启动！"
    fi
}

# ================== 核心配置生成 ==================

generate_config() {
    install_base
    generate_warp
    
    read -p "请输入 VLESS+REALITY 端口 [默认 443]: " VLESS_PORT
    VLESS_PORT=${VLESS_PORT:-443}
    read -p "请输入 VMess+WS(Argo) 端口 [默认 10086]: " VMESS_PORT
    VMESS_PORT=${VMESS_PORT:-10086}
    read -p "请输入 Socks5 端口 [默认 50001]: " SOCKS_PORT
    SOCKS_PORT=${SOCKS_PORT:-50001}

    UUID=$(xray uuid)
    VMESS_UUID=$(xray uuid)
    WS_PATH="/$(openssl rand -hex 6)"
    SOCKS_USER=$(openssl rand -hex 4)
    SOCKS_PASS=$(openssl rand -hex 8)
    
    REALITY_KEYS=$(xray x25519)
    PRI_KEY=$(echo "$REALITY_KEYS" | grep "Private key" | awk '{print $3}')
    SHORT_ID=$(openssl rand -hex 8)

    cat > $CONFIG_FILE <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality", "port": $VLESS_PORT, "protocol": "vless",
      "settings": { "clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}], "decryption": "none" },
      "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": { "dest": "www.yahoo.com:443", "serverNames": ["www.yahoo.com"], "privateKey": "$PRI_KEY", "shortIds": ["$SHORT_ID"] }
      }
    },
    {
      "tag": "vmess-ws", "port": $VMESS_PORT, "listen": "127.0.0.1", "protocol": "vmess",
      "settings": { "clients": [{"id": "$VMESS_UUID"}] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "$WS_PATH", "headers": {"Host": "cf.example.com"} } }
    },
    {
      "tag": "socks5-in", "port": $SOCKS_PORT, "protocol": "socks",
      "settings": { "auth": "password", "accounts": [{"user": "$SOCKS_USER", "pass": "$SOCKS_PASS"}] }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    {
      "tag": "warp-out", "protocol": "wireguard",
      "settings": {
        "secretKey": "$WARP_PRIV_KEY", "address": ["172.16.0.2/32", "$WARP_IPV6/128"],
        "peers": [{"endpoint": "engage.cloudflareclient.com:2408", "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="}]
      }
    },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["socks5-in"], "outboundTag": "direct" },
      { "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block", "description": "AD_BLOCK" },
      { "type": "field", "domain": ["geosite:netflix", "geosite:chatgpt", "geosite:openai"], "outboundTag": "warp-out", "description": "WARP_STREAM" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "warp-out" }
    ]
  }
}
EOF
    systemctl restart xray
    install_argo
    echo "--- 节点部署完成！---"
}

# ================== 交互：账户与节点管理 ==================

show_nodes() {
    IP=$(curl -s4m8 ip.sb)
    echo "================= 当前节点概览 =================="
    echo "[1] VLESS+REALITY (主力): Port: $(jq -r '.inbounds[0].port' $CONFIG_FILE) | UUID: $(jq -r '.inbounds[0].settings.clients[0].id' $CONFIG_FILE)"
    echo "[2] VMess+WS (Argo): Port: $(jq -r '.inbounds[1].port' $CONFIG_FILE) | Host: $(jq -r '.inbounds[1].streamSettings.wsSettings.headers.Host' $CONFIG_FILE) | Path: $(jq -r '.inbounds[1].streamSettings.wsSettings.path' $CONFIG_FILE)"
    echo "    VMess UUIDs: $(jq -c '.inbounds[1].settings.clients[].id' $CONFIG_FILE)"
    echo "[3] Socks5 (下载): Port: $(jq -r '.inbounds[2].port' $CONFIG_FILE) | User: $(jq -r '.inbounds[2].settings.accounts[0].user' $CONFIG_FILE) | Pass: $(jq -r '.inbounds[2].settings.accounts[0].pass' $CONFIG_FILE)"
    echo "================================================="
}

add_user() {
    NEW_UUID=$(xray uuid)
    echo "请选择添加用户的协议: [1] VLESS  [2] VMess"
    read -p "选择: " u_choice
    case $u_choice in
        1) jq --arg id "$NEW_UUID" '.inbounds[0].settings.clients += [{"id": $id, "flow": "xtls-rprx-vision"}]' $CONFIG_FILE > config.tmp && mv config.tmp $CONFIG_FILE ;;
        2) jq --arg id "$NEW_UUID" '.inbounds[1].settings.clients += [{"id": $id}]' $CONFIG_FILE > config.tmp && mv config.tmp $CONFIG_FILE ;;
        *) echo "[错误] 无效选择"; return ;;
    esac
    systemctl restart xray
    echo "[成功] 已添加新用户 UUID: $NEW_UUID"
}

del_user() {
    read -p "请输入要删除的 UUID: " DEL_UUID
    # 从 VLESS 和 VMess 中同时搜索并删除该 UUID
    jq --arg id "$DEL_UUID" '
      .inbounds[0].settings.clients |= map(select(.id != $id)) |
      .inbounds[1].settings.clients |= map(select(.id != $id))
    ' $CONFIG_FILE > config.tmp && mv config.tmp $CONFIG_FILE
    systemctl restart xray
    echo "[成功] 若存在该 UUID，已从配置中移除。"
}

change_vmess_host() {
    echo "当前 VMess Host 伪装域名: $(jq -r '.inbounds[1].streamSettings.wsSettings.headers.Host' $CONFIG_FILE)"
    read -p "请输入新的固定域名 (例如 node1.yourdomain.com): " NEW_HOST
    if [ -n "$NEW_HOST" ]; then
        jq --arg host "$NEW_HOST" '.inbounds[1].streamSettings.wsSettings.headers.Host = $host' $CONFIG_FILE > config.tmp && mv config.tmp $CONFIG_FILE
        systemctl restart xray
        echo "[成功] VMess Host 已更新为: $NEW_HOST"
    fi
}

# ================== 交互：分流与路由管理 ==================

manage_routing() {
    while true; do
        clear
        echo "=== 分流与路由管理 ==="
        echo "当前走 WARP 的域名列表: $(jq -c '.routing.rules[] | select(.description == "WARP_STREAM") | .domain' $CONFIG_FILE)"
        echo "1. 添加域名到 WARP 解锁"
        echo "2. 从 WARP 移除域名"
        echo "3. 切换广告/BT拦截状态 (当前: $(jq -r '.routing.rules[] | select(.description == "AD_BLOCK") | .outboundTag' $CONFIG_FILE))"
        echo "0. 返回主菜单"
        read -p "请选择: " r_choice
        case $r_choice in
            1)
                read -p "输入域名 (如 bbc.com): " ADD_DOM
                jq --arg dom "domain:$ADD_DOM" '(.routing.rules[] | select(.description == "WARP_STREAM") | .domain) += [$dom]' $CONFIG_FILE > config.tmp && mv config.tmp $CONFIG_FILE
                systemctl restart xray; echo "已添加。" ;;
            2)
                read -p "输入要移除的完整字段 (如 domain:bbc.com): " DEL_DOM
                jq --arg dom "$DEL_DOM" '(.routing.rules[] | select(.description == "WARP_STREAM") | .domain) |= map(select(. != $dom))' $CONFIG_FILE > config.tmp && mv config.tmp $CONFIG_FILE
                systemctl restart xray; echo "已移除。" ;;
            3)
                # 切换拦截规则的出站：block <-> direct
                CUR_TAG=$(jq -r '.routing.rules[] | select(.description == "AD_BLOCK") | .outboundTag' $CONFIG_FILE)
                if [ "$CUR_TAG" == "block" ]; then NEW_TAG="direct"; else NEW_TAG="block"; fi
                jq --arg tag "$NEW_TAG" '(.routing.rules[] | select(.description == "AD_BLOCK") | .outboundTag) = $tag' $CONFIG_FILE > config.tmp && mv config.tmp $CONFIG_FILE
                systemctl restart xray; echo "广告拦截已切换至: $NEW_TAG" ;;
            0) break ;;
        esac
        read -n1 -p "按任意键继续..."
    done
}

# ================== 界面服务 ==================

status_check() {
    XRAY_STATUS=$(systemctl is-active xray)
    ARGO_STATUS=$(systemctl is-active cloudflared)
    echo "================================================="
    echo " 服务状态: Xray [$XRAY_STATUS] | Argo Tunnel [$ARGO_STATUS]"
    echo "================================================="
}

menu() {
    clear
    echo "================================================="
    echo " Xray-core NAT 终极全功能脚本 (Final V1.0)"
    echo "================================================="
    status_check
    echo " [1] 全新安装 (Xray三合一 + WARP)"
    echo " [2] 查看节点信息 (端口/密码/UUID)"
    echo " [3] 用户管理 (添加/删除 UUID)"
    echo " [4] 分流管理 (WARP域名/广告拦截)"
    echo " [5] 修改 VMess 伪装域名 (Host)"
    echo " [6] 安装/更新 Argo Tunnel"
    echo " [0] 退出脚本"
    echo "-------------------------------------------------"
    read -p "请选择数字 [0-6]: " choice

    case $choice in
        1) generate_config ;;
        2) show_nodes ;;
        3) 
           echo "1. 添加新用户 | 2. 删除用户"; read -p "选择: " ud_choice
           if [ "$ud_choice" == "1" ]; then add_user; else del_user; fi ;;
        4) manage_routing ;;
        5) change_vmess_host ;;
        6) install_argo ;;
        0) exit 0 ;;
        *) echo "[错误] 无效选择！" ;;
    esac
}

check_root
while true; do menu; read -n1 -p "按任意键返回..."; done
