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
FEISHU_SELECTED_GUIDE_MODE=""
FEISHU_AUTO_APPROVE_FIRST_DM=1
FEISHU_AUTO_APPROVE_TIMEOUT_SEC=0
FEISHU_WEB_AUTH_ENABLED=1
FEISHU_WEB_AUTH_SECRET="megaaifeishu"
FEISHU_WEB_AUTH_TIMEOUT_SEC=0
FEISHU_WEB_AUTH_PORT=38459
FEISHU_WEB_AUTH_PUBLIC_BASE_URL=""

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
  --guide-mode <mode>    Feishu guide mode: auto, manual, browser
  --auto-approve-first-dm    Auto-approve the first Feishu DM user after setup (default)
  --no-auto-approve-first-dm Disable first-user auto approval for Feishu
  --auto-approve-timeout <seconds>
                            How long to wait for the first Feishu DM pairing request; 0 means no timeout
  --feishu-web-auth         Enable Linux temporary Feishu web auth page (default)
  --no-feishu-web-auth      Skip the temporary Feishu web auth page on Linux
  --feishu-web-auth-secret <secret>
                            Access key for the temporary Feishu web auth page (default: megaaifeishu)
  --feishu-web-auth-port <port>
                            Public listen port for the temporary Feishu web auth page (default: 38459)
  --feishu-web-auth-timeout <seconds>
                            Max wait time for temporary Feishu web auth success; 0 means no timeout (default: 0)
  --feishu-web-auth-public-base-url <url>
                            Optional public URL to print when the Linux host is behind a reverse proxy/NAT
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
  bash channel_setup.sh feishu --guide-mode browser --test
  bash channel_setup.sh feishu --guide-mode manual --app-id "YOUR_APP_ID" --app-secret "YOUR_APP_SECRET" --test
  bash channel_setup.sh whatsapp --restart
  bash channel_setup.sh wechat --plugin-id wechat
  bash channel_setup.sh imessage
EOF
}

is_interactive_terminal() {
  [ -t 0 ] && [ -t 1 ]
}

is_linux_host() {
  case "$(uname -s 2>/dev/null || true)" in
    Linux*) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_script_dir() {
  local source_path="${BASH_SOURCE[0]:-$0}"
  local dir_path=""

  dir_path="$(cd "$(dirname "$source_path")" >/dev/null 2>&1 && pwd)" || return 1
  printf '%s\n' "$dir_path"
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
  openclaw browser --help >/dev/null 2>&1
}

select_feishu_guide_mode() {
  case "$GUIDE_MODE" in
    browser)
      printf 'browser\n'
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

  if [ -n "$APP_ID" ] && [ -n "$APP_SECRET" ]; then
    printf 'manual\n'
    return 0
  fi

  if ! is_interactive_terminal; then
    printf 'browser\n'
    return 0
  fi

  while true; do
    printf '\n' >&2
    printf '%s\n' $'\u98de\u4e66\u63a5\u5165\u65b9\u5f0f' >&2
    printf '%s\n' $'  1. \u65b0\u5efa\u673a\u5668\u4eba\uff08\u81ea\u52a8\u521b\u5efa\u5e94\u7528 + \u540e\u7eed\u626b\u7801\u6388\u6743\uff0c\u63a8\u8350\uff09' >&2
    printf '%s\n' $'  2. \u5173\u8054\u5df2\u6709\u673a\u5668\u4eba\uff08\u624b\u52a8\u586b\u5199\u5df2\u6709 App ID/App Secret\uff09' >&2
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
  local portal_url="https://open.feishu.cn/app?lang=zh-CN"
  local docs_url="https://bytedance.larkoffice.com/docx/MFK7dDFLFoVlOGxWCv5cTXKmnMh"
  local guide_mode=""

  if ! is_interactive_terminal; then
    return 0
  fi

  guide_mode="$(select_feishu_guide_mode)"
  FEISHU_SELECTED_GUIDE_MODE="$guide_mode"

  printf '%s %s\n' $'\u5b98\u65b9\u63d2\u4ef6\u8bf4\u660e\uff1a' "$docs_url"

  if [ "$guide_mode" = "browser" ]; then
    printf '%s\n' $'  1. 已选择“新建机器人”。当前不会先直接进入 OpenClaw browser 自动化。'
    printf '%s\n' $'  2. 脚本稍后会先启动一个临时网页地址，输入访问密钥 `megaaifeishu` 后点击生成官方二维码。'
    printf '%s\n' $'  3. 页面会直接显示飞书官方“一键创建机器人”二维码，使用飞书扫码即可。'
    printf '%s\n' $'  4. 如果二维码过期，直接在网页里刷新重新生成即可。'
    printf '%s\n' $'  5. 扫码创建成功后脚本会自动继续后续飞书配置流程。'
  else
    if open_external_url "$portal_url" >/dev/null 2>&1; then
      log_info $'\u5df2\u4e3a\u4f60\u6253\u5f00\u98de\u4e66\u5f00\u53d1\u8005\u540e\u53f0\u3002'
    else
      log_warn "$(
        printf '%s %s' $'\u672a\u80fd\u81ea\u52a8\u6253\u5f00\u6d4f\u89c8\u5668\uff0c\u8bf7\u624b\u52a8\u8bbf\u95ee\uff1a' "$portal_url"
      )"
    fi
    printf '%s\n' $'  1. 如果是关联已有机器人，请在应用凭证与基础信息页复制 App ID 和 App Secret。'
    printf '%s\n' $'  2. 确认已启用机器人能力，并开通消息/群组/文档所需权限。'
    printf '%s\n' $'  3. 配置事件订阅方式为长连接（WebSocket）并添加 `im.message.receive_v1`。'
    printf '%s\n' $'  4. 创建版本并发布应用。'
    if is_linux_host; then
      printf '%s\n' $'  5. Linux 脚本稍后会启动临时 Feishu 网页授权页，默认访问密钥为 `megaaifeishu`。'
    fi
  fi
  wait_for_enter $'\u5b8c\u6210\u4ee5\u4e0a\u6b65\u9aa4\u540e\u6309\u56de\u8f66\u7ee7\u7eed\u3002'
}

show_feishu_post_config_guide() {
  log_info $'\u5df2\u4e3a OpenClaw \u914d\u7f6e Feishu WebSocket \u8fde\u63a5\u6a21\u5f0f\u3002'
  printf '%s\n' $'  1. \u786e\u8ba4\u5df2\u542f\u7528 OpenClaw \u5b98\u65b9 Feishu \u63d2\u4ef6\u3002'
  printf '%s\n' $'  2. \u786e\u8ba4\u5df2\u5f00\u542f\u5e94\u7528\u80fd\u529b\uff1a\u673a\u5668\u4eba\uff0c\u5e76\u5b8c\u6210\u6240\u9700\u6743\u9650\u5f00\u901a\u3002'
  printf '%s\n' $'  3. \u8bf7\u5728 \u4e8b\u4ef6\u4e0e\u56de\u8c03 -> \u8ba2\u9605\u65b9\u5f0f \u91cc\u9009\u62e9 \u957f\u8fde\u63a5\uff08WebSocket\uff09\u3002'
  printf '%s\n' $'  4. \u6dfb\u52a0\u4e8b\u4ef6 `im.message.receive_v1`\u3002'
  printf '%s\n' $'  5. \u521b\u5efa\u7248\u672c\u5e76\u786e\u8ba4\u53d1\u5e03\u3002'
}

show_feishu_registration_post_guide() {
  log_info $'\u5df2\u4e3a OpenClaw \u5199\u5165\u65b0\u5efa\u98de\u4e66\u673a\u5668\u4eba\u7684\u5e94\u7528\u51ed\u8bc1\u3002'
  printf '%s\n' $'  1. \u5728\u98de\u4e66\u91cc\u627e\u5230\u65b0\u5efa\u7684\u673a\u5668\u4eba\uff0c\u5148\u53d1\u4e00\u6761\u6d88\u606f\u6d4b\u8bd5\u3002'
  printf '%s\n' $'  2. \u5982\u9700\u8981 OpenClaw \u4ee5\u4f60\u7684\u8eab\u4efd\u8bbf\u95ee\u6587\u6863/\u6d88\u606f/\u65e5\u5386\u7b49\u80fd\u529b\uff0c\u53ef\u5728\u98de\u4e66\u5bf9\u8bdd\u91cc\u53d1\u9001 `/feishu auth`\u3002'
  printf '%s\n' $'  3. \u53ef\u53d1\u9001 `/feishu start` \u68c0\u67e5\u63d2\u4ef6\u662f\u5426\u5df2\u5b89\u88c5\u6210\u529f\u3002'
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

  if [ "$CHANNEL" = "feishu" ] && [ -z "$APP_ID" ] && [ -z "$APP_SECRET" ]; then
    while true; do
      printf '\n'
      printf '%s\n' $'飞书接入方式'
      printf '%s\n' $'  1. 新建机器人（先走临时网页授权，再继续自动配置，推荐）'
      printf '%s\n' $'  2. 关联已有机器人（手动填写已有 App ID/App Secret）'
      printf '%s' $'请选择飞书接入方式: ' >&2
      read -r choice || true

      case "${choice:-}" in
        1)
          GUIDE_MODE="browser"
          break
          ;;
        2)
          GUIDE_MODE="manual"
          break
          ;;
        *)
          log_warn $'无效选择，请重新输入。'
          ;;
      esac
    done
  fi

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
  local line=""

  while IFS= read -r line; do
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$line" ] || continue
    local candidate="$line"

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

  ensure_linux_user_linger
  log_info "Restarting OpenClaw gateway"
  openclaw gateway restart >/dev/null 2>&1 || openclaw gateway start >/dev/null 2>&1 || \
    log_warn "Gateway restart/start failed. Run 'openclaw gateway status --deep' manually."
}

ensure_linux_user_linger() {
  local current_user linger_state

  [ "$(uname -s 2>/dev/null || true)" = "Linux" ] || return 0
  command -v loginctl >/dev/null 2>&1 || return 0

  current_user="$(id -un 2>/dev/null || true)"
  [ -n "$current_user" ] || return 0

  linger_state="$(loginctl show-user "$current_user" -p Linger --value 2>/dev/null || true)"
  if [ "$linger_state" = "yes" ]; then
    return 0
  fi

  if loginctl enable-linger "$current_user" >/dev/null 2>&1; then
    log_info "Enabled linger for Linux user $current_user so the OpenClaw gateway stays online after logout"
    return 0
  fi

  if command -v sudo >/dev/null 2>&1 && sudo loginctl enable-linger "$current_user" >/dev/null 2>&1; then
    log_info "Enabled linger for Linux user $current_user so the OpenClaw gateway stays online after logout"
    return 0
  fi

  log_warn "Could not enable linger for Linux user $current_user. If the gateway stops after logout, run: loginctl enable-linger $current_user"
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

resolve_feishu_allow_from_path() {
  local state_dir=""

  resolve_config_path >/dev/null 2>&1 || true
  state_dir="$(dirname "$CONFIG_PATH")"
  printf '%s\n' "$state_dir/credentials/feishu-default-allowFrom.json"
}

feishu_has_allowed_dm_users() {
  local allow_from_path=""

  allow_from_path="$(resolve_feishu_allow_from_path)"
  [ -f "$allow_from_path" ] || return 1

  node - "$allow_from_path" <<'NODE'
const fs = require('fs');

const filePath = process.argv[2];
try {
  const raw = fs.readFileSync(filePath, 'utf8');
  const data = JSON.parse(raw);
  const allowFrom = Array.isArray(data.allowFrom) ? data.allowFrom.filter((value) => String(value || '').trim()) : [];
  process.exit(allowFrom.length > 0 ? 0 : 1);
} catch {
  process.exit(1);
}
NODE
}

get_first_feishu_pairing_request() {
  local raw_output=""

  raw_output="$(openclaw pairing list feishu --json 2>/dev/null || true)"
  [ -n "$raw_output" ] || return 1

  printf '%s' "$raw_output" | node -e '
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  input += chunk;
});
process.stdin.on("end", () => {
  const start = input.indexOf("{");
  if (start < 0) {
    process.exit(1);
  }

  let payload;
  try {
    payload = JSON.parse(input.slice(start));
  } catch {
    process.exit(1);
  }

  const requests = Array.isArray(payload.requests) ? payload.requests.slice() : [];
  requests.sort((left, right) => {
    const leftTime = Date.parse(left?.createdAt || left?.lastSeenAt || 0) || 0;
    const rightTime = Date.parse(right?.createdAt || right?.lastSeenAt || 0) || 0;
    return leftTime - rightTime;
  });

  const request = requests[0];
  const code = String(request?.code || "").trim();
  if (!code) {
    process.exit(1);
  }

  const senderId = String(request?.id || "").trim();
  process.stdout.write(`${code}\t${senderId}`);
});
' || return 1
}

auto_approve_first_feishu_dm_user() {
  local deadline=0
  local now=0
  local request_line=""
  local code=""
  local sender_id=""

  [ "$FEISHU_AUTO_APPROVE_FIRST_DM" -eq 1 ] || return 0

  if feishu_has_allowed_dm_users; then
    log_info "Feishu DM allowlist already has entries; skipping first-user auto approval"
    return 0
  fi

  if [ "$FEISHU_AUTO_APPROVE_TIMEOUT_SEC" -gt 0 ]; then
    deadline=$(( $(date +%s) + FEISHU_AUTO_APPROVE_TIMEOUT_SEC ))
    log_info "Waiting up to ${FEISHU_AUTO_APPROVE_TIMEOUT_SEC}s to auto-approve the first Feishu private chat user"
  else
    log_info "Waiting without timeout to auto-approve the first Feishu private chat user"
  fi
  log_info "Send the first private message to the Feishu bot now"

  while true; do
    if [ "$FEISHU_AUTO_APPROVE_TIMEOUT_SEC" -gt 0 ]; then
      now="$(date +%s)"
      [ "$now" -lt "$deadline" ] || break
    fi

    request_line="$(get_first_feishu_pairing_request || true)"
    if [ -n "$request_line" ]; then
      code="${request_line%%$'\t'*}"
      sender_id="${request_line#*$'\t'}"
      [ "$sender_id" = "$request_line" ] && sender_id=""

      if openclaw pairing approve feishu "$code" --notify >/dev/null 2>&1; then
        if [ -n "$sender_id" ]; then
          log_info "Approved first Feishu private chat user: $sender_id"
        else
          log_info "Approved first Feishu private chat user"
        fi
        return 0
      fi

      log_warn "Automatic approval for Feishu pairing code $code failed; retrying"
    fi

    sleep 3
  done

  log_warn "No Feishu private chat pairing request arrived within ${FEISHU_AUTO_APPROVE_TIMEOUT_SEC}s"
  log_warn "If needed, run: openclaw pairing list feishu --json"
}

resolve_feishu_registration_helper() {
  local repo_dir=""
  local helper_path=""
  local temp_path=""
  local helper_url="https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/scripts/feishu-registration-web.mjs"

  repo_dir="$(resolve_script_dir 2>/dev/null || true)"
  if [ -n "$repo_dir" ]; then
    helper_path="$repo_dir/scripts/feishu-registration-web.mjs"
    if [ -f "$helper_path" ]; then
      printf '%s\n' "$helper_path"
      return 0
    fi
  fi

  command -v curl >/dev/null 2>&1 || fail "curl not found. Unable to download the Feishu registration helper."
  temp_path="$(mktemp /tmp/openclaw_feishu_registration.XXXXXX.mjs 2>/dev/null || printf '/tmp/openclaw_feishu_registration.mjs')"
  curl -fsSL "$helper_url" -o "$temp_path" || fail "Failed to download Feishu registration helper from $helper_url"
  printf '%s\n' "$temp_path"
}

run_feishu_web_registration() {
  local helper_path=""
  local cleanup_helper=0
  local result_file=""
  local node_args=()

  helper_path="$(resolve_feishu_registration_helper)"
  case "$helper_path" in
    /tmp/openclaw_feishu_registration.*.mjs|/tmp/openclaw_feishu_registration.mjs) cleanup_helper=1 ;;
  esac

  result_file="$(mktemp /tmp/openclaw_feishu_registration_result.XXXXXX.json 2>/dev/null || printf '/tmp/openclaw_feishu_registration_result.json')"

  log_info "Starting temporary Feishu registration page before channel creation"
  log_info "Default access key: ${FEISHU_WEB_AUTH_SECRET}"

  node_args=(
    "$helper_path"
    --auth-secret "$FEISHU_WEB_AUTH_SECRET"
    --port "$FEISHU_WEB_AUTH_PORT"
    --timeout-sec "$FEISHU_WEB_AUTH_TIMEOUT_SEC"
    --brand feishu
    --result-file "$result_file"
  )

  if [ -n "$FEISHU_WEB_AUTH_PUBLIC_BASE_URL" ]; then
    node_args+=(--public-base-url "$FEISHU_WEB_AUTH_PUBLIC_BASE_URL")
  fi

  if ! node "${node_args[@]}"; then
    rm -f "$result_file"
    [ "$cleanup_helper" -eq 1 ] && rm -f "$helper_path"
    fail "Feishu temporary registration step failed."
  fi

  APP_ID="$(node -e "const fs=require('fs'); const data=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); process.stdout.write(data.appId || '')" "$result_file" 2>/dev/null || true)"
  APP_SECRET="$(node -e "const fs=require('fs'); const data=JSON.parse(fs.readFileSync(process.argv[1],'utf8')); process.stdout.write(data.appSecret || '')" "$result_file" 2>/dev/null || true)"
  rm -f "$result_file"
  [ "$cleanup_helper" -eq 1 ] && rm -f "$helper_path"

  [ -n "$APP_ID" ] && [ -n "$APP_SECRET" ] || fail "Official Feishu registration did not return app credentials."
  log_info "Temporary Feishu registration completed, continuing channel setup"
}

resolve_feishu_web_auth_helper() {
  local repo_dir=""
  local helper_path=""
  local temp_path=""
  local helper_url="https://raw.githubusercontent.com/wellwellwelldonenow-spec/openclaw-installer/main/scripts/feishu-web-auth.mjs"

  repo_dir="$(resolve_script_dir 2>/dev/null || true)"
  if [ -n "$repo_dir" ]; then
    helper_path="$repo_dir/scripts/feishu-web-auth.mjs"
    if [ -f "$helper_path" ]; then
      printf '%s\n' "$helper_path"
      return 0
    fi
  fi

  command -v curl >/dev/null 2>&1 || fail "curl not found. Unable to download the Feishu web auth helper."
  temp_path="$(mktemp /tmp/openclaw_feishu_web_auth.XXXXXX.mjs 2>/dev/null || printf '/tmp/openclaw_feishu_web_auth.mjs')"
  curl -fsSL "$helper_url" -o "$temp_path" || fail "Failed to download Feishu web auth helper from $helper_url"
  printf '%s\n' "$temp_path"
}

run_feishu_linux_web_auth() {
  local helper_path=""
  local cleanup_helper=0
  local node_args=()

  is_linux_host || return 0
  [ "$FEISHU_WEB_AUTH_ENABLED" -eq 1 ] || {
    log_info "Skipping temporary Feishu web auth page on Linux"
    return 0
  }

  helper_path="$(resolve_feishu_web_auth_helper)"
  case "$helper_path" in
    /tmp/openclaw_feishu_web_auth.*.mjs|/tmp/openclaw_feishu_web_auth.mjs) cleanup_helper=1 ;;
  esac

  log_info "Starting temporary Feishu web auth page before channel creation"
  log_info "Default access key: ${FEISHU_WEB_AUTH_SECRET}"

  node_args=(
    "$helper_path"
    --app-id "$APP_ID"
    --app-secret "$APP_SECRET"
    --auth-secret "$FEISHU_WEB_AUTH_SECRET"
    --port "$FEISHU_WEB_AUTH_PORT"
    --timeout-sec "$FEISHU_WEB_AUTH_TIMEOUT_SEC"
    --brand feishu
  )

  if [ -n "$FEISHU_WEB_AUTH_PUBLIC_BASE_URL" ]; then
    node_args+=(--public-base-url "$FEISHU_WEB_AUTH_PUBLIC_BASE_URL")
  fi

  if ! node "${node_args[@]}"; then
    [ "$cleanup_helper" -eq 1 ] && rm -f "$helper_path"
    fail "Feishu temporary web auth step failed."
  fi

  [ "$cleanup_helper" -eq 1 ] && rm -f "$helper_path"
  log_info "Temporary Feishu web auth completed, continuing channel setup"
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
  local selected_guide_mode="$GUIDE_MODE"

  if is_interactive_terminal && { [ -z "$APP_ID" ] || [ -z "$APP_SECRET" ] || [ "$GUIDE_MODE" != "auto" ]; }; then
    show_feishu_setup_guide
    selected_guide_mode="${FEISHU_SELECTED_GUIDE_MODE:-$GUIDE_MODE}"
  else
    selected_guide_mode="$(select_feishu_guide_mode)"
  fi

  if [ "$selected_guide_mode" = "browser" ] && { [ -z "$APP_ID" ] || [ -z "$APP_SECRET" ]; }; then
    if ! run_feishu_web_registration; then
      log_warn "Feishu official registration failed; falling back to manual existing-bot binding."
      selected_guide_mode="manual"
    fi
  fi

  APP_ID="$(prompt_value "Feishu app id" "$APP_ID" 0)"
  APP_SECRET="$(prompt_value "Feishu app secret" "$APP_SECRET" 1)"
  require_value "--app-id" "$APP_ID"
  require_value "--app-secret" "$APP_SECRET"
  if [ "$selected_guide_mode" != "browser" ]; then
    run_feishu_linux_web_auth
  fi

  if ! openclaw plugins enable feishu >/dev/null 2>&1; then
    log_info "Bundled Feishu plugin not available, installing official package @openclaw/feishu"
    openclaw plugins install @openclaw/feishu >/dev/null 2>&1 || \
      log_warn "Official Feishu plugin install returned non-zero; continuing"
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
  openclaw config set channels.feishu.streaming true >/dev/null 2>&1 || log_warn "Failed to set feishu streaming=true"
  openclaw config set channels.feishu.footer.elapsed true >/dev/null 2>&1 || log_warn "Failed to set feishu footer.elapsed=true"
  openclaw config set channels.feishu.footer.status true >/dev/null 2>&1 || log_warn "Failed to set feishu footer.status=true"
  openclaw config set channels.feishu.threadSession true >/dev/null 2>&1 || log_warn "Failed to set feishu threadSession=true"
  restart_gateway

  log_info "Feishu configured"
  printf '  app id: %s\n' "$(mask_value "$APP_ID" 8 4)"
  if [ "$selected_guide_mode" = "browser" ]; then
    show_feishu_registration_post_guide
  else
    show_feishu_post_config_guide
  fi
  run_test_feishu
  auto_approve_first_feishu_dm_user
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
      --auto-approve-first-dm)
        FEISHU_AUTO_APPROVE_FIRST_DM=1
        ;;
      --no-auto-approve-first-dm)
        FEISHU_AUTO_APPROVE_FIRST_DM=0
        ;;
      --auto-approve-timeout)
        FEISHU_AUTO_APPROVE_TIMEOUT_SEC="${2:-}"
        shift
        ;;
      --feishu-web-auth)
        FEISHU_WEB_AUTH_ENABLED=1
        ;;
      --no-feishu-web-auth)
        FEISHU_WEB_AUTH_ENABLED=0
        ;;
      --feishu-web-auth-secret)
        FEISHU_WEB_AUTH_SECRET="${2:-}"
        shift
        ;;
      --feishu-web-auth-port)
        FEISHU_WEB_AUTH_PORT="${2:-}"
        shift
        ;;
      --feishu-web-auth-timeout)
        FEISHU_WEB_AUTH_TIMEOUT_SEC="${2:-}"
        shift
        ;;
      --feishu-web-auth-public-base-url)
        FEISHU_WEB_AUTH_PUBLIC_BASE_URL="${2:-}"
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

  case "$FEISHU_AUTO_APPROVE_TIMEOUT_SEC" in
    ''|*[!0-9]*)
      fail "Unsupported auto-approve timeout: $FEISHU_AUTO_APPROVE_TIMEOUT_SEC"
      ;;
  esac

  case "$FEISHU_WEB_AUTH_TIMEOUT_SEC" in
    ''|*[!0-9]*)
      fail "Unsupported Feishu web auth timeout: $FEISHU_WEB_AUTH_TIMEOUT_SEC"
      ;;
  esac

  case "$FEISHU_WEB_AUTH_PORT" in
    ''|*[!0-9]*)
      fail "Unsupported Feishu web auth port: $FEISHU_WEB_AUTH_PORT"
      ;;
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
