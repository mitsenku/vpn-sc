#!/usr/bin/env bash
# =============================================================================
#  update-geodata.sh — Update Xray geoip.dat and geosite.dat
#  Runs weekly via cron. Safe to run manually at any time.
#  Source: github.com/Loyalsoldier/v2ray-rules-dat (community-maintained)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$INSTALL_DIR/config"
TMP_DIR=$(mktemp -d)

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# GitHub release base URL
REPO="Loyalsoldier/v2ray-rules-dat"
BASE_URL="https://github.com/${REPO}/releases/latest/download"

download_with_verify() {
  local name="$1"
  local url="${BASE_URL}/${name}"
  local sha_url="${url}.sha256sum"
  local dest="${TMP_DIR}/${name}"

  log "Downloading ${name}..."
  curl -fsSL "$url" -o "$dest"

  log "Verifying SHA256 for ${name}..."
  EXPECTED=$(curl -fsSL "$sha_url" | awk '{print $1}')
  ACTUAL=$(sha256sum "$dest" | awk '{print $1}')

  if [[ "$EXPECTED" == "$ACTUAL" ]]; then
    log "${GREEN}SHA256 OK${NC}: $name"
  else
    log "${YELLOW}WARN${NC}: SHA256 mismatch for $name — skipping update"
    return 1
  fi

  mv "$dest" "${CONFIG_DIR}/${name}"
}

reload_xray() {
  cd "$INSTALL_DIR"
  if docker compose ps xray | grep -q "running"; then
    log "Reloading Xray (sending SIGHUP)..."
    docker compose kill -s HUP xray
    log "${GREEN}Xray reloaded with new geo data${NC}"
  else
    log "${YELLOW}Xray not running — skipping reload${NC}"
  fi
}

cleanup() {
  rm -rf "$TMP_DIR"
}

main() {
  trap cleanup EXIT
  mkdir -p "$CONFIG_DIR"

  log "Starting geodata update..."
  UPDATED=0

  if download_with_verify "geoip.dat";   then UPDATED=$((UPDATED+1)); fi
  if download_with_verify "geosite.dat"; then UPDATED=$((UPDATED+1)); fi

  if [[ $UPDATED -gt 0 ]]; then
    reload_xray
    log "Update complete. $UPDATED file(s) updated."
  else
    log "No files updated (verification failed or no changes)."
  fi
}

main "$@"
