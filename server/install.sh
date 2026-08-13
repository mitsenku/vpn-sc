#!/usr/bin/env bash
# =============================================================================
#  install.sh — One-command VPS installer for Cloudflare Tunnel + Xray proxy
#  Supports: Ubuntu 20.04+, Debian 11+, Rocky/AlmaLinux 8+
#  Usage:  curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash
#          — or — ./install.sh
# =============================================================================
set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
banner()  { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${NC}\n"; }

# ── Paths ─────────────────────────────────────────────────────────────────────
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$INSTALL_DIR/config"
SCRIPTS_DIR="$INSTALL_DIR/scripts"
CREDS_FILE="$INSTALL_DIR/.credentials"
ENV_FILE="$INSTALL_DIR/.env"

# =============================================================================
banner "Cloudflare Tunnel + Xray Proxy Installer"
# =============================================================================

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Please run as root: sudo bash install.sh"

# ── Detect OS ────────────────────────────────────────────────────────────────
detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-0}"
  else
    die "Cannot detect OS. /etc/os-release not found."
  fi
  info "Detected OS: $PRETTY_NAME"
}

# ── Install system packages ───────────────────────────────────────────────────
install_deps() {
  banner "Installing Dependencies"
  case "$OS_ID" in
    ubuntu|debian)
      apt-get update -qq
      apt-get install -y -qq curl jq ufw ca-certificates gnupg lsb-release \
        python3 python3-pip qrencode 2>/dev/null || true
      ;;
    rhel|rocky|almalinux|centos)
      dnf install -y -q curl jq firewalld python3 python3-pip qrencode 2>/dev/null || true
      ;;
    *)
      warn "Unknown OS '$OS_ID'. Attempting to install deps with apt-get..."
      apt-get install -y -qq curl jq ufw python3 python3-pip qrencode 2>/dev/null || true
      ;;
  esac
  success "System packages installed"
}

# ── Install Docker ─────────────────────────────────────────────────────────────
install_docker() {
  if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
    success "Docker + Compose already installed ($(docker --version | cut -d' ' -f3 | tr -d ','))"
    return
  fi
  banner "Installing Docker"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  success "Docker installed"
}

# ── Interactive prompts ────────────────────────────────────────────────────────
collect_config() {
  banner "Configuration"

  echo -e "${BOLD}Step 1: Cloudflare Tunnel Token${NC}"
  echo "  → Go to: https://one.dash.cloudflare.com"
  echo "  → Networks > Tunnels > Create a tunnel > Cloudflared"
  echo "  → Name your tunnel (e.g. 'college-proxy')"
  echo "  → Copy the token string (starts with eyJ...)"
  echo ""
  while [[ -z "${CF_TUNNEL_TOKEN:-}" ]]; do
    read -rsp "  Paste your Cloudflare Tunnel token: " CF_TUNNEL_TOKEN
    echo ""
    [[ -z "$CF_TUNNEL_TOKEN" ]] && warn "Token cannot be empty."
  done
  success "Tunnel token received"

  echo ""
  echo -e "${BOLD}Step 2: VPS Public IP${NC}"
  AUTO_IP=$(curl -4 -fsSL https://ifconfig.me 2>/dev/null || echo "")
  if [[ -n "$AUTO_IP" ]]; then
    read -rp "  VPS public IP [$AUTO_IP]: " VPS_IP
    VPS_IP="${VPS_IP:-$AUTO_IP}"
  else
    read -rp "  VPS public IP: " VPS_IP
  fi
  success "VPS IP: $VPS_IP"

  echo ""
  echo -e "${BOLD}Step 3: REALITY Fallback${NC}"
  echo "  REALITY allows a direct connection that mimics HTTPS to Microsoft."
  echo "  Recommended: yes (adds a direct fast fallback if CDN is slow)"
  read -rp "  Enable REALITY fallback? [Y/n]: " ENABLE_REALITY
  ENABLE_REALITY="${ENABLE_REALITY:-Y}"
  [[ "$ENABLE_REALITY" =~ ^[Yy] ]] && ENABLE_REALITY=true || ENABLE_REALITY=false

  echo ""
  echo -e "${BOLD}Step 4: WARP Outbound (for ChatGPT / Netflix / blocked AI sites)${NC}"
  echo "  Routes AI/streaming traffic through Cloudflare WARP for a clean IP."
  read -rp "  Enable Cloudflare WARP outbound? [Y/n]: " ENABLE_WARP
  ENABLE_WARP="${ENABLE_WARP:-Y}"
  [[ "$ENABLE_WARP" =~ ^[Yy] ]] && ENABLE_WARP=true || ENABLE_WARP=false
}

# ── Generate crypto material ──────────────────────────────────────────────────
generate_keys() {
  banner "Generating Cryptographic Keys"

  # Pull Xray image to use its keygen commands
  info "Pulling teddysun/xray image for key generation..."
  docker pull -q teddysun/xray:latest

  # UUID
  XRAY_UUID=$(docker run --rm teddysun/xray:latest xray uuid 2>/dev/null)
  success "Generated UUID: $XRAY_UUID"

  # Random WebSocket path
  WS_PATH="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 12)"
  success "Generated WS path: $WS_PATH"

  # REALITY keys (if enabled)
  if [[ "$ENABLE_REALITY" == true ]]; then
    REALITY_KEYS=$(docker run --rm teddysun/xray:latest xray x25519 2>/dev/null)
    REALITY_PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep "Private key" | awk '{print $NF}')
    REALITY_PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep "Public key"  | awk '{print $NF}')
    REALITY_SHORT_ID=$(tr -dc 'a-f0-9' </dev/urandom | head -c 8)
    success "Generated REALITY key pair"
    success "Generated REALITY short ID: $REALITY_SHORT_ID"
  else
    REALITY_PRIVATE_KEY=""
    REALITY_PUBLIC_KEY=""
    REALITY_SHORT_ID=""
  fi
}

# ── Setup WARP ─────────────────────────────────────────────────────────────────
setup_warp() {
  [[ "$ENABLE_WARP" != true ]] && return

  banner "Setting Up Cloudflare WARP Outbound"

  if ! command -v wgcf &>/dev/null; then
    info "Downloading wgcf..."
    WGCF_VERSION=$(curl -fsSL "https://api.github.com/repos/ViRb3/wgcf/releases/latest" | \
      jq -r '.tag_name' 2>/dev/null || echo "v2.0.12")
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64)  WGCF_ARCH="amd64" ;;
      aarch64) WGCF_ARCH="arm64" ;;
      *)        WGCF_ARCH="amd64" ;;
    esac
    curl -fsSL "https://github.com/ViRb3/wgcf/releases/download/${WGCF_VERSION}/wgcf_${WGCF_VERSION#v}_linux_${WGCF_ARCH}" \
      -o /usr/local/bin/wgcf
    chmod +x /usr/local/bin/wgcf
  fi

  cd /tmp
  wgcf register --accept-tos -f 2>/dev/null || true
  wgcf generate -f 2>/dev/null || true

  if [[ -f /tmp/wgcf-profile.conf ]]; then
    WARP_PRIVATE_KEY=$(grep "PrivateKey" /tmp/wgcf-profile.conf | awk '{print $NF}')
    WARP_ADDRESS=$(grep "^Address"    /tmp/wgcf-profile.conf | awk '{print $NF}' | cut -d',' -f1)
    WARP_PUBLIC_KEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="  # Cloudflare WARP public key (stable)
    WARP_ENDPOINT="engage.cloudflareclient.com:2408"
    rm -f /tmp/wgcf-profile.conf /tmp/wgcf-account.toml
    success "WARP credentials generated"
  else
    warn "wgcf profile generation failed. Disabling WARP outbound."
    ENABLE_WARP=false
    WARP_PRIVATE_KEY=""; WARP_ADDRESS=""; WARP_PUBLIC_KEY=""; WARP_ENDPOINT=""
  fi
  cd "$INSTALL_DIR"
}

# ── Write config files ────────────────────────────────────────────────────────
write_configs() {
  banner "Writing Configuration Files"
  mkdir -p "$CONFIG_DIR"

  # ── .env ──────────────────────────────────────────────────────────────────
  cat > "$ENV_FILE" <<EOF
CF_TUNNEL_TOKEN=${CF_TUNNEL_TOKEN}
XRAY_UUID=${XRAY_UUID}
WS_PATH=${WS_PATH}
VPS_IP=${VPS_IP}
ENABLE_REALITY=${ENABLE_REALITY}
REALITY_PRIVATE_KEY=${REALITY_PRIVATE_KEY}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
REALITY_SHORT_ID=${REALITY_SHORT_ID}
ENABLE_WARP=${ENABLE_WARP}
WARP_PRIVATE_KEY=${WARP_PRIVATE_KEY:-}
WARP_ADDRESS=${WARP_ADDRESS:-172.16.0.2/32}
WARP_PUBLIC_KEY=${WARP_PUBLIC_KEY:-}
WARP_ENDPOINT=${WARP_ENDPOINT:-engage.cloudflareclient.com:2408}
EOF
  chmod 600 "$ENV_FILE"
  success "Written: .env"

  # ── .credentials (human-readable summary) ────────────────────────────────
  cat > "$CREDS_FILE" <<EOF
# ============================================================
#  Generated by install.sh on $(date -u '+%Y-%m-%d %H:%M UTC')
#  KEEP THIS FILE PRIVATE — chmod 600 .credentials
# ============================================================

VPS_IP=${VPS_IP}
XRAY_UUID=${XRAY_UUID}
WS_PATH=${WS_PATH}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
REALITY_SHORT_ID=${REALITY_SHORT_ID}
ENABLE_REALITY=${ENABLE_REALITY}
ENABLE_WARP=${ENABLE_WARP}

# Client connection URIs (also see client/ directory)
# -- Tunnel (primary) --
VLESS_TUNNEL_URI=vless://${XRAY_UUID}@TUNNEL_HOSTNAME:443?type=ws&security=tls&path=${WS_PATH}&host=TUNNEL_HOSTNAME&sni=TUNNEL_HOSTNAME#CF-Tunnel

# -- REALITY (fallback) --
VLESS_REALITY_URI=vless://${XRAY_UUID}@${VPS_IP}:443?type=tcp&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}#Direct-Reality
EOF
  chmod 600 "$CREDS_FILE"
  success "Written: .credentials"

  # ── xray-config.json ──────────────────────────────────────────────────────
  "$SCRIPTS_DIR/generate-xray-config.sh"
  success "Written: config/xray-config.json"
}

# ── Configure firewall ─────────────────────────────────────────────────────────
configure_firewall() {
  banner "Configuring Firewall"
  if command -v ufw &>/dev/null; then
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow 443/tcp    # REALITY fallback
    ufw allow 2408/udp   # WARP WireGuard
    # Do NOT expose port 8080 — it's loopback only, reached via cloudflared
    ufw --force enable
    success "UFW configured (SSH + 443/tcp + 2408/udp)"
  elif command -v firewall-cmd &>/dev/null; then
    systemctl enable --now firewalld
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --permanent --add-port=443/tcp
    firewall-cmd --permanent --add-port=2408/udp
    firewall-cmd --reload
    success "firewalld configured"
  else
    warn "No firewall found. Manually restrict ports if needed."
  fi
}

# ── Pull images and start stack ────────────────────────────────────────────────
start_stack() {
  banner "Starting Docker Stack"
  cd "$INSTALL_DIR"
  docker compose --env-file "$ENV_FILE" pull -q
  docker compose --env-file "$ENV_FILE" up -d
  sleep 5
  docker compose ps
  success "Stack started"
}

# ── Print client URIs and QR codes ────────────────────────────────────────────
print_client_info() {
  banner "Setup Complete!"
  source "$ENV_FILE"

  # Get tunnel hostname from cloudflared (if named tunnel, user must configure it in dashboard)
  TUNNEL_HOST="YOUR_TUNNEL.trycloudflare.com"
  TUNNEL_URI="vless://${XRAY_UUID}@${TUNNEL_HOST}:443?type=ws&security=tls&path=${WS_PATH}&host=${TUNNEL_HOST}&sni=${TUNNEL_HOST}#CF-Tunnel"
  REALITY_URI="vless://${XRAY_UUID}@${VPS_IP}:443?type=tcp&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}#Direct-Reality"

  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  CLIENT CONFIGURATION${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "${BOLD}⚠  IMPORTANT: Complete Tunnel setup in Cloudflare dashboard first!${NC}"
  echo "   Networks → Tunnels → [your tunnel] → Public Hostnames"
  echo "   Add hostname: your-subdomain.yourdomain.com → http://xray:8080"
  echo "   Then update TUNNEL_HOST above with your actual hostname."
  echo ""
  echo -e "${CYAN}[1] Cloudflare Tunnel (Primary — port 443 HTTPS):${NC}"
  echo "    $TUNNEL_URI"
  echo ""

  if [[ "$ENABLE_REALITY" == "true" ]]; then
    echo -e "${CYAN}[2] REALITY Direct (Fallback — direct to VPS port 443):${NC}"
    echo "    $REALITY_URI"
    echo ""
    if command -v qrencode &>/dev/null; then
      echo -e "${BOLD}REALITY QR Code:${NC}"
      qrencode -t ANSIUTF8 "$REALITY_URI"
    fi
  fi

  echo ""
  echo -e "${BOLD}📁 Credentials saved to:${NC} $CREDS_FILE"
  echo -e "${BOLD}🔧 Run client config generator:${NC}"
  echo "   cd ../client && python3 generate_config.py"
  echo ""
  echo -e "${YELLOW}Next steps:${NC}"
  echo "  1. Finish Cloudflare Tunnel public hostname config in dashboard"
  echo "  2. Enable WebSocket support in Cloudflare dashboard (Network tab)"
  echo "  3. Set SSL/TLS mode to 'Full' in Cloudflare dashboard"
  echo "  4. Import connection URI into Hiddify / v2rayN"
  echo "  5. Enable TUN mode in your client app"
  echo "  6. Run ./scripts/harden.sh to harden this VPS"
  echo ""
}

# ── Install weekly geodata cron ────────────────────────────────────────────────
install_cron() {
  CRON_CMD="0 3 * * 1 root bash $SCRIPTS_DIR/update-geodata.sh >> /var/log/xray-geodata.log 2>&1"
  CRON_FILE="/etc/cron.d/xray-geodata"
  echo "$CRON_CMD" > "$CRON_FILE"
  chmod 644 "$CRON_FILE"
  success "Weekly geodata update cron installed ($CRON_FILE)"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  detect_os
  install_deps
  install_docker
  collect_config
  generate_keys
  setup_warp
  write_configs
  configure_firewall
  start_stack
  install_cron
  print_client_info
}

main "$@"
