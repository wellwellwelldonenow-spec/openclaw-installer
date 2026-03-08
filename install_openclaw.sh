#!/usr/bin/env bash

set -Eeuo pipefail

OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
PROVIDER_ID="megabyai"
BASE_URL="https://newapi.megabyai.cc/v1"
MODEL_ID="gpt-5.3-codex"
MODEL_NAME="gpt-5.3-codex (newapi)"
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

install_homebrew() {
  ensure_homebrew_in_path && return 0
  log "安装 Homebrew"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ensure_homebrew_in_path || fail "Homebrew 安装失败"
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

  if ensure_homebrew_in_path; then
    log "检测到 Homebrew，优先通过 Homebrew 安装 Node.js 22"
    brew install node@22
    if brew list node@22 >/dev/null 2>&1; then
      local brew_prefix
      brew_prefix="$(brew --prefix node@22)"
      export PATH="$brew_prefix/bin:$PATH"
    fi
    if command -v node >/dev/null 2>&1 && [ "$(node_major_version)" -ge 22 ]; then
      return 0
    fi
    warn "Homebrew 安装后 Node.js 仍不可用，改用 nvm"
  else
    warn "未检测到 Homebrew，改用 nvm 安装 Node.js"
  fi

  install_nvm
  nvm install 22
  nvm alias default 22 >/dev/null
  nvm use 22 >/dev/null
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
  local major
  if major="$(node_major_version 2>/dev/null)"; then
    if [ "$major" -ge 22 ]; then
      log "已检测到 Node.js v$(node -v | sed 's/^v//')"
      return 0
    fi
    warn "当前 Node.js 版本过低：$(node -v)，将升级到 22+"
  else
    warn "未检测到 Node.js，将自动安装 22+"
  fi

  if [ "$OS" = "macos" ]; then
    install_node_macos
  else
    install_node_linux
  fi

  command -v node >/dev/null 2>&1 || fail "Node.js 安装后仍不可用"
  major="$(node_major_version)"
  [ "$major" -ge 22 ] || fail "Node.js 安装后版本仍低于 22：$(node -v)"
  log "Node.js 已就绪：$(node -v)"
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

install_openclaw() {
  log "安装 OpenClaw"
  if command -v openclaw >/dev/null 2>&1; then
    log "检测到已安装的 OpenClaw：$(openclaw --version)，将执行升级/覆盖安装"
  fi

  ensure_npm_global_bin_in_path

  local prefix install_ok=0
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

ensure_openclaw_initialized() {
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

  log "安装并启动网关"
  openclaw gateway install --runtime node --port "$OPENCLAW_PORT" --force
  openclaw gateway start || openclaw gateway restart
  openclaw gateway status || true
}

resolve_config_path() {
  local config_path
  config_path="$(openclaw config file 2>/dev/null | awk 'NF { path=$0 } END { print path }')"
  if [ -z "$config_path" ]; then
    config_path="$HOME/.openclaw/openclaw.json"
  fi
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
  node - "$config_path" "$NEWAPI_API_KEY" "$BASE_URL" "$PROVIDER_ID" "$MODEL_ID" "$MODEL_NAME" <<'NODE'
const fs = require('fs');

const [configPath, apiKey, baseUrl, providerId, modelId, modelName] = process.argv.slice(2);

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

config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = config.agents.defaults.model || {};
config.agents.defaults.model.primary = `${providerId}/${modelId}`;
config.agents.defaults.models = config.agents.defaults.models || {};
config.agents.defaults.models[`${providerId}/${modelId}`] = {
  ...(config.agents.defaults.models[`${providerId}/${modelId}`] || {}),
};

fs.writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`);
NODE
}

validate_openclaw() {
  log "校验配置并重启网关"
  openclaw config validate
  openclaw gateway restart
  openclaw gateway status
}

probe_provider() {
  log "探测模型可用性"
  if ! openclaw models status --probe --probe-provider "$PROVIDER_ID" --json; then
    warn "模型探测失败，请检查网络、API Key 或上游模型权限"
    return 1
  fi
}

main() {
  detect_platform
  need_cmd curl
  prompt_api_key "${1:-}"
  ensure_node
  install_openclaw
  verify_upstream_api
  ensure_openclaw_initialized
  write_openclaw_config
  validate_openclaw
  probe_provider || true

  cat <<MSG

安装完成。
- 系统：$OS ($ARCH)
- OpenClaw 已安装并初始化
- 网关端口：$OPENCLAW_PORT
- Provider：$PROVIDER_ID
- Model：$MODEL_ID

可继续手动测试：
  openclaw agent --local --message "测试：请回复OK"
MSG
}

main "$@"
