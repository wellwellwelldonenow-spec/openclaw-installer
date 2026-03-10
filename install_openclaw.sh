#!/usr/bin/env bash

set -Eeuo pipefail

OPENCLAW_PORT_INPUT="${OPENCLAW_PORT:-}"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
ACTION="install"
API_KEY_ARG=""
PROVIDER_ID="megabyai"
BASE_URL="https://newapi.megabyai.cc/v1"
MODEL_ID_DEFAULT="gpt-5.3-codex"
MODEL_ID="${OPENCLAW_MODEL_ID:-$MODEL_ID_DEFAULT}"
MODEL_NAME="${MODEL_ID} (newapi)"
ENABLE_BROWSER_TOOL="${OPENCLAW_ENABLE_BROWSER_TOOL:-1}"
REQUESTED_PROVIDER_API="${OPENCLAW_PROVIDER_API:-auto}"
RESOLVED_PROVIDER_API="openai-completions"
OS=""
ARCH=""
TEMP_SWAP_FILE="/var/tmp/openclaw-installer.swap"
TEMP_SWAP_ACTIVE=0
AUTO_PROXY_URL=""

log() {
  printf '\033[1;34m[INFO]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -f /tmp/nodesource_setup_22.sh /tmp/openclaw_models_check.json /tmp/openclaw_xcode_install.log

  if [ "$TEMP_SWAP_ACTIVE" = "1" ] && [ -f "$TEMP_SWAP_FILE" ]; then
    swapoff "$TEMP_SWAP_FILE" >/dev/null 2>&1 || true
    rm -f "$TEMP_SWAP_FILE" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"
}

show_usage() {
  cat <<'EOF'
用法:
  bash install_openclaw.sh [NEWAPI_API_KEY]
  bash install_openclaw.sh --uninstall

选项:
  --uninstall   删除 OpenClaw、网关服务、状态目录，以及脚本安装的 Node.js 环境
  -h, --help    显示帮助
EOF
}

parse_cli_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --uninstall|uninstall)
        ACTION="uninstall"
        ;;
      -h|--help)
        show_usage
        exit 0
        ;;
      *)
        if [ "$ACTION" = "uninstall" ]; then
          fail "卸载模式不接受额外参数：$1"
        fi
        if [ -n "$API_KEY_ARG" ]; then
          fail "仅支持一个 API Key 位置参数"
        fi
        API_KEY_ARG="$1"
        ;;
    esac
    shift
  done
}

proxy_already_configured() {
  [ -n "${HTTPS_PROXY:-}" ] || [ -n "${https_proxy:-}" ] || \
    [ -n "${HTTP_PROXY:-}" ] || [ -n "${http_proxy:-}" ] || \
    [ -n "${ALL_PROXY:-}" ] || [ -n "${all_proxy:-}" ]
}

export_proxy_url() {
  local proxy_url="$1"
  AUTO_PROXY_URL="$proxy_url"
  export HTTP_PROXY="$proxy_url"
  export HTTPS_PROXY="$proxy_url"
  export ALL_PROXY="$proxy_url"
  export http_proxy="$proxy_url"
  export https_proxy="$proxy_url"
  export all_proxy="$proxy_url"
  log "已自动启用本地代理：$proxy_url"
}

probe_proxy_url() {
  local proxy_url="$1"
  local err_file="${2:-/dev/null}"
  curl -fsSIL --connect-timeout 1 --max-time 4 --proxy "$proxy_url" https://github.com >/dev/null 2>"$err_file"
}

proxy_host_port() {
  local proxy_url="$1"
  local hostport="${proxy_url#*://}"
  hostport="${hostport%%/*}"
  printf '%s %s\n' "${hostport%:*}" "${hostport##*:}"
}

proxy_tcp_reachable() {
  local host="$1"
  local port="$2"

  if command -v nc >/dev/null 2>&1; then
    nc -z -w 2 "$host" "$port" >/dev/null 2>&1
    return $?
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout 3 bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1
    return $?
  fi

  bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1
}

describe_proxy_failure() {
  local proxy_url="$1"
  local err_file="$2"
  local host port stderr_text

  read -r host port <<EOF
$(proxy_host_port "$proxy_url")
EOF

  if ! proxy_tcp_reachable "$host" "$port"; then
    printf '端口不可达，代理程序可能未启动或未监听此端口'
    return 0
  fi

  stderr_text="$(tr '\n' ' ' <"$err_file" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"

  case "$stderr_text" in
    *"Could not resolve host"*|*"Couldn't resolve host"*)
      printf '代理端口可连通，但 DNS 解析失败'
      ;;
    *"Received HTTP code 407"*|*"Proxy CONNECT aborted"*|*"authentication"*)
      printf '代理需要认证，或拒绝了到 GitHub 的连接'
      ;;
    *"SSL_ERROR_SYSCALL"*|*"SSL connect error"*|*"TLS"*|*"SSL"*)
      printf '代理端口可连通，但 TLS 握手到 GitHub 失败'
      ;;
    *"Connection reset by peer"*|*"Empty reply from server"*|*"unexpected EOF"*|*"early EOF"*)
      printf '代理端口可连通，但到 GitHub 的连接被中断'
      ;;
    *)
      if [ -n "$stderr_text" ]; then
        printf '代理端口可连通，但访问 GitHub 失败：%.160s' "$stderr_text"
      else
        printf '代理端口可连通，但访问 GitHub 失败'
      fi
      ;;
  esac
}

macos_proxy_candidates() {
  [ "$OS" = "macos" ] || return 0
  command -v scutil >/dev/null 2>&1 || return 0

  scutil --proxy 2>/dev/null | awk '
    /^HTTPEnable : 1$/ { http=1 }
    /^HTTPProxy : / { http_host=$3 }
    /^HTTPPort : / { http_port=$3 }
    /^HTTPSEnable : 1$/ { https=1 }
    /^HTTPSProxy : / { https_host=$3 }
    /^HTTPSPort : / { https_port=$3 }
    /^SOCKSEnable : 1$/ { socks=1 }
    /^SOCKSProxy : / { socks_host=$3 }
    /^SOCKSPort : / { socks_port=$3 }
    END {
      if (http && http_host && http_port) printf "http://%s:%s\n", http_host, http_port;
      if (https && https_host && https_port) printf "http://%s:%s\n", https_host, https_port;
      if (socks && socks_host && socks_port) printf "socks5h://%s:%s\n", socks_host, socks_port;
    }'
}

local_listening_ports() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { sub(/.*:/, "", $9); if ($9 ~ /^[0-9]+$/) print $9 }' | sort -n -u
    return 0
  fi

  if command -v ss >/dev/null 2>&1; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | awk '{ sub(/.*:/, "", $1); if ($1 ~ /^[0-9]+$/) print $1 }' | sort -n -u
    return 0
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | awk 'NR > 2 { sub(/.*:/, "", $4); if ($4 ~ /^[0-9]+$/) print $4 }' | sort -n -u
    return 0
  fi
}

local_proxy_candidates() {
  local port

  local_listening_ports | head -n 64 | while IFS= read -r port; do
    [ -n "$port" ] || continue
    printf 'http://127.0.0.1:%s\n' "$port"
    printf 'socks5h://127.0.0.1:%s\n' "$port"
  done
}

auto_detect_local_proxy() {
  local candidate
  local attempts=0
  local err_file
  local reason
  local -a diagnostics=()

  if proxy_already_configured; then
    log "检测到已设置代理环境变量，保留现有代理配置"
    return 0
  fi

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    attempts=$((attempts + 1))
    err_file="$(mktemp /tmp/openclaw-proxy-probe.XXXXXX)"
    if probe_proxy_url "$candidate" "$err_file"; then
      rm -f "$err_file"
      export_proxy_url "$candidate"
      return 0
    fi
    if [ "${#diagnostics[@]}" -lt 4 ]; then
      reason="$(describe_proxy_failure "$candidate" "$err_file")"
      diagnostics+=("$candidate -> $reason")
    fi
    rm -f "$err_file"
  done <<EOF
$(macos_proxy_candidates)
$(local_proxy_candidates)
EOF

  if [ "$attempts" -gt 0 ]; then
    warn "未检测到可用本地代理，已尝试 ${attempts} 个候选端口"
    for reason in "${diagnostics[@]}"; do
      warn "代理检测：$reason"
    done
    warn "如本机代理端口不在默认列表，请先手动设置 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY"
  fi
}

command_as_text() {
  printf '%s' "$1"
  shift || true
  for arg in "$@"; do
    printf ' %s' "$arg"
  done
  printf '\n'
}

memory_available_mb() {
  [ "$OS" = "linux" ] || return 1
  [ -r /proc/meminfo ] || return 1
  awk '/MemAvailable:/ { printf "%d\n", $2 / 1024; found=1; exit } END { if (!found) exit 1 }' /proc/meminfo
}

swap_total_mb() {
  [ "$OS" = "linux" ] || return 1
  [ -r /proc/meminfo ] || return 1
  awk '/SwapTotal:/ { printf "%d\n", $2 / 1024; found=1; exit } END { if (!found) exit 1 }' /proc/meminfo
}

ensure_linux_temp_swap() {
  local mem_mb swap_mb desired_mb

  [ "$OS" = "linux" ] || return 0
  [ "$TEMP_SWAP_ACTIVE" = "0" ] || return 0

  mem_mb="$(memory_available_mb 2>/dev/null || printf '0')"
  swap_mb="$(swap_total_mb 2>/dev/null || printf '0')"

  if [ "$mem_mb" -ge 1536 ] || [ "$swap_mb" -ge 512 ]; then
    return 0
  fi

  if ! command -v swapon >/dev/null 2>&1 || ! command -v mkswap >/dev/null 2>&1; then
    warn "检测到内存偏低（可用 ${mem_mb}MB，Swap ${swap_mb}MB），但系统缺少 swapon/mkswap，无法自动添加临时 swap"
    return 0
  fi

  desired_mb=2048
  warn "检测到内存偏低（可用 ${mem_mb}MB，Swap ${swap_mb}MB），尝试创建 ${desired_mb}MB 临时 swap 以避免安装被系统杀掉"

  if [ -f "$TEMP_SWAP_FILE" ]; then
    run_privileged rm -f "$TEMP_SWAP_FILE" || true
  fi

  if command -v fallocate >/dev/null 2>&1; then
    run_privileged fallocate -l "${desired_mb}M" "$TEMP_SWAP_FILE" || return 0
  else
    run_privileged dd if=/dev/zero of="$TEMP_SWAP_FILE" bs=1M count="$desired_mb" status=none || return 0
  fi

  run_privileged chmod 600 "$TEMP_SWAP_FILE" || return 0
  run_privileged mkswap "$TEMP_SWAP_FILE" >/dev/null || return 0
  if run_privileged swapon "$TEMP_SWAP_FILE"; then
    TEMP_SWAP_ACTIVE=1
    log "临时 swap 已启用：$TEMP_SWAP_FILE"
  else
    warn "临时 swap 启用失败，将继续尝试安装，但如果再次出现 Killed，基本可判定为内存/容器限额不足"
  fi
}

run_checked() {
  local status

  set +e
  "$@"
  status=$?
  set -e

  if [ "$status" -eq 137 ] || [ "$status" -eq 9 ]; then
    fail "命令被系统强制终止（SIGKILL/OOM），通常表示内存或容器限额不足：$(command_as_text "$@")"
  fi

  return "$status"
}

npm_install_openclaw_cmd() {
  local node_opts="${NODE_OPTIONS:-}"
  if [ -n "$node_opts" ]; then
    node_opts="$node_opts --max-old-space-size=512"
  else
    node_opts="--max-old-space-size=512"
  fi

  env \
    npm_config_audit=false \
    npm_config_fund=false \
    npm_config_update_notifier=false \
    npm_config_jobs=1 \
    NODE_OPTIONS="$node_opts" \
    npm install -g openclaw@latest --legacy-peer-deps
}

run_privileged() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    run_checked "$@"
  elif command -v sudo >/dev/null 2>&1; then
    run_checked sudo "$@"
  else
    fail "需要 root 权限执行：$*"
  fi
}

ensure_macos_sudo() {
  [ "$OS" = "macos" ] || return 0

  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    return 0
  fi

  command -v sudo >/dev/null 2>&1 || fail "当前系统缺少 sudo，无法自动安装所需依赖"

  log "需要管理员权限以安装 Homebrew / Node.js，请按提示输入 macOS 登录密码"
  sudo -v || fail "sudo 验证失败，请确认当前账号具有管理员权限"
}

detect_platform() {
  case "$(uname -s)" in
    Linux) OS="linux" ;;
    Darwin) OS="macos" ;;
    *) fail "暂不支持当前系统：$(uname -s)" ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) ARCH="x64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) ARCH="$(uname -m)" ;;
  esac

  log "检测到系统：$OS ($ARCH)"
}

node_major_version() {
  if ! command -v node >/dev/null 2>&1; then
    return 1
  fi
  node -p "process.versions.node.split('.')[0]"
}

macos_node_path_is_service_safe() {
  local node_path
  node_path="$(command -v node 2>/dev/null || true)"
  [ -n "$node_path" ] || return 1

  case "$node_path" in
    /opt/homebrew/*/bin/node|/usr/local/*/bin/node|/opt/homebrew/bin/node|/usr/local/bin/node)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

linux_node_path_is_service_safe() {
  local node_path
  node_path="$(command -v node 2>/dev/null || true)"
  [ -n "$node_path" ] || return 1

  case "$node_path" in
    /usr/bin/node|/usr/local/bin/node|/bin/node)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

node_path_uses_version_manager() {
  local node_path
  node_path="$(command -v node 2>/dev/null || true)"

  case "$node_path" in
    *"/.nvm/"*|*"/.fnm/"*|*"/.volta/"*|*"/.asdf/"*|*"/shim"*|*"/shims/"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

openclaw_path_uses_version_manager() {
  local openclaw_path
  openclaw_path="$(command -v openclaw 2>/dev/null || true)"

  case "$openclaw_path" in
    *"/.nvm/"*|*"/.fnm/"*|*"/.volta/"*|*"/.asdf/"*|*"/shim"*|*"/shims/"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

prefer_system_node_path() {
  local candidate
  for candidate in /usr/bin /usr/local/bin /bin; do
    if [ -x "$candidate/node" ]; then
      export PATH="$candidate:$PATH"
      hash -r 2>/dev/null || true
      return 0
    fi
  done
  return 1
}

load_nvm() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck disable=SC1090
    . "$NVM_DIR/nvm.sh"
  fi
}

ensure_macos_devtools() {
  log "检查 macOS 开发者工具"

  if xcode-select -p >/dev/null 2>&1 && command -v git >/dev/null 2>&1 && command -v clang >/dev/null 2>&1; then
    log "Xcode Command Line Tools 已安装"
    return 0
  fi

  warn "未检测到 Xcode Command Line Tools，尝试触发系统安装"

  if ! command -v xcode-select >/dev/null 2>&1; then
    fail "系统缺少 xcode-select，无法继续"
  fi

  if xcode-select --install >/tmp/openclaw_xcode_install.log 2>&1; then
    warn "已触发 Xcode Command Line Tools 安装，请在系统弹窗中完成安装"
  else
    if grep -qi 'already installed' /tmp/openclaw_xcode_install.log 2>/dev/null; then
      log "系统提示 Command Line Tools 已安装，继续后续检测"
    else
      cat /tmp/openclaw_xcode_install.log >&2 || true
    fi
  fi

  if xcode-select -p >/dev/null 2>&1 && command -v git >/dev/null 2>&1 && command -v clang >/dev/null 2>&1; then
    log "Xcode Command Line Tools 已可用"
    return 0
  fi

  fail "macOS 缺少 Xcode Command Line Tools。请先完成安装后重新运行脚本。"
}

ensure_homebrew_in_path() {
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi

  if [ -x /opt/homebrew/bin/brew ]; then
    export PATH="/opt/homebrew/bin:$PATH"
    return 0
  fi

  if [ -x /usr/local/bin/brew ]; then
    export PATH="/usr/local/bin:$PATH"
    return 0
  fi

  return 1
}

ensure_homebrew_shellenv() {
  ensure_homebrew_in_path || return 1

  if command -v brew >/dev/null 2>&1; then
    eval "$(brew shellenv)"
    return 0
  fi

  return 1
}

install_homebrew() {
  ensure_homebrew_in_path && return 0
  ensure_macos_sudo
  log "安装 Homebrew"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ensure_homebrew_in_path || fail "Homebrew 安装失败"
  ensure_homebrew_shellenv || fail "Homebrew 已安装，但 shell 环境未生效"
}

install_nvm() {
  load_nvm
  if command -v nvm >/dev/null 2>&1; then
    return 0
  fi

  log "安装 nvm"
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
  load_nvm
  command -v nvm >/dev/null 2>&1 || fail "nvm 安装失败"
}

install_node_macos() {
  log "在 macOS 上准备 Node.js 22"
  ensure_macos_devtools
  ensure_macos_sudo
  ensure_homebrew_in_path || install_homebrew
  ensure_homebrew_shellenv || fail "Homebrew 环境初始化失败"

  log "通过 Homebrew 安装 Node.js 22"
  brew install node@22

  if brew list node@22 >/dev/null 2>&1; then
    local brew_prefix
    brew_prefix="$(brew --prefix node@22)"
    export PATH="$brew_prefix/bin:$PATH"
  fi

  command -v node >/dev/null 2>&1 || fail "Homebrew 安装 Node.js 后仍不可用"
  [ "$(node_major_version)" -ge 22 ] || fail "Homebrew 安装后的 Node.js 版本仍低于 22：$(node -v)"
}

install_node_linux() {
  log "在 Linux 上安装 Node.js 22"
  ensure_linux_temp_swap

  if command -v apt-get >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup_22.sh
    run_privileged bash /tmp/nodesource_setup_22.sh
    run_privileged apt-get install -y nodejs
    return 0
  fi

  if command -v dnf >/dev/null 2>&1; then
    curl -fsSL https://rpm.nodesource.com/setup_22.x -o /tmp/nodesource_setup_22.sh
    run_privileged bash /tmp/nodesource_setup_22.sh
    run_privileged dnf install -y nodejs
    return 0
  fi

  if command -v yum >/dev/null 2>&1; then
    curl -fsSL https://rpm.nodesource.com/setup_22.x -o /tmp/nodesource_setup_22.sh
    run_privileged bash /tmp/nodesource_setup_22.sh
    run_privileged yum install -y nodejs
    return 0
  fi

  if command -v pacman >/dev/null 2>&1; then
    run_privileged pacman -Sy --noconfirm --needed nodejs npm
    return 0
  fi

  fail "未识别的 Linux 包管理器，无法自动安装 Node.js 22"
}

prefer_existing_linux_system_node() {
  local current_node previous_path major

  [ "$OS" = "linux" ] || return 1
  current_node="$(command -v node 2>/dev/null || true)"
  linux_node_path_is_service_safe && return 0

  previous_path="$PATH"
  if ! prefer_system_node_path; then
    return 1
  fi

  if major="$(node_major_version 2>/dev/null)" && [ "$major" -ge 22 ] && linux_node_path_is_service_safe; then
    if [ "$(command -v node 2>/dev/null || true)" != "$current_node" ]; then
      log "已切换到系统 Node.js：$(node -v) ($(command -v node))"
    fi
    return 0
  fi

  PATH="$previous_path"
  export PATH
  hash -r 2>/dev/null || true
  return 1
}

ensure_node() {
  local major needs_install=0

  if [ "$OS" = "linux" ]; then
    prefer_existing_linux_system_node || true
  fi

  if major="$(node_major_version 2>/dev/null)"; then
    if [ "$major" -ge 22 ]; then
      if [ "$OS" = "macos" ] && ! macos_node_path_is_service_safe; then
        warn "当前 Node.js 路径对 macOS launchd 不友好：$(command -v node)，将切换到 Homebrew node@22"
        needs_install=1
      elif [ "$OS" = "linux" ] && ! linux_node_path_is_service_safe; then
        warn "当前 Node.js 路径对 Linux systemd 不友好：$(command -v node)，将切换到系统 Node.js 22+"
        needs_install=1
      else
        log "已检测到 Node.js v$(node -v | sed 's/^v//')"
      fi
    else
      warn "当前 Node.js 版本过低：$(node -v)，将升级到 22+"
      needs_install=1
    fi
  else
    warn "未检测到 Node.js，将自动安装 22+"
    needs_install=1
  fi

  if [ "$needs_install" -eq 1 ]; then
    if [ "$OS" = "macos" ]; then
      install_node_macos
    else
      install_node_linux
      prefer_system_node_path || true
    fi
  elif [ "$OS" = "linux" ]; then
    prefer_system_node_path || true
  fi

  command -v node >/dev/null 2>&1 || fail "Node.js 安装后仍不可用"
  major="$(node_major_version)"
  [ "$major" -ge 22 ] || fail "Node.js 安装后版本仍低于 22：$(node -v)"

  if [ "$OS" = "linux" ] && ! linux_node_path_is_service_safe; then
    fail "当前仍未切换到系统 Node.js：$(command -v node)"
  fi

  log "Node.js 已就绪：$(node -v) ($(command -v node))"
}

ensure_npm_global_bin_in_path() {
  local prefix
  prefix="$(npm config get prefix 2>/dev/null || true)"
  [ -n "$prefix" ] || return 0

  case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *) export PATH="$prefix/bin:$PATH" ;;
  esac
}

strip_managed_profile_block() {
  local profile="$1" temp_file
  [ -f "$profile" ] || return 0

  temp_file="$(mktemp)"
  awk '
    /^# >>> openclaw-installer >>>$/ { skip=1; next }
    /^# <<< openclaw-installer <<<$/{ skip=0; next }
    !skip { print }
  ' "$profile" >"$temp_file"
  mv "$temp_file" "$profile"
}

persist_path_in_profile() {
  local profile="$1" bin_dir="$2"

  [ -n "$profile" ] || return 0
  mkdir -p "$(dirname "$profile")"
  touch "$profile"
  strip_managed_profile_block "$profile"

  if [ -s "$profile" ]; then
    printf '\n' >>"$profile"
  fi

  cat >>"$profile" <<EOF
# >>> openclaw-installer >>>
if [ -d "$bin_dir" ]; then
  case ":\$PATH:" in
    *":$bin_dir:"*) ;;
    *) export PATH="$bin_dir:\$PATH" ;;
  esac
fi
# <<< openclaw-installer <<<
EOF
}

persist_openclaw_cli_path() {
  local prefix bin_dir shell_name primary_profile profile
  local -a profiles=()

  prefix="$(npm config get prefix 2>/dev/null || true)"
  [ -n "$prefix" ] || return 0
  bin_dir="$prefix/bin"
  [ -d "$bin_dir" ] || return 0

  case "$bin_dir" in
    /usr/local/bin|/opt/homebrew/bin|/usr/bin|/bin)
      return 0
      ;;
  esac

  shell_name="$(basename "${SHELL:-}")"
  case "$shell_name" in
    zsh) primary_profile="$HOME/.zprofile" ;;
    bash) primary_profile="$HOME/.bash_profile" ;;
    *) primary_profile="$HOME/.profile" ;;
  esac
  profiles+=("$primary_profile")

  for profile in \
    "$HOME/.zprofile" \
    "$HOME/.zshrc" \
    "$HOME/.bash_profile" \
    "$HOME/.bashrc" \
    "$HOME/.profile"
  do
    [ -f "$profile" ] || continue
    case " ${profiles[*]} " in
      *" $profile "*) ;;
      *) profiles+=("$profile") ;;
    esac
  done

  log "持久化 OpenClaw CLI PATH：$bin_dir"
  for profile in "${profiles[@]}"; do
    persist_path_in_profile "$profile" "$bin_dir"
  done
}

path_entry_uses_version_manager() {
  case "$1" in
    *"/.nvm/"*|*"/.fnm/"*|*"/.volta/"*|*"/.asdf/"*|*/shim|*/shim/*|*/shims|*/shims/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_path_entries() {
  local raw_path="$1" filtered="" entry old_ifs

  old_ifs="$IFS"
  IFS=':'
  for entry in $raw_path; do
    [ -n "$entry" ] || continue
    if [ "$OS" = "linux" ] && path_entry_uses_version_manager "$entry"; then
      continue
    fi

    case ":$filtered:" in
      *":$entry:"*) ;;
      *)
        filtered="${filtered:+$filtered:}$entry"
        ;;
    esac
  done
  IFS="$old_ifs"

  printf '%s\n' "$filtered"
}

common_service_user_paths() {
  local extras="" entry

  for entry in \
    "$HOME/.local/bin" \
    "$HOME/.npm-global/bin" \
    "$HOME/bin" \
    "$HOME/.bun/bin" \
    "$HOME/.local/share/pnpm"
  do
    extras="${extras:+$extras:}$entry"
  done

  printf '%s\n' "$extras"
}

build_service_path() {
  local service_path npm_prefix node_dir extra_paths cleaned_path

  service_path="/usr/local/bin:/usr/bin:/bin"
  if [ "$OS" = "macos" ]; then
    service_path="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  fi

  npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  if [ -n "$npm_prefix" ] && [ -d "$npm_prefix/bin" ]; then
    service_path="$npm_prefix/bin:$service_path"
  fi

  node_dir="$(dirname "$(command -v node 2>/dev/null || printf '/usr/bin/node')")"
  if [ -d "$node_dir" ]; then
    service_path="$node_dir:$service_path"
  fi

  extra_paths=""
  if [ "$OS" = "macos" ] && command -v brew >/dev/null 2>&1; then
    extra_paths="$(brew --prefix 2>/dev/null || true)/bin"
    if brew list node@22 >/dev/null 2>&1; then
      extra_paths="$(brew --prefix node@22 2>/dev/null || true)/bin:$extra_paths"
    fi
  fi

  if [ -n "$(common_service_user_paths)" ]; then
    extra_paths="$(common_service_user_paths)${extra_paths:+:$extra_paths}"
  fi

  cleaned_path="$service_path"
  if [ -n "$extra_paths" ]; then
    cleaned_path="$extra_paths:$cleaned_path"
  fi

  normalize_path_entries "$cleaned_path"
}

resolve_gateway_launch_agent_label() {
  local profile="${OPENCLAW_PROFILE:-}"
  if [ -z "$profile" ] || [ "$profile" = "default" ]; then
    printf '%s\n' 'ai.openclaw.gateway'
    return 0
  fi

  printf 'ai.openclaw.%s\n' "$profile"
}

rewrite_macos_gateway_launch_agent() {
  local plist_path config_path="$1" state_dir="$2"

  [ "$OS" = "macos" ] || return 0
  plist_path="$HOME/Library/LaunchAgents/$(resolve_gateway_launch_agent_label).plist"
  [ -f "$plist_path" ] || return 0

  node - "$plist_path" "$HOME" "$state_dir" "$config_path" "$(build_service_path)" <<'NODE'
const fs = require('fs');

const [plistPath, homeDir, stateDir, configPath, servicePath] = process.argv.slice(2);
let text = fs.readFileSync(plistPath, 'utf8');
const replacements = {
  HOME: homeDir,
  OPENCLAW_STATE_DIR: stateDir,
  OPENCLAW_CONFIG_PATH: configPath,
  PATH: servicePath,
};

const envBlockPattern = /<key>EnvironmentVariables<\/key>\s*<dict>([\s\S]*?)<\/dict>/i;
const existingMatch = text.match(envBlockPattern);
const envMap = {};

if (existingMatch) {
  for (const pair of existingMatch[1].matchAll(/<key>([\s\S]*?)<\/key>\s*<string>([\s\S]*?)<\/string>/gi)) {
    const key = pair[1].trim();
    const value = pair[2].trim();
    if (key) envMap[key] = value;
  }
}

for (const [key, value] of Object.entries(replacements)) {
  envMap[key] = value;
}

const escapeXml = (value) => value
  .replaceAll('&', '&amp;')
  .replaceAll('<', '&lt;')
  .replaceAll('>', '&gt;')
  .replaceAll('"', '&quot;')
  .replaceAll("'", '&apos;');

const envXml = `\n    <key>EnvironmentVariables</key>\n    <dict>${Object.entries(envMap)
  .filter(([, value]) => typeof value === 'string' && value.trim())
  .map(([key, value]) => `\n    <key>${escapeXml(key)}</key>\n    <string>${escapeXml(value.trim())}</string>`)
  .join('')}\n    </dict>`;

if (existingMatch) {
  text = text.replace(envBlockPattern, envXml.trimStart());
} else {
  text = text.replace(/\n  <\/dict>\n<\/plist>\n?$/i, `${envXml}\n  </dict>\n</plist>\n`);
}

fs.writeFileSync(plistPath, text);
NODE
}

openclaw_bin_path() {
  local openclaw_bin
  openclaw_bin="$(command -v openclaw 2>/dev/null || true)"
  [ -n "$openclaw_bin" ] || fail "未找到 openclaw 命令"
  printf '%s\n' "$openclaw_bin"
}

run_openclaw_with_service_env() {
  local config_path="$1" state_dir="$2"
  shift 2

  env \
    PATH="$(build_service_path)" \
    OPENCLAW_PORT="$OPENCLAW_PORT" \
    OPENCLAW_GATEWAY_PORT="$OPENCLAW_PORT" \
    OPENCLAW_CONFIG_PATH="$config_path" \
    OPENCLAW_STATE_DIR="$state_dir" \
    NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache \
    OPENCLAW_NO_RESPAWN=1 \
    "$(openclaw_bin_path)" "$@"
}

rewrite_linux_gateway_service_unit() {
  local unit_file="$HOME/.config/systemd/user/openclaw-gateway.service" config_path="$1" state_dir="$2"

  [ "$OS" = "linux" ] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  [ -f "$unit_file" ] || return 0

  node - "$unit_file" "$HOME" "$state_dir" "$config_path" "$(build_service_path)" <<'NODE'
const fs = require('fs');

const [unitFile, homeDir, stateDir, configPath, servicePath] = process.argv.slice(2);
let text = fs.readFileSync(unitFile, 'utf8');

const replacements = [
  ['HOME', homeDir],
  ['OPENCLAW_STATE_DIR', stateDir],
  ['OPENCLAW_CONFIG_PATH', configPath],
  ['PATH', servicePath],
];

for (const [key, value] of replacements) {
  const pattern = new RegExp(`^Environment=(?:"?)${key}=.*(?:"?)$`, 'm');
  const line = `Environment=${key}=${value}`;
  if (pattern.test(text)) {
    text = text.replace(pattern, line);
    continue;
  }

  text = text.replace('[Service]\n', `[Service]\n${line}\n`);
}

fs.writeFileSync(unitFile, text);
NODE

  systemctl --user daemon-reload
}

rewrite_gateway_service_definition() {
  local config_path="$1" state_dir="$2"

  rewrite_linux_gateway_service_unit "$config_path" "$state_dir"
  rewrite_macos_gateway_launch_agent "$config_path" "$state_dir"
}

write_service_env() {
  local config_home env_file cleaned_path config_path state_dir
  config_home="$HOME/.openclaw"
  env_file="$config_home/.env"
  config_path="${1:-$HOME/.openclaw/openclaw.json}"
  state_dir="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"

  mkdir -p "$config_home"
  cleaned_path="$(build_service_path)"

  cat > "$env_file" <<EOF
PATH=$cleaned_path
OPENCLAW_PORT=$OPENCLAW_PORT
OPENCLAW_GATEWAY_PORT=$OPENCLAW_PORT
OPENCLAW_CONFIG_PATH=$config_path
OPENCLAW_STATE_DIR=$state_dir
NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache
OPENCLAW_NO_RESPAWN=1
EOF

  log "已写入服务环境文件：$env_file"
}

port_is_listening() {
  local port="$1"

  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi

  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$port" >/dev/null 2>&1
    return $?
  fi

  return 1
}

configured_gateway_port() {
  local env_file="$HOME/.openclaw/.env" configured_port=""

  if [ -f "$env_file" ]; then
    configured_port="$(awk -F= '/^OPENCLAW_GATEWAY_PORT=/{print $2; exit}' "$env_file" 2>/dev/null || true)"
  fi

  if [ -z "$configured_port" ] && [ -f "$HOME/.openclaw/openclaw.json" ] && command -v node >/dev/null 2>&1; then
    configured_port="$(node - "$HOME/.openclaw/openclaw.json" <<'NODE'
const fs = require('fs');
const configPath = process.argv[2];
try {
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const port = config && config.gateway && config.gateway.port;
  if (port) process.stdout.write(String(port));
} catch {}
NODE
)"
  fi

  [ -n "$configured_port" ] || return 1
  printf '%s\n' "$configured_port"
}

choose_gateway_port() {
  local candidate max_port existing_port
  candidate="${OPENCLAW_PORT:-18789}"
  max_port=$((candidate + 20))
  existing_port="$(configured_gateway_port 2>/dev/null || true)"

  if [ -z "$OPENCLAW_PORT_INPUT" ] && [ -n "$existing_port" ] && gateway_health_check; then
    candidate="$existing_port"
  fi

  while [ "$candidate" -le "$max_port" ]; do
    if port_is_listening "$candidate"; then
      if [ -n "$existing_port" ] && [ "$candidate" = "$existing_port" ] && gateway_health_check; then
        OPENCLAW_PORT="$candidate"
        export OPENCLAW_PORT
        log "检测到现有 OpenClaw 网关正在使用端口：${OPENCLAW_PORT}，复用该端口"
        return 0
      fi

      warn "端口 $candidate 已被占用，尝试下一个端口"
      candidate=$((candidate + 1))
      continue
    fi

    OPENCLAW_PORT="$candidate"
    export OPENCLAW_PORT
    log "将使用网关端口：${OPENCLAW_PORT}"
    return 0
  done

  fail "未找到可用网关端口，请手动设置 OPENCLAW_PORT"
}

gateway_log_path() {
  if [ -f /tmp/openclaw/openclaw-gateway.log ]; then
    printf '%s\n' '/tmp/openclaw/openclaw-gateway.log'
    return 0
  fi

  if [ -f "$HOME/.openclaw/logs/openclaw-gateway.log" ]; then
    printf '%s\n' "$HOME/.openclaw/logs/openclaw-gateway.log"
    return 0
  fi

  printf '%s\n' '/tmp/openclaw/openclaw-gateway.log'
}

gateway_health_check() {
  local status_output

  if openclaw gateway health >/dev/null 2>&1; then
    return 0
  fi

  status_output="$(mktemp /tmp/openclaw_gateway_status.XXXXXX 2>/dev/null || printf '/tmp/openclaw_gateway_status.txt')"
  openclaw gateway status --deep >"$status_output" 2>&1 || true
  grep -q 'RPC probe: ok' "$status_output"
}

run_gateway_foreground_probe() {
  local probe_log probe_pid
  probe_log='/tmp/openclaw_gateway_foreground.log'

  warn '后台服务仍未就绪，尝试前台启动一次以抓取首个报错'
  rm -f "$probe_log"

  (
    openclaw gateway run --port "$OPENCLAW_PORT" --bind loopback --verbose >"$probe_log" 2>&1
  ) &
  probe_pid=$!

  sleep 12

  if kill -0 "$probe_pid" >/dev/null 2>&1; then
    kill "$probe_pid" >/dev/null 2>&1 || true
  fi
  wait "$probe_pid" 2>/dev/null || true

  [ -f "$probe_log" ] && sed -n '1,160p' "$probe_log" >&2 || true
}

diagnose_gateway_failure() {
  local gateway_log
  gateway_log="$(gateway_log_path)"

  warn '开始采集网关诊断信息'
  openclaw config get gateway.mode >&2 || true
  openclaw config get gateway.bind >&2 || true
  openclaw config get gateway.port >&2 || true
  printf 'config file: %s\n' "$(resolve_config_path)" >&2
  openclaw gateway status --deep >&2 || openclaw gateway status >&2 || true
  openclaw status --all >&2 || true
  openclaw logs --limit 200 --plain >&2 || true

  if [ "$OS" = "linux" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl --user status openclaw-gateway.service --no-pager -l >&2 || true
    journalctl --user -u openclaw-gateway.service -n 200 --no-pager >&2 || true
  fi

  [ -f "$gateway_log" ] && tail -n 200 "$gateway_log" >&2 || true

  if ! port_is_listening "$OPENCLAW_PORT"; then
    run_gateway_foreground_probe
  fi
}

repair_gateway_service() {
  local config_path state_dir
  config_path="$(resolve_config_path)"
  state_dir="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"

  warn '网关健康检查失败，尝试执行 openclaw doctor --fix 自动修复服务'
  run_openclaw_with_service_env "$config_path" "$state_dir" doctor --fix || \
    run_openclaw_with_service_env "$config_path" "$state_dir" doctor --yes || true
  run_openclaw_with_service_env "$config_path" "$state_dir" gateway install --runtime node --port "$OPENCLAW_PORT" --force
  rewrite_gateway_service_definition "$config_path" "$state_dir"
  run_openclaw_with_service_env "$config_path" "$state_dir" gateway restart || \
    run_openclaw_with_service_env "$config_path" "$state_dir" gateway start || true
  sleep 3
}

install_and_start_gateway() {
  local config_path state_dir
  config_path="$(resolve_config_path)"
  state_dir="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"

  log '安装并启动网关'
  run_openclaw_with_service_env "$config_path" "$state_dir" gateway install --runtime node --port "$OPENCLAW_PORT" --force
  rewrite_gateway_service_definition "$config_path" "$state_dir"
  run_openclaw_with_service_env "$config_path" "$state_dir" gateway restart || \
    run_openclaw_with_service_env "$config_path" "$state_dir" gateway start || true
  sleep 3

  if ! gateway_health_check; then
    repair_gateway_service
  fi

  if ! gateway_health_check; then
    diagnose_gateway_failure
    fail "网关仍未就绪，请优先查看：openclaw gateway status --deep && openclaw logs --follow"
  fi

  openclaw gateway status || true
}


installed_openclaw_version() {
  command -v openclaw >/dev/null 2>&1 || return 1
  openclaw --version 2>/dev/null | tail -n 1 | tr -d '[:space:]'
}

latest_openclaw_version() {
  npm view openclaw version --silent 2>/dev/null | tail -n 1 | tr -d '[:space:]'
}

openclaw_runtime_error() {
  local output status

  command -v openclaw >/dev/null 2>&1 || return 1

  set +e
  output="$(openclaw --version 2>&1)"
  status=$?
  set -e

  [ "$status" -eq 0 ] && return 1

  if [ -z "$output" ]; then
    output="openclaw --version exited with status $status"
  fi

  printf '%s\n' "$output"
}

repair_broken_openclaw_install() {
  local reason="${1:-}"

  warn "Detected broken OpenClaw installation remnants; cleaning up before retry"
  if [ -n "$reason" ]; then
    warn "OpenClaw runtime check failed: $reason"
  fi

  remove_openclaw_global_installs
  hash -r 2>/dev/null || true
}

attempt_openclaw_install() {
  local prefix="" install_ok=0

  prefix="$(npm config get prefix 2>/dev/null || true)"

  if [ -n "$prefix" ] && [ -w "$prefix" ]; then
    run_checked npm_install_openclaw_cmd && install_ok=1 || true
  fi

  if [ "$install_ok" -eq 0 ]; then
    if [ "$OS" = "macos" ] && command -v nvm >/dev/null 2>&1; then
      run_checked npm_install_openclaw_cmd && install_ok=1 || true
    fi
  fi

  if [ "$install_ok" -eq 0 ]; then
    run_privileged env \
      npm_config_audit=false \
      npm_config_fund=false \
      npm_config_update_notifier=false \
      npm_config_jobs=1 \
      NODE_OPTIONS="$(
        if [ -n "${NODE_OPTIONS:-}" ]; then
          printf '%s --max-old-space-size=512' "$NODE_OPTIONS"
        else
          printf '%s' '--max-old-space-size=512'
        fi
      )" \
      npm install -g openclaw@latest --legacy-peer-deps
  fi
}

install_openclaw() {
  log "安装 OpenClaw"
  ensure_npm_global_bin_in_path
  ensure_linux_temp_swap

  local installed_version="" latest_version="" force_reinstall=0 existing_runtime_error="" current_runtime_error=""
  installed_version="$(installed_openclaw_version 2>/dev/null || true)"
  latest_version="$(latest_openclaw_version 2>/dev/null || true)"

  existing_runtime_error="$(openclaw_runtime_error 2>/dev/null || true)"
  if [ -n "$existing_runtime_error" ]; then
    repair_broken_openclaw_install "$existing_runtime_error"
    installed_version=""
    force_reinstall=1
  fi

  if [ "$OS" = "linux" ] && openclaw_path_uses_version_manager; then
    warn "检测到 openclaw 来自版本管理器路径：$(command -v openclaw)，将改为系统 npm 安装"
    force_reinstall=1
  fi

  if [ -n "${installed_version:-}" ] && [ -n "${latest_version:-}" ] && [ "${installed_version:-}" = "${latest_version:-}" ] && [ "$force_reinstall" -eq 0 ]; then
    log "检测到已安装最新版 OpenClaw：${installed_version:-}，跳过安装"
    return 0
  fi

  if [ -n "${installed_version:-}" ] && [ -n "${latest_version:-}" ]; then
    log "检测到本地 OpenClaw：${installed_version:-}，npm 最新版：${latest_version:-}，将执行升级"
  elif [ -n "${installed_version:-}" ]; then
    warn "已安装 OpenClaw：${installed_version:-}，但未能确认 npm 最新版本，将尝试升级"
  else
    log "未检测到 OpenClaw，将执行安装"
  fi

  attempt_openclaw_install

  ensure_npm_global_bin_in_path
  persist_openclaw_cli_path
  hash -r 2>/dev/null || true
  current_runtime_error="$(openclaw_runtime_error 2>/dev/null || true)"
  if [ -n "$current_runtime_error" ]; then
    repair_broken_openclaw_install "$current_runtime_error"
    attempt_openclaw_install
    ensure_npm_global_bin_in_path
    persist_openclaw_cli_path
    hash -r 2>/dev/null || true
    current_runtime_error="$(openclaw_runtime_error 2>/dev/null || true)"
  fi
  command -v openclaw >/dev/null 2>&1 || fail "OpenClaw 安装后未找到命令"
  log "OpenClaw 版本：$(openclaw --version)"
}

prompt_api_key() {
  NEWAPI_API_KEY="${NEWAPI_API_KEY:-${1:-}}"
  if [ -n "${NEWAPI_API_KEY:-}" ]; then
    export NEWAPI_API_KEY
    return 0
  fi

  printf '请先前往 https://newapi.megabyai.cc/ 注册并获取 NewAPI API Key。\n'
  printf '请输入 NewAPI API Key: '
  read -r -s NEWAPI_API_KEY
  printf '\n'
  [ -n "$NEWAPI_API_KEY" ] || fail "API Key 不能为空"
  export NEWAPI_API_KEY
}

prompt_model() {
  local input_model

  if [ -n "${OPENCLAW_MODEL_ID:-}" ]; then
    MODEL_ID="$OPENCLAW_MODEL_ID"
    MODEL_NAME="${MODEL_ID} (newapi)"
    log "使用环境变量指定模型：$MODEL_ID"
    return 0
  fi

  if [ ! -t 0 ]; then
    MODEL_ID="$MODEL_ID_DEFAULT"
    MODEL_NAME="${MODEL_ID} (newapi)"
    log "非交互环境，使用默认模型：$MODEL_ID"
    return 0
  fi

  printf '请输入模型 ID（默认 %s）: ' "$MODEL_ID_DEFAULT"
  read -r input_model || true

  if [ -n "${input_model:-}" ]; then
    MODEL_ID="$input_model"
  else
    MODEL_ID="$MODEL_ID_DEFAULT"
  fi

  MODEL_NAME="${MODEL_ID} (newapi)"
  log "使用模型：$MODEL_ID"
}

verify_upstream_api_with_curl() {
  local http_code curl_output curl_exit
  curl_output='/tmp/openclaw_models_check.json'

  if http_code="$(curl --http1.1 --tlsv1.2 --retry 2 --retry-delay 1     --connect-timeout 15 --max-time 30     -sS -o "$curl_output" -w '%{http_code}'     "$BASE_URL/models"     -H "Authorization: Bearer $NEWAPI_API_KEY")"; then
    if [ "$http_code" = "200" ]; then
      return 0
    fi

    warn "curl 校验返回 HTTP $http_code"
    sed -n '1,40p' "$curl_output" >&2 || true
    return 1
  fi

  curl_exit=$?
  warn "curl 校验失败，退出码：$curl_exit"
  return 1
}

verify_upstream_api_with_node() {
  local node_output node_status
  node_output='/tmp/openclaw_models_check.json'

  if node_status="$(node - "$BASE_URL/models" "$NEWAPI_API_KEY" "$node_output" <<'NODE'
const fs = require('fs');

const [url, apiKey, outputPath] = process.argv.slice(2);

(async () => {
  try {
    const response = await fetch(url, {
      headers: {
        Authorization: `Bearer ${apiKey}`,
      },
    });
    const text = await response.text();
    fs.writeFileSync(outputPath, text);
    process.stdout.write(String(response.status));
  } catch (error) {
    fs.writeFileSync(outputPath, String(error && error.stack ? error.stack : error));
    process.stdout.write('FETCH_ERROR');
    process.exit(1);
  }
})();
NODE
)"; then
    if [ "$node_status" = "200" ]; then
      return 0
    fi

    warn "Node.js 校验返回 HTTP $node_status"
    sed -n '1,40p' "$node_output" >&2 || true
    return 1
  fi

  warn "Node.js 校验失败"
  sed -n '1,40p' "$node_output" >&2 || true
  return 1
}

verify_upstream_api() {
  log "验证上游 NewAPI 接口"

  if [ "${OPENCLAW_SKIP_UPSTREAM_CHECK:-0}" = '1' ]; then
    warn '已跳过上游接口校验（OPENCLAW_SKIP_UPSTREAM_CHECK=1）'
    return 0
  fi

  if verify_upstream_api_with_curl; then
    return 0
  fi

  warn 'curl 探测失败，改用 Node.js TLS 栈重试'
  if verify_upstream_api_with_node; then
    return 0
  fi

  fail 'API Key 无效、上游接口不可用，或本机网络/TLS 连接存在问题'
}

responses_status_supported() {
  case "${1:-}" in
    200|201|202|400|401|403|409|422|429|500)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

probe_responses_api_with_curl() {
  local http_code response_output payload
  response_output='/tmp/openclaw_responses_check.json'
  payload="$(printf '{"model":"%s","input":"OpenClaw probe","max_output_tokens":1}' "$MODEL_ID")"

  http_code="$(curl --http1.1 --tlsv1.2 --retry 1 --retry-delay 1 \
    --connect-timeout 15 --max-time 30 \
    -sS -o "$response_output" -w '%{http_code}' \
    -X POST "$BASE_URL/responses" \
    -H "Authorization: Bearer $NEWAPI_API_KEY" \
    -H 'Content-Type: application/json' \
    -d "$payload" 2>/dev/null || printf '000')"

  responses_status_supported "$http_code"
}

probe_responses_api_with_node() {
  local node_status node_output
  node_output='/tmp/openclaw_responses_check.json'

  if node_status="$(node - "$BASE_URL/responses" "$NEWAPI_API_KEY" "$MODEL_ID" "$node_output" <<'NODE'
const fs = require('fs');

const [url, apiKey, modelId, outputPath] = process.argv.slice(2);

(async () => {
  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: modelId,
        input: 'OpenClaw probe',
        max_output_tokens: 1,
      }),
    });
    const text = await response.text();
    fs.writeFileSync(outputPath, text);
    process.stdout.write(String(response.status));
  } catch (error) {
    fs.writeFileSync(outputPath, String(error && error.stack ? error.stack : error));
    process.stdout.write('000');
    process.exit(1);
  }
})();
NODE
)"; then
    responses_status_supported "$node_status"
    return $?
  fi

  return 1
}

resolve_provider_api_mode() {
  case "$REQUESTED_PROVIDER_API" in
    openai-responses|responses)
      RESOLVED_PROVIDER_API="openai-responses"
      log "Using API adapter from OPENCLAW_PROVIDER_API: $RESOLVED_PROVIDER_API"
      return 0
      ;;
    openai-completions|completions)
      RESOLVED_PROVIDER_API="openai-completions"
      log "Using API adapter from OPENCLAW_PROVIDER_API: $RESOLVED_PROVIDER_API"
      return 0
      ;;
    auto|'')
      ;;
    *)
      warn "Unknown OPENCLAW_PROVIDER_API=$REQUESTED_PROVIDER_API, defaulting to openai-responses"
      ;;
  esac

  RESOLVED_PROVIDER_API="openai-responses"
  log "Defaulting to $RESOLVED_PROVIDER_API"
}

bootstrap_openclaw() {
  local config_home
  config_home="${HOME}/.openclaw"

  mkdir -p "$config_home"

  if [ -n "$(find "$config_home" -maxdepth 1 -type f 2>/dev/null)" ]; then
    log "检测到已有 OpenClaw 配置，跳过 onboard，直接更新配置"
  else
    log "跳过 OpenClaw onboard，直接创建配置并写入参数"
  fi
}

resolve_config_path() {
  local config_path
  config_path="$(openclaw config file 2>/dev/null | awk 'NF { path=$0 } END { print path }')"
  if [ -z "$config_path" ]; then
    config_path="$HOME/.openclaw/openclaw.json"
  fi

  case "$config_path" in
    "~/"*) config_path="$HOME/${config_path#\~/}" ;;
    '$HOME/'*) config_path="$HOME/${config_path#\$HOME/}" ;;
  esac

  printf '%s\n' "$config_path"
}

write_openclaw_config() {
  local config_path
  config_path="$(resolve_config_path)"

  mkdir -p "$(dirname "$config_path")"
  if [ -f "$config_path" ]; then
    cp "$config_path" "$config_path.bak.$(date +%Y%m%d%H%M%S)"
  fi

  log "写入 OpenClaw 配置：$config_path"
  node - "$config_path" "$NEWAPI_API_KEY" "$BASE_URL" "$PROVIDER_ID" "$MODEL_ID" "$MODEL_NAME" "$OPENCLAW_PORT" "$ENABLE_BROWSER_TOOL" "$RESOLVED_PROVIDER_API" <<'NODE'
const fs = require('fs');
const crypto = require('crypto');

const [configPath, apiKey, baseUrl, providerId, modelId, modelName, gatewayPort, enableBrowserToolRaw, providerApi] = process.argv.slice(2);
const enableBrowserTool = enableBrowserToolRaw === '1';

let config = {};
if (fs.existsSync(configPath)) {
  const raw = fs.readFileSync(configPath, 'utf8').trim();
  if (raw) {
    config = JSON.parse(raw);
  }
}

config.models = config.models || {};
config.models.mode = 'merge';
config.models.providers = config.models.providers || {};

const existingProvider = config.models.providers[providerId] || {};

config.models.providers[providerId] = {
  ...existingProvider,
  baseUrl,
  apiKey,
  api: providerApi,
  models: [
    {
      id: modelId,
      name: modelName,
      input: ['text'],
      contextWindow: 64000,
      maxTokens: 4096,
    },
  ],
};

config.gateway = config.gateway || {};
config.gateway.mode = 'local';
config.gateway.bind = 'loopback';
config.gateway.port = Number(gatewayPort);
config.gateway.reload = config.gateway.reload || {};
config.gateway.reload.mode = config.gateway.reload.mode || 'hybrid';
config.gateway.auth = config.gateway.auth || {};
if (typeof config.gateway.auth.token !== 'string' || !config.gateway.auth.token.trim()) {
  config.gateway.auth.token = crypto.randomBytes(24).toString('hex');
}
if (!config.gateway.auth.mode || (config.gateway.auth.mode === 'password' && !config.gateway.auth.password)) {
  config.gateway.auth.mode = 'token';
}

config.tools = config.tools || {};
const denyList = Array.isArray(config.tools.deny) ? config.tools.deny.filter((entry) => typeof entry === 'string' && entry.trim()) : [];
const denySet = new Set(denyList);
if (enableBrowserTool) {
  denySet.delete('browser');
} else {
  denySet.add('browser');
}
config.tools.deny = Array.from(denySet);

config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = config.agents.defaults.model || {};
config.agents.defaults.model.primary = `${providerId}/${modelId}`;
config.agents.defaults.models = config.agents.defaults.models || {};
config.agents.defaults.models[`${providerId}/${modelId}`] = {
  ...(config.agents.defaults.models[`${providerId}/${modelId}`] || {}),
};
config.agents.defaults.memorySearch = config.agents.defaults.memorySearch || {};
if (typeof config.agents.defaults.memorySearch.provider === 'undefined' && typeof config.agents.defaults.memorySearch.enabled === 'undefined') {
  config.agents.defaults.memorySearch.enabled = false;
  config.agents.defaults.memorySearch.fallback = 'none';
}

fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}
`);
NODE
}

gateway_auth_token() {
  local config_path="$1"
  [ -f "$config_path" ] || return 1

  node - "$config_path" <<'NODE'
const fs = require('fs');
const configPath = process.argv[2];
try {
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const token = config && config.gateway && config.gateway.auth && config.gateway.auth.token;
  if (typeof token === 'string' && token.trim()) {
    process.stdout.write(token.trim());
  }
} catch {}
NODE
}

extract_dashboard_url() {
  awk 'match($0, /https?:\/\/[^[:space:]]+/) { print substr($0, RSTART, RLENGTH); exit }'
}

open_dashboard_ui() {
  local config_path state_dir token dashboard_output dashboard_url
  config_path="$(resolve_config_path)"
  state_dir="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
  token="$(gateway_auth_token "$config_path" 2>/dev/null || true)"

  log "尝试打开 OpenClaw Control UI"
  dashboard_output="$(run_openclaw_with_service_env "$config_path" "$state_dir" dashboard 2>&1 || true)"
  dashboard_url="$(printf '%s\n' "$dashboard_output" | extract_dashboard_url)"
  [ -n "$dashboard_url" ] || dashboard_url="http://127.0.0.1:${OPENCLAW_PORT}/"

  case "$OS" in
    macos)
      command -v open >/dev/null 2>&1 && open "$dashboard_url" >/dev/null 2>&1 || true
      ;;
    linux)
      command -v xdg-open >/dev/null 2>&1 && xdg-open "$dashboard_url" >/dev/null 2>&1 || true
      ;;
  esac

  log "Control UI：$dashboard_url"
  if [ -n "$token" ]; then
    log "Gateway token：$token"
    warn "若 UI 提示 unauthorized，请在 Control UI settings 中粘贴上面的 gateway token"
  fi
}

validate_openclaw() {
  log "校验 OpenClaw 配置"
  openclaw config validate
}


probe_provider() {
  log "探测模型可用性"
  if ! openclaw models status --probe --probe-provider "$PROVIDER_ID" --json; then
    warn "模型探测失败，请检查网络、API Key 或上游模型权限"
    return 1
  fi
}

remove_path_if_exists() {
  [ -e "$1" ] || [ -L "$1" ] || return 0
  rm -rf "$1"
}

remove_openclaw_global_installs() {
  local npm_bin

  for npm_bin in \
    "$(command -v npm 2>/dev/null || true)" \
    /usr/bin/npm \
    /usr/local/bin/npm \
    "$HOME"/.nvm/versions/node/*/bin/npm
  do
    [ -n "$npm_bin" ] || continue
    [ -x "$npm_bin" ] || continue
    "$npm_bin" uninstall -g openclaw >/dev/null 2>&1 || true
  done

  remove_path_if_exists /usr/bin/openclaw
  remove_path_if_exists /bin/openclaw
  remove_path_if_exists /usr/local/bin/openclaw
  remove_path_if_exists /usr/lib/node_modules/openclaw
  remove_path_if_exists /usr/local/lib/node_modules/openclaw

  for npm_bin in "$HOME"/.nvm/versions/node/*/bin/openclaw "$HOME"/.nvm/versions/node/*/lib/node_modules/openclaw; do
    [ -e "$npm_bin" ] || continue
    remove_path_if_exists "$npm_bin"
  done
}

remove_gateway_service() {
  if [ "$OS" = "linux" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl --user stop openclaw-gateway.service >/dev/null 2>&1 || true
    systemctl --user disable openclaw-gateway.service >/dev/null 2>&1 || true
    remove_path_if_exists "$HOME/.config/systemd/user/openclaw-gateway.service"
    remove_path_if_exists "$HOME/.config/systemd/user/openclaw-gateway.service.bak"
    remove_path_if_exists "$HOME/.config/systemd/user/default.target.wants/openclaw-gateway.service"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    return 0
  fi

  if [ "$OS" = "macos" ] && command -v launchctl >/dev/null 2>&1; then
    local label plist_path gui_domain
    label="$(resolve_gateway_launch_agent_label)"
    plist_path="$HOME/Library/LaunchAgents/${label}.plist"
    gui_domain="gui/$(id -u)"
    launchctl bootout "$gui_domain" "$plist_path" >/dev/null 2>&1 || true
    launchctl unload "$plist_path" >/dev/null 2>&1 || true
    remove_path_if_exists "$plist_path"
  fi
}

remove_openclaw_state() {
  remove_path_if_exists "$HOME/.openclaw"

  for path in \
    /tmp/openclaw \
    /tmp/openclaw-0 \
    /tmp/openclaw-home-orig \
    /tmp/openclaw-home-fixed \
    /tmp/openclaw-home-fixed-2 \
    /tmp/openclaw-home-fixed-3 \
    /tmp/openclaw-home-fixed-4 \
    /tmp/openclaw_gateway_foreground.log
  do
    remove_path_if_exists "$path"
  done

  for path in /tmp/openclaw_gateway_status.*; do
    [ -e "$path" ] || continue
    remove_path_if_exists "$path"
  done
}

remove_openclaw_cli_path_persistence() {
  local profile

  for profile in \
    "$HOME/.zprofile" \
    "$HOME/.zshrc" \
    "$HOME/.bash_profile" \
    "$HOME/.bashrc" \
    "$HOME/.profile"
  do
    [ -f "$profile" ] || continue
    strip_managed_profile_block "$profile"
  done
}

remove_script_installed_node_linux() {
  local nodejs_version

  if command -v dpkg-query >/dev/null 2>&1; then
    nodejs_version="$(dpkg-query -W -f='${Version}' nodejs 2>/dev/null || true)"
    case "$nodejs_version" in
      *nodesource*)
        log "卸载脚本安装的 Node.js 包：$nodejs_version"
        run_privileged apt-get purge -y nodejs || true
        run_privileged apt-get autoremove -y || true
        ;;
    esac
  fi

  if [ -f /etc/apt/sources.list.d/nodesource.sources ]; then
    run_privileged rm -f /etc/apt/sources.list.d/nodesource.sources
  fi

  if [ -f /etc/apt/keyrings/nodesource.gpg ]; then
    run_privileged rm -f /etc/apt/keyrings/nodesource.gpg
  fi

  if command -v apt-get >/dev/null 2>&1; then
    run_privileged apt-get update || true
  fi
}

remove_script_installed_node_macos() {
  if command -v brew >/dev/null 2>&1 && brew list node@22 >/dev/null 2>&1; then
    log "卸载脚本安装的 Homebrew node@22"
    brew uninstall node@22 >/dev/null 2>&1 || true
  fi
}

uninstall_openclaw() {
  detect_platform
  log "开始卸载 OpenClaw 和脚本生成的环境"

  remove_gateway_service
  remove_openclaw_global_installs
  remove_openclaw_state
  remove_openclaw_cli_path_persistence

  if [ "$OS" = "linux" ]; then
    remove_script_installed_node_linux
  elif [ "$OS" = "macos" ]; then
    remove_script_installed_node_macos
  fi

  log "卸载完成"
}

main() {
  local config_path

  parse_cli_args "$@"

  if [ "$ACTION" = "uninstall" ]; then
    uninstall_openclaw
    return 0
  fi

  detect_platform
  need_cmd curl
  auto_detect_local_proxy
  prompt_api_key "$API_KEY_ARG"
  prompt_model
  ensure_node
  choose_gateway_port
  install_openclaw
  bootstrap_openclaw
  config_path="$(resolve_config_path)"
  write_service_env "$config_path"
  verify_upstream_api
  resolve_provider_api_mode
  write_openclaw_config
  validate_openclaw
  install_and_start_gateway
  probe_provider || true
  open_dashboard_ui

  cat <<MSG

安装完成。
- 系统：$OS ($ARCH)
- OpenClaw 已安装并初始化
- 网关端口：$OPENCLAW_PORT
- Provider：$PROVIDER_ID
- Model：$MODEL_ID
- Browser tool：$(
  if [ "$ENABLE_BROWSER_TOOL" = "1" ]; then
    printf '%s' 'enabled'
  else
    printf '%s' 'disabled (set OPENCLAW_ENABLE_BROWSER_TOOL=1 to enable)'
  fi
)
- Dashboard：http://127.0.0.1:${OPENCLAW_PORT}/
- Gateway token：$(gateway_auth_token "$config_path" 2>/dev/null || printf '%s' '未读取到，请执行 openclaw config get gateway.auth.token')

可继续手动测试：
  openclaw gateway status --deep
  openclaw logs --follow
  openclaw agent --local --message "测试：请回复OK"
  curl -fsSL https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/channel_setup.sh -o /tmp/channel_setup.sh && bash /tmp/channel_setup.sh telegram --token <bot-token> --user-id <chat-id> --test
MSG
}

main "$@"
