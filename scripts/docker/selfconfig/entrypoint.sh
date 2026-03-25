#!/usr/bin/env bash
# Self-configuring container entrypoint.
# Consolidates initialization logic that setup.sh previously ran from the host
# into a single script that executes inside the container at startup.
#
# Lifecycle:
#   1. Fix data-directory ownership (as root, via gosu/su-exec)
#   2. Detect or generate gateway token
#   3. Pin gateway.mode and gateway.bind in config
#   4. Set Control UI allowed origins for non-loopback bind
#   5. Apply sandbox config (if OPENCLAW_SANDBOX=1)
#   6. Drop to non-root user and exec the gateway process
#
# Environment variables (all optional, sane defaults provided):
#   OPENCLAW_GATEWAY_TOKEN   - Pre-shared auth token; auto-generated if absent
#   OPENCLAW_GATEWAY_BIND    - "loopback" | "lan" (default: lan)
#   OPENCLAW_GATEWAY_PORT    - Host-facing port (default: 18789)
#   OPENCLAW_SANDBOX         - "1" to enable sandbox isolation
#   OPENCLAW_SKIP_ONBOARD    - "1" to skip interactive onboarding
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

# Read gateway token from persisted config (openclaw.json).
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

# ── Phase 1: Fix data-directory permissions ─────────────────────
fix_permissions() {
  if [[ "$(id -u)" == "0" ]]; then
    log "Fixing data-directory permissions (running as root)"
    # -xdev avoids crossing into the workspace bind mount
    find "${OPENCLAW_CONFIG_DIR}" -xdev -exec chown node:node {} + 2>/dev/null || true
    if [[ -d "${OPENCLAW_CONFIG_DIR}/workspace/.openclaw" ]]; then
      chown -R node:node "${OPENCLAW_CONFIG_DIR}/workspace/.openclaw" 2>/dev/null || true
    fi
    # Ensure base directories exist and are owned by node
    for dir in \
      "${OPENCLAW_CONFIG_DIR}" \
      "${OPENCLAW_CONFIG_DIR}/identity" \
      "${OPENCLAW_CONFIG_DIR}/agents/main/agent" \
      "${OPENCLAW_CONFIG_DIR}/agents/main/sessions"; do
      mkdir -p "$dir"
      chown node:node "$dir"
    done
  fi
}

# ── Phase 2: Resolve gateway token ──────────────────────────────
resolve_token() {
  if [[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    log "Using gateway token from environment"
    return
  fi
  local existing
  existing="$(read_config_token)"
  if [[ -n "$existing" ]]; then
    export OPENCLAW_GATEWAY_TOKEN="$existing"
    log "Reusing gateway token from ${OPENCLAW_CONFIG_DIR}/openclaw.json"
    return
  fi
  # Generate a new random token
  if command -v openssl >/dev/null 2>&1; then
    export OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
  else
    export OPENCLAW_GATEWAY_TOKEN="$(node -e "process.stdout.write(require('node:crypto').randomBytes(32).toString('hex'))")"
  fi
  log "Generated new gateway token"
}

# ── Phase 3: Pin gateway config ─────────────────────────────────
sync_gateway_config() {
  log "Pinning gateway.mode=local, gateway.bind=${OPENCLAW_GATEWAY_BIND}"
  "${CLI_CMD[@]}" config set gateway.mode local >/dev/null 2>&1 || true
  "${CLI_CMD[@]}" config set gateway.bind "$OPENCLAW_GATEWAY_BIND" >/dev/null 2>&1 || true
}

# ── Phase 4: Control UI allowed origins ─────────────────────────
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

# ── Phase 5: Sandbox config (opt-in) ───────────────────────────
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

# ── Phase 6: Optional onboarding ────────────────────────────────
run_onboarding() {
  if is_truthy "${OPENCLAW_SKIP_ONBOARD}"; then
    log "Skipping onboarding (OPENCLAW_SKIP_ONBOARD=1)"
    return
  fi
  log "Running onboarding (non-interactive)"
  "${CLI_CMD[@]}" onboard --mode local --no-install-daemon 2>&1 || true
}

# ── Orchestration ───────────────────────────────────────────────
main() {
  log "Initializing self-configuring container"

  fix_permissions
  resolve_token

  # If running as root, drop to node for config/gateway operations
  if [[ "$(id -u)" == "0" ]]; then
    log "Dropping privileges to user 'node' for config and gateway"
    # Re-exec this script as node user, preserving env
    exec gosu node "$0" "$@"
  fi

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

# Allow overriding the entrypoint entirely (e.g. docker run ... /bin/bash)
if [[ "${1:-}" == "gateway" || -z "${1:-}" ]]; then
  main "$@"
else
  exec "$@"
fi
