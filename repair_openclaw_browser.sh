#!/usr/bin/env bash

set -Eeuo pipefail

OS=""
ARCH=""
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
OPENCLAW_PROXY_URL="${OPENCLAW_PROXY_URL:-}"
BROWSER_FORCE_HEADLESS=0
BROWSER_FORCE_NO_SANDBOX=0
OPENCLAW_CONFIG_RESOLVED=""
OPENCLAW_STATE_DIR_RESOLVED=""
OPENCLAW_GATEWAY_TOKEN_RESOLVED=""

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

run_with_timeout() {
  local seconds="$1"
  shift

  if command -v timeout >/dev/null 2>&1; then
    timeout "${seconds}s" "$@"
    return $?
  fi

  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${seconds}s" "$@"
    return $?
  fi

  "$@"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"
}

run_privileged() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    fail "需要 root 权限执行：$*"
  fi
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

export_proxy_if_needed() {
  [ -n "$OPENCLAW_PROXY_URL" ] || return 0
  export HTTP_PROXY="$OPENCLAW_PROXY_URL"
  export HTTPS_PROXY="$OPENCLAW_PROXY_URL"
  export ALL_PROXY="$OPENCLAW_PROXY_URL"
  export http_proxy="$OPENCLAW_PROXY_URL"
  export https_proxy="$OPENCLAW_PROXY_URL"
  export all_proxy="$OPENCLAW_PROXY_URL"
}

ensure_openclaw_present() {
  command -v openclaw >/dev/null 2>&1 || fail "未找到 openclaw，请先执行 install_openclaw.sh"
  log "OpenClaw CLI：$(command -v openclaw)"
}

normalize_config_path() {
  local raw_output="${1:-}" line="" candidate=""

  while IFS= read -r line; do
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$line" ] || continue

    candidate="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[Cc]onfig[[:space:]]+file[[:space:]]*:[[:space:]]*//')"
    candidate="${candidate%\"}"
    candidate="${candidate#\"}"
    candidate="${candidate%\'}"
    candidate="${candidate#\'}"

    case "$candidate" in
      "~/"*) candidate="$HOME/${candidate#\~/}" ;;
      "~\\"*) candidate="$HOME/${candidate#\~\\}"; candidate="${candidate//\\//}" ;;
      '$HOME/'*) candidate="$HOME/${candidate#\$HOME/}" ;;
      '$HOME\\'*) candidate="$HOME/${candidate#\$HOME\\}"; candidate="${candidate//\\//}" ;;
    esac

    case "$candidate" in
      *[\\/]*|openclaw.json)
        printf '%s\n' "$candidate"
        return 0
        ;;
    esac
  done <<EOF
$raw_output
EOF

  return 1
}

ensure_openclaw_context() {
  local raw_output="" config_path="" configured_token=""

  if [ -z "$OPENCLAW_CONFIG_RESOLVED" ]; then
    raw_output="$(openclaw config file 2>/dev/null || true)"
    config_path="$(normalize_config_path "$raw_output" 2>/dev/null || true)"
    if [ -z "$config_path" ]; then
      config_path="$HOME/.openclaw/openclaw.json"
    fi

    case "$config_path" in
      "~/"*) config_path="$HOME/${config_path#\~/}" ;;
      '$HOME/'*) config_path="$HOME/${config_path#\$HOME/}" ;;
    esac

    OPENCLAW_CONFIG_RESOLVED="$config_path"
  fi

  if [ -z "$OPENCLAW_STATE_DIR_RESOLVED" ]; then
    OPENCLAW_STATE_DIR_RESOLVED="$(dirname "$OPENCLAW_CONFIG_RESOLVED")"
  fi

  if [ -z "$OPENCLAW_GATEWAY_TOKEN_RESOLVED" ]; then
    configured_token="$(node - "$OPENCLAW_CONFIG_RESOLVED" <<'NODE'
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
)"

    OPENCLAW_GATEWAY_TOKEN_RESOLVED="$configured_token"
  fi
}

resolve_config_path() {
  ensure_openclaw_context
  printf '%s\n' "$OPENCLAW_CONFIG_RESOLVED"
}

resolve_state_dir() {
  ensure_openclaw_context
  printf '%s\n' "$OPENCLAW_STATE_DIR_RESOLVED"
}

detect_linux_browser_command() {
  local candidate
  for candidate in google-chrome-stable google-chrome chrome chromium chromium-browser; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

install_google_chrome_deb() {
  local deb_path="/tmp/google-chrome-stable_current_amd64.deb"

  [ "$ARCH" = "x64" ] || return 1
  curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o "$deb_path" || return 1
  if run_privileged apt-get install -y "$deb_path"; then
    return 0
  fi

  if command -v dpkg >/dev/null 2>&1; then
    run_privileged dpkg -i "$deb_path" >/dev/null 2>&1 || true
    run_privileged apt-get -f install -y >/dev/null 2>&1 || true
  fi

  detect_linux_browser_command >/dev/null 2>&1
}

install_google_chrome_rpm() {
  local rpm_path="/tmp/google-chrome-stable_current_x86_64.rpm"
  local manager="$1"

  [ "$ARCH" = "x64" ] || return 1
  curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm -o "$rpm_path" || return 1

  case "$manager" in
    dnf)
      run_privileged dnf install -y "$rpm_path"
      ;;
    yum)
      run_privileged yum localinstall -y "$rpm_path"
      ;;
    zypper)
      run_privileged zypper --non-interactive install "$rpm_path"
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_linux_browser_installed() {
  local browser_cmd=""

  [ "$OS" = "linux" ] || return 0

  browser_cmd="$(detect_linux_browser_command 2>/dev/null || true)"
  if [ -n "$browser_cmd" ]; then
    log "已检测到浏览器：$browser_cmd"
    return 0
  fi

  warn "未检测到 Chrome/Chromium，开始自动安装"

  if command -v apt-get >/dev/null 2>&1; then
    run_privileged apt-get update
    install_google_chrome_deb || \
      run_privileged apt-get install -y chromium || \
      run_privileged apt-get install -y chromium-browser || \
      fail "未能在当前 Debian/Ubuntu 系统上自动安装 Chrome/Chromium"
  elif command -v dnf >/dev/null 2>&1; then
    install_google_chrome_rpm dnf || \
      run_privileged dnf install -y chromium || \
      fail "未能在当前 Fedora/RHEL 系统上自动安装 Chrome/Chromium"
  elif command -v yum >/dev/null 2>&1; then
    install_google_chrome_rpm yum || \
      run_privileged yum install -y chromium || \
      fail "未能在当前 Yum 系统上自动安装 Chrome/Chromium"
  elif command -v pacman >/dev/null 2>&1; then
    run_privileged pacman -Sy --noconfirm --needed chromium || \
      fail "未能在当前 Arch 系统上自动安装 Chromium"
  elif command -v zypper >/dev/null 2>&1; then
    install_google_chrome_rpm zypper || \
      run_privileged zypper --non-interactive install chromium || \
      fail "未能在当前 openSUSE 系统上自动安装 Chrome/Chromium"
  else
    fail "未识别的 Linux 包管理器，无法自动安装 Chrome/Chromium"
  fi

  browser_cmd="$(detect_linux_browser_command 2>/dev/null || true)"
  [ -n "$browser_cmd" ] || fail "浏览器安装后仍未出现在 PATH 中"
  log "浏览器已就绪：$browser_cmd"
}

detect_browser_runtime_preferences() {
  BROWSER_FORCE_HEADLESS=0
  BROWSER_FORCE_NO_SANDBOX=0

  [ "$OS" = "linux" ] || return 0

  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    BROWSER_FORCE_NO_SANDBOX=1
    warn "当前以 root 身份运行，将启用 browser.noSandbox=true"
  fi

  if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    BROWSER_FORCE_HEADLESS=1
    warn "当前未检测到 DISPLAY/WAYLAND_DISPLAY，将启用 browser.headless=true"
  fi
}

set_browser_runtime_flags() {
  local config_path="$1" force_headless="${2:-0}" force_no_sandbox="${3:-0}"

  mkdir -p "$(dirname "$config_path")"
  if [ ! -f "$config_path" ]; then
    printf '{}\n' > "$config_path"
  fi

  node - "$config_path" "$force_headless" "$force_no_sandbox" <<'NODE'
const fs = require('fs');

const [configPath, forceHeadlessRaw, forceNoSandboxRaw] = process.argv.slice(2);
const forceHeadless = forceHeadlessRaw === '1';
const forceNoSandbox = forceNoSandboxRaw === '1';

let config = {};
if (fs.existsSync(configPath)) {
  const raw = fs.readFileSync(configPath, 'utf8').trim();
  if (raw) {
    config = JSON.parse(raw);
  }
}

config.browser = config.browser && typeof config.browser === 'object' ? config.browser : {};

let changed = false;
if (forceHeadless && config.browser.headless !== true) {
  config.browser.headless = true;
  changed = true;
}
if (forceNoSandbox && config.browser.noSandbox !== true) {
  config.browser.noSandbox = true;
  changed = true;
}

fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}
`);
process.stdout.write(changed ? 'changed\n' : 'unchanged\n');
NODE
}

configured_gateway_port() {
  local env_file="$HOME/.openclaw/.env" configured_port=""

  if [ -f "$env_file" ]; then
    configured_port="$(awk -F= '/^OPENCLAW_GATEWAY_PORT=/{print $2; exit}' "$env_file" 2>/dev/null || true)"
  fi

  if [ -z "$configured_port" ]; then
    configured_port="$(node - "$(resolve_config_path)" <<'NODE'
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

configured_gateway_token() {
  ensure_openclaw_context
  [ -n "$OPENCLAW_GATEWAY_TOKEN_RESOLVED" ] || return 1
  printf '%s\n' "$OPENCLAW_GATEWAY_TOKEN_RESOLVED"
}

refresh_gateway_port() {
  local configured_port
  configured_port="$(configured_gateway_port 2>/dev/null || true)"
  if [ -n "$configured_port" ]; then
    OPENCLAW_PORT="$configured_port"
  fi
}

run_openclaw_with_env() {
  ensure_openclaw_context

  env \
    OPENCLAW_PORT="$OPENCLAW_PORT" \
    OPENCLAW_GATEWAY_PORT="$OPENCLAW_PORT" \
    OPENCLAW_CONFIG_PATH="$OPENCLAW_CONFIG_RESOLVED" \
    OPENCLAW_STATE_DIR="$OPENCLAW_STATE_DIR_RESOLVED" \
    OPENCLAW_NO_RESPAWN=1 \
    openclaw "$@"
}

run_openclaw_with_env_timeout() {
  local seconds="$1" timeout_cmd=""
  shift
  ensure_openclaw_context

  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd="gtimeout"
  fi

  if [ -n "$timeout_cmd" ]; then
    env \
      OPENCLAW_PORT="$OPENCLAW_PORT" \
      OPENCLAW_GATEWAY_PORT="$OPENCLAW_PORT" \
      OPENCLAW_CONFIG_PATH="$OPENCLAW_CONFIG_RESOLVED" \
      OPENCLAW_STATE_DIR="$OPENCLAW_STATE_DIR_RESOLVED" \
      OPENCLAW_NO_RESPAWN=1 \
      "$timeout_cmd" "${seconds}s" openclaw "$@"
    return $?
  fi

  run_openclaw_with_env "$@"
}

run_openclaw_gateway_rpc() {
  local token=""
  token="$(configured_gateway_token 2>/dev/null || true)"

  if [ -n "$token" ]; then
    run_openclaw_with_env "$@" --token "$token"
    return $?
  fi

  run_openclaw_with_env "$@"
}

run_openclaw_gateway_rpc_timeout() {
  local seconds="$1" token=""
  shift
  token="$(configured_gateway_token 2>/dev/null || true)"

  if [ -n "$token" ]; then
    run_openclaw_with_env_timeout "$seconds" "$@" --token "$token"
    return $?
  fi

  run_openclaw_with_env_timeout "$seconds" "$@"
}

restart_gateway() {
  refresh_gateway_port
  run_openclaw_with_env gateway restart || run_openclaw_with_env gateway start || true
  sleep 3
}

gateway_health_check() {
  local status_output

  status_output="$(mktemp /tmp/openclaw_gateway_status.XXXXXX 2>/dev/null || printf '/tmp/openclaw_gateway_status.txt')"
  run_openclaw_with_env_timeout 20 gateway status --deep >"$status_output" 2>&1 || true
  if grep -q 'RPC probe: ok' "$status_output"; then
    rm -f "$status_output"
    return 0
  fi

  rm -f "$status_output"
  return 1
}

repair_gateway_if_needed() {
  warn "browser 自检提示 Gateway 未就绪，尝试执行 doctor --fix"
  run_openclaw_with_env_timeout 60 doctor --fix || run_openclaw_with_env_timeout 60 doctor --yes || true
  run_openclaw_with_env_timeout 60 gateway install --runtime node --port "$OPENCLAW_PORT" --force || true
  restart_gateway
}

probe_browser_start() {
  local probe_log="$1" attempt probe_output=""

  for attempt in 1 2 3 4 5; do
    if run_openclaw_gateway_rpc_timeout 30 browser start --json >"$probe_log" 2>&1; then
      run_openclaw_gateway_rpc browser stop --json >/dev/null 2>&1 || true
      return 0
    fi

    probe_output="$(cat "$probe_log" 2>/dev/null || true)"
    if probe_output_indicates_gateway_issue "$probe_output" && [ "$attempt" -lt 5 ]; then
      sleep 2
      continue
    fi

    break
  done

  return 1
}

probe_output_indicates_gateway_issue() {
  case "${1:-}" in
    *"gateway closed"*|*"Connect: failed - timeout"*|*"ECONNREFUSED"*|*"ETIMEDOUT"*|*"Failed to connect"*|*"connect failed"*)
      return 0
      ;;
  esac

  return 1
}

auto_repair_from_probe_output() {
  local config_path="$1" output="$2"
  local applied_headless=0 applied_no_sandbox=0

  case "$output" in
    *"Running as root without --no-sandbox is not supported"*)
      applied_no_sandbox=1
      ;;
  esac

  case "$output" in
    *"Missing X server or \$DISPLAY"*|*"The platform failed to initialize"*)
      applied_headless=1
      ;;
  esac

  if [ "$applied_headless" -eq 0 ] && [ "$applied_no_sandbox" -eq 0 ]; then
    return 1
  fi

  warn "browser 自检命中已知环境问题，尝试自动修复"
  [ "$applied_no_sandbox" -eq 1 ] && warn "自动修复：browser.noSandbox=true"
  [ "$applied_headless" -eq 1 ] && warn "自动修复：browser.headless=true"
  set_browser_runtime_flags "$config_path" "$applied_headless" "$applied_no_sandbox" >/dev/null
  restart_gateway
  return 0
}

main() {
  local config_path probe_log probe_output

  detect_platform
  export_proxy_if_needed
  need_cmd curl
  need_cmd node
  ensure_openclaw_present
  ensure_linux_browser_installed

  config_path="$(resolve_config_path)"
  detect_browser_runtime_preferences
  set_browser_runtime_flags "$config_path" "$BROWSER_FORCE_HEADLESS" "$BROWSER_FORCE_NO_SANDBOX" >/dev/null

  refresh_gateway_port
  restart_gateway

  probe_log="$(mktemp /tmp/openclaw_browser_repair.XXXXXX 2>/dev/null || printf '/tmp/openclaw_browser_repair.log')"
  if probe_browser_start "$probe_log"; then
    log "browser 自检通过，当前配置可用"
    rm -f "$probe_log"
    return 0
  fi

  probe_output="$(cat "$probe_log" 2>/dev/null || true)"
  if probe_output_indicates_gateway_issue "$probe_output"; then
    repair_gateway_if_needed
    if probe_browser_start "$probe_log"; then
      log "browser 修复成功"
      rm -f "$probe_log"
      return 0
    fi
    probe_output="$(cat "$probe_log" 2>/dev/null || true)"
  fi

  if auto_repair_from_probe_output "$config_path" "$probe_output"; then
    if probe_browser_start "$probe_log"; then
      log "browser 自动修复成功"
      rm -f "$probe_log"
      return 0
    fi
  fi

  warn "browser 修复后仍未通过自检，以下是最后一次报错："
  cat "$probe_log" >&2 || true
  rm -f "$probe_log"
  exit 1
}

main "$@"
