<div align="center">

# Sudoku 一键安装与 Mihomo 扫码订阅

**自动部署 Sudoku 服务端 · 受信任的公网 IP HTTPS 证书 · Mihomo YAML 订阅与二维码**

[![Sudoku](https://img.shields.io/badge/Sudoku-v0.5.0-6c63ff?style=flat-square)](https://github.com/SUDOKU-ASCII/sudoku)
[![Mihomo](https://img.shields.io/badge/Mihomo-%3E%20v1.19.21-00b4d8?style=flat-square)](https://github.com/MetaCubeX/mihomo)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)](./sudoku-install.sh)
[![License](https://img.shields.io/badge/License-GPL--3.0-blue?style=flat-square)](./LICENSE)

</div>

## 项目介绍

本项目用于在 Linux VPS 上快速部署 [SUDOKU-ASCII/sudoku](https://github.com/SUDOKU-ASCII/sudoku) 服务端。脚本完成安装后会生成：

- Sudoku 服务端及 systemd 服务；
- 可直接导入 Mihomo 内核软件的完整 YAML；
- 带随机访问令牌的 HTTPS 订阅地址；
- 浏览器扫码页面及本机生成的 SVG 二维码；
- Sudoku 原生客户端 JSON 与 `sudoku://` 短链。

与只生成节点文本的脚本不同，本项目把下载校验、配置校验、TLS、订阅页面、二维码、重装备份和运行状态检查放在同一条安装流程中。

## 主要功能

- **一键安装/重装**：自动识别 `amd64`、`arm64` 并安装上游最新 Release。
- **下载完整性校验**：核对 GitHub Release API 提供的 SHA-256 摘要。
- **受信任的 IP HTTPS**：通过 Certbot 5.4+ 自动申请 Let's Encrypt 公网 IP 短期证书。
- **自动续期**：启用 Certbot 定时器，续期后自动重载订阅服务。
- **兼容新装 snapd**：主动识别 `/snap/bin/certbot`，当前终端无需重新登录或刷新 PATH。
- **扫码与订阅导入**：输出 Mihomo YAML、订阅 URL、网页二维码和一键导入链接。
- **配置预检**：启动前调用 Sudoku 自带的 `-test` 校验服务端与客户端配置。
- **服务托管**：创建 `sudoku.service`、`sudoku-subscription.service` 和 `sudoku-mss.service`。
- **链路兼容**：默认对 Sudoku 端口应用 TCP MSS 1200，规避部分跨网链路的 PMTU 黑洞。
- **窄范围防火墙变更**：仅放行所需 TCP 端口，端口变更时清理原脚本管理的旧规则。
- **可回滚重装**：修改前备份到 `/var/backups/sudoku-install/`。
- **安全订阅路径**：随机令牌、无目录列表、`no-store` 与基础安全响应头。

## 环境要求

- 使用 systemd 的 Linux VPS；
- `root` 权限；
- `amd64` 或 `arm64`；
- 公网 IPv4；
- 外部能够访问 `80/tcp`，用于证书首次签发和自动续期；
- Mihomo 内核版本高于 `v1.19.21`。

当前已在 **Ubuntu 24.04 / amd64 / Mihomo v1.19.30** 上完成安装与真实 HTTPS 代理链路验证。

## 一键安装

```bash
bash <(curl -fL --retry 5 --retry-all-errors --connect-timeout 15 --max-time 120 \
  -H 'Accept: application/vnd.github.raw+json' \
  'https://api.github.com/repos/yuwanx/sudoku-install/contents/sudoku-install.sh?ref=main') install
```

脚本默认随机选择 Sudoku 和订阅端口。指定端口与公网 IP：

```bash
SUDOKU_PORT=443 SUBSCRIPTION_PORT=18080 SERVER_IP=203.0.113.10 \
  bash <(curl -fL --retry 5 --retry-all-errors --connect-timeout 15 --max-time 120 \
    -H 'Accept: application/vnd.github.raw+json' \
    'https://api.github.com/repos/yuwanx/sudoku-install/contents/sudoku-install.sh?ref=main') install
```

### 可选环境变量

| 变量 | 默认值 | 说明 |
|---|---:|---|
| `SUDOKU_PORT` | 随机 | Sudoku TCP 服务端口 |
| `SUBSCRIPTION_PORT` | 随机 | HTTPS 扫码与订阅端口 |
| `SERVER_IP` | 自动探测 | 对外公布的公网 IPv4 |
| `SUDOKU_FALLBACK` | `127.0.0.1:80` | 可疑连接的回落地址 |
| `SUDOKU_TCP_MSS` | `1200` | Sudoku 端口 MSS；设为 `0` 可关闭 |
| `SUDOKU_TLS_MODE` | `letsencrypt` | 可选 `letsencrypt` / `self-signed` |
| `SUDOKU_FORCE_DOWNLOAD` | `0` | 设为 `1` 强制重新下载当前版本 |

> 自签模式也会使用 HTTPS，但扫码设备需先信任该证书；默认的 Let's Encrypt IP 证书可被主流系统直接验证。

## 导入 Mihomo

安装成功后终端会显示：

```text
扫码页面:   https://SERVER_IP:SUBSCRIPTION_PORT/RANDOM_TOKEN/
订阅链接:   https://SERVER_IP:SUBSCRIPTION_PORT/RANDOM_TOKEN/config.yaml
Mihomo YAML: /etc/sudoku/mihomo.yaml
```

导入方式：

1. 浏览器打开“扫码页面”；
2. 在采用 Mihomo 内核的代理软件中选择扫码导入；
3. 或直接复制订阅链接到订阅管理页面；
4. 更新订阅后选择生成的 `sudoku-PORT` 节点。

二维码由服务器本机的 `qrencode` 生成，节点信息不会提交给第三方二维码网站。订阅 URL 含客户端连接密钥，应按密码级别保存。

## 管理命令

先定义下载函数：

```bash
fetch_sudoku_installer() {
  curl -fL --retry 5 --retry-all-errors --connect-timeout 15 --max-time 120 \
    -H 'Accept: application/vnd.github.raw+json' \
    'https://api.github.com/repos/yuwanx/sudoku-install/contents/sudoku-install.sh?ref=main'
}
```

```bash
bash <(fetch_sudoku_installer)             # 交互菜单
bash <(fetch_sudoku_installer) install     # 安装或重装
bash <(fetch_sudoku_installer) update      # 更新 Sudoku 内核并保留配置
bash <(fetch_sudoku_installer) show        # 查看服务状态与当前链接
bash <(fetch_sudoku_installer) qr          # 再次显示扫码/订阅地址
bash <(fetch_sudoku_installer) restart     # 重启服务
bash <(fetch_sudoku_installer) stop        # 停止服务
bash <(fetch_sudoku_installer) start       # 启动服务
bash <(fetch_sudoku_installer) log -n 100  # 查看最近日志
bash <(fetch_sudoku_installer) uninstall   # 卸载，保留历史备份
```

## 文件与服务

| 路径/服务 | 用途 |
|---|---|
| `/usr/local/bin/sudoku` | Sudoku 主程序 |
| `/etc/sudoku/server.config.json` | 服务端配置 |
| `/etc/sudoku/client.config.json` | 原生客户端配置 |
| `/etc/sudoku/mihomo.yaml` | Mihomo 完整配置 |
| `/etc/sudoku/subscription/` | 令牌化网页、YAML 与二维码 |
| `/etc/letsencrypt/live/IP/` | 公网 IP 证书与私钥 |
| `/var/backups/sudoku-install/` | 重装前备份 |
| `sudoku.service` | Sudoku 服务端 |
| `sudoku-subscription.service` | HTTPS 扫码与订阅服务 |
| `sudoku-mss.service` | TCP MSS 兼容规则 |

## HTTPS 与续期

Let's Encrypt 的 IP 地址证书属于短期证书，脚本会：

1. 安装支持 IP 证书的 Certbot；
2. 使用 `shortlived` 配置申请证书；
3. 启用 `snap.certbot.renew.timer`；
4. 在续期成功后重启 `sudoku-subscription.service` 载入新证书。

检查证书和模拟续期：

```bash
certbot certificates
certbot renew --dry-run --no-random-sleep-on-renew
systemctl status snap.certbot.renew.timer
```

## 常见排查

```bash
# 服务状态
systemctl status sudoku sudoku-subscription sudoku-mss --no-pager

# 端口监听
ss -lntp | grep -E 'sudoku|python3'

# 配置校验
/usr/local/bin/sudoku -c /etc/sudoku/server.config.json -test
/usr/local/bin/sudoku -c /etc/sudoku/client.config.json -test

# HTTPS 订阅服务
curl -I "https://SERVER_IP:SUBSCRIPTION_PORT/RANDOM_TOKEN/config.yaml"

# 日志
journalctl -u sudoku -u sudoku-subscription -n 100 --no-pager
```

如果证书签发失败，优先检查云安全组、UFW/firewalld 是否允许 `80/tcp`，以及端口 80 是否被其他程序占用。

## 上游与许可

- Sudoku：[SUDOKU-ASCII/sudoku](https://github.com/SUDOKU-ASCII/sudoku)
- Mihomo：[MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo)
- 同类型项目参考：[tianrking/AnyTLS-Go-Script](https://github.com/tianrking/AnyTLS-Go-Script)

本项目采用 [GPL-3.0 License](./LICENSE)。
