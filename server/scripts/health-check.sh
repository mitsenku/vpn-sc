#!/usr/bin/env bash
# =============================================================================
#  health-check.sh — Proxy stack health monitor
#  Checks containers, connectivity, and optionally alerts via Telegram/Discord.
#  Cron: */5 * * * * root bash /path/to/health-check.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$INSTALL_DIR/.env"

# ── Optional alerting (set these to enable notifications) ─────────────────────
# Telegram: set BOT_TOKEN and CHAT_ID
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Discord: set DISCORD_WEBHOOK_URL
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

# ── State ─────────────────────────────────────────────────────────────────────
ALERT_FLAG="/tmp/.proxy-health-alerted"
FAILED=0
MESSAGES=()

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── Alert helpers ─────────────────────────────────────────────────────────────
send_telegram() {
  [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return
  curl -fsSL -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="$TELEGRAM_CHAT_ID" \
    -d text="🔴 *Proxy Alert*: $1" \
    -d parse_mode="Markdown" > /dev/null 2>&1 || true
}

send_discord() {
  [[ -z "$DISCORD_WEBHOOK_URL" ]] && return
  curl -fsSL -X POST "$DISCORD_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "{\"content\": \"🔴 **Proxy Alert**: $1\"}" > /dev/null 2>&1 || true
}

alert() {
  local msg="$1"
  # Only alert once per failure cycle (prevent spam)
  if [[ ! -f "$ALERT_FLAG" ]]; then
    send_telegram "$msg"
    send_discord "$msg"
    touch "$ALERT_FLAG"
  fi
}

# ── Checks ────────────────────────────────────────────────────────────────────
check_container() {
  local name="$1"
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
    log "FAIL: Container '$name' is not running"
    MESSAGES+=("Container '$name' is down")
    FAILED=$((FAILED+1))
    # Try to restart
    cd "$INSTALL_DIR"
    docker compose --env-file "$ENV_FILE" up -d "$name" 2>/dev/null || true
    log "INFO: Attempted restart of '$name'"
  else
    log "OK:   Container '$name' is running"
  fi
}

check_port() {
  local port="$1" desc="$2"
  if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
    log "OK:   Port ${port} (${desc}) is listening"
  else
    log "FAIL: Port ${port} (${desc}) is not listening"
    MESSAGES+=("Port $port ($desc) not listening")
    FAILED=$((FAILED+1))
  fi
}

check_xray_ws() {
  # Test WS inbound responds (via local curl to loopback)
  if curl -fsSL --max-time 5 \
      -H "Upgrade: websocket" \
      -H "Connection: Upgrade" \
      "http://127.0.0.1:8080${WS_PATH:-/healthz}" > /dev/null 2>&1; then
    log "OK:   Xray WebSocket inbound responding"
  else
    # A 400 response is actually OK — means Xray got the request
    HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 \
      "http://127.0.0.1:8080/" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" != "000" ]]; then
      log "OK:   Xray WS inbound reachable (HTTP $HTTP_CODE)"
    else
      log "FAIL: Xray WebSocket inbound not reachable on 127.0.0.1:8080"
      MESSAGES+=("Xray WS inbound unreachable")
      FAILED=$((FAILED+1))
    fi
  fi
}

check_outbound() {
  # Quick connectivity test — does the proxy reach the internet?
  OUTBOUND_IP=$(docker exec xray-proxy sh -c \
    'curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null' 2>/dev/null || echo "")
  if [[ -n "$OUTBOUND_IP" ]]; then
    log "OK:   Outbound internet reachable (exit IP: $OUTBOUND_IP)"
  else
    log "WARN: Could not verify outbound internet from Xray container"
  fi
}

check_disk() {
  DISK_USE=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
  if [[ "$DISK_USE" -gt 85 ]]; then
    log "WARN: Disk usage at ${DISK_USE}%"
    MESSAGES+=("Disk usage critical: ${DISK_USE}%")
    FAILED=$((FAILED+1))
  else
    log "OK:   Disk usage: ${DISK_USE}%"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || true

  log "--- Health check start ---"
  check_container "xray-proxy"
  check_container "cf-tunnel"
  check_port "8080" "Xray WS"
  check_xray_ws
  check_outbound
  check_disk

  if [[ $FAILED -gt 0 ]]; then
    MSG="$(IFS=', '; echo "${MESSAGES[*]}")"
    log "RESULT: $FAILED check(s) failed — $MSG"
    alert "$MSG"
    exit 1
  else
    log "RESULT: All checks passed"
    # Clear alert flag if previously set
    rm -f "$ALERT_FLAG"
    exit 0
  fi
}

main "$@"
