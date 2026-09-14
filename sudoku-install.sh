#!/usr/bin/env bash
# Sudoku 一键安装与 Mihomo 订阅/扫码导入脚本
# Upstream: https://github.com/SUDOKU-ASCII/sudoku

set -Eeuo pipefail
umask 077

readonly SCRIPT_VERSION="1.3.2"
readonly SUDOKU_REPO="${SUDOKU_REPO:-SUDOKU-ASCII/sudoku}"
readonly BIN="/usr/local/bin/sudoku"
readonly MANAGER_BIN="/usr/local/bin/sudoku-manager"
readonly ETC_DIR="/etc/sudoku"
readonly CONFIG_FILE="${ETC_DIR}/server.config.json"
readonly KEYS_FILE="${ETC_DIR}/keys.env"
readonly STATE_FILE="${ETC_DIR}/install.env"
readonly CLIENT_FILE="${ETC_DIR}/client.config.json"
readonly MIHOMO_FILE="${ETC_DIR}/mihomo.yaml"
readonly EXTERNAL_QR_FILE="${ETC_DIR}/external-qr.url"
readonly VERSION_FILE="${ETC_DIR}/version"
readonly WEB_ROOT="${ETC_DIR}/subscription"
readonly WEB_ENV="${ETC_DIR}/subscription.env"
readonly WEB_APP_DIR="/usr/local/lib/sudoku-subscription"
readonly WEB_APP="${WEB_APP_DIR}/server.py"
readonly SUDOKU_SERVICE="sudoku.service"
readonly WEB_SERVICE="sudoku-subscription.service"
readonly MSS_SERVICE="sudoku-mss.service"
readonly MSS_SCRIPT="/usr/local/lib/sudoku-mss"
readonly CERTBOT_HOOK="/etc/letsencrypt/renewal-hooks/deploy/sudoku-subscription"
readonly LEGO_BIN="/usr/local/bin/lego"
readonly LEGO_DIR="${ETC_DIR}/lego"
readonly LEGO_RENEW_SCRIPT="/usr/local/lib/sudoku-lego-renew"
readonly LEGO_RENEW_SERVICE="sudoku-lego-renew.service"
readonly LEGO_RENEW_TIMER="sudoku-lego-renew.timer"
readonly LEGO_VERSION="5.4.1"
readonly BACKUP_ROOT="/var/backups/sudoku-install"
readonly DEFAULT_FALLBACK="${SUDOKU_FALLBACK:-127.0.0.1:80}"
readonly DEFAULT_AEAD="chacha20-poly1305"
readonly DEFAULT_ASCII="prefer_entropy"
readonly DEFAULT_CLIENT_PORT="1080"
readonly DEFAULT_TCP_MSS="${SUDOKU_TCP_MSS:-1200}"
readonly DEFAULT_TLS_MODE="${SUDOKU_TLS_MODE:-letsencrypt}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
CERTBOT_BIN=""
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

install_manager() {
  local source_file="${BASH_SOURCE[0]}" tmp
  [[ -r $source_file ]] || die "读取当前安装脚本失败"
  tmp=$(mktemp "${MANAGER_BIN}.tmp.XXXXXX")
  cat "$source_file" > "$tmp"
  chmod 0755 "$tmp"
  mv -f "$tmp" "$MANAGER_BIN"
  ok "管理命令已安装：${MANAGER_BIN}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "仅支持 amd64/arm64，当前架构：$(uname -m)" ;;
  esac
}

install_dependencies() {
  local packages=(curl ca-certificates tar python3 qrencode iproute2 iptables openssl)
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v tar >/dev/null 2>&1 || missing+=(tar)
  command -v python3 >/dev/null 2>&1 || missing+=(python3)
  command -v qrencode >/dev/null 2>&1 || missing+=(qrencode)
  command -v ss >/dev/null 2>&1 || missing+=(iproute2)
  command -v iptables >/dev/null 2>&1 || missing+=(iptables)
  command -v openssl >/dev/null 2>&1 || missing+=(openssl)
  [[ -r /etc/ssl/certs/ca-certificates.crt || -r /etc/pki/tls/certs/ca-bundle.crt ]] || missing+=(ca-certificates)
  ((${#missing[@]} == 0)) && return 0
  info "安装依赖：${missing[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    wait_for_apt
    if ! timeout 180 apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=20 \
      -o Acquire::https::Timeout=20 update -qq; then
      warn "APT 索引更新超时，尝试使用现有软件包索引继续安装"
    fi
    DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=2 \
      -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 install -y -qq "${missing[@]}"
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
  local waited=0 busy
  while ((waited < 300)); do
    busy=false
    if pgrep -x apt-get >/dev/null 2>&1 || pgrep -x apt >/dev/null 2>&1 \
      || pgrep -x dpkg >/dev/null 2>&1; then
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
is_valid_mss() { [[ ${1:-} =~ ^[0-9]+$ ]] && ((10#$1 == 0 || (536 <= 10#$1 && 10#$1 <= 1460))); }
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
  local requested=${1:-} range_low=$2 range_high=$3 label=$4 allowed_in_use=${5:-}
  if [[ -n $requested ]]; then
    is_valid_port "$requested" || die "${label}端口无效：${requested}"
    if port_in_use "$requested" && [[ $requested != "$allowed_in_use" ]]; then
      die "${label}端口已占用：${requested}"
    fi
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

  if [[ ${SUDOKU_FORCE_DOWNLOAD:-0} != 1 && -x $BIN && -r $VERSION_FILE ]] \
    && [[ $(<"$VERSION_FILE") == "$version" ]]; then
    ok "已安装最新版本 ${version}，复用现有已校验二进制"
    return 0
  fi

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
TCP_MSS=${TCP_MSS}
SUBSCRIPTION_SCHEME=${SUBSCRIPTION_SCHEME}
SUBSCRIPTION_MODE=${SUBSCRIPTION_MODE}
TLS_CERT_FILE=${TLS_CERT_FILE}
TLS_KEY_FILE=${TLS_KEY_FILE}
ACME_METHOD=${ACME_METHOD}
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
  "enable_pure_downlink": true,
  "multiplex": "off",
  "httpmask": {
    "disable": true,
    "mode": "legacy",
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

write_mss_service() {
  mkdir -p "$(dirname "$MSS_SCRIPT")"
  cat > "$MSS_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
action=${1:?apply or remove}
port=${2:?port}
mss=${3:?mss}
((mss == 0)) && exit 0
rules=(
  "PREROUTING -p tcp --dport ${port} --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss}"
  "OUTPUT -p tcp --sport ${port} --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss}"
)
for rule in "${rules[@]}"; do
  read -r chain rest <<<"$rule"
  # shellcheck disable=SC2086
  if [[ $action == apply ]]; then
    iptables -w 5 -t mangle -C "$chain" $rest 2>/dev/null || iptables -w 5 -t mangle -I "$chain" 1 $rest
  else
    while iptables -w 5 -t mangle -C "$chain" $rest 2>/dev/null; do
      # shellcheck disable=SC2086
      iptables -w 5 -t mangle -D "$chain" $rest
    done
  fi
done
EOF
  chmod 755 "$MSS_SCRIPT"
  cat > "/etc/systemd/system/${MSS_SERVICE}" <<EOF
[Unit]
Description=Sudoku TCP MSS clamp
Before=${SUDOKU_SERVICE}
After=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${MSS_SCRIPT} apply ${SUDOKU_PORT} ${TCP_MSS}
ExecStop=${MSS_SCRIPT} remove ${SUDOKU_PORT} ${TCP_MSS}

[Install]
WantedBy=multi-user.target
EOF
}

certbot_is_current() {
  local candidate version
  CERTBOT_BIN=""
  candidate=$(command -v certbot 2>/dev/null || true)
  for candidate in "$candidate" /snap/bin/certbot /usr/local/bin/certbot /usr/bin/certbot; do
    if [[ -n $candidate && -x $candidate ]]; then
      CERTBOT_BIN=$candidate
      break
    fi
  done
  [[ -n $CERTBOT_BIN ]] || return 1
  version=$("$CERTBOT_BIN" --version 2>&1 | sed -n 's/^certbot \([0-9][0-9.]*\).*/\1/p')
  [[ -n $version ]] && python3 - "$version" <<'PY'
import sys
parts = tuple(int(x) for x in sys.argv[1].split('.')[:2])
raise SystemExit(0 if parts >= (5, 4) else 1)
PY
}

install_current_certbot() {
  certbot_is_current && return 0
  if ! command -v snap >/dev/null 2>&1; then
    info "安装 snapd"
    if command -v apt-get >/dev/null 2>&1; then
      wait_for_apt
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq snapd
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y snapd
    elif command -v yum >/dev/null 2>&1; then
      yum install -y snapd
    else
      die "自动申请 IP 证书需要 Certbot 5.4+ 与 snapd"
    fi
    systemctl enable --now snapd.socket
  fi
  info "安装支持 IP 证书的新版 Certbot"
  snap install certbot --classic || snap refresh certbot
  hash -r
  certbot_is_current || die "Certbot 版本低于 5.4"
}

install_lego() {
  local digest tmp actual
  if [[ -x $LEGO_BIN ]] && "$LEGO_BIN" --version 2>/dev/null | grep -q "version ${LEGO_VERSION}"; then
    return 0
  fi
  case "$ARCH" in
    amd64) digest="ebb33f1bead5a7c99dd46f1c5734b44cf1eab5b5c12faf397cd14d50a5916419" ;;
    arm64) digest="8494c06bde449ac4d65c726b7ea50d67ac61f422e698c9b78b47778445b098f2" ;;
    *) die "Lego 不支持当前架构：$ARCH" ;;
  esac
  tmp=$(mktemp -d)
  info "安装 Lego ${LEGO_VERSION}，用于 443/tcp TLS-ALPN-01 验证"
  curl -fL --retry 3 --connect-timeout 15 --max-time 180 \
    -o "${tmp}/lego.tar.gz" \
    "https://github.com/go-acme/lego/releases/download/v${LEGO_VERSION}/lego_v${LEGO_VERSION}_linux_${ARCH}.tar.gz"
  actual=$(sha256sum "${tmp}/lego.tar.gz" | awk '{print $1}')
  [[ ${actual,,} == "$digest" ]] || { rm -rf "$tmp"; die "Lego SHA-256 校验失败"; }
  tar -xzf "${tmp}/lego.tar.gz" -C "$tmp" lego
  install -m 0755 "${tmp}/lego" "$LEGO_BIN"
  rm -rf "$tmp"
}

issue_lego_ip_certificate() {
  port_in_use 443 && die "80/tcp 的 Webroot 不可用且 443/tcp 也已占用"
  install_lego
  open_firewall_port 443
  mkdir -p "$LEGO_DIR"
  info "通过 443/tcp TLS-ALPN-01 申请受信任的公网 IP 证书"
  "$LEGO_BIN" run --path "$LEGO_DIR" --accept-tos \
    --email="${SUDOKU_ACME_EMAIL:-}" --server letsencrypt \
    --domains "$PUBLIC_IP" --profile shortlived --tls
  TLS_CERT_FILE="${LEGO_DIR}/certificates/${PUBLIC_IP}.crt"
  TLS_KEY_FILE="${LEGO_DIR}/certificates/${PUBLIC_IP}.key"
  ACME_METHOD=lego
}

write_lego_renewal_service() {
  cat > "$LEGO_RENEW_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
source ${STATE_FILE}
openssl x509 -checkend 172800 -noout -in "\$TLS_CERT_FILE" >/dev/null 2>&1 && exit 0
stopped=()
if [[ \${SUDOKU_PORT:-0} == 443 ]] && systemctl is-active --quiet ${SUDOKU_SERVICE}; then
  systemctl stop ${SUDOKU_SERVICE}; stopped+=(${SUDOKU_SERVICE})
fi
if [[ \${SUBSCRIPTION_PORT:-0} == 443 ]] && systemctl is-active --quiet ${WEB_SERVICE}; then
  systemctl stop ${WEB_SERVICE}; stopped+=(${WEB_SERVICE})
fi
restore() { for service in "\${stopped[@]}"; do systemctl start "\$service"; done; }
trap restore EXIT
${LEGO_BIN} run --path ${LEGO_DIR} --accept-tos --email="${SUDOKU_ACME_EMAIL:-}" \
  --server letsencrypt --domains "\$PUBLIC_IP" --profile shortlived --tls
systemctl try-restart ${WEB_SERVICE}
EOF
  chmod 755 "$LEGO_RENEW_SCRIPT"
  cat > "/etc/systemd/system/${LEGO_RENEW_SERVICE}" <<EOF
[Unit]
Description=Renew Sudoku IP certificate using TLS-ALPN-01
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${LEGO_RENEW_SCRIPT}
EOF
  cat > "/etc/systemd/system/${LEGO_RENEW_TIMER}" <<EOF
[Unit]
Description=Daily Sudoku IP certificate renewal check

[Timer]
OnCalendar=daily
RandomizedDelaySec=2h
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

discover_certbot_webroot() {
  local requested=${SUDOKU_CERTBOT_WEBROOT:-} root probe token body
  local candidates=()
  if [[ -n $requested ]]; then
    [[ $requested == /* ]] || die "SUDOKU_CERTBOT_WEBROOT 必须是绝对路径"
    candidates+=("$requested")
  else
    candidates+=(/var/www/html /usr/share/nginx/html /var/www/default/html)
  fi
  probe="sudoku-$(generate_token)"
  token=$(generate_token)
  for root in "${candidates[@]}"; do
    [[ -d $root ]] || continue
    mkdir -p "${root}/.well-known/acme-challenge"
    printf '%s' "$token" > "${root}/.well-known/acme-challenge/${probe}"
    body=$(curl -kfsSL --connect-timeout 4 --max-time 8 \
      "http://${PUBLIC_IP}/.well-known/acme-challenge/${probe}" 2>/dev/null || true)
    rm -f "${root}/.well-known/acme-challenge/${probe}"
    if [[ $body == "$token" ]]; then
      printf '%s\n' "$root"
      return 0
    fi
  done
  return 1
}

setup_tls() {
  local webroot=""
  SUBSCRIPTION_SCHEME=https
  SUBSCRIPTION_MODE=https
  ACME_METHOD=self-signed
  if [[ $DEFAULT_TLS_MODE == self-signed ]]; then
    local cert_dir="${ETC_DIR}/tls"
    mkdir -p "$cert_dir"
    TLS_CERT_FILE="${cert_dir}/fullchain.pem"
    TLS_KEY_FILE="${cert_dir}/privkey.pem"
    openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 365 \
      -subj "/CN=${PUBLIC_IP}" -addext "subjectAltName=IP:${PUBLIC_IP}" \
      -keyout "$TLS_KEY_FILE" -out "$TLS_CERT_FILE" >/dev/null 2>&1
    chmod 600 "$TLS_CERT_FILE" "$TLS_KEY_FILE"
    warn "已生成自签证书；客户端需先信任该证书"
    return 0
  fi
  [[ $DEFAULT_TLS_MODE == letsencrypt ]] || die "SUDOKU_TLS_MODE 仅支持 letsencrypt/self-signed"
  [[ $PUBLIC_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "IP 证书模式当前需要 IPv4 地址"
  if port_in_use 80 && port_in_use 443; then
    SUBSCRIPTION_MODE=external-qr
    SUBSCRIPTION_SCHEME=external
    TLS_CERT_FILE=""
    TLS_KEY_FILE=""
    ACME_METHOD=external-qr
    warn "检测到 80/tcp 与 443/tcp 均已占用，使用 api.qrserver.com 生成 sudoku:// 导入二维码"
    return 0
  fi
  TLS_CERT_FILE="/etc/letsencrypt/live/${PUBLIC_IP}/fullchain.pem"
  TLS_KEY_FILE="/etc/letsencrypt/live/${PUBLIC_IP}/privkey.pem"
  open_firewall_port 80
  if [[ -s $TLS_CERT_FILE && -s $TLS_KEY_FILE ]] && openssl x509 -checkend 43200 -noout -in "$TLS_CERT_FILE" >/dev/null; then
    ACME_METHOD=certbot
  elif ! port_in_use 80; then
    install_current_certbot
    info "向 Let's Encrypt 申请受信任的公网 IP 短期证书"
    "$CERTBOT_BIN" certonly --non-interactive --agree-tos --register-unsafely-without-email \
      --preferred-profile shortlived --standalone --ip-address "$PUBLIC_IP"
    ACME_METHOD=certbot
  else
    webroot=$(discover_certbot_webroot || true)
    if [[ -n $webroot ]]; then
      install_current_certbot
      info "复用现有 Web 服务进行证书验证，Webroot：${webroot}"
      "$CERTBOT_BIN" certonly --non-interactive --agree-tos --register-unsafely-without-email \
        --preferred-profile shortlived --webroot --webroot-path "$webroot" --ip-address "$PUBLIC_IP"
      ACME_METHOD=certbot
    else
      if port_in_use 443; then
        SUBSCRIPTION_MODE=external-qr
        SUBSCRIPTION_SCHEME=external
        TLS_CERT_FILE=""
        TLS_KEY_FILE=""
        ACME_METHOD=external-qr
        warn "80/tcp 与 443/tcp 均已占用，使用 api.qrserver.com 生成 sudoku:// 导入二维码"
        return 0
      fi
      issue_lego_ip_certificate
    fi
  fi
  if [[ $ACME_METHOD == certbot ]]; then
    mkdir -p "$(dirname "$CERTBOT_HOOK")"
    cat > "$CERTBOT_HOOK" <<EOF
#!/usr/bin/env bash
systemctl try-restart ${WEB_SERVICE}
EOF
    chmod 755 "$CERTBOT_HOOK"
  fi
  [[ -s $TLS_CERT_FILE && -s $TLS_KEY_FILE ]] || die "证书文件生成失败"
  ok "公网 IP HTTPS 证书有效期至：$(openssl x509 -enddate -noout -in "$TLS_CERT_FILE" | cut -d= -f2-)"
}

write_client_exports() {
  local server_address subscription_url="" clash_url encoded
  server_address="${PUBLIC_IP}:${SUDOKU_PORT}"

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
  "enable_pure_downlink": true,
  "multiplex": "off",
  "httpmask": {
    "disable": true,
    "mode": "legacy",
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
      disable: true
      mode: legacy
      tls: false
      host: ""
      path-root: "${HTTPMASK_PATH_ROOT}"
      multiplex: "off"
    enable-pure-downlink: true

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

  if [[ ${SUBSCRIPTION_MODE:-https} == external-qr ]]; then
    encoded=$(python3 - "$SHORT_LINK" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
)
    printf 'https://api.qrserver.com/v1/create-qr-code/?size=400x400&data=%s\n' "$encoded" > "$EXTERNAL_QR_FILE"
    chmod 600 "$EXTERNAL_QR_FILE"
    rm -rf "$WEB_ROOT"
    return 0
  fi

  rm -f "$EXTERNAL_QR_FILE"
  subscription_url="${SUBSCRIPTION_SCHEME}://${PUBLIC_IP}:${SUBSCRIPTION_PORT}/${SUBSCRIPTION_TOKEN}/config.yaml"

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
import http.server, os, ssl
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(os.environ["SUB_ROOT"]).resolve()
TOKEN = os.environ["SUB_TOKEN"]
PORT = int(os.environ["SUB_PORT"])
CERT_FILE = os.environ["TLS_CERT_FILE"]
KEY_FILE = os.environ["TLS_KEY_FILE"]
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

server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(CERT_FILE, KEY_FILE)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PY
  chmod 755 "$WEB_APP"
  cat > "$WEB_ENV" <<EOF
SUB_ROOT=${WEB_ROOT}
SUB_TOKEN=${SUBSCRIPTION_TOKEN}
SUB_PORT=${SUBSCRIPTION_PORT}
TLS_CERT_FILE=${TLS_CERT_FILE}
TLS_KEY_FILE=${TLS_KEY_FILE}
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

close_firewall_port() {
  local port=${1:-}
  is_valid_port "$port" || return 0
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
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
  [[ -e /etc/systemd/system/$MSS_SERVICE ]] && cp -a "/etc/systemd/system/$MSS_SERVICE" "$dest/"
  ok "现有安装已备份：$dest"
}

wait_listen() {
  local port=$1 i
  for ((i=0; i<20; i++)); do port_in_use "$port" && return 0; sleep 0.5; done
  return 1
}

show_result() {
  load_state || die "安装状态文件缺失"
  local page sub qr_url
  printf '\n%b════════ Sudoku 安装结果 ════════%b\n' "$CYAN" "$RESET"
  printf '版本:       %s\n' "$(cat "$VERSION_FILE" 2>/dev/null || echo unknown)"
  printf '服务端口:   %s/tcp\n' "$SUDOKU_PORT"
  if [[ ${SUBSCRIPTION_MODE:-https} == external-qr ]]; then
    qr_url=$(cat "$EXTERNAL_QR_FILE" 2>/dev/null || true)
    printf '导入方式:   外部 HTTPS 二维码（二维码内容为 sudoku:// 原生短链）\n'
    printf '二维码图片: %s\n' "$qr_url"
  else
    page="${SUBSCRIPTION_SCHEME}://${PUBLIC_IP}:${SUBSCRIPTION_PORT}/${SUBSCRIPTION_TOKEN}/"
    sub="${SUBSCRIPTION_SCHEME}://${PUBLIC_IP}:${SUBSCRIPTION_PORT}/${SUBSCRIPTION_TOKEN}/config.yaml"
    printf '扫码页面:   %s\n' "$page"
    printf '订阅链接:   %s\n' "$sub"
  fi
  printf 'Mihomo YAML: %s\n' "$MIHOMO_FILE"
  printf '客户端 JSON: %s\n' "$CLIENT_FILE"
  if [[ ${SUBSCRIPTION_MODE:-https} == external-qr ]]; then
    printf '状态:       systemctl status sudoku\n'
  else
    printf '状态:       systemctl status sudoku sudoku-subscription\n'
  fi
  printf '%b══════════════════════════════════%b\n\n' "$CYAN" "$RESET"
}

install_all() {
  local previous_sudoku_port="" previous_subscription_port=""
  require_root; detect_arch; install_dependencies
  install_manager
  backup_existing
  if [[ -r $STATE_FILE ]]; then
    previous_sudoku_port=$(sed -n 's/^SUDOKU_PORT=//p' "$STATE_FILE" | head -n1)
    previous_subscription_port=$(sed -n 's/^SUBSCRIPTION_PORT=//p' "$STATE_FILE" | head -n1)
  fi
  SUDOKU_PORT=$(choose_port "${SUDOKU_PORT:-}" 20000 50000 "Sudoku" "$previous_sudoku_port")
  SUBSCRIPTION_PORT=$(choose_port "${SUBSCRIPTION_PORT:-}" 10000 19999 "订阅" "$previous_subscription_port")
  [[ $SUDOKU_PORT != "$SUBSCRIPTION_PORT" ]] || die "两个端口不可相同"
  PUBLIC_IP=$(get_public_ip)
  SUBSCRIPTION_TOKEN=$(generate_token)
  HTTPMASK_PATH_ROOT=""
  TCP_MSS="$DEFAULT_TCP_MSS"
  is_valid_mss "$TCP_MSS" || die "SUDOKU_TCP_MSS 应为 0 或 536-1460"
  mkdir -p "$ETC_DIR" "$WEB_ROOT"
  download_binary
  generate_keys
  # shellcheck disable=SC1090
  source "$KEYS_FILE"
  setup_tls
  write_state
  write_server_config
  write_sudoku_service
  systemctl disable --now "$MSS_SERVICE" >/dev/null 2>&1 || true
  write_mss_service
  write_client_exports
  if [[ $SUBSCRIPTION_MODE == external-qr ]]; then
    systemctl disable --now "$WEB_SERVICE" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${WEB_SERVICE}"
  else
    write_web_service
  fi
  if [[ $ACME_METHOD == lego ]]; then
    write_lego_renewal_service
  else
    systemctl disable --now "$LEGO_RENEW_TIMER" >/dev/null 2>&1 || true
  fi
  systemctl daemon-reload
  systemctl enable "$MSS_SERVICE" "$SUDOKU_SERVICE" >/dev/null
  if [[ $SUBSCRIPTION_MODE != external-qr ]]; then
    systemctl enable "$WEB_SERVICE" >/dev/null
  fi
  if [[ $ACME_METHOD == lego ]]; then
    systemctl enable --now "$LEGO_RENEW_TIMER" >/dev/null
  fi
  systemctl restart "$MSS_SERVICE" "$SUDOKU_SERVICE"
  if [[ $SUBSCRIPTION_MODE != external-qr ]]; then
    systemctl restart "$WEB_SERVICE"
  fi
  wait_listen "$SUDOKU_PORT" || { journalctl -u "$SUDOKU_SERVICE" -n 30 --no-pager; die "Sudoku 未监听端口"; }
  if [[ $SUBSCRIPTION_MODE != external-qr ]]; then
    wait_listen "$SUBSCRIPTION_PORT" || { journalctl -u "$WEB_SERVICE" -n 30 --no-pager; die "订阅服务未监听端口"; }
    curl -fsS --max-time 8 --cacert "$TLS_CERT_FILE" \
      --connect-to "${PUBLIC_IP}:${SUBSCRIPTION_PORT}:127.0.0.1:${SUBSCRIPTION_PORT}" \
      "https://${PUBLIC_IP}:${SUBSCRIPTION_PORT}/healthz" | grep -qx ok || die "HTTPS 订阅服务健康检查失败"
  fi
  open_firewall_port "$SUDOKU_PORT"
  if [[ $SUBSCRIPTION_MODE != external-qr ]]; then
    open_firewall_port "$SUBSCRIPTION_PORT"
  fi
  if [[ -n $previous_sudoku_port && $previous_sudoku_port != "$SUDOKU_PORT" ]]; then
    close_firewall_port "$previous_sudoku_port"
  fi
  if [[ -n $previous_subscription_port && $previous_subscription_port != "$SUBSCRIPTION_PORT" ]]; then
    close_firewall_port "$previous_subscription_port"
  fi
  if [[ $SUBSCRIPTION_MODE == external-qr && -n $previous_subscription_port ]]; then
    close_firewall_port "$previous_subscription_port"
  fi
  if [[ $SUBSCRIPTION_MODE == external-qr ]]; then
    ok "Sudoku 已启动；80/443 均被占用，已生成外部 HTTPS 二维码链接"
  else
    ok "Sudoku 与订阅服务均已启动"
  fi
  show_result
}

update_binary() {
  require_root; detect_arch; install_dependencies
  [[ -r $CONFIG_FILE ]] || die "尚未安装 Sudoku"
  install_manager
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
  load_state || die "安装状态文件缺失"
  if [[ ${SUBSCRIPTION_MODE:-https} == external-qr ]]; then
    systemctl --no-pager --full status "$SUDOKU_SERVICE" || true
  else
    systemctl --no-pager --full status "$SUDOKU_SERVICE" "$WEB_SERVICE" || true
  fi
  show_result
}

service_action() {
  require_root
  local action=$1
  load_state || die "安装状态文件缺失"
  if [[ ${SUBSCRIPTION_MODE:-https} == external-qr ]]; then
    systemctl "$action" "$SUDOKU_SERVICE"
  else
    systemctl "$action" "$SUDOKU_SERVICE" "$WEB_SERVICE"
  fi
  ok "服务已执行：$action"
  if [[ ${SUBSCRIPTION_MODE:-https} == external-qr ]]; then
    systemctl is-active "$SUDOKU_SERVICE" || true
  else
    systemctl is-active "$SUDOKU_SERVICE" "$WEB_SERVICE" || true
  fi
}

show_logs() {
  require_root
  shift || true
  if (($#)); then
    journalctl -u "$SUDOKU_SERVICE" -u "$WEB_SERVICE" "$@" --no-pager
  else
    journalctl -u "$SUDOKU_SERVICE" -u "$WEB_SERVICE" -n 100 --no-pager
  fi
}

uninstall_all() {
  require_root
  load_state || true
  systemctl disable --now "$SUDOKU_SERVICE" "$WEB_SERVICE" "$MSS_SERVICE" "$LEGO_RENEW_TIMER" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SUDOKU_SERVICE}" "/etc/systemd/system/${WEB_SERVICE}" "/etc/systemd/system/${MSS_SERVICE}" "/etc/systemd/system/${LEGO_RENEW_SERVICE}" "/etc/systemd/system/${LEGO_RENEW_TIMER}" "$MSS_SCRIPT" "$LEGO_RENEW_SCRIPT" "$CERTBOT_HOOK" "$LEGO_BIN" "$BIN" "$MANAGER_BIN"
  rm -rf "$ETC_DIR" "$WEB_APP_DIR"
  systemctl daemon-reload
  if [[ -n ${SUDOKU_PORT:-} ]] && command -v ufw >/dev/null 2>&1; then ufw delete allow "${SUDOKU_PORT}/tcp" >/dev/null 2>&1 || true; fi
  if [[ -n ${SUBSCRIPTION_PORT:-} ]] && command -v ufw >/dev/null 2>&1; then ufw delete allow "${SUBSCRIPTION_PORT}/tcp" >/dev/null 2>&1 || true; fi
  ok "卸载完成；备份目录未删除：${BACKUP_ROOT}"
}

print_help() {
  cat <<EOF
Sudoku 服务端管理脚本 v${SCRIPT_VERSION}
用法：$(basename "$0") [命令]

可用命令：
  install              安装或重装 Sudoku 服务（需要 root）
  update               更新 Sudoku 内核并保留现有配置（需要 root）
  uninstall            卸载 Sudoku 服务，保留历史备份（需要 root）
  start                启动 Sudoku 服务（需要 root）
  stop                 停止 Sudoku 服务（需要 root）
  restart              重启 Sudoku 服务（需要 root）
  status               查看服务当前状态、导入地址和配置路径
  log [参数]           查看服务日志（例：$(basename "$0") log -n 100）
  qr                   显示当前扫码导入信息
  menu                 打开交互式管理菜单
  help                 显示此帮助菜单

示例：bash $(basename "$0") install
EOF
}

menu() {
  while true; do
    printf '\n%b════════ Sudoku 服务端管理 ════════%b\n' "$CYAN" "$RESET"
    printf '1) 安装/重装    2) 更新内核    3) 查看状态/二维码\n'
    printf '4) 查看日志     5) 启动        6) 停止        7) 重启\n'
    printf '0) 卸载         h) 命令帮助    q) 退出\n'
    read -r -p '请选择: ' choice
    case "$choice" in
      1) install_all ;;
      2) update_binary ;;
      3) show_status ;;
      4) show_logs -n 100 ;;
      5) service_action start ;;
      6) service_action stop ;;
      7) service_action restart ;;
      0) read -r -p '确认卸载？[y/N] ' ans; [[ ${ans,,} == y ]] && uninstall_all ;;
      h|H|help) print_help ;;
      q|Q) exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

case "${1:-help}" in
  install) install_all ;;
  update) update_binary ;;
  show|status) show_status ;;
  start|stop|restart) service_action "$1" ;;
  log|logs) show_logs "$@" ;;
  qr) show_result ;;
  uninstall) uninstall_all ;;
  menu) menu ;;
  help|-h|--help) print_help ;;
  *) print_help >&2; die "未知命令：$1" ;;
esac
