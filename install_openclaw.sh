#!/usr/bin/env bash

set -Eeuo pipefail

OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
PROVIDER_ID="megabyai"
BASE_URL="https://newapi.megabyai.cc/v1"
MODEL_ID_DEFAULT="gpt-5.3-codex"
MODEL_ID="${OPENCLAW_MODEL_ID:-$MODEL_ID_DEFAULT}"
MODEL_NAME="${MODEL_ID} (newapi)"
OS=""
ARCH=""

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
}

trap cleanup EXIT

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

ensure_node() {
  local major needs_install=0

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

write_service_env() {
  local config_home env_file service_path npm_prefix node_dir extra_paths cleaned_path config_path state_dir
  config_home="$HOME/.openclaw"
  env_file="$config_home/.env"
  config_path="${1:-$HOME/.openclaw/openclaw.json}"
  state_dir="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"

  mkdir -p "$config_home"

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

  cleaned_path="$service_path"
  if [ -n "$extra_paths" ]; then
    cleaned_path="$extra_paths:$cleaned_path"
  fi

  cleaned_path="$(printf '%s' "$cleaned_path" | awk -F: '
    {
      out="";
      for (i=1; i<=NF; i++) {
        if ($i == "") continue;
        if (seen[$i]++) continue;
        out = out (out ? ":" : "") $i;
      }
      print out;
    }')"

  if [ "$OS" = "linux" ]; then
    cleaned_path="$(printf '%s' "$cleaned_path" | awk -F: '
      {
        out="";
        for (i=1; i<=NF; i++) {
          if ($i == "") continue;
          if ($i ~ /\\/.nvm\\// || $i ~ /\\/.fnm\\// || $i ~ /\\/.volta\\// || $i ~ /\\/.asdf\\// || $i ~ /\\/shims?$/) continue;
          if (seen[$i]++) continue;
          out = out (out ? ":" : "") $i;
        }
        print out;
      }')"
  fi

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

choose_gateway_port() {
  local candidate max_port
  candidate="${OPENCLAW_PORT:-18789}"
  max_port=$((candidate + 20))

  while [ "$candidate" -le "$max_port" ]; do
    if port_is_listening "$candidate"; then
      warn "端口 $candidate 已被占用，尝试下一个端口"
      candidate=$((candidate + 1))
      continue
    fi

    OPENCLAW_PORT="$candidate"
    export OPENCLAW_PORT
    log "将使用网关端口：$OPENCLAW_PORT"
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
  warn '网关健康检查失败，尝试执行 openclaw doctor --fix 自动修复服务'
  openclaw doctor --fix || openclaw doctor --yes || true
  openclaw gateway install --runtime node --port "$OPENCLAW_PORT" --force
  openclaw gateway restart || openclaw gateway start || true
  sleep 3
}

install_and_start_gateway() {
  log '安装并启动网关'
  openclaw gateway install --runtime node --port "$OPENCLAW_PORT" --force
  openclaw gateway restart || openclaw gateway start || true
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

install_openclaw() {
  log "安装 OpenClaw"
  ensure_npm_global_bin_in_path

  local installed_version="" latest_version="" prefix="" install_ok=0 force_reinstall=0
  installed_version="$(installed_openclaw_version 2>/dev/null || true)"
  latest_version="$(latest_openclaw_version 2>/dev/null || true)"

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

  prefix="$(npm config get prefix 2>/dev/null || true)"

  if [ -n "$prefix" ] && [ -w "$prefix" ]; then
    npm install -g openclaw@latest && install_ok=1 || true
  fi

  if [ "$install_ok" -eq 0 ]; then
    if [ "$OS" = "macos" ] && command -v nvm >/dev/null 2>&1; then
      npm install -g openclaw@latest && install_ok=1 || true
    fi
  fi

  if [ "$install_ok" -eq 0 ]; then
    run_privileged npm install -g openclaw@latest
  fi

  ensure_npm_global_bin_in_path
  command -v openclaw >/dev/null 2>&1 || fail "OpenClaw 安装后未找到命令"
  log "OpenClaw 版本：$(openclaw --version)"
}

prompt_api_key() {
  NEWAPI_API_KEY="${NEWAPI_API_KEY:-${1:-}}"
  if [ -n "${NEWAPI_API_KEY:-}" ]; then
    export NEWAPI_API_KEY
    return 0
  fi

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

bootstrap_openclaw() {
  local config_home
  config_home="${HOME}/.openclaw"

  if [ -d "$config_home" ] && [ -n "$(find "$config_home" -maxdepth 1 -type f 2>/dev/null)" ]; then
    log "检测到已有 OpenClaw 配置，跳过 onboard"
  else
    log "无交互初始化 OpenClaw"
    if ! openclaw onboard       --non-interactive       --mode local       --auth-choice custom-api-key       --custom-provider-id "$PROVIDER_ID"       --custom-compatibility openai       --custom-base-url "$BASE_URL"       --custom-model-id "$MODEL_ID"       --custom-api-key "$NEWAPI_API_KEY"       --gateway-port "$OPENCLAW_PORT"       --gateway-bind loopback       --skip-skills; then
      warn "无交互 onboard 失败，回退到最小初始化流程"
      mkdir -p "$config_home"
    fi
  fi
}

resolve_config_path() {
  local config_path
  config_path="$(openclaw config file 2>/dev/null | awk 'NF { path=$0 } END { print path }')"
  if [ -z "$config_path" ]; then
    config_path="$HOME/.openclaw/openclaw.json"
  fi

  case "$config_path" in
    ~/*) config_path="$HOME/${config_path#~/}" ;;
    \$HOME/*) config_path="$HOME/${config_path#\$HOME/}" ;;
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
  node - "$config_path" "$NEWAPI_API_KEY" "$BASE_URL" "$PROVIDER_ID" "$MODEL_ID" "$MODEL_NAME" "$OPENCLAW_PORT" <<'NODE'
const fs = require('fs');

const [configPath, apiKey, baseUrl, providerId, modelId, modelName, gatewayPort] = process.argv.slice(2);

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
  api: 'openai-completions',
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

main() {
  local config_path

  detect_platform
  need_cmd curl
  prompt_api_key "${1:-}"
  prompt_model
  ensure_node
  choose_gateway_port
  install_openclaw
  bootstrap_openclaw
  config_path="$(resolve_config_path)"
  write_service_env "$config_path"
  verify_upstream_api
  write_openclaw_config
  validate_openclaw
  install_and_start_gateway
  probe_provider || true

  cat <<MSG

安装完成。
- 系统：$OS ($ARCH)
- OpenClaw 已安装并初始化
- 网关端口：$OPENCLAW_PORT
- Provider：$PROVIDER_ID
- Model：$MODEL_ID

可继续手动测试：
  openclaw gateway status --deep
  openclaw logs --follow
  openclaw agent --local --message "测试：请回复OK"
MSG
}

main "$@"
