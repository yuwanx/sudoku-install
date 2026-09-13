# Sudoku 一键安装 + Mihomo 扫码订阅

面向 Linux `amd64` / `arm64` 的 Sudoku 服务端安装脚本。安装完成后会提供一个带随机令牌的网页，页面包含 Mihomo YAML 订阅二维码，可用采用 Mihomo 内核的客户端扫码或粘贴订阅链接导入。

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

安装完成后终端会输出：

- 扫码页面：浏览器打开后可扫描 Mihomo 订阅二维码；
- 订阅链接：也可直接复制到客户端；
- `/etc/sudoku/mihomo.yaml`：完整 Mihomo 配置；
- `/etc/sudoku/client.config.json`：Sudoku 原生客户端配置。

二维码在服务器本机使用 `qrencode` 生成，不会把节点信息发送给第三方二维码服务。

## 管理

```bash
# 菜单
bash <(curl -fsSL https://raw.githubusercontent.com/yuwanx/sudoku-install/main/sudoku-install.sh)

# 更新 Sudoku 二进制并保留配置
bash <(curl -fsSL https://raw.githubusercontent.com/yuwanx/sudoku-install/main/sudoku-install.sh) update

# 查看服务状态、扫码页面和订阅链接
bash <(curl -fsSL https://raw.githubusercontent.com/yuwanx/sudoku-install/main/sudoku-install.sh) show

# 卸载
bash <(curl -fsSL https://raw.githubusercontent.com/yuwanx/sudoku-install/main/sudoku-install.sh) uninstall
```

## 文件与服务

- `/usr/local/bin/sudoku`
- `/etc/sudoku/server.config.json`
- `/etc/sudoku/mihomo.yaml`
- `sudoku.service`
- `sudoku-subscription.service`
- 重装前备份：`/var/backups/sudoku-install/`

## 设计说明

- 下载 GitHub 最新 Release，并核对 GitHub Release API 给出的 SHA-256；
- 默认使用直接 Sudoku TCP 传输，服务端与 Mihomo 导出的 HTTPMask、下行模式保持一致；
- 启动前使用 Sudoku 自带 `-test` 校验服务端与客户端配置；
- 订阅 Web 服务只响应随机令牌路径，不开放目录列表；
- systemd 服务自动重启并启用基础沙箱限制；
- 不会主动关闭 UFW/firewalld，只放行本次使用的 TCP 端口。

> 订阅 URL 中包含客户端密钥，请像保管密码一样保管该链接。默认是 HTTP；如需公网 TLS，可在现有反向代理中为扫码页面和 YAML 订阅配置 HTTPS。

上游项目：[SUDOKU-ASCII/sudoku](https://github.com/SUDOKU-ASCII/sudoku)
