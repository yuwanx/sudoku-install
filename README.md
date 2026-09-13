# Sudoku 一键安装 + Mihomo 扫码订阅

面向 Linux `amd64` / `arm64` 的 Sudoku 服务端安装脚本。安装完成后会自动为公网 IP 申请受信任的 HTTPS 证书，并提供带随机令牌的 Mihomo YAML 订阅二维码。

## 一键安装

```bash
bash <(curl -fL --retry 5 --retry-all-errors --connect-timeout 15 --max-time 120 \
  -H 'Accept: application/vnd.github.raw+json' \
  'https://api.github.com/repos/yuwanx/sudoku-install/contents/sudoku-install.sh?ref=main') install
```

指定端口：

```bash
SUDOKU_PORT=34567 SUBSCRIPTION_PORT=18080 \
  bash <(curl -fL --retry 5 --retry-all-errors --connect-timeout 15 --max-time 120 \
    -H 'Accept: application/vnd.github.raw+json' \
    'https://api.github.com/repos/yuwanx/sudoku-install/contents/sudoku-install.sh?ref=main') install
```

如果所在网络确认不需要 TCP MSS 兼容规则，可在安装命令前设置 `SUDOKU_TCP_MSS=0`；默认值 `1200` 用于避免部分跨网链路在较大握手报文上出现 PMTU 黑洞。

默认使用 Certbot 5.4+ 申请 Let's Encrypt 公网 IP 短期证书并自动续期，签发时要求外部可访问服务器 `80/tcp`。如明确需要自签模式，可设置 `SUDOKU_TLS_MODE=self-signed`，但导入设备需要事先信任该证书。

安装完成后终端会输出：

- 扫码页面：浏览器打开后可扫描 Mihomo 订阅二维码；
- 订阅链接：也可直接复制到客户端；
- `/etc/sudoku/mihomo.yaml`：完整 Mihomo 配置；
- `/etc/sudoku/client.config.json`：Sudoku 原生客户端配置。

二维码在服务器本机使用 `qrencode` 生成，不会把节点信息发送给第三方二维码服务。

## 管理

```bash
fetch_sudoku_installer() {
  curl -fL --retry 5 --retry-all-errors --connect-timeout 15 --max-time 120 \
    -H 'Accept: application/vnd.github.raw+json' \
    'https://api.github.com/repos/yuwanx/sudoku-install/contents/sudoku-install.sh?ref=main'
}

# 菜单
bash <(fetch_sudoku_installer)

# 更新 / 查看 / 卸载
bash <(fetch_sudoku_installer) update
bash <(fetch_sudoku_installer) show
bash <(fetch_sudoku_installer) uninstall
```

## 文件与服务

- `/usr/local/bin/sudoku`
- `/etc/sudoku/server.config.json`
- `/etc/sudoku/mihomo.yaml`
- `sudoku.service`
- `sudoku-mss.service`
- `sudoku-subscription.service`
- 重装前备份：`/var/backups/sudoku-install/`

## 设计说明

- 下载 GitHub 最新 Release，并核对 GitHub Release API 给出的 SHA-256；
- 自动申请受系统信任的公网 IP HTTPS 证书，Certbot 自动续期并重载订阅服务；
- 默认使用直接 Sudoku TCP 传输，服务端与 Mihomo 导出的 HTTPMask、下行模式保持一致；
- 启动前使用 Sudoku 自带 `-test` 校验服务端与客户端配置；
- 订阅 Web 服务只响应随机令牌路径，不开放目录列表；
- systemd 服务自动重启并启用基础沙箱限制；
- 默认持久化仅作用于 Sudoku 端口的 TCP MSS=1200 规则，规避 PMTU 黑洞导致的 TLS 握手中断；
- 不会主动关闭 UFW/firewalld，只放行本次使用的 TCP 端口。

> 订阅 URL 中包含客户端密钥，请像保管密码一样保管该链接。

上游项目：[SUDOKU-ASCII/sudoku](https://github.com/SUDOKU-ASCII/sudoku)
