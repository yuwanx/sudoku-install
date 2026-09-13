#!/usr/bin/env bash
# Sudoku 一键安装与 Mihomo 订阅/扫码导入脚本
# Upstream: https://github.com/SUDOKU-ASCII/sudoku

set -Eeuo pipefail
umask 077

readonly SCRIPT_VERSION="1.0.0"
readonly SUDOKU_REPO="${SUDOKU_REPO:-SUDOKU-ASCII/sudoku}"
readonly BIN="/usr/local/bin/sudoku"
readonly ETC_DIR="/etc/sudoku"
readonly CONFIG_FILE="${ETC_DIR}/server.config.json"
readonly KEYS_FILE="${ETC_DIR}/keys.env"
readonly STATE_FILE="${ETC_DIR}/install.env"
readonly CLIENT_FILE="${ETC_DIR}/client.config.json"
readonly MIHOMO_FILE="${ETC_DIR}/mihomo.yaml"
readonly VERSION_FILE="${ETC_DIR}/version"
readonly WEB_ROOT="${ETC_DIR}/subscription"
readonly WEB_ENV="${ETC_DIR}/subscription.env"
readonly WEB_APP_DIR="/usr/local/lib/sudoku-subscription"
readonly WEB_APP="${WEB_APP_DIR}/server.py"
readonly SUDOKU_SERVICE="sudoku.service"
readonly WEB_SERVICE="sudoku-subscription.service"
readonly BACKUP_ROOT="/var/backups/sudoku-install"
readonly DEFAULT_FALLBACK="${SUDOKU_FALLBACK:-127.0.0.1:80}"
readonly DEFAULT_AEAD="chacha20-poly1305"
readonly DEFAULT_ASCII="prefer_entropy"
readonly DEFAULT_CLIENT_PORT="1080"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
info() { printf '%b[*]%b %s\n' "$CYAN" "$RESET" "$*"; }
ok()   { printf '%b[OK]%b %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%b[!]%b %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%b[ERR]%b %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

on_error() {
  local code=$? line=${BASH_LINENO[0]:-unknown}
  printf '%b[ERR]%b 第 %s 行执行失败（退出码 %s）\n' "$RED" "$RESET" "$line" "$code" >&2
  exit "$code"
}
trap on_error ERR

require_root() {
  [[ ${EUID} -eq 0 ]] || die "请使用 root 运行此脚本"
  [[ -d /run/systemd/system ]] || die "当前系统未运行 systemd"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "仅支持 amd64/arm64，当前架构：$(uname -m)" ;;
  esac
}

install_dependencies() {
  local packages=(curl ca-certificates tar python3 qrencode iproute2)
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v tar >/dev/null 2>&1 || missing+=(tar)
  command -v python3 >/dev/null 2>&1 || missing+=(python3)
  command -v qrencode >/dev/null 2>&1 || missing+=(qrencode)
  command -v ss >/dev/null 2>&1 || missing+=(iproute2)
  [[ -r /etc/ssl/certs/ca-certificates.crt || -r /etc/pki/tls/certs/ca-bundle.crt ]] || missing+=(ca-certificates)
  ((${#missing[@]} == 0)) && return 0
  info "安装依赖：${missing[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    wait_for_apt
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${missing[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${missing[@]}"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${missing[@]}"
  else
    die "未识别包管理器，请先安装：${packages[*]}"
  fi
}

wait_for_apt() {
  local waited=0 lock busy
  while ((waited < 300)); do
    busy=false
    if command -v fuser >/dev/null 2>&1; then
      for lock in /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock; do
        if fuser "$lock" >/dev/null 2>&1; then busy=true; break; fi
      done
    fi
    if pgrep -x apt-get >/dev/null 2>&1 || pgrep -x apt >/dev/null 2>&1 \
      || pgrep -x dpkg >/dev/null 2>&1 || pgrep -x unattended-upgr >/dev/null 2>&1; then
      busy=true
    fi
    [[ $busy == false ]] && return 0
    ((waited == 0)) && warn "APT/DPKG 正在被其他任务使用，最多等待 5 分钟"
    sleep 3
    ((waited += 3))
  done
  die "等待 APT/DPKG 锁超时"
}

is_valid_port() { [[ ${1:-} =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535)); }
port_in_use() { ss -H -lnt "sport = :$1" 2>/dev/null | grep -q .; }

random_port() {
  local low=$1 high=$2 p i
  for ((i=0; i<200; i++)); do
    p=$(python3 - "$low" "$high" <<'PY'
import secrets, sys
lo, hi = map(int, sys.argv[1:])
print(lo + secrets.randbelow(hi - lo + 1))
PY
)
    port_in_use "$p" || { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

choose_port() {
  local requested=${1:-} range_low=$2 range_high=$3 label=$4
  if [[ -n $requested ]]; then
    is_valid_port "$requested" || die "${label}端口无效：${requested}"
    port_in_use "$requested" && die "${label}端口已占用：${requested}"
    printf '%s\n' "$requested"
  else
    random_port "$range_low" "$range_high" || die "找不到可用的${label}端口"
  fi
}

get_public_ip() {
  local ip="${SERVER_IP:-}" endpoint
  if [[ -z $ip ]]; then
    for endpoint in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
      ip=$(curl -4fsSL --connect-timeout 5 --max-time 8 "$endpoint" 2>/dev/null | tr -d '[:space:]') || true
      [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
      ip=""
    done
  fi
  [[ -n $ip ]] || die "公网 IP 探测失败，可用 SERVER_IP=地址 指定"
  [[ $ip =~ ^[A-Za-z0-9._:-]+$ ]] || die "SERVER_IP 含有无效字符"
  printf '%s\n' "$ip"
}

get_release_metadata() {
  local json asset
  asset="sudoku-linux-${ARCH}.tar.gz"
  json=$(curl -fsSL --connect-timeout 10 --max-time 30 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${SUDOKU_REPO}/releases/latest") || die "获取 Sudoku 最新版本失败"
  python3 -c '
import json, sys
asset_name = sys.argv[1]
data = json.load(sys.stdin)
for item in data.get("assets", []):
    if item.get("name") == asset_name:
        digest = (item.get("digest") or "").removeprefix("sha256:")
        print(data["tag_name"], item["browser_download_url"], digest, sep="\t")
        break
else:
    raise SystemExit(f"release asset not found: {asset_name}")
' "$asset" <<<"$json"
}

download_binary() {
  local metadata version url digest tmp actual extracted
  metadata=$(get_release_metadata)
  IFS=$'\t' read -r version url digest <<<"$metadata"
  [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号异常：$version"
  [[ $url == https://github.com/* ]] || die "下载地址异常"
  [[ $digest =~ ^[0-9a-fA-F]{64}$ ]] || die "GitHub Release 未提供 SHA-256 摘要"

  tmp=$(mktemp -d)
  info "下载 Sudoku ${version}（linux-${ARCH}）"
  curl -fL --retry 3 --connect-timeout 15 --max-time 180 -o "${tmp}/sudoku.tar.gz" "$url"
  actual=$(sha256sum "${tmp}/sudoku.tar.gz" | awk '{print $1}')
  [[ ${actual,,} == ${digest,,} ]] || { rm -rf "$tmp"; die "二进制 SHA-256 校验失败"; }
  tar -xzf "${tmp}/sudoku.tar.gz" -C "$tmp"
  extracted=$(find "$tmp" -maxdepth 2 -type f -name sudoku -print -quit)
  [[ -n $extracted ]] || { rm -rf "$tmp"; die "压缩包内未找到 sudoku"; }
  install -m 0755 "$extracted" "${BIN}.new"
  mv -f "${BIN}.new" "$BIN"
  mkdir -p "$ETC_DIR"
  printf '%s\n' "$version" > "$VERSION_FILE"
  chmod 600 "$VERSION_FILE"
  rm -rf "$tmp"
  ok "已安装 ${version}，SHA-256 校验通过"
}

generate_token() {
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(24))
PY
}

generate_path_root() {
  python3 - <<'PY'
import secrets, string
alphabet = string.ascii_lowercase
print(''.join(secrets.choice(alphabet) for _ in range(10)))
PY
}

generate_keys() {
  local output available master_private master_public
  output=$($BIN -keygen 2>&1)
  available=$(sed -n 's/.*Available Private Key:[[:space:]]*\([0-9a-fA-F]*\).*/\1/p' <<<"$output" | head -n1)
  master_private=$(sed -n 's/.*Master Private Key:[[:space:]]*\([0-9a-fA-F]*\).*/\1/p' <<<"$output" | head -n1)
  master_public=$(sed -n 's/.*Master Public Key:[[:space:]]*\([0-9a-fA-F]*\).*/\1/p' <<<"$output" | head -n1)
  [[ $available =~ ^[0-9a-fA-F]{128}$ && $master_private =~ ^[0-9a-fA-F]{64}$ && $master_public =~ ^[0-9a-fA-F]{64}$ ]] \
    || die "Sudoku 密钥输出解析失败"
  cat > "$KEYS_FILE" <<EOF
AVAILABLE_PRIVATE_KEY=${available}
MASTER_PRIVATE_KEY=${master_private}
MASTER_PUBLIC_KEY=${master_public}
EOF
  chmod 600 "$KEYS_FILE"
}

load_state() {
  [[ -r $STATE_FILE && -r $KEYS_FILE ]] || return 1
  # 文件由本脚本生成，仅包含受约束的数字/地址/token/hex 值。
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  # shellcheck disable=SC1090
  source "$KEYS_FILE"
}

write_state() {
  cat > "$STATE_FILE" <<EOF
SUDOKU_PORT=${SUDOKU_PORT}
SUBSCRIPTION_PORT=${SUBSCRIPTION_PORT}
SUBSCRIPTION_TOKEN=${SUBSCRIPTION_TOKEN}
PUBLIC_IP=${PUBLIC_IP}
HTTPMASK_PATH_ROOT=${HTTPMASK_PATH_ROOT}
EOF
  chmod 600 "$STATE_FILE"
}

write_server_config() {
  cat > "$CONFIG_FILE" <<EOF
{
  "mode": "server",
  "transport": "tcp",
  "local_port": ${SUDOKU_PORT},
  "fallback_address": "${DEFAULT_FALLBACK}",
  "key": "${MASTER_PUBLIC_KEY}",
  "aead": "${DEFAULT_AEAD}",
  "suspicious_action": "fallback",
  "padding_min": 2,
  "padding_max": 7,
  "ascii": "${DEFAULT_ASCII}",
  "enable_pure_downlink": false,
  "multiplex": "off",
  "httpmask": {
    "disable": false,
    "mode": "ws",
    "tls": false,
    "host": "",
    "path_root": "${HTTPMASK_PATH_ROOT}",
    "multiplex": "off"
  }
}
EOF
  chmod 600 "$CONFIG_FILE"
  "$BIN" -c "$CONFIG_FILE" -test >/dev/null 2>&1 || die "服务端配置校验失败"
}

write_sudoku_service() {
  cat > "/etc/systemd/system/${SUDOKU_SERVICE}" <<EOF
[Unit]
Description=Sudoku Proxy Server
Documentation=https://github.com/SUDOKU-ASCII/sudoku
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN} -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=${ETC_DIR}

[Install]
WantedBy=multi-user.target
EOF
}

write_client_exports() {
  local server_address subscription_url clash_url
  server_address="${PUBLIC_IP}:${SUDOKU_PORT}"
  subscription_url="http://${PUBLIC_IP}:${SUBSCRIPTION_PORT}/${SUBSCRIPTION_TOKEN}/config.yaml"

  cat > "$CLIENT_FILE" <<EOF
{
  "mode": "client",
  "transport": "tcp",
  "local_port": ${DEFAULT_CLIENT_PORT},
  "server_address": "${server_address}",
  "key": "${AVAILABLE_PRIVATE_KEY}",
  "aead": "${DEFAULT_AEAD}",
  "padding_min": 2,
  "padding_max": 7,
  "ascii": "${DEFAULT_ASCII}",
  "enable_pure_downlink": false,
  "multiplex": "off",
  "httpmask": {
    "disable": false,
    "mode": "ws",
    "tls": false,
    "host": "",
    "path_root": "${HTTPMASK_PATH_ROOT}",
    "multiplex": "off"
  },
  "rule_urls": ["global"]
}
EOF
  chmod 600 "$CLIENT_FILE"
  "$BIN" -c "$CLIENT_FILE" -test >/dev/null 2>&1 || die "客户端配置校验失败"

  cat > "$MIHOMO_FILE" <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true

proxies:
  - name: "sudoku-${SUDOKU_PORT}"
    type: sudoku
    server: "${PUBLIC_IP}"
    port: ${SUDOKU_PORT}
    key: "${AVAILABLE_PRIVATE_KEY}"
    aead-method: ${DEFAULT_AEAD}
    padding-min: 2
    padding-max: 7
    table-type: ${DEFAULT_ASCII}
    multiplex: "off"
    httpmask:
      disable: false
      mode: ws
      tls: false
      host: ""
      path-root: "${HTTPMASK_PATH_ROOT}"
      multiplex: "off"
    enable-pure-downlink: false

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - "sudoku-${SUDOKU_PORT}"

rules:
  - MATCH,Proxy
EOF
  chmod 600 "$MIHOMO_FILE"

  SHORT_LINK=$($BIN -c "$CLIENT_FILE" -export-link 2>&1 | grep -Eo 'sudoku://[^[:space:]]+' | tail -n1)
  [[ -n $SHORT_LINK ]] || die "生成 sudoku:// 链接失败"

  mkdir -p "${WEB_ROOT}/${SUBSCRIPTION_TOKEN}"
  install -m 0600 "$MIHOMO_FILE" "${WEB_ROOT}/${SUBSCRIPTION_TOKEN}/config.yaml"
  qrencode -t SVG -m 2 -o "${WEB_ROOT}/${SUBSCRIPTION_TOKEN}/qr.svg" "$subscription_url"
  chmod 600 "${WEB_ROOT}/${SUBSCRIPTION_TOKEN}/qr.svg"

  clash_url=$(python3 - "$subscription_url" <<'PY'
import sys, urllib.parse
print("clash://install-config?url=" + urllib.parse.quote(sys.argv[1], safe=""))
PY
)
  python3 - "$subscription_url" "$clash_url" "$SHORT_LINK" "$SUDOKU_PORT" > "${WEB_ROOT}/${SUBSCRIPTION_TOKEN}/index.html" <<'PY'
import html, sys
sub, clash, short, port = map(html.escape, sys.argv[1:])
print(f'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sudoku Mihomo 导入</title><style>
body{{font-family:system-ui,sans-serif;background:#0b1020;color:#e9eefb;margin:0;padding:28px}}main{{max-width:680px;margin:auto;background:#151d33;border-radius:18px;padding:28px;box-shadow:0 16px 50px #0008}}h1{{margin-top:0}}img{{display:block;width:min(78vw,330px);background:white;padding:12px;border-radius:12px;margin:22px auto}}code{{display:block;overflow-wrap:anywhere;background:#09101f;padding:12px;border-radius:9px}}a,button{{display:inline-block;margin:8px 6px 8px 0;padding:11px 16px;border:0;border-radius:9px;background:#5c7cfa;color:white;text-decoration:none;font-weight:650;cursor:pointer}}.muted{{color:#a9b4ca;font-size:.92rem}}</style></head>
<body><main><h1>Sudoku → Mihomo</h1><p>使用代理软件内的扫码功能扫描下方二维码，或复制订阅链接导入。</p>
<img src="qr.svg" alt="Mihomo subscription QR code"><p><a href="{clash}">尝试一键导入</a><button onclick="navigator.clipboard.writeText('{sub}')">复制订阅链接</button></p>
<code>{sub}</code><p class="muted">Sudoku 服务端口：{port}。二维码内容就是上面的订阅地址，不经过第三方二维码服务。</p>
<details><summary>Sudoku 原生短链</summary><code>{short}</code></details></main></body></html>''')
PY
  chmod 600 "${WEB_ROOT}/${SUBSCRIPTION_TOKEN}/index.html"
}

write_web_service() {
  mkdir -p "$WEB_APP_DIR"
  cat > "$WEB_APP" <<'PY'
#!/usr/bin/env python3
import http.server, os
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(os.environ["SUB_ROOT"]).resolve()
TOKEN = os.environ["SUB_TOKEN"]
PORT = int(os.environ["SUB_PORT"])
FILES = {
    f"/{TOKEN}/": ("index.html", "text/html; charset=utf-8"),
    f"/{TOKEN}/index.html": ("index.html", "text/html; charset=utf-8"),
    f"/{TOKEN}/config.yaml": ("config.yaml", "text/yaml; charset=utf-8"),
    f"/{TOKEN}/qr.svg": ("qr.svg", "image/svg+xml"),
}

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "SudokuSubscription/1"
    def do_HEAD(self): self._serve(False)
    def do_GET(self): self._serve(True)
    def _serve(self, body):
        path = unquote(urlsplit(self.path).path)
        if path == "/healthz":
            data, ctype, status = b"ok\n", "text/plain; charset=utf-8", 200
        elif path == f"/{TOKEN}":
            self.send_response(302); self.send_header("Location", f"/{TOKEN}/"); self.end_headers(); return
        elif path in FILES:
            name, ctype = FILES[path]
            data, status = (ROOT / TOKEN / name).read_bytes(), 200
        else:
            data, ctype, status = b"not found\n", "text/plain; charset=utf-8", 404
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'")
        self.end_headers()
        if body: self.wfile.write(data)
    def log_message(self, fmt, *args):
        print(f"{self.client_address[0]} {fmt % args}", flush=True)

http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
PY
  chmod 755 "$WEB_APP"
  cat > "$WEB_ENV" <<EOF
SUB_ROOT=${WEB_ROOT}
SUB_TOKEN=${SUBSCRIPTION_TOKEN}
SUB_PORT=${SUBSCRIPTION_PORT}
EOF
  chmod 600 "$WEB_ENV"
  cat > "/etc/systemd/system/${WEB_SERVICE}" <<EOF
[Unit]
Description=Sudoku Mihomo Subscription Server
After=network-online.target ${SUDOKU_SERVICE}
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${WEB_ENV}
ExecStart=/usr/bin/python3 ${WEB_APP}
Restart=on-failure
RestartSec=3s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=${ETC_DIR}
MemoryDenyWriteExecute=true
RestrictAddressFamilies=AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
EOF
}

open_firewall_port() {
  local port=$1
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "${port}/tcp" >/dev/null
    ok "UFW 已放行 ${port}/tcp"
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    ok "firewalld 已放行 ${port}/tcp"
  else
    warn "未检测到活动的 UFW/firewalld；如外部访问失败，请检查云安全组端口 ${port}/tcp"
  fi
}

backup_existing() {
  [[ -e $ETC_DIR || -e $BIN || -e /etc/systemd/system/$SUDOKU_SERVICE ]] || return 0
  local dest="${BACKUP_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$dest"
  [[ -d $ETC_DIR ]] && cp -a "$ETC_DIR" "$dest/etc-sudoku"
  [[ -e $BIN ]] && cp -a "$BIN" "$dest/sudoku.bin"
  [[ -e /etc/systemd/system/$SUDOKU_SERVICE ]] && cp -a "/etc/systemd/system/$SUDOKU_SERVICE" "$dest/"
  [[ -e /etc/systemd/system/$WEB_SERVICE ]] && cp -a "/etc/systemd/system/$WEB_SERVICE" "$dest/"
  ok "现有安装已备份：$dest"
}

wait_listen() {
  local port=$1 i
  for ((i=0; i<20; i++)); do port_in_use "$port" && return 0; sleep 0.5; done
  return 1
}

show_result() {
  load_state || die "安装状态文件缺失"
  local page="http://${PUBLIC_IP}:${SUBSCRIPTION_PORT}/${SUBSCRIPTION_TOKEN}/"
  local sub="http://${PUBLIC_IP}:${SUBSCRIPTION_PORT}/${SUBSCRIPTION_TOKEN}/config.yaml"
  printf '\n%b════════ Sudoku 安装结果 ════════%b\n' "$CYAN" "$RESET"
  printf '版本:       %s\n' "$(cat "$VERSION_FILE" 2>/dev/null || echo unknown)"
  printf '服务端口:   %s/tcp\n' "$SUDOKU_PORT"
  printf '扫码页面:   %s\n' "$page"
  printf '订阅链接:   %s\n' "$sub"
  printf 'Mihomo YAML: %s\n' "$MIHOMO_FILE"
  printf '客户端 JSON: %s\n' "$CLIENT_FILE"
  printf '状态:       systemctl status sudoku sudoku-subscription\n'
  printf '%b══════════════════════════════════%b\n\n' "$CYAN" "$RESET"
}

install_all() {
  require_root; detect_arch; install_dependencies
  backup_existing
  SUDOKU_PORT=$(choose_port "${SUDOKU_PORT:-}" 20000 50000 "Sudoku")
  SUBSCRIPTION_PORT=$(choose_port "${SUBSCRIPTION_PORT:-}" 10000 19999 "订阅")
  [[ $SUDOKU_PORT != "$SUBSCRIPTION_PORT" ]] || die "两个端口不可相同"
  PUBLIC_IP=$(get_public_ip)
  SUBSCRIPTION_TOKEN=$(generate_token)
  HTTPMASK_PATH_ROOT=$(generate_path_root)
  mkdir -p "$ETC_DIR" "$WEB_ROOT"
  download_binary
  generate_keys
  write_state
  write_server_config
  write_sudoku_service
  write_client_exports
  write_web_service
  systemctl daemon-reload
  systemctl enable --now "$SUDOKU_SERVICE" "$WEB_SERVICE" >/dev/null
  wait_listen "$SUDOKU_PORT" || { journalctl -u "$SUDOKU_SERVICE" -n 30 --no-pager; die "Sudoku 未监听端口"; }
  wait_listen "$SUBSCRIPTION_PORT" || { journalctl -u "$WEB_SERVICE" -n 30 --no-pager; die "订阅服务未监听端口"; }
  curl -fsS --max-time 5 "http://127.0.0.1:${SUBSCRIPTION_PORT}/healthz" | grep -qx ok || die "订阅服务健康检查失败"
  open_firewall_port "$SUDOKU_PORT"
  open_firewall_port "$SUBSCRIPTION_PORT"
  ok "Sudoku 与订阅服务均已启动"
  show_result
}

update_binary() {
  require_root; detect_arch; install_dependencies
  [[ -r $CONFIG_FILE ]] || die "尚未安装 Sudoku"
  backup_existing
  download_binary
  "$BIN" -c "$CONFIG_FILE" -test >/dev/null 2>&1 || die "更新后二进制未通过现有配置校验"
  systemctl restart "$SUDOKU_SERVICE"
  load_state && write_client_exports
  ok "更新完成"
  show_result
}

show_status() {
  require_root
  systemctl --no-pager --full status "$SUDOKU_SERVICE" "$WEB_SERVICE" || true
  show_result
}

uninstall_all() {
  require_root
  load_state || true
  systemctl disable --now "$SUDOKU_SERVICE" "$WEB_SERVICE" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SUDOKU_SERVICE}" "/etc/systemd/system/${WEB_SERVICE}" "$BIN"
  rm -rf "$ETC_DIR" "$WEB_APP_DIR"
  systemctl daemon-reload
  if [[ -n ${SUDOKU_PORT:-} ]] && command -v ufw >/dev/null 2>&1; then ufw delete allow "${SUDOKU_PORT}/tcp" >/dev/null 2>&1 || true; fi
  if [[ -n ${SUBSCRIPTION_PORT:-} ]] && command -v ufw >/dev/null 2>&1; then ufw delete allow "${SUBSCRIPTION_PORT}/tcp" >/dev/null 2>&1 || true; fi
  ok "卸载完成；备份目录未删除：${BACKUP_ROOT}"
}

menu() {
  while true; do
    printf '\n1) 安装/重装  2) 更新内核  3) 查看状态与链接  4) 日志  0) 卸载  q) 退出\n'
    read -r -p '请选择: ' choice
    case "$choice" in
      1) install_all ;;
      2) update_binary ;;
      3) show_status ;;
      4) journalctl -u "$SUDOKU_SERVICE" -u "$WEB_SERVICE" -n 100 --no-pager ;;
      0) read -r -p '确认卸载？[y/N] ' ans; [[ ${ans,,} == y ]] && uninstall_all ;;
      q|Q) exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

case "${1:-menu}" in
  install) install_all ;;
  update) update_binary ;;
  show|status) show_status ;;
  uninstall) uninstall_all ;;
  menu) menu ;;
  *) die "用法：$0 [install|update|show|uninstall|menu]" ;;
esac
