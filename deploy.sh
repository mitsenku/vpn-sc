#!/usr/bin/env bash
# =============================================================================
#  deploy.sh — All-In-One Single Script VPS Proxy Deployment (No Docker)
#
#  Features:
#    - VLESS + WebSocket over Cloudflare Tunnel (primary — hides VPS IP)
#    - VLESS + REALITY (fallback — direct, fast, port 443, mimics Microsoft)
#    - Zero dependencies required on host (installs Xray, cloudflared, qrencode)
#    - Prints ready-to-use vless:// links & terminal QR codes immediately
#
#  Usage (on fresh VPS as root):
#    sudo bash deploy.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
banner()  { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${NC}\n"; }

# ── Root Check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Please run as root: sudo bash deploy.sh"

banner "All-In-One VPS Proxy Installer (Direct / Bare-Metal)"

# ── 1. Detect OS ──────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS_ID="${ID:-unknown}"
else
  die "Cannot detect OS."
fi
info "OS Detected: $PRETTY_NAME"

# ── 2. Install Package Dependencies ───────────────────────────────────────────
banner "Step 1/5: Installing Dependencies"
case "$OS_ID" in
  ubuntu|debian)
    apt-get update -qq
    apt-get install -y -qq curl jq ufw ca-certificates qrencode 2>/dev/null || true
    ;;
  rhel|rocky|almalinux|centos)
    dnf install -y -q curl jq firewalld qrencode 2>/dev/null || true
    ;;
  *)
    apt-get install -y -qq curl jq ufw qrencode 2>/dev/null || true
    ;;
esac
success "Dependencies installed"

# ── 3. Install Xray Native ────────────────────────────────────────────────────
banner "Step 2/5: Installing Native Xray-core"
if ! command -v xray &>/dev/null; then
  info "Downloading Xray-core..."
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
else
  info "Xray is already installed: $(xray version | head -n1)"
fi
success "Xray core active"

# ── 4. Install Cloudflared Native ─────────────────────────────────────────────
banner "Step 3/5: Installing Cloudflared"
if ! command -v cloudflared &>/dev/null; then
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
else
  info "cloudflared is already installed: $(cloudflared --version)"
fi
success "cloudflared active"

# ── 5. User Input ─────────────────────────────────────────────────────────────
banner "Step 4/5: Configuration Prompts"

echo -e "${BOLD}Select Cloudflare Tunnel Mode:${NC}"
echo "  [1] Cloudflare Zero Trust Token (Persistent domain/subdomain — Recommended)"
echo "  [2] Free Quick Tunnel (trycloudflare.com — No Cloudflare account needed)"
read -rp "  Option [1/2] (default: 1): " TUNNEL_MODE
TUNNEL_MODE="${TUNNEL_MODE:-1}"

CF_TOKEN=""
CF_HOST=""
if [[ "$TUNNEL_MODE" == "1" ]]; then
  while [[ -z "$CF_TOKEN" ]]; do
    read -rsp "  Paste Cloudflare Tunnel Token: " CF_TOKEN
    echo ""
    [[ -z "$CF_TOKEN" ]] && warn "Token cannot be empty."
  done
  read -rp "  Enter your Public Tunnel Hostname (e.g., proxy.yourdomain.com): " CF_HOST
  CF_HOST="${CF_HOST:-proxy.yourdomain.com}"
fi

AUTO_IP=$(curl -4 -fsSL https://ifconfig.me 2>/dev/null || echo "1.2.3.4")
read -rp "  VPS Public IPv4 [${AUTO_IP}]: " VPS_IP
VPS_IP="${VPS_IP:-$AUTO_IP}"

echo ""
read -rp "  Enable REALITY direct fallback on port 443? [Y/n]: " ENABLE_REALITY
ENABLE_REALITY="${ENABLE_REALITY:-Y}"
[[ "$ENABLE_REALITY" =~ ^[Yy] ]] && ENABLE_REALITY=true || ENABLE_REALITY=false

# ── 6. Generate Keys & Configs ────────────────────────────────────────────────
banner "Step 5/5: Generating Keys & Starting Services"

UUID=$(xray uuid)
WS_PATH="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"

REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
REALITY_SHORT_ID=""
REALITY_JSON=""

if [[ "$ENABLE_REALITY" == "true" ]]; then
  KEYS=$(xray x25519)
  REALITY_PRIVATE_KEY=$(echo "$KEYS" | grep "Private key" | awk '{print $NF}')
  REALITY_PUBLIC_KEY=$(echo "$KEYS"  | grep "Public key"  | awk '{print $NF}')
  REALITY_SHORT_ID=$(tr -dc 'a-f0-9' </dev/urandom | head -c 8)

  REALITY_JSON=",
    {
      \"tag\": \"inbound-reality\",
      \"port\": 443,
      \"listen\": \"0.0.0.0\",
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [
          {
            \"id\": \"${UUID}\",
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

# Write Xray JSON
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "inbound-ws",
      "port": 8080,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}", "level": 0 } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "${WS_PATH}" }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }${REALITY_JSON}
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "outboundTag": "block", "ip": ["geoip:private"] },
      { "type": "field", "outboundTag": "direct", "network": "tcp,udp" }
    ]
  }
}
EOF

# Restart Xray service
systemctl restart xray
systemctl enable xray
success "Xray service active"

# Configure Cloudflared Service
if [[ "$TUNNEL_MODE" == "1" ]]; then
  cloudflared service install "$CF_TOKEN" 2>/dev/null || true
  systemctl restart cloudflared
  systemctl enable cloudflared
  success "Cloudflare Zero Trust Tunnel running"
else
  cat > /etc/systemd/system/cf-tunnel.service <<EOF
[Unit]
Description=Cloudflare Quick Tunnel
After=network.target xray.service

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:8080
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now cf-tunnel
  success "Cloudflare Quick Tunnel running"
  sleep 3
fi

# Configure Firewall
if command -v ufw &>/dev/null; then
  ufw allow ssh >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
fi

# Determine Tunnel URL for output
if [[ "$TUNNEL_MODE" == "1" ]]; then
  FINAL_TUNNEL_HOST="$CF_HOST"
else
  # Extract trycloudflare.com URL from journal logs
  FINAL_TUNNEL_HOST=$(journalctl -u cf-tunnel -n 50 --no-pager 2>/dev/null | grep -o 'https://[-a-z0-9]*\.trycloudflare\.com' | tail -n 1 | sed 's|https://||' || echo "CHECK_JOURNALCTL")
fi

# Construct VLESS URIs
TUNNEL_URI="vless://${UUID}@${FINAL_TUNNEL_HOST}:443?type=ws&security=tls&path=${WS_PATH}&host=${FINAL_TUNNEL_HOST}&sni=${FINAL_TUNNEL_HOST}#CF-Tunnel"
REALITY_URI="vless://${UUID}@${VPS_IP}:443?type=tcp&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}#Direct-REALITY"

# Save info file on VPS
cat > /root/vpn_info.txt <<EOF
UUID=${UUID}
WS_PATH=${WS_PATH}
TUNNEL_HOST=${FINAL_TUNNEL_HOST}
VPS_IP=${VPS_IP}

TUNNEL_URI=${TUNNEL_URI}
REALITY_URI=${REALITY_URI}
EOF
chmod 600 /root/vpn_info.txt

# ── 7. Display Results ────────────────────────────────────────────────────────
banner "🎉 DEPLOYMENT COMPLETE 🎉"

echo -e "${BOLD}1. Cloudflare Tunnel Profile (Primary — hides VPS IP):${NC}"
echo -e "${CYAN}${TUNNEL_URI}${NC}\n"

if command -v qrencode &>/dev/null && [[ "$FINAL_TUNNEL_HOST" != "CHECK_JOURNALCTL" ]]; then
  echo -e "${BOLD}Scan with Hiddify / v2rayNG on Mobile:${NC}"
  qrencode -t ANSIUTF8 "$TUNNEL_URI"
  echo ""
fi

if [[ "$ENABLE_REALITY" == "true" ]]; then
  echo -e "${BOLD}2. REALITY Direct Profile (Fallback — direct fast connection):${NC}"
  echo -e "${CYAN}${REALITY_URI}${NC}\n"
fi

if [[ "$TUNNEL_MODE" == "2" && "$FINAL_TUNNEL_HOST" == "CHECK_JOURNALCTL" ]]; then
  echo -e "${YELLOW}Note: Quick Tunnel URL is initializing. Run this command to see your URL:${NC}"
  echo "  sudo journalctl -u cf-tunnel -n 20 --no-pager | grep trycloudflare"
  echo ""
fi

echo -e "${BOLD}Configuration saved to:${NC} /root/vpn_info.txt"
echo -e "${GREEN}Import the link above into Hiddify (Windows/Android/iOS) or v2rayN!${NC}\n"
