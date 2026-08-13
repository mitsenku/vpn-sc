#!/usr/bin/env bash
# =============================================================================
#  install_direct.sh — Direct (Bare-Metal, Non-Docker) VPS Installer
#  Sets up Xray-core + Cloudflare Tunnel natively as systemd services.
#  Supports: Ubuntu 20.04+, Debian 11+, Rocky/AlmaLinux 8+
#  Usage: sudo bash install_direct.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
banner()  { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${NC}\n"; }

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="$INSTALL_DIR/.credentials"
ENV_FILE="$INSTALL_DIR/.env"

banner "Direct VPS Installer (No Docker Required)"

[[ $EUID -ne 0 ]] && die "Please run as root: sudo bash install_direct.sh"

# ── Detect OS ────────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS_ID="${ID:-unknown}"
else
  die "Cannot detect OS."
fi
info "Detected OS: $PRETTY_NAME"

# ── Install dependencies ─────────────────────────────────────────────────────
banner "Installing System Dependencies"
case "$OS_ID" in
  ubuntu|debian)
    apt-get update -qq
    apt-get install -y -qq curl jq ufw ca-certificates python3 python3-pip qrencode wireguard-tools 2>/dev/null || true
    ;;
  rhel|rocky|almalinux|centos)
    dnf install -y -q curl jq firewalld python3 python3-pip qrencode wireguard-tools 2>/dev/null || true
    ;;
  *)
    apt-get install -y -qq curl jq ufw python3 python3-pip qrencode 2>/dev/null || true
    ;;
esac
success "Dependencies installed"

# ── Interactive Prompts ───────────────────────────────────────────────────────
banner "Configuration"

echo -e "${BOLD}Step 1: Cloudflare Tunnel Token / Quick Tunnel${NC}"
echo "  Options:"
echo "   [1] Use Cloudflare Zero Trust Token (Persistent hostname — Recommended)"
echo "   [2] Use Free Quick Tunnel (trycloudflare.com — No account required)"
read -rp "  Select option [1/2] (default: 1): " TUNNEL_CHOICE
TUNNEL_CHOICE="${TUNNEL_CHOICE:-1}"

if [[ "$TUNNEL_CHOICE" == "1" ]]; then
  while [[ -z "${CF_TUNNEL_TOKEN:-}" ]]; do
    read -rsp "  Paste your Cloudflare Tunnel token: " CF_TUNNEL_TOKEN
    echo ""
    [[ -z "$CF_TUNNEL_TOKEN" ]] && warn "Token cannot be empty."
  done
else
  CF_TUNNEL_TOKEN=""
fi

echo ""
echo -e "${BOLD}Step 2: VPS Public IP${NC}"
AUTO_IP=$(curl -4 -fsSL https://ifconfig.me 2>/dev/null || echo "")
read -rp "  VPS public IP [${AUTO_IP}]: " VPS_IP
VPS_IP="${VPS_IP:-$AUTO_IP}"

echo ""
echo -e "${BOLD}Step 3: REALITY Fallback (direct connection on port 443)${NC}"
read -rp "  Enable REALITY fallback? [Y/n]: " ENABLE_REALITY
ENABLE_REALITY="${ENABLE_REALITY:-Y}"
[[ "$ENABLE_REALITY" =~ ^[Yy] ]] && ENABLE_REALITY=true || ENABLE_REALITY=false

# ── Install Xray-core natively ───────────────────────────────────────────────
banner "Installing Native Xray-core"
info "Downloading latest Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
success "Xray installed: $(xray version | head -n1)"

# ── Install cloudflared natively ─────────────────────────────────────────────
banner "Installing Native cloudflared"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  CF_ARCH="amd64" ;;
  aarch64) CF_ARCH="arm64" ;;
  *)       CF_ARCH="amd64" ;;
esac

if command -v apt-get &>/dev/null; then
  curl -L -o /tmp/cloudflared.deb "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}.deb"
  dpkg -i /tmp/cloudflared.deb
  rm -f /tmp/cloudflared.deb
elif command -v dnf &>/dev/null; then
  curl -L -o /tmp/cloudflared.rpm "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}.rpm"
  dnf localinstall -y /tmp/cloudflared.rpm
  rm -f /tmp/cloudflared.rpm
else
  curl -L -o /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
  chmod +x /usr/local/bin/cloudflared
fi
success "cloudflared installed: $(cloudflared --version)"

# ── Generate Keys ─────────────────────────────────────────────────────────────
banner "Generating Keys"
XRAY_UUID=$(xray uuid)
WS_PATH="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 12)"

if [[ "$ENABLE_REALITY" == "true" ]]; then
  REALITY_KEYS=$(xray x25519)
  REALITY_PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep "Private key" | awk '{print $NF}')
  REALITY_PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep "Public key"  | awk '{print $NF}')
  REALITY_SHORT_ID=$(tr -dc 'a-f0-9' </dev/urandom | head -c 8)
  success "Generated REALITY key pair"
else
  REALITY_PRIVATE_KEY=""
  REALITY_PUBLIC_KEY=""
  REALITY_SHORT_ID=""
fi

# ── Write Xray JSON ───────────────────────────────────────────────────────────
banner "Configuring Xray Service"

REALITY_INBOUND_JSON=""
if [[ "$ENABLE_REALITY" == "true" ]]; then
  REALITY_INBOUND_JSON=",
    {
      \"tag\": \"inbound-reality\",
      \"port\": 443,
      \"listen\": \"0.0.0.0\",
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [
          {
            \"id\": \"${XRAY_UUID}\",
            \"flow\": \"xtls-rprx-vision\",
            \"level\": 0
          }
        ],
        \"decryption\": \"none\"
      },
      \"streamSettings\": {
        \"network\": \"tcp\",
        \"security\": \"reality\",
        \"realitySettings\": {
          \"show\": false,
          \"dest\": \"www.microsoft.com:443\",
          \"xver\": 0,
          \"serverNames\": [\"www.microsoft.com\", \"microsoft.com\"],
          \"privateKey\": \"${REALITY_PRIVATE_KEY}\",
          \"shortIds\": [\"${REALITY_SHORT_ID}\", \"\"]
        }
      },
      \"sniffing\": {
        \"enabled\": true,
        \"destOverride\": [\"http\", \"tls\"]
      }
    }"
fi

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "inbound-ws",
      "port": 8080,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${XRAY_UUID}",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "${WS_PATH}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }${REALITY_INBOUND_JSON}
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "outboundTag": "block",
        "ip": ["geoip:private"]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "network": "tcp,udp"
      }
    ]
  }
}
EOF

systemctl restart xray
systemctl enable xray
success "Xray systemd service configured and running"

# ── Configure cloudflared systemd service ─────────────────────────────────────
banner "Configuring Cloudflare Tunnel Service"

if [[ -n "$CF_TUNNEL_TOKEN" ]]; then
  cloudflared service install "$CF_TUNNEL_TOKEN" 2>/dev/null || true
  systemctl restart cloudflared
  systemctl enable cloudflared
  success "cloudflared Zero Trust Tunnel service running"
else
  # Quick Tunnel (trycloudflare.com)
  cat > /etc/systemd/system/cf-tunnel.service <<EOF
[Unit]
Description=Cloudflare Quick Tunnel
After=network.target xray.service

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:8080
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now cf-tunnel
  success "cloudflared Quick Tunnel service running"
fi

# ── Firewall ──────────────────────────────────────────────────────────────────
banner "Configuring Firewall"
if command -v ufw &>/dev/null; then
  ufw allow ssh
  ufw allow 443/tcp
  ufw --force enable
  success "UFW firewall enabled (Port 22 SSH, Port 443 REALITY)"
elif command -v firewall-cmd &>/dev/null; then
  firewall-cmd --permanent --add-service=ssh
  firewall-cmd --permanent --add-port=443/tcp
  firewall-cmd --reload
  success "firewalld enabled"
fi

# ── Save Credentials ──────────────────────────────────────────────────────────
cat > "$CREDS_FILE" <<EOF
VPS_IP=${VPS_IP}
XRAY_UUID=${XRAY_UUID}
WS_PATH=${WS_PATH}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
REALITY_SHORT_ID=${REALITY_SHORT_ID}
ENABLE_REALITY=${ENABLE_REALITY}
EOF
chmod 600 "$CREDS_FILE"

cat > "$ENV_FILE" <<EOF
CF_TUNNEL_TOKEN=${CF_TUNNEL_TOKEN}
XRAY_UUID=${XRAY_UUID}
WS_PATH=${WS_PATH}
VPS_IP=${VPS_IP}
ENABLE_REALITY=${ENABLE_REALITY}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
REALITY_SHORT_ID=${REALITY_SHORT_ID}
EOF
chmod 600 "$ENV_FILE"

# ── Completion Output ─────────────────────────────────────────────────────────
banner "Installation Complete! (Direct / Non-Docker)"

echo -e "${BOLD}Credentials saved to:${NC} $CREDS_FILE"
echo ""
echo -e "${CYAN}Xray UUID:${NC}       $XRAY_UUID"
echo -e "${CYAN}WebSocket Path:${NC}  $WS_PATH"
if [[ "$ENABLE_REALITY" == "true" ]]; then
  echo -e "${CYAN}REALITY PubKey:${NC}  $REALITY_PUBLIC_KEY"
  echo -e "${CYAN}REALITY ShortID:${NC} $REALITY_SHORT_ID"
fi
echo ""

if [[ -z "$CF_TUNNEL_TOKEN" ]]; then
  echo -e "${YELLOW}Quick Tunnel URL:${NC} Check journalctl to view your trycloudflare.com URL:"
  echo "  sudo journalctl -u cf-tunnel -n 20 --no-pager | grep trycloudflare"
fi

echo ""
echo -e "${BOLD}Generate client configs & QR codes:${NC}"
echo "  cd client && python3 generate_config.py"
echo ""
