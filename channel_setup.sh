#!/usr/bin/env bash

set -Eeuo pipefail

CHANNEL=""
CONFIG_PATH=""
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
  --config-path <path>   Override OpenClaw config path
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
  bash channel_setup.sh telegram --token <bot-token> --user-id <chat-id> --test
  bash channel_setup.sh discord --token <bot-token> --channel-id <channel-id> --test
  bash channel_setup.sh slack --bot-token <xoxb-token> --app-token <xapp-token> --test
  bash channel_setup.sh feishu --app-id <app-id> --app-secret <app-secret> --test
  bash channel_setup.sh whatsapp --restart
  bash channel_setup.sh wechat --plugin-id wechat
  bash channel_setup.sh imessage
EOF
}

check_openclaw() {
  command -v openclaw >/dev/null 2>&1 || fail "openclaw not found. Run install_openclaw.sh first."
  command -v node >/dev/null 2>&1 || fail "node not found. OpenClaw channel setup needs Node.js."
}

resolve_config_path() {
  if [ -n "$CONFIG_PATH" ]; then
    return 0
  fi

  CONFIG_PATH="$(openclaw config file 2>/dev/null | awk 'NF { path=$0 } END { print path }')"
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
  [ "$#" -gt 0 ] || {
    show_usage
    exit 1
  }

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
