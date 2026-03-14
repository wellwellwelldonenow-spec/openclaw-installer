#!/usr/bin/env bash

set -euo pipefail

if ! command -v openclaw >/dev/null 2>&1; then
  echo "openclaw not found in PATH" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node not found in PATH" >&2
  exit 1
fi

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

config_path="$(normalize_config_path "$(openclaw config file 2>/dev/null || true)" 2>/dev/null || true)"
[ -n "$config_path" ] || config_path="$HOME/.openclaw/openclaw.json"

case "$config_path" in
  "~/"*) config_path="$HOME/${config_path#\~/}" ;;
  '$HOME/'*) config_path="$HOME/${config_path#\$HOME/}" ;;
esac

state_dir="$(dirname "$config_path")"
approvals_path="$state_dir/exec-approvals.json"

mkdir -p "$state_dir"

node - "$config_path" <<'NODE'
const fs = require('fs');

const configPath = process.argv[2];
let config = {};

if (fs.existsSync(configPath)) {
  const raw = fs.readFileSync(configPath, 'utf8').trim();
  if (raw) {
    config = JSON.parse(raw);
  }
}

config.tools = config.tools || {};
delete config.tools.allow;
delete config.tools.alsoAllow;
config.tools.deny = [];
config.tools.exec = {
  ...(config.tools.exec || {}),
  host: 'gateway',
  security: 'full',
  ask: 'off',
};
config.tools.elevated = {
  ...(config.tools.elevated || {}),
  enabled: true,
  allowFrom: {
    ...((config.tools.elevated && typeof config.tools.elevated.allowFrom === 'object' && config.tools.elevated.allowFrom) || {}),
    feishu: ['*'],
  },
};

config.gateway = config.gateway || {};
config.gateway.tools = config.gateway.tools && typeof config.gateway.tools === 'object' ? config.gateway.tools : {};
delete config.gateway.tools.allow;
delete config.gateway.tools.deny;

fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
NODE

node - "$approvals_path" "$state_dir" <<'NODE'
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const approvalsPath = process.argv[2];
const stateDir = process.argv[3];
let approvals = {};

if (fs.existsSync(approvalsPath)) {
  const raw = fs.readFileSync(approvalsPath, 'utf8').trim();
  if (raw) {
    approvals = JSON.parse(raw);
  }
}

approvals.version = 1;
approvals.socket = approvals.socket && typeof approvals.socket === 'object' ? approvals.socket : {};
if (typeof approvals.socket.path !== 'string' || !approvals.socket.path.trim()) {
  approvals.socket.path = path.join(stateDir, 'exec-approvals.sock');
}
if (typeof approvals.socket.token !== 'string' || !approvals.socket.token.trim()) {
  approvals.socket.token = crypto.randomBytes(24).toString('base64url');
}
approvals.defaults = {
  ...(approvals.defaults && typeof approvals.defaults === 'object' ? approvals.defaults : {}),
  security: 'full',
  ask: 'off',
  askFallback: 'full',
  autoAllowSkills: true,
};
approvals.agents = approvals.agents && typeof approvals.agents === 'object' ? approvals.agents : {};

fs.writeFileSync(approvalsPath, JSON.stringify(approvals, null, 2) + '\n');
NODE

openclaw config validate >/dev/null
openclaw gateway restart >/dev/null 2>&1 || openclaw gateway start >/dev/null 2>&1 || true

echo "OpenClaw permissions unlocked"
echo "Config: $config_path"
echo "Exec approvals: $approvals_path"
