# sing-box on DGX Spark

TUN 模式整机代理：除局域网/私网外，所有出口走 Mac 上 Clash Verge 的 mixed 端口
`192.168.3.14:7897`。本机不保存任何节点配置，节点/规则完全由 Mac 侧决定。

## 仓库内容

| 文件 | 说明 |
|---|---|
| `install.sh` | 安装/修复脚本：拉取二进制、生成配置、写 systemd unit、修系统 DNS，起不来会自动还原旧 unit |
| `config.json` | 当前线上配置快照（模板在 `install.sh` 的 `write_config` 里，`--reset-config` 会重新生成） |
| `README.md` | 本文件 |

`state/`（运行缓存）与 `sing-box` 二进制不入库，见 `.gitignore`；二进制由 `install.sh` 按需下载（v1.14.4）。

## 架构

```
任意进程 → tun(singbox0, 172.19.0.1/30) ─┬─ 私网/局域网(192.168/10/172.16…) → 直连
                                          └─ socks5 → 192.168.3.14:7897 (Mac Clash) → 节点 → Internet
tun DNS 172.19.0.2 → DoH 1.1.1.1（经代理）→ 无污染解析
```

## 文件

| 路径 | 说明 |
|---|---|
| `~/.local/opt/singbox/sing-box` | 二进制 1.14.4（root:root，`install.sh` 管理） |
| `~/.local/opt/singbox/config.json` | 配置，归 `zysq`，可直接改 |
| `~/.local/opt/singbox/state/` | cache（root 运行，root 所有） |
| `~/.local/opt/singbox/install.sh` | 安装/修复脚本（需 root） |
| `/etc/systemd/system/sing-box.service` | systemd unit（root 运行，含 CAP_NET_ADMIN / CAP_DAC_READ_SEARCH） |
| `/etc/systemd/resolved.conf.d/10-sing-box-dns.conf` | 整机 DNS 指向 `172.19.0.2` |

## 日常操作

```bash
# 改上游（Mac 换 IP / 换端口）：编辑 config.json 的 outbounds[0].server / server_port
sudo systemctl restart sing-box

# 只改配置后先校验，再生效
~/.local/opt/singbox/sing-box check -c ~/.local/opt/singbox/config.json
sudo systemctl restart sing-box

# 只重新修系统 DNS（换机器/换网段后，或 DNS 又被污染）
sudo bash ~/.local/opt/singbox/install.sh --dns-only

# 配置丢失/想重置成默认（socks → 192.168.3.14:7897）
sudo bash ~/.local/opt/singbox/install.sh --reset-config

# 完整重装（会自动停容器、备份旧 unit，失败自动还原）
sudo bash ~/.local/opt/singbox/install.sh

# 日志
sudo journalctl -u sing-box -f

# 卸载
sudo systemctl disable --now sing-box
sudo rm -f /etc/systemd/system/sing-box.service /etc/systemd/resolved.conf.d/10-sing-box-dns.conf
sudo systemctl daemon-reload && sudo systemctl restart systemd-resolved
rm -rf ~/.local/opt/singbox
```

## 验证

```bash
systemctl is-active sing-box                       # active
curl -s https://api.ipify.org                      # 应为节点 IP，不是本地公网 IP
curl -s -o /dev/null -w '%{http_code}\n' https://www.google.com      # 200（经 tun）
curl -s -x http://127.0.0.1:7897 -o /dev/null -w '%{http_code}\n' https://www.google.com  # 200
getent ahostsv4 www.google.com | head -1           # 真实 IP；若是 185.45.5.35 说明 DNS 未走隧道
ping -c1 192.168.3.1                               # 局域网直连仍通
curl -s https://ipv6.icanhazip.com                 # IPv6 出口（隧道内）
```

## 排障

- **所有请求 000 / 断网**：先看 Mac 侧 Clash 是否在跑、`192.168.3.14:7897` 是否可达
  （`curl -x http://192.168.3.14:7897 -o /dev/null -w '%{http_code}\n' https://www.google.com`）。
  TUN 把全部非局域网出口交给 Mac，Mac 睡眠/离开局域网时 Spark 就没有外网。
- **服务启动失败、`read config … permission denied`**：unit 的 `CapabilityBoundingSet` 必须包含
  `CAP_DAC_READ_SEARCH`，否则 root 无法穿过 `~/.local`（`0700`）。`install.sh` 已包含该 cap，
  并且安装前会用 `systemd-run` 在同样 cap 集下跑一次 `check` 预检。
- **只有 TLS 能上、个别域名怪**：说明应用 DNS 还在走路由器（会返回 GFW 黑洞 IP）。跑
  `sudo bash …/install.sh --dns-only`；TLS 之所以还能用，是靠 SNI 嗅探把域名交给代理远端解析。
- **端口占用**：本机 mixed 只监听 `127.0.0.1:7897`，clash-api 在 `127.0.0.1:9097`（无 secret，仅本机）。
- 改 config 时注意 `inbounds.tun.route_exclude_address` 里的私网段：删了会把 SSH/局域网也代理掉。
