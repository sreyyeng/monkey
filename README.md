# sb — sing-box 多协议一键部署

一个脚本搞定 VPS 节点部署与管理，取代旧的 `singbox-ipv6.sh` / `xray.sh` / `httpproxy.sh`（已移到 `legacy/`）。

## 一键安装

```bash
wget -O /root/sb.sh https://raw.githubusercontent.com/sreyyeng/monkey/main/sb.sh && bash /root/sb.sh install
```

装好后直接用 `sb` 命令（不带参数进入菜单）：

```bash
sb quick                          # 一键部署 VLESS-Reality + Hysteria2 并输出链接
sb add vless-reality --egress v4  # 仅 IPv4 出站的 Reality 节点
sb add hysteria2 --egress v6      # 仅 IPv6 出站的 Hy2 节点
sb list / sb links / sb del <标签>
```

从旧版 `singbox-ipv6.sh` 升级：直接执行上面的安装命令，已有的 Reality 和带认证的 SOCKS5 节点会自动迁移，UUID、密钥、端口都不变，客户端不用改。旧配置会备份为 `config.json.legacy.*`。

## 支持的协议

| 协议 | 说明 |
|---|---|
| `vless-reality` | VLESS + Reality + Vision，主力推荐，不需要域名和证书 |
| `hysteria2` | UDP/QUIC，适合弱网和高丢包线路 |
| `tuic` | TUIC v5，UDP/QUIC |
| `anytls` | 能抵抗 TLS-in-TLS 特征识别 |
| `ss` | Shadowsocks 2022，适合做中转或落地 |
| `vless-ws` | 配合 Cloudflare Argo 隧道或 CDN（`sb argo <token>`），只监听本机 |
| `socks` / `http` | 强制认证。明文协议，建议只在中转或临时场景使用 |

每个节点都可以单独指定出口：`auto`（系统默认）、`v4`（仅 IPv4）、`v6`（仅 IPv6）、`warp`。选 `warp` 时，流量经本机的 WARP SOCKS5 转发（默认 `127.0.0.1:40000`，可用 `sb set warp` 修改），需要先用下面的 WARP 脚本开启 SOCKS5 代理模式。

## 为什么不会再因为 sing-box 更新而失效

1. **锁定版本**：默认安装脚本里的 `SB_PINNED_VERSION`（目前是 1.14.2），不会去追 latest。
2. **节点信息和配置分开存**：节点信息存在 `/etc/sing-box/nodes.json`，`config.json` 每次都由脚本重新生成。配置只用长期稳定的字段，已在 sing-box **1.12 / 1.13 / 1.14 / 1.15-alpha** 上验证，都能通过校验，也能正常转发流量。
3. **升级安全**：`sb upgrade [版本]` 会先下载新内核，并用它校验当前配置。校验不通过就不替换，正在运行的服务不受影响；新版本启动失败会自动回滚。随时可以用 `sb rollback` 退回上一个版本。
4. 将来 sing-box 如果又改了字段，只需要更新脚本里的 `render_config`，然后执行 `sb self-update`，所有节点会自动按新格式重新生成。

## 安全

- sing-box 以专用的 `sing-box` 用户运行（不是 root），只保留绑定低端口的权限，并启用 systemd 沙箱（`ProtectSystem=strict`、`NoNewPrivileges` 等）。
- 默认禁止通过代理访问本机或内网地址，防止节点被用来探测 VPS 内网或云厂商的元数据接口。确实需要时可执行 `sb set block-private off`。
- 配置和密钥文件权限为 `640 root:sing-box`；Argo token 存在 root 只读的文件里，不会出现在进程命令行中。
- 不执行任何第三方的 `curl | bash`。内核只从 SagerNet 的 GitHub Release 通过 HTTPS 下载，安装前会核对版本号。
- 所有配置都由 `jq` 生成，用户输入先经过格式校验，避免 JSON 注入。
- 如果 ufw 或 firewalld 处于启用状态，脚本会自动开放和关闭对应端口。

## 占用资源少

只有一个 sing-box 进程，不加载 geoip/geosite 规则库，日志级别为 warn，并按内存大小自动设置 `GOMEMLIMIT`。10 个节点空载时内存约 40 MB。另外可以用 `sb bbr` 开启 BBR。

## 其它命令

```
sb set host <域名/IP>        分享链接里使用的地址（NAT 机器或 DDNS 用）
sb status | log | restart    服务管理
sb regen                     根据 nodes.json 重新生成配置
sb uninstall                 卸载（会先把配置备份到 /root）
```

GitHub 连不上时（比如纯 IPv6 机器），可以设置下载加速前缀：`GH_PROXY=https://你的代理/ bash /root/sb.sh install`

## WARP

```bash
wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh
```
