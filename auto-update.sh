#!/usr/bin/env bash
#
# auto-update.sh - 通用 Linux 全自动更新脚本
#
# 支持:
#   Debian / Ubuntu                          (apt)
#   Oracle Linux / RHEL / Rocky / Alma /
#   CentOS / Fedora                          (dnf / yum)
#   openSUSE / SLES                          (zypper)
#
# 用法:
#   sudo ./auto-update.sh [选项]
#   curl -fsSL <raw 链接> | sudo bash -s -- [选项]
#
# 选项:
#   --security-only     只安装安全更新
#   --no-reboot         更新后即使需要重启也不重启
#   --force-reboot      更新后无条件重启
#   --reboot-delay N    N 分钟后重启 (默认 1, 0 为立即)
#   --autoremove        更新后清理不再需要的依赖
#   --check             只检查可用更新, 不安装, 不重启
#   -h, --help          显示帮助
#
# 环境变量 (可选):
#   NTFY_TOPIC          设置后, 更新结果会推送到 ntfy 主题 (手机 ntfy App 订阅)
#   NTFY_SERVER         ntfy 服务器地址, 默认 https://ntfy.sh
#   LOG_FILE            日志路径, 默认 /var/log/auto-update.log
#
set -Eeuo pipefail

export LC_ALL=C

LOG_FILE="${LOG_FILE:-/var/log/auto-update.log}"
LOCK_FILE="${LOCK_FILE:-/var/lock/auto-update.lock}"
NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-}"

SECURITY_ONLY=0
DO_REBOOT=1
FORCE_REBOOT=0
REBOOT_DELAY=1
AUTOREMOVE=0
CHECK_ONLY=0
PM=""

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "错误: $*"; exit 1; }

usage() {
  sed -n '2,/^set -Eeuo/p' "$0" 2>/dev/null | sed '$d' | sed 's/^# \{0,1\}//' \
    || echo "见脚本头部注释"
}

notify() {
  [ -n "$NTFY_TOPIC" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsS -m 15 \
    -H "Title: auto-update: $(hostname)" \
    -d "$1" "${NTFY_SERVER%/}/${NTFY_TOPIC}" >/dev/null 2>&1 || true
}

on_error() {
  local line="$1"
  log "更新失败 (脚本第 ${line} 行出错), 详见 ${LOG_FILE}"
  notify "更新失败 (第 ${line} 行出错), 请登录检查: ${LOG_FILE}"
  exit 1
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --security-only) SECURITY_ONLY=1 ;;
      --no-reboot)     DO_REBOOT=0 ;;
      --force-reboot)  FORCE_REBOOT=1 ;;
      --reboot-delay)
        shift
        [[ "${1:-}" =~ ^[0-9]+$ ]] || die "--reboot-delay 需要一个整数 (分钟)"
        REBOOT_DELAY="$1" ;;
      --autoremove)    AUTOREMOVE=1 ;;
      --check)         CHECK_ONLY=1 ;;
      -h|--help)       usage; exit 0 ;;
      *) die "未知参数: $1 (使用 --help 查看用法)" ;;
    esac
    shift
  done
}

detect_pm() {
  if   command -v apt-get >/dev/null 2>&1; then PM="apt"
  elif command -v dnf     >/dev/null 2>&1; then PM="dnf"
  elif command -v yum     >/dev/null 2>&1; then PM="yum"
  elif command -v zypper  >/dev/null 2>&1; then PM="zypper"
  else die "未找到支持的包管理器 (apt / dnf / yum / zypper)"
  fi
}

# ---------------------------------------------------------------- apt
update_apt() {
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  local opts=(-y
    -o Dpkg::Lock::Timeout=300
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold)

  log "刷新软件源索引"
  apt-get update -o Dpkg::Lock::Timeout=300 </dev/null

  if [ "$CHECK_ONLY" = 1 ]; then
    log "可升级的软件包:"
    apt-get -s full-upgrade </dev/null | grep '^Inst' || log "没有可用更新"
    return
  fi

  if [ "$SECURITY_ONLY" = 1 ]; then
    if ! command -v unattended-upgrade >/dev/null 2>&1; then
      log "安装 unattended-upgrades (用于只装安全更新)"
      apt-get install "${opts[@]}" unattended-upgrades </dev/null
    fi
    log "安装安全更新"
    unattended-upgrade -v </dev/null
  else
    log "安装所有更新"
    apt-get "${opts[@]}" full-upgrade </dev/null
  fi

  if [ "$AUTOREMOVE" = 1 ]; then
    log "清理无用依赖"
    apt-get "${opts[@]}" autoremove --purge </dev/null
  fi
}

# ---------------------------------------------------------- dnf / yum
update_rpm() {
  local sec=() refresh=()
  [ "$SECURITY_ONLY" = 1 ] && sec=(--security)
  [ "$PM" = "dnf" ] && refresh=(--refresh)

  if [ "$CHECK_ONLY" = 1 ]; then
    log "可用更新 (退出码 100 表示有更新):"
    "$PM" -q "${refresh[@]}" check-update "${sec[@]}" </dev/null || true
    return
  fi

  # 确保有 needs-restarting 命令, 用于判断是否需要重启
  if ! "$PM" needs-restarting --help >/dev/null 2>&1 </dev/null; then
    log "安装 needs-restarting 所需插件"
    "$PM" -y install dnf-utils </dev/null 2>/dev/null \
      || "$PM" -y install yum-utils </dev/null 2>/dev/null \
      || "$PM" -y install dnf-plugins-core </dev/null 2>/dev/null \
      || log "警告: 无法安装 dnf-utils, 将无法自动判断是否需要重启"
  fi

  log "安装更新 (${PM})"
  "$PM" -y "${refresh[@]}" upgrade "${sec[@]}" </dev/null

  if [ "$AUTOREMOVE" = 1 ]; then
    log "清理无用依赖"
    "$PM" -y autoremove </dev/null
  fi
}

# ------------------------------------------------------------- zypper
update_zypper() {
  local z=(zypper --non-interactive)
  log "刷新软件源"
  "${z[@]}" refresh </dev/null

  if [ "$CHECK_ONLY" = 1 ]; then
    log "可用更新:"
    "${z[@]}" list-updates </dev/null || true
    return
  fi

  if [ "$SECURITY_ONLY" = 1 ]; then
    log "安装安全补丁"
    "${z[@]}" patch --category security </dev/null
  else
    log "安装所有更新"
    "${z[@]}" update </dev/null
  fi
}

# --------------------------------------------------------- 是否需要重启
reboot_required() {
  [ "$FORCE_REBOOT" = 1 ] && return 0
  local out rc
  case "$PM" in
    apt)
      [ -f /var/run/reboot-required ] ;;
    dnf|yum)
      out="$("$PM" needs-restarting -r 2>&1 </dev/null || true)"
      grep -qi 'reboot is required' <<<"$out" ;;
    zypper)
      rc=0
      zypper --non-interactive needs-rebooting >/dev/null 2>&1 </dev/null || rc=$?
      [ "$rc" -eq 102 ] ;;
    *) return 1 ;;
  esac
}

do_reboot() {
  if [ "$REBOOT_DELAY" -eq 0 ]; then
    log "立即重启"
    notify "更新完成, 正在重启"
    sync
    shutdown -r now "auto-update: 更新完成, 重启" 2>/dev/null || systemctl reboot
  else
    log "将在 ${REBOOT_DELAY} 分钟后重启 (期间可执行 shutdown -c 取消)"
    notify "更新完成, 将在 ${REBOOT_DELAY} 分钟后重启"
    shutdown -r "+${REBOOT_DELAY}" "auto-update: 更新完成, 即将重启" 2>/dev/null \
      || systemd-run --on-active="${REBOOT_DELAY}m" systemctl reboot
  fi
}

# --------------------------------------------------------------- main
# 整个逻辑包在函数里, 避免 curl | bash 时 stdin 被脚本内的命令吞掉
main() {
  parse_args "$@"

  [ "$(id -u)" -eq 0 ] || die "请使用 root 或 sudo 运行"

  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
  exec </dev/null
  trap 'on_error $LINENO' ERR

  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "已有另一个 auto-update 正在运行"
  fi

  detect_pm
  local os_name="未知系统"
  [ -r /etc/os-release ] && os_name="$(. /etc/os-release && echo "${PRETTY_NAME:-$NAME}")"
  log "======== 开始 | ${os_name} | 包管理器: ${PM} | 内核: $(uname -r) ========"

  case "$PM" in
    apt)       update_apt ;;
    dnf|yum)   update_rpm ;;
    zypper)    update_zypper ;;
  esac

  if [ "$CHECK_ONLY" = 1 ]; then
    log "检查完成 (--check 模式, 未做任何修改)"
    return 0
  fi

  if reboot_required; then
    if [ "$DO_REBOOT" = 1 ]; then
      log "更新完成, 需要重启以使更新生效"
      do_reboot
    else
      log "更新完成, 需要重启, 但指定了 --no-reboot, 请手动重启"
      notify "更新完成, 需要重启 (已指定 --no-reboot), 请手动重启"
    fi
  else
    log "更新完成, 无需重启"
    notify "更新完成, 无需重启"
  fi
}

main "$@"
