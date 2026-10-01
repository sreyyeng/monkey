#!/usr/bin/env bash
# =====================================================================
#  sb — sing-box 多协议一键部署 / 管理脚本  (整合版)
#
#  取代: singbox-ipv6.sh / xray.sh / httpproxy.sh
#
#  设计要点:
#   * 版本锁定: 默认安装经过验证的 sing-box 版本, 绝不自动追 latest;
#               升级走 `sb upgrade`, 先用新内核校验现有配置, 失败自动回滚。
#   * 状态与配置分离: 节点信息保存在 nodes.json, config.json 每次由脚本
#               重新生成, 只使用长期稳定的字段 (已在 1.12 ~ 1.15 验证)。
#               即便未来字段变化, 只需更新脚本的渲染函数, `sb regen` 即可。
#   * 安全: 非 root 用户运行 + systemd 沙箱; socks/http 强制认证;
#           默认禁止代理访问内网/本机地址 (防 SSRF); 所有 JSON 由 jq 构造。
#   * 省资源: 单进程, 无 geo 规则库, warn 级日志, 按内存设置 GOMEMLIMIT。
# =====================================================================

set -o pipefail
umask 027

SB_SCRIPT_VERSION="4.0.0"
# 经过验证的内核版本 (升级脚本时同步更新这里即可)
SB_PINNED_VERSION="${SB_VERSION:-1.14.2}"
SB_MIN_VERSION="1.12.0"
SB_SCRIPT_URL="${SB_SCRIPT_URL:-https://raw.githubusercontent.com/sreyyeng/monkey/main/sb.sh}"
# 可选 GitHub 下载加速前缀, 例如 GH_PROXY=https://ghproxy.example.com/
GH_PROXY="${GH_PROXY:-}"

SB_ETC="${SB_ETC:-/etc/sing-box}"
SB_BIN="${SB_BIN:-/usr/local/bin/sing-box}"
SB_CMD="${SB_CMD:-/usr/local/bin/sb}"
SB_UNIT="/etc/systemd/system/sing-box.service"
CF_BIN="/usr/local/bin/cloudflared"
CF_UNIT="/etc/systemd/system/cloudflared-sb.service"
CF_ENV="$SB_ETC/cloudflared.env"
SB_USER="sing-box"
STATE="$SB_ETC/nodes.json"
CONFIG="$SB_ETC/config.json"
TLS_DIR="$SB_ETC/tls"
# 测试用: SB_NO_SYSTEMD=1 时不调用 systemctl / chown
SB_NO_SYSTEMD="${SB_NO_SYSTEMD:-0}"

if [[ -t 1 ]]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi
info() { echo "${C_B}[*]${C_0} $*"; }
ok()   { echo "${C_G}[✓]${C_0} $*"; }
warn() { echo "${C_Y}[!]${C_0} $*" >&2; }
die()  { echo "${C_R}[✗]${C_0} $*" >&2; exit 1; }

is_tty() { [[ -t 0 ]]; }
ask() {  # ask <变量名> <提示> <默认值>
    local __v="$1" __p="$2" __d="$3" __in=""
    if is_tty; then read -rp "$__p [${__d}]: " __in; fi
    printf -v "$__v" '%s' "${__in:-$__d}"
}

need_root() { [[ $EUID -eq 0 ]] || die "请使用 root 运行"; }
have() { command -v "$1" >/dev/null 2>&1; }
systemd_on() { [[ "$SB_NO_SYSTEMD" != 1 ]]; }

# ------------------------------------------------------------------
# 基础工具
# ------------------------------------------------------------------
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        armv7*|armv8l) echo armv7 ;;
        i386|i686)     echo 386 ;;
        s390x)         echo s390x ;;
        riscv64)       echo riscv64 ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
}

install_deps() {
    local miss=()
    for c in curl jq openssl tar ss shuf; do have "$c" || miss+=("$c"); done
    [[ ${#miss[@]} -eq 0 ]] && return 0
    info "安装依赖: ${miss[*]}"
    if have apt-get; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq openssl tar iproute2 coreutils ca-certificates >/dev/null
    elif have dnf; then
        dnf install -y -q curl jq openssl tar iproute coreutils ca-certificates >/dev/null
    elif have yum; then
        yum install -y -q epel-release >/dev/null 2>&1
        yum install -y -q curl jq openssl tar iproute coreutils ca-certificates >/dev/null
    else
        die "未识别的包管理器, 请手动安装: curl jq openssl tar iproute2"
    fi
    for c in curl jq openssl tar ss; do have "$c" || die "依赖安装失败: $c"; done
}

ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }
core_version() { [[ -x "$SB_BIN" ]] && "$SB_BIN" version 2>/dev/null | awk 'NR==1{print $3}'; }

rand_port() {
    local p i
    for i in $(seq 1 50); do
        p=$(shuf -i 20000-60000 -n 1)
        port_free "$p" both && { echo "$p"; return; }
    done
    die "找不到可用端口"
}
# port_free <端口> <tcp|udp|both>
port_free() {
    local p="$1" proto="$2"
    if [[ -f "$STATE" ]] && jq -e --argjson p "$p" '.nodes[] | select(.port == $p)' "$STATE" >/dev/null; then
        return 1
    fi
    have ss || return 0
    if [[ "$proto" != udp ]] && [[ -n "$(ss -Hltn "sport = :$p" 2>/dev/null)" ]]; then return 1; fi
    if [[ "$proto" != tcp ]] && [[ -n "$(ss -Hlun "sport = :$p" 2>/dev/null)" ]]; then return 1; fi
    return 0
}
valid_port()   { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_domain() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; }
valid_path()   { [[ "$1" =~ ^/[A-Za-z0-9._~/-]{0,63}$ ]]; }

gen_uuid() { cat /proc/sys/kernel/random/uuid; }
gen_pass() { openssl rand -hex 16; }
gen_b64key() { openssl rand -base64 "$1"; }
urlenc() { jq -rn --arg s "$1" '$s|@uri'; }
b64url() { base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '='; }

get_ip() {  # get_ip 4|6
    local u ip
    for u in https://api.ipify.org https://ip.sb https://ifconfig.co https://icanhazip.com; do
        ip=$(curl -"$1" -fsS --max-time 4 "$u" 2>/dev/null | tr -d '[:space:]')
        if [[ "$1" == 4 && "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || [[ "$1" == 6 && "$ip" == *:* ]]; then
            echo "$ip"; return
        fi
    done
}
ipv6_ok() { [[ -f /proc/net/if_inet6 ]] && [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != 1 ]]; }
default_listen() { if ipv6_ok; then echo "::"; else echo "0.0.0.0"; fi; }

# ------------------------------------------------------------------
# 状态文件 (唯一数据源)
# ------------------------------------------------------------------
state_init() {
    mkdir -p "$SB_ETC" "$TLS_DIR"
    [[ -s "$STATE" ]] && return 0
    jq -n '{
        schema: 1,
        settings: {host: "", block_private: true, warp: "127.0.0.1:40000", log_level: "warn", tls_sni: "www.bing.com"},
        nodes: []
    }' > "$STATE"
}
state_get() { jq -r "$1" "$STATE"; }

# 修改状态并应用; 失败时恢复原状态
# state_apply '<jq 表达式>' [jq 参数...]
state_apply() {
    local expr="$1"; shift
    local bak="$STATE.prev"
    state_init
    cp -p "$STATE" "$bak"
    if ! jq "$@" "$expr" "$bak" > "$STATE.tmp"; then
        rm -f "$STATE.tmp"; die "状态更新失败"
    fi
    mv "$STATE.tmp" "$STATE"
    if ! apply_config; then
        cp -p "$bak" "$STATE"
        apply_config >/dev/null 2>&1
        die "应用失败, 已恢复到修改前的状态"
    fi
}

# ------------------------------------------------------------------
# 配置渲染: nodes.json -> config.json
# 只使用自 1.11/1.12 起稳定且在 1.15 中仍未弃用的字段
# ------------------------------------------------------------------
render_config() {
    jq --arg cert "$TLS_DIR/cert.pem" --arg key "$TLS_DIR/key.pem" '
    def selftls($alpn): {enabled: true, server_name: .sni, certificate_path: $cert, key_path: $key}
        + (if $alpn then {alpn: $alpn} else {} end);
    def inbound:
        {tag: .tag, listen: .listen, listen_port: .port} +
        if .type == "vless-reality" then
            {type: "vless",
             users: [{uuid: .uuid, flow: "xtls-rprx-vision"}],
             tls: {enabled: true, server_name: .sni,
                   reality: {enabled: true,
                             handshake: {server: .dest, server_port: .dest_port},
                             private_key: .private_key, short_id: [.short_id]}}}
        elif .type == "hysteria2" then
            {type: "hysteria2", users: [{password: .password}], tls: selftls(["h3"])}
        elif .type == "tuic" then
            {type: "tuic", users: [{uuid: .uuid, password: .password}],
             congestion_control: "bbr", tls: selftls(["h3"])}
        elif .type == "anytls" then
            {type: "anytls", users: [{password: .password}], tls: selftls(null)}
        elif .type == "ss" then
            {type: "shadowsocks", method: .method, password: .password}
        elif .type == "vless-ws" then
            {type: "vless", users: [{uuid: .uuid}], transport: {type: "ws", path: .path}}
        elif .type == "socks" then
            {type: "socks", users: [{username: .username, password: .password}]}
        elif .type == "http" then
            {type: "http", users: [{username: .username, password: .password}]}
        else error("未知节点类型: \(.type)") end;
    def tags($e): [.nodes[] | select((.egress // "auto") == $e) | .tag];
    .settings as $s
    | tags("v4") as $v4 | tags("v6") as $v6 | tags("warp") as $warp
    | {
        log: {level: ($s.log_level // "warn"), timestamp: false},
        inbounds: [.nodes[] | inbound],
        outbounds: (
            [{type: "direct", tag: "direct"}]
            + (if ($warp | length) > 0 then
                 [{type: "socks", tag: "warp", version: "5",
                   server: ($s.warp | sub(":[0-9]+$"; "") | gsub("^\\[|\\]$"; "")),
                   server_port: ($s.warp | capture(":(?<p>[0-9]+)$").p | tonumber)}]
               else [] end)
        ),
        route: {
            rules: (
                  (if ($warp | length) > 0 then [{inbound: $warp, outbound: "warp"}] else [] end)
                + (if ($v4 | length) > 0 then
                     [{inbound: $v4, action: "resolve", strategy: "ipv4_only"},
                      {inbound: $v4, ip_cidr: ["::/0"], action: "reject"}] else [] end)
                + (if ($v6 | length) > 0 then
                     [{inbound: $v6, action: "resolve", strategy: "ipv6_only"},
                      {inbound: $v6, ip_cidr: ["0.0.0.0/0"], action: "reject"}] else [] end)
                + (if $s.block_private then
                     [{action: "resolve"}, {ip_is_private: true, action: "reject"}] else [] end)
            ),
            final: "direct"
        }
      }
    ' "$STATE"
}

fix_perms() {
    systemd_on || return 0
    id "$SB_USER" >/dev/null 2>&1 || return 0
    chown -R root:"$SB_USER" "$SB_ETC"
    chmod 750 "$SB_ETC" "$TLS_DIR"
    chmod 640 "$SB_ETC"/*.json "$TLS_DIR"/* 2>/dev/null
    [[ -f "$CF_ENV" ]] && { chown root:root "$CF_ENV"; chmod 600 "$CF_ENV"; }
    return 0
}

# 生成 -> 用内核校验 -> 原子替换 -> 重启 -> 失败回滚
apply_config() {
    [[ -x "$SB_BIN" ]] || { warn "sing-box 未安装"; return 1; }
    local new="$CONFIG.new" out
    render_config > "$new" || { rm -f "$new"; warn "配置渲染失败"; return 1; }
    if ! out=$("$SB_BIN" check -c "$new" 2>&1); then
        echo "$out" >&2; rm -f "$new"; warn "sing-box 校验未通过"; return 1
    fi
    [[ -f "$CONFIG" ]] && cp -p "$CONFIG" "$CONFIG.bak"
    mv "$new" "$CONFIG"
    fix_perms
    if ! service_restart; then
        warn "服务启动失败, 回滚配置"
        [[ -f "$CONFIG.bak" ]] && cp -p "$CONFIG.bak" "$CONFIG" && service_restart
        return 1
    fi
    return 0
}

service_restart() {
    systemd_on || return 0
    systemctl restart sing-box
    local i
    for i in 1 2 3 4 5; do
        sleep 1
        systemctl is-active --quiet sing-box && return 0
    done
    journalctl -u sing-box -n 15 --no-pager >&2
    return 1
}

# ------------------------------------------------------------------
# 内核下载 / 安装 / 升级
# ------------------------------------------------------------------
# download_core <版本> <目标目录>  -> 输出二进制路径
download_core() {
    local v="$1" dir="$2" arch url bin
    arch=$(detect_arch)
    url="${GH_PROXY}https://github.com/SagerNet/sing-box/releases/download/v${v}/sing-box-${v}-linux-${arch}.tar.gz"
    info "下载 sing-box v${v} (${arch})" >&2
    curl -fL --retry 3 --connect-timeout 10 --proto '=https' --tlsv1.2 -o "$dir/sb.tgz" "$url" >&2 \
        || { warn "下载失败: $url"; return 1; }
    tar -xzf "$dir/sb.tgz" -C "$dir" || { warn "解压失败"; return 1; }
    bin=$(find "$dir" -type f -name sing-box | head -1)
    [[ -n "$bin" ]] || { warn "压缩包内未找到 sing-box"; return 1; }
    chmod 755 "$bin"
    # 校验二进制可执行且版本匹配
    if [[ "$("$bin" version 2>/dev/null | awk 'NR==1{print $3}')" != "$v" ]]; then
        warn "二进制版本校验失败"; return 1
    fi
    echo "$bin"
}

write_unit() {
    local mem_kb limit_mb
    mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
    limit_mb=$(( ${mem_kb:-524288} / 1024 / 2 ))
    (( limit_mb < 48 )) && limit_mb=48
    cat > "$SB_UNIT" <<EOF
[Unit]
Description=sing-box (managed by sb)
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=$SB_USER
Group=$SB_USER
WorkingDirectory=/var/lib/sing-box
StateDirectory=sing-box
Environment=GOMEMLIMIT=${limit_mb}MiB
ExecStart=$SB_BIN run -c $CONFIG
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
SystemCallArchitectures=native
ReadOnlyPaths=$SB_ETC

[Install]
WantedBy=multi-user.target
EOF
}

gen_selfsigned() {
    [[ -s "$TLS_DIR/cert.pem" && -s "$TLS_DIR/key.pem" ]] && return 0
    local sni; sni=$(state_get '.settings.tls_sni')
    info "生成自签名证书 (CN=$sni, ECDSA P-256, 10 年)"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
        -keyout "$TLS_DIR/key.pem" -out "$TLS_DIR/cert.pem" -subj "/CN=$sni" \
        -addext "subjectAltName=DNS:$sni" >/dev/null 2>&1 \
    || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
        -keyout "$TLS_DIR/key.pem" -out "$TLS_DIR/cert.pem" -subj "/CN=$sni" >/dev/null 2>&1 \
    || die "证书生成失败"
}
cert_pin() { openssl x509 -in "$TLS_DIR/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2; }

install_self() {
    local src; src="$(readlink -f "$0" 2>/dev/null)"
    if [[ -f "$src" && "$src" != "$SB_CMD" ]]; then
        install -m 755 "$src" "$SB_CMD"
    elif [[ ! -f "$SB_CMD" ]]; then
        # 通过管道运行 (bash <(curl ...)) 时从仓库获取
        curl -fsSL --proto '=https' -o "$SB_CMD.tmp" "$SB_SCRIPT_URL" && bash -n "$SB_CMD.tmp" \
            && install -m 755 "$SB_CMD.tmp" "$SB_CMD"
        rm -f "$SB_CMD.tmp"
    fi
}

cmd_install() {
    need_root
    local v="$SB_PINNED_VERSION"
    [[ "$1" == "--version" && -n "$2" ]] && v="${2#v}"
    have systemctl || die "需要 systemd"
    install_deps
    ver_ge "$v" "$SB_MIN_VERSION" || die "最低支持 sing-box $SB_MIN_VERSION"

    local cur; cur=$(core_version)
    if [[ "$cur" != "$v" ]]; then
        local tmp bin; tmp=$(mktemp -d)
        bin=$(download_core "$v" "$tmp") || { rm -rf "$tmp"; die "内核下载失败 (可设置 GH_PROXY 后重试)"; }
        [[ -x "$SB_BIN" ]] && cp -p "$SB_BIN" "$SB_BIN.prev"
        install -m 755 "$bin" "$SB_BIN"
        rm -rf "$tmp"
    else
        info "sing-box v$v 已安装"
    fi

    id "$SB_USER" >/dev/null 2>&1 || useradd -r -M -d /var/lib/sing-box -s /usr/sbin/nologin "$SB_USER" 2>/dev/null \
        || useradd -r -M -d /var/lib/sing-box -s /sbin/nologin "$SB_USER" || die "创建用户失败"
    state_init
    import_legacy
    gen_selfsigned
    write_unit
    install_self
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    apply_config || die "服务启动失败"
    ok "sing-box v$v 安装完成 (运行用户: $SB_USER)"
    echo
    echo "  sb add        添加节点 (交互)      sb list    查看节点"
    echo "  sb quick      一键 Reality + Hy2   sb help    全部命令"
}

cmd_upgrade() {
    need_root
    local v="${1:-$SB_PINNED_VERSION}"; v="${v#v}"
    local cur; cur=$(core_version)
    [[ "$cur" == "$v" ]] && { ok "已是 v$v"; return; }
    ver_ge "$v" "$SB_MIN_VERSION" || die "最低支持 sing-box $SB_MIN_VERSION"
    if [[ "$v" != "$SB_PINNED_VERSION" ]]; then
        warn "v$v 不是本脚本验证过的版本 (验证版本: v$SB_PINNED_VERSION)"
        warn "将先用新内核校验现有配置, 不通过则不会替换"
    fi
    local tmp bin out; tmp=$(mktemp -d)
    bin=$(download_core "$v" "$tmp") || { rm -rf "$tmp"; die "下载失败"; }
    render_config > "$tmp/config.json" || { rm -rf "$tmp"; die "渲染失败"; }
    if ! out=$("$bin" check -c "$tmp/config.json" 2>&1); then
        echo "$out"; rm -rf "$tmp"; die "新内核 v$v 不兼容当前配置, 已放弃升级 (现有服务不受影响)"
    fi
    cp -p "$SB_BIN" "$SB_BIN.prev"
    install -m 755 "$bin" "$SB_BIN"
    rm -rf "$tmp"
    if apply_config; then
        ok "已升级: v$cur -> v$v   (如有问题: sb rollback)"
    else
        install -m 755 "$SB_BIN.prev" "$SB_BIN"; apply_config
        die "新版本启动失败, 已回滚到 v$cur"
    fi
}

cmd_rollback() {
    need_root
    [[ -x "$SB_BIN.prev" ]] || die "没有可回滚的旧版本"
    local a b; a=$(core_version); b=$("$SB_BIN.prev" version | awk 'NR==1{print $3}')
    cp -p "$SB_BIN" "$SB_BIN.tmp"; install -m 755 "$SB_BIN.prev" "$SB_BIN"; mv "$SB_BIN.tmp" "$SB_BIN.prev"
    apply_config && ok "已回滚: v$a -> v$b"
}

cmd_self_update() {
    need_root
    local tmp; tmp=$(mktemp)
    curl -fsSL --proto '=https' -o "$tmp" "$SB_SCRIPT_URL" || { rm -f "$tmp"; die "下载脚本失败"; }
    bash -n "$tmp" || { rm -f "$tmp"; die "新脚本语法错误, 放弃"; }
    install -m 755 "$tmp" "$SB_CMD"; rm -f "$tmp"
    ok "脚本已更新: $("$SB_CMD" version-script)"
    # 新脚本可能调整了渲染方式, 重新生成配置
    "$SB_CMD" regen
    local pv; pv=$(grep -m1 -oP 'SB_PINNED_VERSION="\$\{SB_VERSION:-\K[0-9.]+' "$SB_CMD")
    [[ -n "$pv" && "$pv" != "$(core_version)" ]] && info "新脚本验证的内核版本为 v$pv, 执行 'sb upgrade' 升级"
}

# ------------------------------------------------------------------
# 节点
# ------------------------------------------------------------------
TYPES="vless-reality hysteria2 tuic anytls ss vless-ws socks http"
type_desc() {
    case "$1" in
        vless-reality) echo "VLESS + Reality + Vision  (TCP, 主力推荐, 无需域名/证书)" ;;
        hysteria2)     echo "Hysteria2                 (UDP, 弱网/高丢包友好)" ;;
        tuic)          echo "TUIC v5                   (UDP, QUIC)" ;;
        anytls)        echo "AnyTLS                    (TCP, 抗流量特征)" ;;
        ss)            echo "Shadowsocks 2022          (TCP/UDP, 适合中转/落地)" ;;
        vless-ws)      echo "VLESS + WS                (配合 CF Argo 隧道/CDN)" ;;
        socks)         echo "SOCKS5 (强制认证)" ;;
        http)          echo "HTTP 代理 (强制认证)" ;;
    esac
}
type_proto() { case "$1" in hysteria2|tuic) echo udp ;; ss|socks) echo both ;; *) echo tcp ;; esac; }

pick_type() {
    local i=1 t arr=($TYPES)
    for t in "${arr[@]}"; do printf "  %d) %-14s %s\n" "$i" "$t" "$(type_desc "$t")" >&2; i=$((i+1)); done
    local c; read -rp "选择协议 [1-${#arr[@]}]: " c
    [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#arr[@]} )) || die "无效选择"
    echo "${arr[$((c-1))]}"
}

pick_egress() {
    local c
    echo "出口模式:" >&2
    echo "  1) auto  系统默认 (双栈)" >&2
    echo "  2) v4    仅 IPv4 出站" >&2
    echo "  3) v6    仅 IPv6 出站" >&2
    echo "  4) warp  经本机 WARP SOCKS5 出站 ($(state_get '.settings.warp'))" >&2
    read -rp "选择 [1]: " c
    case "${c:-1}" in 1) echo auto ;; 2) echo v4 ;; 3) echo v6 ;; 4) echo warp ;; *) die "无效选择" ;; esac
}

reality_target_ok() {
    have openssl || return 0
    timeout 6 openssl s_client -connect "$1:${2:-443}" -servername "$1" -tls1_3 </dev/null >/dev/null 2>&1
}

# sb add <type> [--port N] [--egress auto|v4|v6|warp] [--sni X] [--domain X] [--name X]
cmd_add() {
    need_root
    [[ -x "$SB_BIN" ]] || die "请先执行 sb install"
    state_init
    local type="$1"; [[ -n "$type" ]] && shift
    if [[ -z "$type" ]]; then is_tty || die "用法: sb add <$TYPES>"; type=$(pick_type); fi
    [[ " $TYPES " == *" $type "* ]] || case "$type" in
        vless|reality) type=vless-reality ;;
        hy2|hysteria)  type=hysteria2 ;;
        shadowsocks)   type=ss ;;
        argo|ws)       type=vless-ws ;;
        socks5)        type=socks ;;
        *) die "未知协议: $type  (可选: $TYPES)" ;;
    esac

    local port="" egress="" sni="" domain="" name="" user="" pass=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)   port="$2"; shift 2 ;;
            --egress|--ip) egress="$2"; shift 2 ;;
            --sni)    sni="$2"; shift 2 ;;
            --domain) domain="$2"; shift 2 ;;
            --name)   name="$2"; shift 2 ;;
            --user)   user="$2"; shift 2 ;;
            --pass)   pass="$2"; shift 2 ;;
            *) die "未知参数: $1" ;;
        esac
    done

    if [[ -z "$egress" ]]; then if is_tty; then egress=$(pick_egress); else egress=auto; fi; fi
    [[ "$egress" =~ ^(auto|v4|v6|warp)$ ]] || die "egress 只能是 auto|v4|v6|warp"

    local proto; proto=$(type_proto "$type")
    local defport; defport=$(rand_port)
    [[ "$type" == vless-reality && -z "$port" ]] && port_free 443 tcp && defport=443
    [[ -z "$port" ]] && ask port "端口" "$defport"
    valid_port "$port" || die "端口无效: $port"
    port_free "$port" "$proto" || die "端口 $port 已被占用"

    local listen; listen=$(default_listen)
    local tag="${type}-${port}"
    local node
    node=$(jq -n --arg tag "$tag" --arg type "$type" --argjson port "$port" \
                 --arg listen "$listen" --arg egress "$egress" --arg name "${name:-$tag}" \
           '{tag:$tag, type:$type, name:$name, port:$port, listen:$listen, egress:$egress}')

    case "$type" in
        vless-reality)
            [[ -z "$sni" ]] && ask sni "Reality 伪装站点 (需支持 TLS1.3, 建议与 VPS 同地区)" "www.apple.com"
            valid_domain "$sni" || die "域名无效: $sni"
            reality_target_ok "$sni" || warn "无法从本机以 TLS1.3 连接 $sni:443, 建议换一个站点"
            local kp pk pub
            kp=$("$SB_BIN" generate reality-keypair)
            pk=$(awk '/PrivateKey/{print $2}' <<<"$kp"); pub=$(awk '/PublicKey/{print $2}' <<<"$kp")
            [[ -n "$pk" && -n "$pub" ]] || die "Reality 密钥生成失败"
            node=$(jq --arg u "$(gen_uuid)" --arg sni "$sni" --arg pk "$pk" --arg pub "$pub" \
                      --arg sid "$(openssl rand -hex 8)" \
                   '. + {uuid:$u, sni:$sni, dest:$sni, dest_port:443, private_key:$pk, public_key:$pub, short_id:$sid}' <<<"$node") ;;
        hysteria2|anytls)
            gen_selfsigned
            node=$(jq --arg p "$(gen_pass)" --arg sni "$(state_get .settings.tls_sni)" '. + {password:$p, sni:$sni}' <<<"$node") ;;
        tuic)
            gen_selfsigned
            node=$(jq --arg u "$(gen_uuid)" --arg p "$(gen_pass)" --arg sni "$(state_get .settings.tls_sni)" \
                   '. + {uuid:$u, password:$p, sni:$sni}' <<<"$node") ;;
        ss)
            node=$(jq --arg p "$(gen_b64key 16)" '. + {method:"2022-blake3-aes-128-gcm", password:$p}' <<<"$node") ;;
        vless-ws)
            [[ -z "$domain" ]] && ask domain "CF 隧道/CDN 绑定的域名 (如 node.example.com)" ""
            [[ -n "$domain" ]] && { valid_domain "$domain" || die "域名无效: $domain"; }
            local path="/$(openssl rand -hex 6)"
            # 走 Argo 隧道时只监听本机, 不暴露公网
            node=$(jq --arg u "$(gen_uuid)" --arg path "$path" --arg d "$domain" \
                   '. + {uuid:$u, path:$path, domain:$d, listen:"127.0.0.1"}' <<<"$node") ;;
        socks|http)
            [[ -z "$user" ]] && user="u$(openssl rand -hex 4)"
            [[ -z "$pass" ]] && pass=$(gen_pass)
            [[ "$user" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "用户名只允许字母数字._-"
            (( ${#pass} >= 8 )) || die "密码至少 8 位"
            node=$(jq --arg u "$user" --arg p "$pass" '. + {username:$u, password:$p}' <<<"$node") ;;
    esac

    state_apply '.nodes += [$n]' --argjson n "$node"
    [[ "$type" != vless-ws ]] && fw_open "$port" "$proto"
    ok "已添加 $tag"
    echo
    show_node "$tag"
    if [[ "$type" == vless-ws ]]; then
        echo
        info "Cloudflare Zero Trust -> Tunnels -> Public Hostname 中添加:"
        echo "     ${domain:-<你的域名>}  ->  http://localhost:$port"
        [[ -f "$CF_UNIT" ]] || info "尚未安装隧道: sb argo <隧道 Token>"
    fi
    [[ "$egress" == warp ]] && info "warp 出口需先用 WARP 脚本开启本机 SOCKS5 (默认 127.0.0.1:40000), 地址可用 sb set warp 修改"
}

node_host() {  # 生成分享链接用的地址
    local n="$1" h e
    h=$(state_get '.settings.host')
    e=$(jq -r '.egress' <<<"$n")
    if [[ -z "$h" ]]; then
        if [[ "$e" == v6 ]]; then h=$(get_ip 6); else h=$(get_ip 4); [[ -z "$h" ]] && h=$(get_ip 6); fi
    fi
    [[ -z "$h" ]] && h="YOUR_SERVER_IP"
    [[ "$h" == *:* ]] && h="[$h]"
    echo "$h"
}

node_link() {
    local n="$1" host="$2" t port name
    t=$(jq -r .type <<<"$n"); port=$(jq -r .port <<<"$n"); name=$(urlenc "$(jq -r .name <<<"$n")")
    g() { jq -r ".$1 // empty" <<<"$n"; }
    case "$t" in
        vless-reality)
            echo "vless://$(g uuid)@${host}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(g sni)&fp=chrome&pbk=$(g public_key)&sid=$(g short_id)&type=tcp#${name}" ;;
        hysteria2)
            echo "hysteria2://$(g password)@${host}:${port}?sni=$(g sni)&alpn=h3&insecure=1&pinSHA256=$(cert_pin)#${name}" ;;
        tuic)
            echo "tuic://$(g uuid):$(g password)@${host}:${port}?sni=$(g sni)&alpn=h3&congestion_control=bbr&udp_relay_mode=native&allow_insecure=1#${name}" ;;
        anytls)
            echo "anytls://$(g password)@${host}:${port}?sni=$(g sni)&insecure=1#${name}" ;;
        ss)
            echo "ss://$(printf '%s:%s' "$(g method)" "$(g password)" | b64url)@${host}:${port}#${name}" ;;
        vless-ws)
            local d; d=$(g domain); d=${d:-YOUR_DOMAIN}
            echo "vless://$(g uuid)@${d}:443?encryption=none&security=tls&sni=${d}&fp=chrome&type=ws&host=${d}&path=$(urlenc "$(g path)")#${name}" ;;
        socks)
            echo "socks5://$(urlenc "$(g username)"):$(urlenc "$(g password)")@${host}:${port}#${name}" ;;
        http)
            echo "http://$(urlenc "$(g username)"):$(urlenc "$(g password)")@${host}:${port}#${name}" ;;
    esac
}

find_node() {
    local tag="$1" n
    n=$(jq -c --arg t "$tag" '.nodes[] | select(.tag == $t or .name == $t)' "$STATE" 2>/dev/null | head -1)
    [[ -n "$n" ]] || die "节点不存在: $tag  (sb list 查看)"
    echo "$n"
}

show_node() {
    local n; n=$(find_node "$1")
    local host; host=$(node_host "$n")
    jq -r '"  标签: \(.tag)   协议: \(.type)   端口: \(.port)   出口: \(.egress)"' <<<"$n"
    echo "  链接:"
    echo "  $(node_link "$n" "$host")"
    if have qrencode && is_tty; then qrencode -t ANSIUTF8 "$(node_link "$n" "$host")"; fi
}

cmd_list() {
    [[ -s "$STATE" ]] || die "尚未安装或无节点"
    local cnt; cnt=$(state_get '.nodes | length')
    [[ "$cnt" == 0 ]] && { info "暂无节点, 使用 sb add 添加"; return; }
    printf "%-4s %-22s %-14s %-7s %-6s\n" "#" "标签" "协议" "端口" "出口"
    jq -r '.nodes | to_entries[] | "\(.key+1)|\(.value.tag)|\(.value.type)|\(.value.port)|\(.value.egress)"' "$STATE" \
        | while IFS='|' read -r i t y p e; do printf "%-4s %-22s %-14s %-7s %-6s\n" "$i" "$t" "$y" "$p" "$e"; done
}

cmd_links() {
    [[ -s "$STATE" ]] || die "尚未安装或无节点"
    local n
    while read -r n; do
        [[ -z "$n" ]] && continue
        node_link "$n" "$(node_host "$n")"
    done < <(jq -c '.nodes[]' "$STATE")
}

cmd_del() {
    need_root
    local tag="$1"
    if [[ -z "$tag" ]]; then cmd_list; read -rp "输入要删除的标签或序号: " tag; fi
    [[ "$tag" =~ ^[0-9]+$ ]] && tag=$(jq -r --argjson i "$tag" '.nodes[$i-1].tag // empty' "$STATE")
    local n; n=$(find_node "$tag")
    tag=$(jq -r .tag <<<"$n")
    if is_tty; then local c; read -rp "确认删除 $tag ? (y/N): " c; [[ "$c" == y ]] || return 0; fi
    state_apply 'del(.nodes[] | select(.tag == $t))' --arg t "$tag"
    [[ "$(jq -r .type <<<"$n")" != vless-ws ]] && fw_close "$(jq -r .port <<<"$n")" "$(type_proto "$(jq -r .type <<<"$n")")"
    ok "已删除 $tag"
}

# sb set host|block-private|warp|log <值>
cmd_set() {
    need_root
    local k="$1" v="$2"
    case "$k" in
        host)
            [[ -z "$v" ]] || valid_domain "$v" || [[ "$v" =~ ^[0-9a-fA-F:.]+$ ]] || die "地址无效"
            state_apply '.settings.host = $v' --arg v "$v"; ok "分享链接地址: ${v:-自动检测}" ;;
        block-private)
            [[ "$v" =~ ^(on|off)$ ]] || die "用法: sb set block-private on|off"
            [[ "$v" == off ]] && warn "关闭后客户端可通过代理访问本机/内网服务, 请确认你需要这样做"
            state_apply '.settings.block_private = ($v == "on")' --arg v "$v"; ok "block-private = $v" ;;
        warp)
            [[ "$v" =~ ^(\[[0-9a-fA-F:]+\]|[0-9.]+|localhost):[0-9]+$ ]] || die "格式: 127.0.0.1:40000"
            state_apply '.settings.warp = $v' --arg v "$v"; ok "WARP SOCKS5 = $v" ;;
        log)
            [[ "$v" =~ ^(trace|debug|info|warn|error|fatal|panic)$ ]] || die "级别: debug|info|warn|error"
            state_apply '.settings.log_level = $v' --arg v "$v"; ok "日志级别 = $v" ;;
        *) die "用法: sb set host <域名/IP> | block-private on|off | warp <ip:port> | log <级别>" ;;
    esac
}

# 一键: Reality + Hysteria2
cmd_quick() {
    need_root
    [[ -x "$SB_BIN" ]] || cmd_install
    local p1=443; port_free 443 tcp || p1=$(rand_port)
    cmd_add vless-reality --port "$p1" --egress auto --sni "${SNI:-www.apple.com}" </dev/null
    echo
    cmd_add hysteria2 --port "$(rand_port)" --egress auto </dev/null
}

# ------------------------------------------------------------------
# 防火墙 (仅在 ufw / firewalld 启用时操作)
# ------------------------------------------------------------------
fw_each() {  # fw_each <open|close> <端口> <tcp|udp|both>
    local act="$1" p="$2" pr="$3" x protos=()
    [[ "$pr" == both ]] && protos=(tcp udp) || protos=("$pr")
    systemd_on || return 0
    if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        for x in "${protos[@]}"; do
            if [[ "$act" == open ]]; then ufw allow "$p/$x" >/dev/null; else ufw delete allow "$p/$x" >/dev/null 2>&1; fi
        done
    elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        for x in "${protos[@]}"; do
            if [[ "$act" == open ]]; then firewall-cmd -q --permanent --add-port="$p/$x"
            else firewall-cmd -q --permanent --remove-port="$p/$x" 2>/dev/null; fi
        done
        firewall-cmd -q --reload
    fi
    return 0
}
fw_open()  { fw_each open "$@"; }
fw_close() { fw_each close "$@"; }

# ------------------------------------------------------------------
# Cloudflare Argo 隧道 (可选, token 模式)
# ------------------------------------------------------------------
cmd_argo() {
    need_root
    local tok="$1"
    if [[ "$tok" == remove ]]; then
        systemctl disable --now cloudflared-sb >/dev/null 2>&1
        rm -f "$CF_UNIT" "$CF_ENV" "$CF_BIN"; systemctl daemon-reload
        ok "已移除 Argo 隧道"; return
    fi
    if [[ -z "$tok" ]]; then read -rsp "Cloudflare Tunnel Token: " tok; echo; fi
    [[ "$tok" =~ ^[A-Za-z0-9._=-]{50,}$ ]] || die "Token 格式不正确"
    local arch; arch=$(detect_arch); [[ "$arch" == armv7 ]] && arch=arm
    local tmp; tmp=$(mktemp)
    info "下载 cloudflared ($arch)"
    curl -fL --retry 3 --proto '=https' -o "$tmp" \
        "${GH_PROXY}https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" \
        || { rm -f "$tmp"; die "下载失败"; }
    chmod 755 "$tmp"; "$tmp" --version >/dev/null 2>&1 || { rm -f "$tmp"; die "cloudflared 校验失败"; }
    install -m 755 "$tmp" "$CF_BIN"; rm -f "$tmp"
    # token 放在 root 只读的环境文件中, 不出现在进程命令行里
    ( umask 077; printf 'TUNNEL_TOKEN=%s\n' "$tok" > "$CF_ENV" )
    cat > "$CF_UNIT" <<EOF
[Unit]
Description=Cloudflare Tunnel (managed by sb)
After=network-online.target
Wants=network-online.target

[Service]
DynamicUser=yes
EnvironmentFile=$CF_ENV
ExecStart=$CF_BIN tunnel --no-autoupdate run
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now cloudflared-sb >/dev/null 2>&1
    sleep 3
    systemctl is-active --quiet cloudflared-sb && ok "Argo 隧道已运行" || { journalctl -u cloudflared-sb -n 15 --no-pager; die "隧道启动失败"; }
    jq -e '.nodes[] | select(.type == "vless-ws")' "$STATE" >/dev/null 2>&1 || info "接下来: sb add vless-ws --domain <隧道域名>"
}

# ------------------------------------------------------------------
# 旧版脚本 (singbox-ipv6.sh) 配置迁移
# ------------------------------------------------------------------
x25519_pub() {  # 由 Reality 私钥推导公钥
    local raw
    raw=$(printf '%s' "$1" | tr -- '-_' '+/'); while (( ${#raw} % 4 )); do raw+="="; done
    { printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20'; printf '%s' "$raw" | base64 -d; } \
        | openssl pkey -inform DER -pubout -outform DER 2>/dev/null | tail -c 32 | b64url
}

import_legacy() {
    [[ -f "$CONFIG" ]] || return 0
    [[ "$(state_get '.nodes | length')" == 0 ]] || return 0
    jq -e '.inbounds | length > 0' "$CONFIG" >/dev/null 2>&1 || return 0
    info "检测到旧配置, 尝试迁移..."
    cp -p "$CONFIG" "$CONFIG.legacy.$(date +%s)"
    local ib tag type n pub
    while read -r ib; do
        tag=$(jq -r .tag <<<"$ib"); type=$(jq -r .type <<<"$ib")
        local eg=auto; [[ "$tag" == *-v4-* ]] && eg=v4; [[ "$tag" == *-v6-* ]] && eg=v6
        n=""
        if [[ "$type" == vless ]] && jq -e '.tls.reality.enabled' <<<"$ib" >/dev/null; then
            pub=""
            [[ -f "$SB_ETC/conf/$tag.json" ]] && pub=$(jq -r '.public_key // empty' "$SB_ETC/conf/$tag.json")
            [[ -z "$pub" ]] && pub=$(x25519_pub "$(jq -r .tls.reality.private_key <<<"$ib")")
            n=$(jq -c --arg eg "$eg" --arg pub "$pub" --arg l "$(default_listen)" '{
                tag: "vless-reality-\(.listen_port)", name: .tag, type: "vless-reality", port: .listen_port,
                listen: $l, egress: $eg, uuid: .users[0].uuid, sni: .tls.server_name,
                dest: .tls.reality.handshake.server, dest_port: (.tls.reality.handshake.server_port // 443),
                private_key: .tls.reality.private_key, public_key: $pub, short_id: .tls.reality.short_id[0]}' <<<"$ib")
        elif [[ "$type" == socks ]]; then
            if jq -e '.users[0].username' <<<"$ib" >/dev/null; then
                n=$(jq -c --arg eg "$eg" --arg l "$(default_listen)" '{
                    tag: "socks-\(.listen_port)", name: .tag, type: "socks", port: .listen_port, listen: $l,
                    egress: $eg, username: .users[0].username, password: .users[0].password}' <<<"$ib")
            else
                warn "跳过无认证 SOCKS5 ($tag): 新版强制认证, 请用 sb add socks 重新添加"
            fi
        else
            warn "跳过不支持迁移的入站: $tag ($type)"
        fi
        [[ -n "$n" ]] && jq --argjson n "$n" '.nodes += [$n]' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE" \
            && ok "已迁移: $tag"
    done < <(jq -c '.inbounds[]' "$CONFIG")
}

# ------------------------------------------------------------------
# 其它
# ------------------------------------------------------------------
cmd_bbr() {
    need_root
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then ok "BBR 已启用"; return; fi
    modprobe tcp_bbr 2>/dev/null
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || die "内核不支持 BBR"
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-sb-bbr.conf
    sysctl -q -p /etc/sysctl.d/99-sb-bbr.conf && ok "BBR 已启用"
}

cmd_status() {
    echo "脚本: v$SB_SCRIPT_VERSION   内核: v$(core_version || echo '-') (验证版本 v$SB_PINNED_VERSION)"
    if systemd_on; then
        local mem pid
        echo "服务: $(systemctl is-active sing-box 2>/dev/null)"
        pid=$(systemctl show -p MainPID --value sing-box 2>/dev/null)
        if [[ -n "$pid" && "$pid" != 0 ]]; then
            mem=$(awk '/VmRSS/{printf "%.1f MB", $2/1024}' /proc/"$pid"/status 2>/dev/null)
            echo "内存: $mem"
        fi
        [[ -f "$CF_UNIT" ]] && echo "Argo: $(systemctl is-active cloudflared-sb 2>/dev/null)"
    fi
    [[ -s "$STATE" ]] && echo "节点: $(state_get '.nodes | length') 个   内网访问拦截: $(state_get '.settings.block_private')"
}

cmd_uninstall() {
    need_root
    local c; read -rp "将删除 sing-box、全部节点和配置, 输入 YES 确认: " c
    [[ "$c" == YES ]] || { info "已取消"; return; }
    local bk="/root/sing-box-backup-$(date +%Y%m%d-%H%M%S)"
    [[ -d "$SB_ETC" ]] && cp -a "$SB_ETC" "$bk" && ok "配置已备份到 $bk"
    if [[ -s "$STATE" ]]; then
        local n
        while read -r n; do
            [[ -z "$n" ]] && continue
            [[ "$(jq -r .type <<<"$n")" == vless-ws ]] || fw_close "$(jq -r .port <<<"$n")" "$(type_proto "$(jq -r .type <<<"$n")")"
        done < <(jq -c '.nodes[]' "$STATE")
    fi
    systemctl disable --now sing-box cloudflared-sb >/dev/null 2>&1
    rm -f "$SB_UNIT" "$CF_UNIT" "$SB_BIN" "$SB_BIN.prev" "$CF_BIN" "$SB_CMD"
    rm -rf "$SB_ETC" /var/lib/sing-box
    systemctl daemon-reload
    userdel "$SB_USER" >/dev/null 2>&1
    ok "已卸载"
}

cmd_help() {
    cat <<EOF
sb v$SB_SCRIPT_VERSION — sing-box 多协议管理 (内核验证版本 v$SB_PINNED_VERSION)

安装/维护:
  sb install [--version X]   安装 (默认锁定验证版本, 自动迁移旧脚本配置)
  sb quick                   一键部署 VLESS-Reality + Hysteria2
  sb upgrade [版本]          升级内核 (先校验配置, 失败不替换)
  sb rollback                回滚到上一个内核
  sb self-update             更新本脚本并重新生成配置
  sb regen                   根据 nodes.json 重新生成配置并重启
  sb uninstall               卸载

节点:
  sb add [协议] [--port N] [--egress auto|v4|v6|warp] [--sni 域名] [--domain 域名] [--name 名称]
        协议: $TYPES
  sb list | sb links | sb info <标签> | sb del <标签|序号>

设置:
  sb set host <域名/IP>          分享链接使用的地址 (NAT/DDNS 用)
  sb set block-private on|off    禁止代理访问内网/本机 (默认 on)
  sb set warp <ip:port>          WARP SOCKS5 地址 (默认 127.0.0.1:40000)
  sb set log <级别>              日志级别 (默认 warn)
  sb argo <token> | sb argo remove   Cloudflare 隧道 (配合 vless-ws)
  sb bbr                         启用 BBR

服务:
  sb status | sb start | sb stop | sb restart | sb log | sb check
EOF
}

menu() {
    while true; do
        echo
        echo "========== sb v$SB_SCRIPT_VERSION  (sing-box v$(core_version || echo 未安装)) =========="
        echo "  1) 安装/修复        2) 一键 Reality+Hy2   3) 添加节点"
        echo "  4) 节点列表         5) 全部分享链接        6) 删除节点"
        echo "  7) 升级内核         8) 状态               9) 日志"
        echo "  10) 启用 BBR        11) 更新脚本          12) 卸载"
        echo "  0) 退出"
        local c; read -rp "选择: " c
        case "$c" in
            1) cmd_install ;; 2) cmd_quick ;; 3) cmd_add ;; 4) cmd_list ;; 5) cmd_links ;;
            6) cmd_del ;; 7) cmd_upgrade ;; 8) cmd_status ;; 9) journalctl -u sing-box -n 50 --no-pager ;;
            10) cmd_bbr ;; 11) cmd_self_update ;; 12) cmd_uninstall ;; 0|q) exit 0 ;;
            *) warn "无效选择" ;;
        esac
    done
}

main() {
    local c="${1:-}"; [[ $# -gt 0 ]] && shift
    case "$c" in
        install)          cmd_install "$@" ;;
        quick)            cmd_quick ;;
        add)              cmd_add "$@" ;;
        list|ls)          cmd_list ;;
        links|sub)        cmd_links ;;
        info|show)        [[ -n "$1" ]] || die "用法: sb info <标签>"; show_node "$1" ;;
        del|delete|rm)    cmd_del "$@" ;;
        set)              cmd_set "$@" ;;
        upgrade|update)   cmd_upgrade "$@" ;;
        rollback)         cmd_rollback ;;
        self-update)      cmd_self_update ;;
        regen)            need_root; apply_config && ok "配置已重新生成" ;;
        render)           render_config ;;
        check)            render_config > "${TMPDIR:-/tmp}/sb-check.json" && "$SB_BIN" check -c "${TMPDIR:-/tmp}/sb-check.json" && ok "配置有效"; rm -f "${TMPDIR:-/tmp}/sb-check.json" ;;
        argo)             cmd_argo "$@" ;;
        bbr)              cmd_bbr ;;
        status)           cmd_status ;;
        start|stop|restart) need_root; systemctl "$c" sing-box && ok "$c 完成" ;;
        log|logs)         journalctl -u sing-box -f --no-pager ;;
        uninstall)        cmd_uninstall ;;
        version-script)   echo "$SB_SCRIPT_VERSION" ;;
        help|-h|--help)   cmd_help ;;
        "")               if is_tty; then menu; else cmd_help; fi ;;
        *)                die "未知命令: $c   (sb help)" ;;
    esac
}

main "$@"
