#!/usr/bin/env bash
# Self-configuring container entrypoint.
#
# ROOT phase:  chown + gosu drop
# NODE phase:  configure + start gateway
set -euo pipefail

OPENCLAW_HOME="${HOME:-/home/node}"
OPENCLAW_CONFIG_DIR="${OPENCLAW_HOME}/.openclaw"
OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
OPENCLAW_GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-lan}"
OPENCLAW_SANDBOX="${OPENCLAW_SANDBOX:-}"
OPENCLAW_SKIP_ONBOARD="${OPENCLAW_SKIP_ONBOARD:-}"

CLI_CMD=(node dist/index.js)

log() { printf '[entrypoint] %s\n' "$*"; }

is_truthy() {
  local v="${1:-}"
  v="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

read_config_token() {
  local config_path="${OPENCLAW_CONFIG_DIR}/openclaw.json"
  [[ -f "$config_path" ]] || return 0
  node -e "
    const fs = require('node:fs');
    try {
      const cfg = JSON.parse(fs.readFileSync('${config_path}', 'utf8'));
      const t = cfg?.gateway?.auth?.token;
      if (typeof t === 'string' && t.trim()) process.stdout.write(t.trim());
    } catch {}
  " 2>/dev/null || true
}

# ── ROOT phase ──────────────────────────────────────────────────
run_root_phase() {
  log "Fixing permissions on ${OPENCLAW_CONFIG_DIR}"
  chown -R node:node "${OPENCLAW_CONFIG_DIR}"
  log "Done. Dropping to user 'node'"
  export ENTRYPOINT_PHASE=node
  exec gosu node "$0" "$@"
}

# ── NODE phase ──────────────────────────────────────────────────

resolve_token() {
  if [[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    log "Using gateway token from environment"
    return
  fi
  local existing
  existing="$(read_config_token)"
  if [[ -n "$existing" ]]; then
    export OPENCLAW_GATEWAY_TOKEN="$existing"
    log "Reusing gateway token from config"
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    export OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
  else
    export OPENCLAW_GATEWAY_TOKEN="$(node -e "process.stdout.write(require('node:crypto').randomBytes(32).toString('hex'))")"
  fi
  log "Generated new gateway token"
}

run_onboarding() {
  if is_truthy "${OPENCLAW_SKIP_ONBOARD}"; then
    log "Skipping onboarding (OPENCLAW_SKIP_ONBOARD=1)"
    return
  fi
  log "Running onboarding (non-interactive)"
  "${CLI_CMD[@]}" onboard \
    --non-interactive \
    --accept-risk \
    --mode local \
    --no-install-daemon \
    --skip-channels \
    --skip-skills \
    --skip-search \
    --skip-health \
    --skip-ui \
    2>&1 || log "WARNING: onboarding exited non-zero (non-fatal)"
}

sync_gateway_config() {
  log "Pinning gateway.mode=local, gateway.bind=${OPENCLAW_GATEWAY_BIND}"
  "${CLI_CMD[@]}" config set gateway.mode local >/dev/null 2>&1 || true
  "${CLI_CMD[@]}" config set gateway.bind "$OPENCLAW_GATEWAY_BIND" >/dev/null 2>&1 || true
}

ensure_control_ui_origins() {
  if [[ "$OPENCLAW_GATEWAY_BIND" == "loopback" ]]; then
    return
  fi
  local current
  current="$("${CLI_CMD[@]}" config get gateway.controlUi.allowedOrigins 2>/dev/null || true)"
  current="${current//$'\r'/}"
  if [[ -n "$current" && "$current" != "null" && "$current" != "[]" ]]; then
    log "Control UI allowlist already configured"
    return
  fi
  local origins
  origins="$(printf '["http://localhost:%s","http://127.0.0.1:%s"]' "$OPENCLAW_GATEWAY_PORT" "$OPENCLAW_GATEWAY_PORT")"
  "${CLI_CMD[@]}" config set gateway.controlUi.allowedOrigins "$origins" --strict-json >/dev/null 2>&1 || true
  log "Set control UI allowedOrigins to ${origins}"
}

apply_sandbox_config() {
  if ! is_truthy "${OPENCLAW_SANDBOX}"; then
    "${CLI_CMD[@]}" config set agents.defaults.sandbox.mode "off" >/dev/null 2>&1 || true
    return
  fi
  if ! command -v docker >/dev/null 2>&1; then
    log "WARNING: Sandbox requested but Docker CLI not found in image"
    "${CLI_CMD[@]}" config set agents.defaults.sandbox.mode "off" >/dev/null 2>&1 || true
    return
  fi
  if [[ ! -S /var/run/docker.sock ]]; then
    log "WARNING: Sandbox requested but Docker socket not mounted"
    "${CLI_CMD[@]}" config set agents.defaults.sandbox.mode "off" >/dev/null 2>&1 || true
    return
  fi
  log "Enabling sandbox: mode=non-main, scope=agent, workspaceAccess=none"
  "${CLI_CMD[@]}" config set agents.defaults.sandbox.mode "non-main" >/dev/null 2>&1 || true
  "${CLI_CMD[@]}" config set agents.defaults.sandbox.scope "agent" >/dev/null 2>&1 || true
  "${CLI_CMD[@]}" config set agents.defaults.sandbox.workspaceAccess "none" >/dev/null 2>&1 || true
}

run_node_phase() {
  log "Configuring as user '$(whoami)'"
  resolve_token
  run_onboarding
  sync_gateway_config
  ensure_control_ui_origins
  apply_sandbox_config

  log "Starting gateway on bind=${OPENCLAW_GATEWAY_BIND}, port=18789"
  log "Token: ${OPENCLAW_GATEWAY_TOKEN}"

  exec node dist/index.js gateway \
    --bind "$OPENCLAW_GATEWAY_BIND" \
    --port 18789 \
    --allow-unconfigured
}

# ── Orchestration ───────────────────────────────────────────────
main() {
  # ENTRYPOINT_PHASE=node means gosu already dropped privileges
  if [[ "${ENTRYPOINT_PHASE:-}" == "node" ]]; then
    run_node_phase
    return
  fi

  log "Initializing self-configuring container"

  if [[ "$(id -u)" == "0" ]]; then
    run_root_phase "$@"
  fi

  run_node_phase
}

if [[ "${1:-}" == "gateway" || -z "${1:-}" ]]; then
  main "$@"
else
  exec "$@"
fi
