#!/usr/bin/env bash
# =============================================================================
#  setup-warp.sh — Generate or refresh Cloudflare WARP WireGuard credentials
#  Standalone use: sudo bash scripts/setup-warp.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$INSTALL_DIR/.env"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
success() { echo -e "${GREEN}[OK]\033[0m    $*"; }
warn()    { echo -e "${YELLOW}[WARN]\033[0m  $*"; }
die()     { echo -e "${RED}[ERROR]\033[0m $*" >&2; exit 1; }

# ── Install wgcf ──────────────────────────────────────────────────────────────
install_wgcf() {
  if command -v wgcf &>/dev/null; then
    info "wgcf already installed at $(which wgcf)"
    return
  fi
  info "Downloading wgcf..."
  LATEST=$(curl -fsSL "https://api.github.com/repos/ViRb3/wgcf/releases/latest" \
    | grep '"tag_name"' | cut -d'"' -f4 2>/dev/null || echo "v2.0.12")
  VER="${LATEST#v}"
  ARCH=$(uname -m)
  [[ "$ARCH" == "aarch64" ]] && BIN_ARCH="arm64" || BIN_ARCH="amd64"
  URL="https://github.com/ViRb3/wgcf/releases/download/${LATEST}/wgcf_${VER}_linux_${BIN_ARCH}"
  curl -fsSL "$URL" -o /usr/local/bin/wgcf
  chmod +x /usr/local/bin/wgcf
  success "wgcf ${LATEST} installed"
}

# ── Generate WARP credentials ─────────────────────────────────────────────────
generate_warp() {
  TMPDIR=$(mktemp -d)
  cd "$TMPDIR"

  info "Registering WARP account..."
  wgcf register --accept-tos -f 2>/dev/null

  info "Generating WireGuard profile..."
  wgcf generate -f 2>/dev/null

  [[ -f wgcf-profile.conf ]] || die "Profile generation failed."

  WARP_PRIVATE_KEY=$(grep "^PrivateKey" wgcf-profile.conf | awk '{print $NF}')
  WARP_ADDRESS=$(grep "^Address"    wgcf-profile.conf | awk '{print $NF}' | cut -d',' -f1)
  # Cloudflare WARP peer public key (this is a well-known stable value)
  WARP_PUBLIC_KEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
  WARP_ENDPOINT="engage.cloudflareclient.com:2408"

  rm -rf "$TMPDIR"
  cd "$INSTALL_DIR"

  success "WARP credentials generated"
  echo "  Private Key : $WARP_PRIVATE_KEY"
  echo "  Address     : $WARP_ADDRESS"
  echo "  Public Key  : $WARP_PUBLIC_KEY"
  echo "  Endpoint    : $WARP_ENDPOINT"
}

# ── Update .env ───────────────────────────────────────────────────────────────
update_env() {
  [[ -f "$ENV_FILE" ]] || die ".env not found. Run install.sh first."

  # Update or append WARP vars
  update_or_append() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$ENV_FILE"; then
      sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    else
      echo "${key}=${val}" >> "$ENV_FILE"
    fi
  }

  update_or_append "ENABLE_WARP"      "true"
  update_or_append "WARP_PRIVATE_KEY" "$WARP_PRIVATE_KEY"
  update_or_append "WARP_ADDRESS"     "$WARP_ADDRESS"
  update_or_append "WARP_PUBLIC_KEY"  "$WARP_PUBLIC_KEY"
  update_or_append "WARP_ENDPOINT"    "$WARP_ENDPOINT"

  success "Updated .env with WARP credentials"
}

# ── Regenerate Xray config and reload ─────────────────────────────────────────
reload_xray() {
  info "Regenerating xray-config.json..."
  bash "$SCRIPT_DIR/generate-xray-config.sh"

  info "Restarting Xray container..."
  cd "$INSTALL_DIR"
  docker compose restart xray
  success "Xray restarted with WARP outbound enabled"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  [[ $EUID -ne 0 ]] && die "Run as root: sudo bash scripts/setup-warp.sh"
  install_wgcf
  generate_warp
  update_env
  reload_xray
  echo ""
  echo -e "${GREEN}Done! WARP outbound is now active.${NC}"
  echo "  AI/streaming traffic (ChatGPT, Netflix, etc.) will route via WARP."
}

main "$@"
