#!/usr/bin/env bash

set -Eeuo pipefail

CHANNEL=""
CONFIG_PATH=""
GUIDE_MODE="auto"
TOKEN=""
BOT_TOKEN=""
APP_TOKEN=""
USER_ID=""
CHANNEL_ID=""
APP_ID=""
APP_SECRET=""
PLUGIN_ID=""
RESTART_GATEWAY=1
RUN_TEST=0
INTERACTIVE_MENU=0

log_info() {
  printf '\033[1;34m[INFO]\033[0m %s\n' "$*"
}

log_warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

show_usage() {
  cat <<'EOF'
Usage:
  bash channel_setup.sh
  bash channel_setup.sh <channel> [options]
  bash channel_setup.sh --channel <channel> [options]

Supported channels:
  telegram
  discord
  slack
  feishu
  whatsapp
  wechat
  imessage

General options:
  --config-path "PATH_TO_CONFIG"   Override OpenClaw config path
  --guide-mode <mode>    Feishu guide mode: auto, browser, manual
  --restart              Restart gateway after changes (default)
  --no-restart           Do not restart gateway
  --test                 Run a basic channel credential test when supported
  -h, --help             Show this help

Channel-specific options:
  --token <token>        Telegram / Discord bot token
  --bot-token <token>    Slack bot token
  --app-token <token>    Slack app token
  --user-id <id>         Telegram user/chat id for test message
  --channel-id <id>      Discord channel id for test message
  --app-id <id>          Feishu app id
  --app-secret <secret>  Feishu app secret
  --plugin-id <id>       WeChat plugin id (default: wechat)

Examples:
  bash channel_setup.sh
  bash channel_setup.sh telegram --token "YOUR_BOT_TOKEN" --user-id "YOUR_CHAT_ID" --test
  bash channel_setup.sh discord --token "YOUR_BOT_TOKEN" --channel-id "YOUR_CHANNEL_ID" --test
  bash channel_setup.sh slack --bot-token "YOUR_XOXB_TOKEN" --app-token "YOUR_XAPP_TOKEN" --test
  bash channel_setup.sh feishu --guide-mode browser --app-id "YOUR_APP_ID" --app-secret "YOUR_APP_SECRET" --test
  bash channel_setup.sh whatsapp --restart
  bash channel_setup.sh wechat --plugin-id wechat
  bash channel_setup.sh imessage
EOF
}

is_interactive_terminal() {
  [ -t 0 ] && [ -t 1 ]
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local answer=""

  if [ ! -t 0 ]; then
    [ "$default" = "y" ]
    return
  fi

  if [ "$default" = "y" ]; then
    printf '%s [Y/n]: ' "$prompt" >&2
  else
    printf '%s [y/N]: ' "$prompt" >&2
  fi

  read -r answer || true
  answer="${answer:-$default}"
  case "$answer" in
    y|Y|yes|YES|1) return 0 ;;
    *) return 1 ;;
  esac
}

open_external_url() {
  local url="$1"
  local use_browser_automation="${2:-0}"

  if [ "$use_browser_automation" -eq 1 ] && test_openclaw_browser_available; then
    if openclaw browser start >/dev/null 2>&1 && openclaw browser open "$url" >/dev/null 2>&1; then
      printf 'browser\n'
      return 0
    fi
    log_warn "openclaw browser open failed; falling back to system browser." >&2
  fi

  if command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 && {
      printf 'system\n'
      return 0
    }
  fi

  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 && {
      printf 'system\n'
      return 0
    }
  fi

  if command -v cmd.exe >/dev/null 2>&1; then
    cmd.exe /c start "" "$url" >/dev/null 2>&1 && {
      printf 'system\n'
      return 0
    }
  fi

  printf 'none\n'
  return 1
}

wait_for_enter() {
  local prompt="$1"

  [ -t 0 ] || return 0
  printf '%s ' "$prompt" >&2
  read -r _ || true
}

test_openclaw_browser_available() {
  if openclaw browser --help >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

select_feishu_guide_mode() {
  local choice=""

  case "$GUIDE_MODE" in
    browser)
      if test_openclaw_browser_available; then
        printf 'browser\n'
      else
        log_warn $'\u5f53\u524d\u672a\u68c0\u6d4b\u5230\u53ef\u7528\u7684 OpenClaw browser\uff0c\u5df2\u56de\u9000\u4e3a\u624b\u52a8\u63d0\u793a\u6a21\u5f0f\u3002' >&2
        GUIDE_MODE="manual"
        printf 'manual\n'
      fi
      return 0
      ;;
    manual)
      printf 'manual\n'
      return 0
      ;;
    auto)
      ;;
    *)
      fail "Unsupported guide mode: $GUIDE_MODE"
      ;;
  esac

  if ! is_interactive_terminal; then
    if test_openclaw_browser_available; then
      printf 'browser\n'
    else
      printf 'manual\n'
    fi
    return 0
  fi

  if ! test_openclaw_browser_available; then
    GUIDE_MODE="manual"
    printf 'manual\n'
    return 0
  fi

  while true; do
    printf '\n' >&2
    printf '%s\n' $'\u98de\u4e66\u63a5\u5165\u65b9\u5f0f' >&2
    printf '%s\n' $'  1. \u81ea\u52a8\u5316\u6d4f\u89c8\u5668\u8f85\u52a9\uff08\u4f7f\u7528 OpenClaw browser\uff09' >&2
    printf '%s\n' $'  2. \u624b\u52a8\u6309\u63d0\u793a\u64cd\u4f5c' >&2
    printf '%s' $'\u8bf7\u9009\u62e9\u98de\u4e66\u63a5\u5165\u65b9\u5f0f: ' >&2
    read -r choice || true

    case "${choice:-}" in
      1)
        GUIDE_MODE="browser"
        printf 'browser\n'
        return 0
        ;;
      2)
        GUIDE_MODE="manual"
        printf 'manual\n'
        return 0
        ;;
      *)
        log_warn $'\u65e0\u6548\u9009\u62e9\uff0c\u8bf7\u91cd\u65b0\u8f93\u5165\u3002' >&2
        ;;
    esac
  done
}

show_feishu_setup_guide() {
  local portal_url="https://open.feishu.cn/"
  local guide_mode=""
  local open_method=""

  if ! is_interactive_terminal; then
    return 0
  fi

  guide_mode="$(select_feishu_guide_mode)"

  if open_method="$(open_external_url "$portal_url" "$([ "$guide_mode" = "browser" ] && printf '1' || printf '0')")"; then
    if [ "$open_method" = "browser" ]; then
      log_info $'\u5df2\u4f7f\u7528 OpenClaw \u6d4f\u89c8\u5668\u6253\u5f00\u98de\u4e66\u5f00\u53d1\u8005\u540e\u53f0\u3002'
      printf '%s\n' $'  0. \u5982\u672a\u767b\u5f55\uff0c\u8bf7\u5148\u5728 OpenClaw \u6d4f\u89c8\u5668\u5b8c\u6210\u767b\u5f55\u3001\u4f01\u4e1a\u5207\u6362\u548c\u5e94\u7528\u521b\u5efa\u3002'
    else
      log_info $'\u5df2\u4e3a\u4f60\u6253\u5f00\u98de\u4e66\u5f00\u53d1\u8005\u540e\u53f0\u3002'
    fi
  else
    log_warn "$(
      printf '%s %s' $'\u672a\u80fd\u81ea\u52a8\u6253\u5f00\u6d4f\u89c8\u5668\uff0c\u8bf7\u624b\u52a8\u8bbf\u95ee\uff1a' "$portal_url"
    )"
  fi

  printf '%s\n' $'  1. \u521b\u5efa\u4f01\u4e1a\u81ea\u5efa\u5e94\u7528\u3002'
  printf '%s\n' $'  2. \u5728\u5e94\u7528\u51ed\u8bc1\u4e0e\u57fa\u7840\u4fe1\u606f\u9875\u590d\u5236 App ID \u548c App Secret\u3002'
  printf '%s\n' $'  3. \u5f00\u542f\u5e94\u7528\u80fd\u529b\uff1a\u673a\u5668\u4eba\u3002'
  printf '%s\n' $'  4. \u5f00\u901a\u6d88\u606f\u4e0e\u7fa4\u7ec4\u76f8\u5173\u6743\u9650\u3002'
  wait_for_enter $'\u5b8c\u6210\u4ee5\u4e0a\u6b65\u9aa4\u540e\u6309\u56de\u8f66\u7ee7\u7eed\u3002'
}

show_feishu_post_config_guide() {
  log_info $'\u5df2\u4e3a OpenClaw \u914d\u7f6e Feishu WebSocket \u8fde\u63a5\u6a21\u5f0f\u3002'
  printf '%s\n' $'  1. \u786e\u8ba4\u5df2\u5f00\u542f\u5e94\u7528\u80fd\u529b\uff1a\u673a\u5668\u4eba\u3002'
  printf '%s\n' $'  2. \u786e\u8ba4\u5df2\u5f00\u901a\u6d88\u606f\u4e0e\u7fa4\u7ec4\u76f8\u5173\u6743\u9650\u3002'
  printf '%s\n' $'  3. \u8bf7\u5728 \u4e8b\u4ef6\u4e0e\u56de\u8c03 -> \u8ba2\u9605\u65b9\u5f0f \u91cc\u9009\u62e9 \u957f\u8fde\u63a5\u3002'
  printf '%s\n' $'  4. \u5e76\u6dfb\u52a0\u4e8b\u4ef6\uff1a\u63a5\u6536\u6d88\u606f\u3002'
}

show_channel_menu() {
  local choice=""

  while true; do
    printf '\n'
    printf '%s\n' $'OpenClaw \u6d88\u606f\u6e20\u9053\u4e00\u952e\u63a5\u5165'
    printf '%s\n' '  1. Telegram'
    printf '%s\n' '  2. Discord'
    printf '%s\n' '  3. Slack'
    printf '%s\n' '  4. Feishu'
    printf '%s\n' '  5. WhatsApp'
    printf '%s\n' '  6. WeChat Plugin'
    printf '%s\n' '  7. iMessage'
    printf '%s\n' $'  h. \u67e5\u770b\u547d\u4ee4\u884c\u5e2e\u52a9'
    printf '%s\n' $'  q. \u9000\u51fa'
    printf '%s' $'\u8bf7\u9009\u62e9\u8981\u63a5\u5165\u7684\u6e20\u9053: ' >&2
    read -r choice || true

    case "${choice:-}" in
      1) CHANNEL="telegram"; break ;;
      2) CHANNEL="discord"; break ;;
      3) CHANNEL="slack"; break ;;
      4) CHANNEL="feishu"; break ;;
      5) CHANNEL="whatsapp"; break ;;
      6) CHANNEL="wechat"; break ;;
      7) CHANNEL="imessage"; break ;;
      h|H)
        show_usage
        ;;
      q|Q)
        exit 0
        ;;
      *)
        log_warn $'\u65e0\u6548\u9009\u62e9\uff0c\u8bf7\u91cd\u65b0\u8f93\u5165\u3002'
        ;;
    esac
  done

  INTERACTIVE_MENU=1
}

configure_menu_options() {
  [ "$INTERACTIVE_MENU" -eq 1 ] || return 0

  if prompt_yes_no $'\u914d\u7f6e\u5b8c\u6210\u540e\u662f\u5426\u81ea\u52a8\u91cd\u542f OpenClaw \u7f51\u5173\uff1f' "y"; then
    RESTART_GATEWAY=1
  else
    RESTART_GATEWAY=0
  fi

  case "$CHANNEL" in
    telegram|discord|slack|feishu)
      if prompt_yes_no $'\u662f\u5426\u7acb\u5373\u6267\u884c\u4e00\u6b21\u6e20\u9053\u8fde\u901a\u6027\u6d4b\u8bd5\uff1f' "y"; then
        RUN_TEST=1
      else
        RUN_TEST=0
      fi
      ;;
    *)
      RUN_TEST=0
      ;;
  esac
}

check_openclaw() {
  command -v openclaw >/dev/null 2>&1 || fail "openclaw not found. Run install_openclaw.sh first."
  command -v node >/dev/null 2>&1 || fail "node not found. OpenClaw channel setup needs Node.js."
}

normalize_config_path() {
  local raw_output="${1:-}"
  local candidate=""
  local line=""

  while IFS= read -r line; do
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$line" ] || continue
    candidate="$line"
  done <<EOF
$raw_output
EOF

  candidate="$(printf '%s' "$candidate" | sed -E 's/^[[:space:]]*[Cc]onfig[[:space:]]+file[[:space:]]*:[[:space:]]*//')"
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
    *[\\/]*|openclaw.json) printf '%s\n' "$candidate" ;;
    *) return 1 ;;
  esac
}

resolve_config_path() {
  local raw_output=""

  if [ -n "$CONFIG_PATH" ]; then
    CONFIG_PATH="$(normalize_config_path "$CONFIG_PATH" 2>/dev/null || printf '%s' "$CONFIG_PATH")"
    return 0
  fi

  raw_output="$(openclaw config file 2>/dev/null || true)"
  CONFIG_PATH="$(normalize_config_path "$raw_output" 2>/dev/null || true)"
  if [ -z "$CONFIG_PATH" ]; then
    CONFIG_PATH="$HOME/.openclaw/openclaw.json"
  fi
}

ensure_config_file() {
  resolve_config_path
  mkdir -p "$(dirname "$CONFIG_PATH")"
  if [ ! -f "$CONFIG_PATH" ]; then
    printf '{}\n' >"$CONFIG_PATH"
  fi
}

mask_value() {
  local value="${1:-}"
  local prefix="${2:-6}"
  local suffix="${3:-4}"

  if [ -z "$value" ]; then
    printf '%s\n' ''
    return 0
  fi

  if [ "${#value}" -le $((prefix + suffix)) ]; then
    printf '%s\n' "$value"
    return 0
  fi

  printf '%s...%s\n' "${value:0:prefix}" "${value: -suffix}"
}

prompt_value() {
  local prompt="$1"
  local current="${2:-}"
  local secret="${3:-0}"
  local value="$current"

  if [ -n "$value" ]; then
    printf '%s\n' "$value"
    return 0
  fi

  if [ ! -t 0 ]; then
    printf '%s\n' ''
    return 0
  fi

  if [ "$secret" = "1" ]; then
    printf '%s: ' "$prompt" >&2
    read -r -s value
    printf '\n' >&2
  else
    printf '%s: ' "$prompt" >&2
    read -r value
  fi

  printf '%s\n' "$value"
}

require_value() {
  local name="$1"
  local value="${2:-}"
  [ -n "$value" ] || fail "$name is required."
}

ensure_plugin_enabled() {
  local plugin_id="$1"
  if ! openclaw plugins enable "$plugin_id" >/dev/null 2>&1; then
    log_warn "openclaw plugins enable $plugin_id returned non-zero; continuing with config repair"
  fi
}

ensure_plugin_config() {
  local plugin_id="$1"
  local group_policy="${2:-allowlist}"
  local dm_policy="${3:-pairing}"

  ensure_config_file

  node - "$CONFIG_PATH" "$plugin_id" "$group_policy" "$dm_policy" <<'NODE'
const fs = require('fs');

const [configPath, pluginId, groupPolicy, dmPolicy] = process.argv.slice(2);
let config = {};

if (fs.existsSync(configPath)) {
  const raw = fs.readFileSync(configPath, 'utf8').trim();
  if (raw) {
    config = JSON.parse(raw);
  }
}

config.plugins = config.plugins || {};
config.plugins.allow = Array.isArray(config.plugins.allow) ? config.plugins.allow : [];
config.plugins.entries = config.plugins.entries && typeof config.plugins.entries === 'object' ? config.plugins.entries : {};
config.channels = config.channels && typeof config.channels === 'object' ? config.channels : {};

if (!config.plugins.allow.includes(pluginId)) {
  config.plugins.allow.push(pluginId);
}

config.plugins.entries[pluginId] = Object.assign({}, config.plugins.entries[pluginId], { enabled: true });
config.channels[pluginId] = Object.assign({ dmPolicy, groupPolicy }, config.channels[pluginId] || {});

fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
NODE
}

restart_gateway() {
  if [ "$RESTART_GATEWAY" -ne 1 ]; then
    log_info "Gateway restart skipped"
    return 0
  fi

  log_info "Restarting OpenClaw gateway"
  openclaw gateway restart >/dev/null 2>&1 || openclaw gateway start >/dev/null 2>&1 || \
    log_warn "Gateway restart/start failed. Run 'openclaw gateway status --deep' manually."
}

run_test_telegram() {
  [ "$RUN_TEST" -eq 1 ] || return 0
  [ -n "$USER_ID" ] || {
    log_warn "Telegram test skipped because --user-id was not provided"
    return 0
  }
  command -v curl >/dev/null 2>&1 || {
    log_warn "curl not found, skipping Telegram test"
    return 0
  }
  log_info "Sending Telegram test message"
  curl -fsS -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${USER_ID}\",\"text\":\"OpenClaw Telegram channel setup completed.\"}" >/dev/null
}

run_test_discord() {
  [ "$RUN_TEST" -eq 1 ] || return 0
  [ -n "$CHANNEL_ID" ] || {
    log_warn "Discord test skipped because --channel-id was not provided"
    return 0
  }
  command -v curl >/dev/null 2>&1 || {
    log_warn "curl not found, skipping Discord test"
    return 0
  }
  log_info "Sending Discord test message"
  curl -fsS -X POST "https://discord.com/api/v10/channels/${CHANNEL_ID}/messages" \
    -H "Authorization: Bot ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"content":"OpenClaw Discord channel setup completed."}' >/dev/null
}

run_test_slack() {
  [ "$RUN_TEST" -eq 1 ] || return 0
  command -v curl >/dev/null 2>&1 || {
    log_warn "curl not found, skipping Slack test"
    return 0
  }
  log_info "Checking Slack bot token"
  curl -fsS "https://slack.com/api/auth.test" \
    -H "Authorization: Bearer ${BOT_TOKEN}" >/dev/null
}

run_test_feishu() {
  [ "$RUN_TEST" -eq 1 ] || return 0
  command -v curl >/dev/null 2>&1 || {
    log_warn "curl not found, skipping Feishu test"
    return 0
  }
  log_info "Checking Feishu app credentials"
  curl -fsS -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
    -H "Content-Type: application/json" \
    -d "{\"app_id\":\"${APP_ID}\",\"app_secret\":\"${APP_SECRET}\"}" >/dev/null
}

setup_telegram() {
  TOKEN="$(prompt_value "Telegram bot token" "$TOKEN" 1)"
  USER_ID="$(prompt_value "Telegram user/chat id for test (optional)" "$USER_ID" 0)"
  require_value "--token" "$TOKEN"

  ensure_plugin_enabled telegram
  ensure_plugin_config telegram
  openclaw channels add --channel telegram --token "$TOKEN" >/dev/null 2>&1 || \
    log_warn "openclaw channels add --channel telegram returned non-zero; verify with 'openclaw channels list'"
  restart_gateway

  log_info "Telegram configured"
  printf '  token: %s\n' "$(mask_value "$TOKEN")"
  run_test_telegram
}

setup_discord() {
  TOKEN="$(prompt_value "Discord bot token" "$TOKEN" 1)"
  CHANNEL_ID="$(prompt_value "Discord channel id for test (optional)" "$CHANNEL_ID" 0)"
  require_value "--token" "$TOKEN"

  ensure_plugin_enabled discord
  ensure_plugin_config discord open pairing
  openclaw channels add --channel discord --token "$TOKEN" >/dev/null 2>&1 || \
    log_warn "openclaw channels add --channel discord returned non-zero; verify with 'openclaw channels list'"
  openclaw config set channels.discord.groupPolicy open >/dev/null 2>&1 || \
    log_warn "Failed to set channels.discord.groupPolicy=open"
  restart_gateway

  log_info "Discord configured"
  printf '  token: %s\n' "$(mask_value "$TOKEN")"
  run_test_discord
}

setup_slack() {
  BOT_TOKEN="$(prompt_value "Slack bot token" "$BOT_TOKEN" 1)"
  APP_TOKEN="$(prompt_value "Slack app token" "$APP_TOKEN" 1)"
  require_value "--bot-token" "$BOT_TOKEN"
  require_value "--app-token" "$APP_TOKEN"

  ensure_plugin_enabled slack
  ensure_plugin_config slack
  openclaw channels add --channel slack --bot-token "$BOT_TOKEN" --app-token "$APP_TOKEN" >/dev/null 2>&1 || \
    log_warn "openclaw channels add --channel slack returned non-zero; verify with 'openclaw channels list'"
  restart_gateway

  log_info "Slack configured"
  printf '  bot token: %s\n' "$(mask_value "$BOT_TOKEN")"
  printf '  app token: %s\n' "$(mask_value "$APP_TOKEN")"
  run_test_slack
}

setup_feishu() {
  if is_interactive_terminal && { [ -z "$APP_ID" ] || [ -z "$APP_SECRET" ] || [ "$GUIDE_MODE" != "auto" ]; }; then
    show_feishu_setup_guide
  fi

  APP_ID="$(prompt_value "Feishu app id" "$APP_ID" 0)"
  APP_SECRET="$(prompt_value "Feishu app secret" "$APP_SECRET" 1)"
  require_value "--app-id" "$APP_ID"
  require_value "--app-secret" "$APP_SECRET"

  if ! openclaw plugins list 2>/dev/null | grep -qi feishu; then
    log_info "Installing Feishu plugin"
    openclaw plugins install @m1heng-clawd/feishu >/dev/null 2>&1 || \
      log_warn "Feishu plugin install returned non-zero; continuing"
  fi

  ensure_plugin_enabled feishu
  ensure_plugin_config feishu
  openclaw channels add --channel feishu >/dev/null 2>&1 || \
    log_warn "openclaw channels add --channel feishu returned non-zero; verify with 'openclaw channels list'"
  openclaw config set channels.feishu.appId "$APP_ID" >/dev/null 2>&1 || log_warn "Failed to set feishu appId"
  openclaw config set channels.feishu.appSecret "$APP_SECRET" >/dev/null 2>&1 || log_warn "Failed to set feishu appSecret"
  openclaw config set channels.feishu.enabled true >/dev/null 2>&1 || log_warn "Failed to set feishu enabled=true"
  openclaw config set channels.feishu.connectionMode websocket >/dev/null 2>&1 || log_warn "Failed to set feishu connectionMode=websocket"
  openclaw config set channels.feishu.domain feishu >/dev/null 2>&1 || log_warn "Failed to set feishu domain=feishu"
  openclaw config set channels.feishu.requireMention true >/dev/null 2>&1 || log_warn "Failed to set feishu requireMention=true"
  restart_gateway

  log_info "Feishu configured"
  printf '  app id: %s\n' "$(mask_value "$APP_ID" 8 4)"
  show_feishu_post_config_guide
  run_test_feishu
}

setup_whatsapp() {
  ensure_plugin_enabled whatsapp
  ensure_plugin_config whatsapp
  log_info "Starting WhatsApp login flow"
  openclaw channels login --channel whatsapp --verbose
  restart_gateway

  log_info "WhatsApp configured"
}

setup_wechat() {
  PLUGIN_ID="$(prompt_value "WeChat plugin id" "${PLUGIN_ID:-wechat}" 0)"
  require_value "--plugin-id" "$PLUGIN_ID"

  ensure_plugin_enabled "$PLUGIN_ID"
  ensure_plugin_config "$PLUGIN_ID"
  restart_gateway

  log_info "WeChat plugin enabled"
  printf '  plugin: %s\n' "$PLUGIN_ID"
}

setup_imessage() {
  case "$(uname -s 2>/dev/null || true)" in
    Darwin*) ;;
    *) fail "iMessage setup is only supported on macOS." ;;
  esac

  ensure_plugin_enabled imessage
  ensure_plugin_config imessage
  openclaw channels add --channel imessage >/dev/null 2>&1 || \
    log_warn "openclaw channels add --channel imessage returned non-zero; verify with 'openclaw channels list'"
  restart_gateway

  log_info "iMessage configured"
}

parse_args() {
  if [ "$#" -eq 0 ]; then
    if is_interactive_terminal; then
      show_channel_menu
      configure_menu_options
      return 0
    fi

    show_usage
    exit 1
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      telegram|discord|slack|feishu|whatsapp|wechat|imessage)
        CHANNEL="$1"
        ;;
      --channel)
        CHANNEL="${2:-}"
        shift
        ;;
      --config-path)
        CONFIG_PATH="${2:-}"
        shift
        ;;
      --guide-mode)
        GUIDE_MODE="${2:-}"
        shift
        ;;
      --token)
        TOKEN="${2:-}"
        shift
        ;;
      --bot-token)
        BOT_TOKEN="${2:-}"
        shift
        ;;
      --app-token)
        APP_TOKEN="${2:-}"
        shift
        ;;
      --user-id)
        USER_ID="${2:-}"
        shift
        ;;
      --channel-id)
        CHANNEL_ID="${2:-}"
        shift
        ;;
      --app-id)
        APP_ID="${2:-}"
        shift
        ;;
      --app-secret)
        APP_SECRET="${2:-}"
        shift
        ;;
      --plugin-id)
        PLUGIN_ID="${2:-}"
        shift
        ;;
      --restart)
        RESTART_GATEWAY=1
        ;;
      --no-restart)
        RESTART_GATEWAY=0
        ;;
      --test)
        RUN_TEST=1
        ;;
      -h|--help)
        show_usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
    shift
  done

  case "$GUIDE_MODE" in
    auto|browser|manual) ;;
    *) fail "Unsupported guide mode: $GUIDE_MODE" ;;
  esac

  [ -n "$CHANNEL" ] || fail "Channel is required."
}

main() {
  parse_args "$@"
  check_openclaw
  ensure_config_file

  case "$CHANNEL" in
    telegram) setup_telegram ;;
    discord) setup_discord ;;
    slack) setup_slack ;;
    feishu) setup_feishu ;;
    whatsapp) setup_whatsapp ;;
    wechat) setup_wechat ;;
    imessage) setup_imessage ;;
    *) fail "Unsupported channel: $CHANNEL" ;;
  esac

  printf '\n'
  log_info "Done. Recommended checks:"
  printf '  openclaw channels list\n'
  printf '  openclaw gateway status --deep\n'
}

main "$@"
