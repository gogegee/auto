#!/usr/bin/env bash
# =====================================================================
#  VPS 一键配置脚本 (菜单版)
#
#  系统配置: 更新 / 时区(上海) / BBR / 防火墙 / SSH 加固 / fail2ban + 自动安全更新
#  节点配置: 证书 + Nginx 伪装站(仅本地) + Xray VLESS-Reality(443)
#  适用: Debian 12/13 (Ubuntu 22.04+ 基本可用)，请用 root 运行
#
#  交互菜单:
#    bash <(curl -fsSL https://raw.githubusercontent.com/你的用户名/你的仓库/main/setup-vps.sh)
#  直接执行某一项 (跳过菜单):
#    bash setup-vps.sh all | system | node | update | tz | bbr | firewall |
#                      ssh | security | cert | nginx | xray | site | info
#  可选环境变量 (非交互):
#    DOMAIN EMAIL SSH_PORT PUBKEY BLOCK_CN TIMEZONE ASSUME_YES=1
#    REGEN=1 (重新生成 UUID/密钥)   FORCE_SITE=1 (重置伪装网页)
#    SITE_URL=https://.../index.html (使用自己的伪装网页)
# =====================================================================
set -Eeuo pipefail

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
info() { echo "${GRN}[+]${RST} $*"; }
warn() { echo "${YEL}[!]${RST} $*"; }
die()  { echo "${RED}[x]${RST} $*" >&2; exit 1; }

STATE_DIR=/var/lib/vps-setup; STATE_FILE="$STATE_DIR/state.conf"; LOG=/var/log/vps-setup.log
XRAY=/usr/local/bin/xray; CONF=/usr/local/etc/xray/config.json; OUT=/root/xray-client.txt
OPENED80=0; FW_OK=0; APT_READY=""; CERT=""; CUR_SSH_PORTS=""
cleanup() { [[ $OPENED80 -eq 1 ]] && ufw delete allow 80/tcp >/dev/null 2>&1 || true; }
trap cleanup EXIT
trap 'die "脚本在第 $LINENO 行出错并中止，详情见上面的输出和 $LOG。排除问题后重新运行本脚本即可，已完成的步骤会自动跳过。"' ERR

fw() { [[ $FW_OK -eq 1 ]] && ufw "$@" >/dev/null 2>&1 || true; }
fw_detect() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then FW_OK=1; fi
  return 0
}

# ---------------------------------------------------------------- 交互输入 (直接读写 /dev/tty)
have_tty() { (exec </dev/tty) 2>/dev/null; }
prompt() { # prompt "提示文字" 变量名
  local __a=""
  have_tty || { printf -v "$2" '%s' ""; return 1; }
  printf '%s' "$1" >/dev/tty
  IFS= read -r __a </dev/tty || { printf -v "$2" '%s' ""; return 1; }
  printf -v "$2" '%s' "$__a"
}
ask() { # ask "提示" 变量名 [默认值]；变量已有值(环境变量)时不再询问
  local p="$1" v="$2" d="${3:-}" a=""
  [[ -n "${!v+x}" ]] && return 0
  if [[ -n "$d" ]]; then prompt "$p [$d]: " a || true; a="${a:-$d}"
  else prompt "$p: " a || true; fi
  printf -v "$v" '%s' "$a"
}
yn() { # yn "问题" ；ASSUME_YES=1 时直接视为是
  local a=""
  [[ "${ASSUME_YES:-0}" == 1 ]] && return 0
  prompt "$1 [y/N] " a || return 1
  [[ "$a" =~ ^[Yy]$ ]]
}
pause() { local a=""; prompt "按回车继续..." a || true; return 0; }

# ---------------------------------------------------------------- 记住上次输入
P_DOMAIN=""; P_EMAIL=""; P_SSH_PORT=""; P_BLOCK_CN=""
load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
  fi
  return 0
}
save_state() {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  printf 'P_DOMAIN=%q\nP_EMAIL=%q\nP_SSH_PORT=%q\nP_BLOCK_CN=%q\n' \
    "${DOMAIN-$P_DOMAIN}" "${EMAIL-$P_EMAIL}" "${SSH_PORT-$P_SSH_PORT}" "${BLOCK_CN-$P_BLOCK_CN}" > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

# ---------------------------------------------------------------- 参数收集 (需要时才问，只问一次)
need_domain() {
  [[ -n "${DOMAIN_OK:-}" ]] && return 0
  ask "域名 (已解析到本机 IP；若用 Cloudflare 必须是灰云)" DOMAIN "$P_DOMAIN"
  [[ -n "${DOMAIN:-}" ]] || die "未输入域名 (非交互运行请设置 DOMAIN 环境变量)"
  DOMAIN="${DOMAIN,,}"
  [[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || die "域名格式不正确: $DOMAIN"
  ask "证书通知邮箱 (可留空)" EMAIL "$P_EMAIL"
  CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  DOMAIN_OK=1; save_state
}
need_cn() {
  [[ -n "${CN_OK:-}" ]] && return 0
  ask "屏蔽代理回国流量? 1=是 0=否" BLOCK_CN "${P_BLOCK_CN:-1}"
  [[ "$BLOCK_CN" =~ ^[01]$ ]] || die "BLOCK_CN 只能是 0 或 1"
  CN_OK=1; save_state
}
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1024 && $1 <= 65535 && $1 != 443 && $1 != 8443 )); }
need_ssh_port() { # 端口不写在脚本里，运行时手动输入 (上次输入会记在本机的状态文件里，仅作回车默认值)
  [[ -n "${SSHP_OK:-}" ]] && return 0
  local a="" tries=0
  if [[ -z "${SSH_PORT:-}" ]]; then
    while (( tries < 3 )); do
      if [[ -n "$P_SSH_PORT" ]]; then
        prompt "请输入新的 SSH 端口 (1024-65535) [上次: $P_SSH_PORT]: " a || break
        a="${a:-$P_SSH_PORT}"
      else
        prompt "请输入新的 SSH 端口 (1024-65535): " a || break
      fi
      if valid_port "$a"; then SSH_PORT="$a"; break; fi
      warn "端口无效：需要是 1024-65535 之间的数字，且不能是 443 或 8443"
      tries=$((tries + 1))
    done
  fi
  [[ -n "${SSH_PORT:-}" ]] || die "未设置 SSH 端口 (非交互运行请设置 SSH_PORT 环境变量)"
  valid_port "$SSH_PORT" || die "SSH 端口无效: $SSH_PORT (需要 1024-65535 之间，且不能是 443 或 8443)"
  SSHP_OK=1; save_state
}
KEY_OK=0
need_pubkey() {
  [[ -n "${PUBKEY_DONE:-}" ]] && return 0
  KEY_OK=0
  if [[ -s /root/.ssh/authorized_keys ]] && grep -qE '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys; then
    KEY_OK=1; info "检测到 root 已有公钥。"
  fi
  PUBKEY="${PUBKEY:-}"
  if [[ -z "$PUBKEY" ]]; then
    echo "请粘贴你的 SSH 公钥(整行，形如 ssh-ed25519 AAAA... 备注)。"
    if [[ $KEY_OK -eq 1 ]]; then echo "已有公钥，直接回车可跳过。"; else echo "留空则保留密码登录，不会禁用密码。"; fi
    prompt "公钥: " PUBKEY || true
  fi
  if [[ -n "$PUBKEY" ]]; then
    local tmpk; tmpk="$(mktemp)"; echo "$PUBKEY" > "$tmpk"
    ssh-keygen -l -f "$tmpk" >/dev/null 2>&1 || { rm -f "$tmpk"; die "公钥格式不正确，请粘贴 .pub 文件的完整一行"; }
    rm -f "$tmpk"
    mkdir -p /root/.ssh; chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    grep -qxF "$PUBKEY" /root/.ssh/authorized_keys || echo "$PUBKEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    KEY_OK=1
  fi
  [[ $KEY_OK -eq 1 ]] || warn "没有公钥：将只改端口，密码登录保持开启。以后添加公钥后可重新执行 SSH 加固。"
  PUBKEY_DONE=1
}

# ---------------------------------------------------------------- 软件包
apt_prepare() {
  [[ -n "$APT_READY" ]] && return 0
  export DEBIAN_FRONTEND=noninteractive
  dpkg --configure -a || true
  apt-get update -y
  APT_READY=1
}
need_pkgs() { # 只安装缺失的包
  local m=() p
  for p in "$@"; do dpkg -s "$p" >/dev/null 2>&1 || m+=("$p"); done
  if (( ${#m[@]} )); then
    apt_prepare
    info "安装软件包: ${m[*]}"
    apt-get -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" install "${m[@]}"
  fi
  return 0
}

# ================================================================= 系统配置
step_update() { # step_update [auto]  auto: 做过一次就跳过 (用于一键流程重跑)
  info "系统更新与基础软件..."
  apt_prepare
  if [[ "${1:-}" == auto && -f "$STATE_DIR/upgraded" ]]; then
    info "系统升级已执行过，跳过"
  else
    apt-get -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" full-upgrade
    apt-get -y autoremove
    touch "$STATE_DIR/upgraded"
  fi
  need_pkgs curl ca-certificates jq dnsutils openssl iproute2 qrencode
  return 0
}

step_timezone() {
  local tz="${TIMEZONE:-Asia/Shanghai}"
  info "设置时区为 $tz ..."
  if [[ "$(timedatectl show -p Timezone --value 2>/dev/null || true)" == "$tz" ]]; then
    info "时区已经是 $tz，跳过"
  else
    timedatectl set-timezone "$tz" || die "设置时区失败，请确认时区名称正确 (timedatectl list-timezones)"
  fi
  timedatectl set-ntp true >/dev/null 2>&1 || true
  info "当前时间: $(date '+%F %T %Z')"
  return 0
}

step_bbr() {
  info "开启 BBR..."
  modprobe tcp_bbr 2>/dev/null || true
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    warn "内核不支持 BBR (容器型 VPS 或内核过旧)，已跳过"
    return 0
  fi
  echo tcp_bbr > /etc/modules-load.d/bbr.conf
  cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null 2>&1 || true
  local cc qd
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  if [[ "$cc" == bbr ]]; then info "BBR 已启用 (拥塞控制: $cc，队列: $qd)"
  else warn "BBR 设置未生效 (当前: ${cc:-未知})，容器型 VPS 通常不允许修改内核参数"; fi
  return 0
}

step_firewall() {
  need_ssh_port
  info "配置防火墙 (ufw)..."
  need_pkgs ufw
  ufw default deny incoming >/dev/null 2>&1 || true
  ufw default allow outgoing >/dev/null 2>&1 || true
  local p
  for p in $CUR_SSH_PORTS; do ufw allow "$p/tcp" >/dev/null 2>&1 || true; done   # 过渡期保留当前 SSH 端口
  ufw allow "$SSH_PORT/tcp" >/dev/null 2>&1 || true
  [[ -x "$XRAY" ]] && ufw allow 443/tcp >/dev/null 2>&1 || true                 # 已装节点则保留 443
  if ufw --force enable >/dev/null 2>&1; then
    FW_OK=1; info "ufw 已启用"
  else
    warn "ufw 无法启用(常见于 OpenVZ/LXC 容器或内核缺少模块)，已跳过系统防火墙，请在服务商面板里只放行所需端口。"
  fi
  return 0
}

step_ssh() { # 放在最后做：改端口 + 密钥登录
  need_ssh_port; need_pubkey
  info "配置 SSH (端口 $SSH_PORT)..."
  fw allow "$SSH_PORT/tcp"          # 先放行新端口，避免切换后被防火墙挡住
  mkdir -p /etc/ssh/sshd_config.d
  [[ -f /etc/ssh/sshd_config.bak.setup ]] || cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.setup
  grep -qE '^\s*Include\s+/etc/ssh/sshd_config.d/' /etc/ssh/sshd_config \
    || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  # Port 是累加型指令，先注释掉其它地方的 Port，避免同时监听旧端口
  sed -i -E 's/^\s*Port\s+/#Port /' /etc/ssh/sshd_config
  local f
  for f in /etc/ssh/sshd_config.d/*.conf; do
    [[ -e "$f" ]] || continue
    [[ "$f" == */00-hardening.conf ]] && continue
    sed -i -E 's/^\s*Port\s+/#Port /' "$f"
  done
  {
    echo "Port $SSH_PORT"
    if [[ $KEY_OK -eq 1 ]]; then
      echo "PasswordAuthentication no"
      echo "KbdInteractiveAuthentication no"
      echo "PubkeyAuthentication yes"
      echo "PermitRootLogin prohibit-password"
    fi
  } > /etc/ssh/sshd_config.d/00-hardening.conf

  sshd -t || die "sshd 配置语法错误 (未重启，当前连接不受影响)"
  local EFF; EFF="$(sshd -T 2>/dev/null)"
  [[ "$(grep -c '^port ' <<<"$EFF")" -eq 1 ]] && grep -qx "port $SSH_PORT" <<<"$EFF" \
    || die "sshd 生效端口不是 $SSH_PORT (未重启，当前连接不受影响)，请检查 /etc/ssh 下的配置"
  if [[ $KEY_OK -eq 1 ]]; then
    grep -qx 'passwordauthentication no' <<<"$EFF" \
      || die "密码登录仍被其它配置开启 (未重启)，请执行: grep -rn PasswordAuthentication /etc/ssh/"
  fi

  local svc
  if systemctl cat ssh.service >/dev/null 2>&1; then svc=ssh; else svc=sshd; fi
  systemctl disable --now ssh.socket 2>/dev/null || true   # 避免 socket 激活占用旧端口
  systemctl enable "$svc" >/dev/null 2>&1 || true
  systemctl restart "$svc"
  sleep 1
  ss -tln | awk '{print $4}' | grep -qE "[:.]${SSH_PORT}$" || die "sshd 没有监听 $SSH_PORT，请用面板 VNC 控制台检查"
  info "SSH 已切换到端口 $SSH_PORT"

  local p                                                   # 关闭过渡期保留的旧 SSH 端口规则
  for p in $CUR_SSH_PORTS; do
    [[ "$p" == "$SSH_PORT" ]] && continue
    fw delete allow "$p/tcp"
  done
  SSH_CHANGED=1
  return 0
}

step_security() { # fail2ban + 自动安全更新
  need_ssh_port
  info "启用 fail2ban 和自动安全更新..."
  need_pkgs fail2ban unattended-upgrades
  cat > /etc/fail2ban/jail.d/sshd-custom.conf <<EOF
[sshd]
enabled = true
port = $SSH_PORT
backend = systemd
maxretry = 5
bantime = 1h
EOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban || warn "fail2ban 启动失败，可稍后手动检查"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  return 0
}

# ================================================================= 节点配置
free_port80() { # 移除 nginx 默认站点；若 nginx 占着 80 就先停掉
  [[ -d /etc/nginx/sites-enabled ]] && rm -f /etc/nginx/sites-enabled/default
  if ss -tlnp 2>/dev/null | grep -E '[:.]80\s' | grep -q nginx; then systemctl stop nginx 2>/dev/null || true; fi
  return 0
}
cert_ok() { [[ -s "$CERT" ]] && openssl x509 -checkend 2592000 -noout -in "$CERT" >/dev/null 2>&1; }

step_cert() {
  need_domain
  info "申请/检查证书..."
  need_pkgs certbot ca-certificates curl dnsutils openssl
  if cert_ok; then
    info "已有有效证书(剩余 30 天以上)，跳过申请"
  else
    local PUB_IP DNS_IP
    PUB_IP="$(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    DNS_IP="$(dig +short A "$DOMAIN" 2>/dev/null | grep -E '^[0-9.]+$' | tail -n1 || true)"
    info "本机公网 IP: ${PUB_IP:-未知}    域名解析: ${DNS_IP:-无}"
    if [[ -z "$DNS_IP" || -z "$PUB_IP" || "$DNS_IP" != "$PUB_IP" ]]; then
      warn "域名解析与本机公网 IP 不一致(或无法获取)，证书申请很可能失败。"
      yn "仍要继续?" || die "已取消，请先修正域名解析"
    fi
    free_port80
    if ss -tln | awk '{print $4}' | grep -qE '[:.]80$'; then
      die "80 端口被占用，无法申请证书。查看: ss -tlnp | grep ':80 '"
    fi
    local MAILARG="--register-unsafely-without-email"
    [[ -n "${EMAIL:-}" ]] && MAILARG="-m $EMAIL --no-eff-email"
    fw allow 80/tcp; OPENED80=1
    # shellcheck disable=SC2086
    if ! certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos $MAILARG --keep-until-expiring; then
      fw delete allow 80/tcp; OPENED80=0
      die "证书申请失败。请检查: 域名解析是否正确、面板防火墙是否放行 80、Cloudflare 是否为灰云。"
    fi
    fw delete allow 80/tcp; OPENED80=0
  fi
  [[ -s "$CERT" ]] || die "未找到证书文件"

  # 续期钩子: 续期时临时开放 80，结束后关闭；续期后重载 nginx
  mkdir -p /etc/letsencrypt/renewal-hooks/{pre,post,deploy}
  printf '#!/bin/sh\nif command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then ufw allow 80/tcp; fi\nexit 0\n' > /etc/letsencrypt/renewal-hooks/pre/open80.sh
  printf '#!/bin/sh\nif command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then ufw delete allow 80/tcp; fi\nexit 0\n' > /etc/letsencrypt/renewal-hooks/post/close80.sh
  printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
  chmod +x /etc/letsencrypt/renewal-hooks/{pre/open80.sh,post/close80.sh,deploy/reload-nginx.sh}
  if certbot renew --dry-run >/dev/null 2>&1; then info "证书自动续期模拟通过"; else warn "证书续期模拟失败，请稍后手动执行 certbot renew --dry-run 查看"; fi
  fw delete allow 80/tcp
  return 0
}

step_nginx() {
  need_domain
  [[ -s "$CERT" ]] || die "未找到证书，请先执行「证书」步骤"
  info "配置 Nginx 伪装站 (仅监听 127.0.0.1:8443)..."
  need_pkgs nginx curl
  free_port80

  local NGX_VER H2_LISTEN H2_DIRECTIVE
  NGX_VER="$(nginx -v 2>&1 | sed -E 's/.*\/([0-9.]+).*/\1/')"
  if [[ "$(printf '%s\n' 1.25.1 "$NGX_VER" | sort -V | head -n1)" == "1.25.1" ]]; then
    H2_LISTEN=""; H2_DIRECTIVE="http2 on;"
  else
    H2_LISTEN=" http2"; H2_DIRECTIVE=""
  fi

  cat > /etc/nginx/conf.d/site.conf <<EOF
# 空 SNI / 未知 SNI: 直接拒绝 TLS 握手
server {
    listen 127.0.0.1:8443 ssl default_server;
    ssl_reject_handshake on;
}

server {
    listen 127.0.0.1:8443 ssl${H2_LISTEN};
    ${H2_DIRECTIVE}
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    # Host 头不匹配: 断开
    if (\$host != "${DOMAIN}") { return 444; }

    root /var/www/site;
    index index.html;
    error_page 404 /404.html;
}
EOF

  # 隐藏 nginx 版本号
  if grep -qE '^\s*server_tokens\s' /etc/nginx/nginx.conf; then
    sed -i -E 's/^\s*server_tokens\s+\w+;/\tserver_tokens off;/' /etc/nginx/nginx.conf
  elif grep -qE '^\s*#\s*server_tokens\s' /etc/nginx/nginx.conf; then
    sed -i -E 's/^\s*#\s*server_tokens\s+\w+;/\tserver_tokens off;/' /etc/nginx/nginx.conf
  else
    sed -i '/^http {/a\\tserver_tokens off;' /etc/nginx/nginx.conf
  fi

  # 伪装网页 (内置: 公司内部文件交换系统登录页)
  mkdir -p /var/www/site
  if [[ -s /var/www/site/index.html && "${FORCE_SITE:-0}" != 1 ]]; then
    info "伪装网页已存在，保留现有内容 (在菜单里选「重置伪装网页」可恢复默认)"
  elif [[ -n "${SITE_URL:-}" ]]; then
    curl -fsSL "$SITE_URL" -o /var/www/site/index.html || die "下载 SITE_URL 失败: $SITE_URL"
    info "已使用自定义网页: $SITE_URL"
  else
base64 -d <<'__B64__' | gunzip > /var/www/site/index.html
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
Rvp/1v0fcyBLdGonAAA=
__B64__
    info "已写入内置伪装网页"
  fi
  cat > /var/www/site/robots.txt <<'EOF'
User-agent: *
Disallow: /
EOF
  cat > /var/www/site/404.html <<'EOF'
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Page not found - Document Exchange</title>
<meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex">
<style>body{font:15px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,Arial,sans-serif;margin:0;display:grid;place-items:center;min-height:100vh;background:#f2f5f8;color:#16222e}
main{max-width:420px;padding:32px;text-align:center}h1{margin:0 0 8px;font-size:22px}p{color:#5b6b7b;margin:0 0 18px}a{color:#0e7c86}
@media (prefers-color-scheme:dark){body{background:#10161c;color:#e7edf3}p{color:#9aa9b8}a{color:#2aa3ad}}</style></head>
<body><main><h1>Page not found</h1><p>The document or page you requested does not exist, or you do not have permission to view it.</p><a href="/">Return to sign in</a></main></body></html>
EOF
  chmod 755 /var/www /var/www/site
  chmod 644 /var/www/site/*

  nginx -t
  systemctl enable nginx >/dev/null 2>&1
  systemctl restart nginx
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:8443:127.0.0.1" "https://$DOMAIN:8443" || true)"
  if [[ "$code" == "200" ]]; then info "伪装站本地自检通过 (HTTP 200)"; else warn "伪装站自检返回 $code，请稍后检查 nginx"; fi
  return 0
}

step_xray() {
  need_domain; need_cn
  info "安装并配置 Xray (VLESS + Reality)..."
  need_pkgs curl ca-certificates jq openssl qrencode
  ss -tln | awk '{print $4}' | grep -qE '^127\.0\.0\.1:8443$' || die "Nginx 伪装站没有在 127.0.0.1:8443 运行，请先执行「Nginx 伪装站」步骤"
  if ss -tlnp 2>/dev/null | grep -E '[:.]443\s' | grep -vq xray; then
    die "443 端口已被其它程序占用，请先停止它: ss -tlnp | grep 443"
  fi
  fw allow 443/tcp

  if [[ -x "$XRAY" ]]; then
    info "Xray 已安装，跳过安装"
  else
    info "安装 Xray..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  fi
  [[ -x "$XRAY" ]] || die "Xray 安装失败"
  mkdir -p "$(dirname "$CONF")"

  parse_priv() { awk -F': *' 'tolower($1) ~ /^private ?key/ {print $2; exit}' | tr -d '[:space:]'; }
  parse_pub()  { awk -F': *' 'tolower($1) ~ /^(public ?key|password)/ {print $2; exit}' | tr -d '[:space:]'; }
  pubkey_of()  { "$XRAY" x25519 -i "$1" 2>/dev/null | parse_pub; }

  local UUID="" PRIV="" SID="" PUB="" REUSED=0 KEYS
  # 重跑时沿用已有的 UUID/密钥，客户端无需改动 (REGEN=1 可强制重新生成)
  if [[ "${REGEN:-0}" != 1 && -s "$CONF" ]] && jq -e --arg d "$DOMAIN" '.inbounds[0].streamSettings.realitySettings.serverNames[0] == $d' "$CONF" >/dev/null 2>&1; then
    UUID="$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$CONF")"
    PRIV="$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // empty' "$CONF")"
    SID="$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0] // empty' "$CONF")"
    if [[ -n "$UUID" && -n "$PRIV" && -n "$SID" ]]; then
      PUB="$(pubkey_of "$PRIV")"
      [[ -n "$PUB" ]] && REUSED=1
    fi
  fi
  if [[ $REUSED -eq 1 ]]; then
    info "沿用已有的 UUID 和 Reality 密钥"
  else
    UUID="$($XRAY uuid)"
    KEYS="$($XRAY x25519)"
    PRIV="$(parse_priv <<<"$KEYS")"
    PUB="$(parse_pub <<<"$KEYS")"
    [[ -z "$PUB" && -n "$PRIV" ]] && PUB="$(pubkey_of "$PRIV")"
    if [[ -z "$PRIV" || -z "$PUB" ]]; then
      echo "xray x25519 输出格式(已隐藏具体内容):"; sed -E 's/: .*/: ****/' <<<"$KEYS"
      die "无法解析 xray x25519 的输出，请把上面这几行格式发给作者修复"
    fi
    SID="$(openssl rand -hex 8)"
  fi
  XRAY_REUSED=$REUSED

  local NEWCONF; NEWCONF="$(mktemp --suffix=.json)"
  jq -n --arg uuid "$UUID" --arg priv "$PRIV" --arg sid "$SID" --arg dom "$DOMAIN" --argjson cn "$BLOCK_CN" '
{
  log: { loglevel: "warning" },
  inbounds: [{
    listen: "0.0.0.0", port: 443, protocol: "vless",
    settings: { clients: [{ id: $uuid, flow: "xtls-rprx-vision" }], decryption: "none" },
    streamSettings: {
      network: "tcp", security: "reality",
      realitySettings: {
        show: false, dest: "127.0.0.1:8443", xver: 0,
        serverNames: [$dom], privateKey: $priv, shortIds: [$sid]
      }
    },
    sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
  }],
  outbounds: [
    { protocol: "freedom",   tag: "direct" },
    { protocol: "blackhole", tag: "block"  }
  ],
  routing: {
    domainStrategy: "IPIfNonMatch",
    rules: (
      [
        { type: "field", ip: ["geoip:private"], outboundTag: "block" },
        { type: "field", domain: ["geosite:youtube", "geosite:google", "geosite:openai"], outboundTag: "direct" },
        { type: "field", protocol: ["bittorrent"], outboundTag: "block" }
      ] + (
        if $cn == 1 then [
          { type: "field", domain: ["geosite:cn"], outboundTag: "block" },
          { type: "field", ip: ["geoip:cn"], outboundTag: "block" }
        ] else [] end
      )
    )
  }
}' > "$NEWCONF"
  chmod 644 "$NEWCONF"

  "$XRAY" run -test -config "$NEWCONF" >/dev/null || { "$XRAY" run -test -config "$NEWCONF"; die "Xray 配置校验失败"; }
  local CHANGED=1
  if [[ -f "$CONF" ]] && cmp -s "$NEWCONF" "$CONF"; then
    CHANGED=0
  else
    [[ -f "$CONF" ]] && cp "$CONF" "$CONF.bak.$(date +%s)"
    cp "$NEWCONF" "$CONF"
  fi
  chmod 644 "$CONF"; rm -f "$NEWCONF"
  systemctl enable xray >/dev/null 2>&1
  if [[ $CHANGED -eq 1 ]] || ! systemctl is-active --quiet xray; then systemctl restart xray; fi
  sleep 2
  systemctl is-active --quiet xray || die "Xray 未能启动，查看: journalctl -u xray -n 50 --no-pager"
  ss -tln | awk '{print $4}' | grep -qE '[:.]443$' || die "Xray 没有监听 443"
  info "Xray 已启动并监听 443"

  local LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp#${DOMAIN}"
  cat > "$OUT" <<EOF
===== VLESS + Reality 客户端配置 =====
协议        : VLESS
地址        : ${DOMAIN}
端口        : 443
UUID        : ${UUID}
flow        : xtls-rprx-vision
传输        : tcp
安全        : reality
SNI         : ${DOMAIN}
Fingerprint : chrome
PublicKey   : ${PUB}
ShortId     : ${SID}

分享链接:
${LINK}
EOF
  chmod 600 "$OUT"
  return 0
}

show_info() {
  if [[ ! -s "$OUT" ]]; then warn "还没有客户端信息，请先执行「节点配置」或「安装配置 Xray」。"; return 0; fi
  echo
  echo "${CYN}==================== 客户端配置 ====================${RST}"
  [[ "${XRAY_REUSED:-0}" == 1 ]] && echo "(本次沿用了已有的 UUID/密钥，客户端无需更改)"
  cat "$OUT"
  local link; link="$(grep -m1 '^vless://' "$OUT" || true)"
  if [[ -n "$link" ]] && command -v qrencode >/dev/null 2>&1; then
    echo; echo "二维码 (手机客户端可扫码导入):"
    qrencode -t ansiutf8 "$link" || true
  fi
  echo "(以上信息保存在 $OUT，仅 root 可读)"
  return 0
}

# ================================================================= 组合流程
panel_notice() { # panel_notice "需要放行的端口说明"
  echo
  echo "${CYN}开始前请确认(在服务商面板的防火墙里)：${RST}"
  echo "  - 已放行: $1"
  echo "  - 当前 SSH 窗口保持打开，涉及 SSH 的步骤完成后，用新端口另开一个窗口测试"
  echo
  [[ "${ASSUME_YES:-0}" == 1 ]] && return 0
  local a=""; prompt "确认无误后按回车开始 (Ctrl+C 取消) " a || true
  return 0
}

finish_notes() {
  echo
  echo "${YEL}提示:${RST}"
  if [[ "${SSH_CHANGED:-0}" == 1 ]]; then
    echo "  - ${RED}不要关闭当前窗口${RST}，先用新端口 ${SSH_PORT} 另开一个 SSH 窗口测试能否登录。"
    if [[ $KEY_OK -eq 1 ]]; then echo "  - 现已禁用密码登录，只能用公钥登录。"
    else echo "  - 未提供公钥，密码登录仍开启；添加公钥后可重新执行 SSH 加固。"; fi
  fi
  if [[ -f /var/run/reboot-required ]]; then echo "  - 内核已更新，确认新端口能登录后执行 reboot。"; fi
  echo "  - 运行日志: $LOG"
  return 0
}

run_system() {
  need_ssh_port; need_pubkey
  panel_notice "TCP ${SSH_PORT} (新 SSH 端口)"
  step_update auto; step_timezone; step_bbr; step_firewall
  step_ssh; step_security
  finish_notes
  return 0
}
run_node() {
  need_domain; need_cn
  panel_notice "TCP 80 (申请/续期证书)、443 (节点)；域名 ${DOMAIN} 已解析到本机 IP"
  fw_detect
  [[ $FW_OK -eq 1 ]] || warn "未检测到启用的 ufw，请确保面板防火墙只放行所需端口。"
  step_cert; step_nginx; step_xray
  show_info; finish_notes
  return 0
}
run_full() {
  need_domain; need_ssh_port; need_pubkey; need_cn
  panel_notice "TCP 80 (证书)、443 (节点)、${SSH_PORT} (新 SSH 端口)；域名 ${DOMAIN} 已解析到本机 IP"
  step_update auto; step_timezone; step_bbr; step_firewall
  step_cert; step_nginx; step_xray
  step_ssh; step_security
  show_info; finish_notes
  return 0
}

# ================================================================= 菜单
dispatch() {
  case "$1" in
    all|full)        run_full ;;
    system)          run_system ;;
    node)            run_node ;;
    update)          step_update ;;
    tz|timezone)     step_timezone ;;
    bbr)             step_bbr ;;
    firewall)        step_firewall ;;
    ssh)             step_ssh; finish_notes ;;
    security)        step_security ;;
    cert)            step_cert ;;
    nginx)           step_nginx ;;
    xray)            step_xray; show_info ;;
    site)            FORCE_SITE=1 step_nginx ;;
    info)            show_info ;;
    *)               die "未知选项: $1 (可用: all system node update tz bbr firewall ssh security cert nginx xray site info)" ;;
  esac
}

submenu() {
  local c=""
  while true; do
    echo
    echo "${CYN}------------- 单项选择 -------------${RST}"
    echo " 系统:"
    echo "   1) 系统更新与基础软件"
    echo "   2) 设置时区 (${TIMEZONE:-Asia/Shanghai})"
    echo "   3) 开启 BBR"
    echo "   4) 配置防火墙 (ufw)"
    echo "   5) SSH 加固 (改端口 + 密钥登录)"
    echo "   6) fail2ban + 自动安全更新"
    echo " 节点:"
    echo "   7) 申请/检查证书"
    echo "   8) 安装配置 Nginx 伪装站"
    echo "   9) 安装配置 Xray (Reality)"
    echo "  10) 重置伪装网页为默认"
    echo "   0) 返回上级"
    prompt "请选择: " c || return 0
    case "$c" in
      1) dispatch update ;;   2) dispatch tz ;;       3) dispatch bbr ;;
      4) dispatch firewall ;; 5) dispatch ssh ;;      6) dispatch security ;;
      7) dispatch cert ;;     8) dispatch nginx ;;    9) dispatch xray ;;
      10) dispatch site ;;    0|"") return 0 ;;       *) warn "无效选择" ;;
    esac
  done
}

menu() {
  local c=""
  while true; do
    echo
    echo "${CYN}==================== VPS 一键配置 ====================${RST}"
    echo "   1) 一键全部      系统配置 + 节点配置"
    echo "   2) 系统配置      更新 / 时区 / BBR / 防火墙 / SSH 加固 / fail2ban"
    echo "   3) 节点配置      证书 + Nginx 伪装站 + Xray Reality"
    echo "   4) 单项选择      只做其中某一步 (如只开 BBR)"
    echo "   5) 查看客户端信息和二维码"
    echo "   0) 退出"
    prompt "请选择 [0-5]: " c || exit 0
    case "$c" in
      1) dispatch all ;;  2) dispatch system ;;  3) dispatch node ;;
      4) submenu ;;       5) dispatch info ;;    0|q|Q) exit 0 ;;
      "") ;;              *) warn "无效选择" ;;
    esac
  done
}

# ================================================================= 入口
[[ $EUID -eq 0 ]] || die "请使用 root 运行此脚本"
[[ -r /etc/os-release ]] || die "无法识别系统"
. /etc/os-release
case "${ID:-}" in debian|ubuntu) ;; *) die "仅支持 Debian / Ubuntu，当前系统: ${ID:-unknown}" ;; esac
command -v apt-get >/dev/null || die "未找到 apt-get"
[[ -d /run/systemd/system ]] || die "需要 systemd 环境"
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
load_state

# 之后的输出同时写入日志；即使 SSH 窗口断线，脚本也会继续跑完 (提示和输入直接走 /dev/tty)
trap '' HUP
exec > >(tee --output-error=warn -a "$LOG") 2>&1
echo "==== $(date '+%F %T') 开始运行 (${PRETTY_NAME:-$ID}) ===="

# 记录当前 SSH 监听端口，供防火墙/SSH 步骤保留过渡连接
CUR_SSH_PORTS="$(ss -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}' | sort -u | tr '\n' ' ' || true)"
[[ -n "${SSH_CONNECTION:-}" ]] && CUR_SSH_PORTS="$CUR_SSH_PORTS ${SSH_CONNECTION##* }"
CUR_SSH_PORTS="$(echo "$CUR_SSH_PORTS" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u | tr '\n' ' ' || true)"
fw_detect

if [[ $# -ge 1 ]]; then
  dispatch "$1"
else
  menu
fi
